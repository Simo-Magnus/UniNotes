import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

class DownloadException implements Exception {
  DownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Download annullato dall'utente: il file parziale resta e si riprende.
class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download annullato.';
}

/// Annullamento di un download in corso.
class CancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
  }

  /// [f] viene chiamata all'annullamento (subito se già annullato).
  void addListener(void Function() f) {
    if (_cancelled) {
      f();
    } else {
      _listeners.add(f);
    }
  }

  void removeListener(void Function() f) => _listeners.remove(f);
}

class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;

  /// null = dimensione sconosciuta.
  final int? total;
  double? get fraction =>
      (total == null || total == 0) ? null : (received / total!).clamp(0, 1);

  String get label =>
      total == null ? mb(received) : '${mb(received)} di ${mb(total!)}';

  static String mb(int bytes) {
    final m = bytes / (1024 * 1024);
    if (m >= 1024) {
      return '${(m / 1024).toStringAsFixed(1).replaceAll('.', ',')} GB';
    }
    return '${m.round()} MB';
  }
}

/// Download di file grandi (modelli Whisper, programmi) con avanzamento,
/// annullamento, ripresa (`Range`), controllo dello spazio libero e verifica
/// facoltativa dell'impronta SHA-1.
class FileDownloader {
  FileDownloader({
    HttpClient Function()? httpClientFactory,
    Future<int?> Function(Directory dir)? freeSpace,
  }) : _http = httpClientFactory ?? HttpClient.new,
       _freeSpace = freeSpace ?? defaultFreeSpace;

  final HttpClient Function() _http;
  final Future<int?> Function(Directory dir) _freeSpace;

  /// Margine lasciato libero sul disco oltre al file.
  static const spaceMargin = 200 * 1024 * 1024;

  /// Scarica [url] in [target] (prima in `<target>.part`, poi rinominato).
  /// [expectedBytes] serve al controllo dello spazio prima di iniziare;
  /// [sha1] o [sha256] (esadecimali) verificano il file completo (lo
  /// SHA-256 è quello che Hugging Face pubblica per i file grandi).
  Stream<DownloadProgress> download(
    Uri url,
    File target, {
    CancelToken? cancel,
    int? expectedBytes,
    String? sha1,
    String? sha256,
  }) async* {
    final part = File('${target.path}.part');
    await target.parent.create(recursive: true);
    final client = _http()..connectionTimeout = const Duration(seconds: 30);
    void abort() => client.close(force: true);
    if (cancel != null && !cancel.isCancelled) cancel._listeners.add(abort);
    try {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      var start = await part.exists() ? await part.length() : 0;
      if (expectedBytes != null) {
        await _checkSpace(target.parent, expectedBytes - start);
      }
      var uri = url;
      HttpClientResponse res;
      // Segue i reindirizzamenti (GitHub e Hugging Face usano CDN).
      for (var hops = 0; ; hops++) {
        final req = await client.getUrl(uri);
        req.followRedirects = false;
        if (start > 0) {
          req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
        }
        res = await req.close();
        if (res.isRedirect && hops < 8) {
          final loc = res.headers.value(HttpHeaders.locationHeader);
          await res.drain<void>();
          if (loc == null) break;
          uri = uri.resolve(loc);
          // mai da https a http (o ad altri schemi) durante un download
          if (!uri.isScheme('https') && url.isScheme('https')) {
            throw HttpException('Reindirizzamento non sicuro', uri: uri);
          }
          continue;
        }
        break;
      }
      if (res.statusCode == 416) {
        // Già completo.
        await res.drain<void>();
      } else {
        if (res.statusCode != 200 && res.statusCode != 206) {
          await res.drain<void>();
          throw DownloadException(switch (res.statusCode) {
            404 => 'File non trovato su ${url.host} (errore 404).',
            401 ||
            403 => 'Download negato da ${url.host} (errore ${res.statusCode}).',
            _ =>
              'Download non riuscito (errore ${res.statusCode}) da ${url.host}.',
          });
        }
        if (res.statusCode == 200) start = 0;
        final total = res.contentLength < 0 ? null : start + res.contentLength;
        if (expectedBytes == null && total != null) {
          await _checkSpace(target.parent, total - start);
        }
        final sink = part.openWrite(
          mode: res.statusCode == 206 ? FileMode.append : FileMode.write,
        );
        var got = start;
        var lastPct = -1;
        yield DownloadProgress(got, total);
        try {
          await for (final chunk in res) {
            if (cancel?.isCancelled ?? false) throw DownloadCancelled();
            sink.add(chunk);
            got += chunk.length;
            final pct = total == null ? got ~/ (1 << 20) : got * 100 ~/ total;
            if (pct != lastPct) {
              lastPct = pct;
              yield DownloadProgress(got, total);
            }
          }
        } finally {
          await sink.close();
        }
        if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      }
      if (sha1 != null && sha1.isNotEmpty) {
        final digest = await sha1Of(part);
        if (digest.toLowerCase() != sha1.toLowerCase()) {
          await part.delete();
          throw DownloadException(
            'Il file scaricato è danneggiato (impronta SHA-1 diversa): '
            'riprova il download.',
          );
        }
      }
      if (sha256 != null && sha256.isNotEmpty) {
        final digest = await sha256Of(part);
        if (digest.toLowerCase() != sha256.toLowerCase()) {
          await part.delete();
          throw DownloadException(
            'Il file scaricato è danneggiato (impronta SHA-256 diversa): '
            'riprova il download.',
          );
        }
      }
      if (await target.exists()) await target.delete();
      await part.rename(target.path);
    } on DownloadCancelled {
      rethrow;
    } on SocketException {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      throw DownloadException(
        'Download interrotto: controlla la connessione. Riprovando riparte da '
        'dove si era fermato.',
      );
    } on HttpException catch (e) {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      throw DownloadException('Download interrotto: ${e.message}. Riprova.');
    } finally {
      cancel?.removeListener(abort);
      client.close(force: true);
    }
  }

  /// Errore se nella cartella [dir] non ci sono [needed] byte liberi (più
  /// il margine): per più file da scaricare insieme.
  Future<void> checkSpace(Directory dir, int needed) =>
      _checkSpace(dir, needed);

  Future<void> _checkSpace(Directory dir, int needed) async {
    if (needed <= 0) return;
    int? free;
    try {
      free = await _freeSpace(dir);
    } catch (_) {
      free = null;
    }
    if (free != null && free < needed + spaceMargin) {
      throw DownloadException(
        'Spazio insufficiente: servono ${DownloadProgress.mb(needed + spaceMargin)} '
        'liberi, ce ne sono ${DownloadProgress.mb(free)}. Libera spazio e riprova.',
      );
    }
  }

  static Future<String> sha1Of(File f) async =>
      (await sha1.bind(f.openRead()).first).toString();

  static Future<String> sha256Of(File f) async =>
      (await sha256.bind(f.openRead()).first).toString();

  /// Spazio libero sul disco di [dir] (null = non determinabile).
  static Future<int?> defaultFreeSpace(Directory dir) async {
    try {
      if (Platform.isWindows) {
        final root = dir.absolute.path.substring(0, 3);
        final r = await Process.run('powershell', [
          '-NoProfile',
          '-Command',
          "([System.IO.DriveInfo]::new('$root')).AvailableFreeSpace",
        ]);
        return int.tryParse('${r.stdout}'.trim());
      }
      if (Platform.isIOS) return null;
      final r = await Process.run('df', ['-Pk', dir.path]);
      if (r.exitCode != 0) return null;
      final lines = '${r.stdout}'.trim().split('\n');
      if (lines.length < 2) return null;
      final cols = lines.last.trim().split(RegExp(r'\s+'));
      if (cols.length < 4) return null;
      final kb = int.tryParse(cols[3]);
      return kb == null ? null : kb * 1024;
    } catch (_) {
      return null;
    }
  }
}
