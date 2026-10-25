import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../features/cloud/graph_client.dart' show networkIdleTimeout;

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

  /// Download in corso in tutta l'app, per file di destinazione: due
  /// download dello stesso file (doppio tocco, due modelli che chiedono
  /// whisper.cpp, scheda e seconda passata) scriverebbero sullo stesso
  /// `.part`. Il valore dice se è finito bene.
  static final Map<String, Future<bool>> _active = {};

  static String _key(File f) {
    final path = f.absolute.path;
    return Platform.isWindows || Platform.isMacOS ? path.toLowerCase() : path;
  }

  /// Scarica [url] in [target] (prima in `<target>.part`, poi rinominato).
  /// [expectedBytes] serve al controllo dello spazio prima di iniziare;
  /// [sha1] o [sha256] (esadecimali) verificano il file completo (lo
  /// SHA-256 è quello che Hugging Face pubblica per i file grandi). Se lo
  /// stesso [target] si sta già scaricando, si aspetta quel download e, se è
  /// riuscito, non si riscarica.
  Stream<DownloadProgress> download(
    Uri url,
    File target, {
    CancelToken? cancel,
    int? expectedBytes,
    String? sha1,
    String? sha256,
  }) async* {
    final key = _key(target);
    for (var other = _active[key]; other != null; other = _active[key]) {
      final stop = Completer<bool>();
      void onCancel() => stop.isCompleted ? null : stop.complete(false);
      cancel?.addListener(onCancel);
      final ok = await Future.any([other, stop.future]);
      cancel?.removeListener(onCancel);
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      if (ok && _active[key] == null) {
        try {
          if (await target.exists()) {
            final n = await target.length();
            yield DownloadProgress(n, n);
            return;
          }
        } on FileSystemException {
          // si riscarica
        }
      }
    }
    final done = Completer<bool>();
    _active[key] = done.future;
    var ok = false;
    try {
      yield* _download(
        url,
        target,
        cancel: cancel,
        expectedBytes: expectedBytes,
        sha1: sha1,
        sha256: sha256,
      );
      ok = true;
    } finally {
      // remove() restituisce il Future tolto dalla mappa: chi l'aspetta lo
      // aspetta già, qui non c'è niente da attendere
      // ignore: unawaited_futures
      if (identical(_active[key], done.future)) _active.remove(key);
      done.complete(ok);
    }
  }

  Stream<DownloadProgress> _download(
    Uri url,
    File target, {
    CancelToken? cancel,
    int? expectedBytes,
    String? sha1,
    String? sha256,
  }) async* {
    final part = File('${target.path}.part');
    // attesa massima senza dati (collegamento, risposta, ogni pezzo): una
    // rete caduta senza errore non lascia il download appeso per sempre
    final idle = networkIdleTimeout;
    final client = _http()..connectionTimeout = const Duration(seconds: 30);
    void abort() => client.close(force: true);
    if (cancel != null && !cancel.isCancelled) cancel._listeners.add(abort);
    try {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      await target.parent.create(recursive: true);
      var start = await part.exists() ? await part.length() : 0;
      if (expectedBytes != null) {
        await _checkSpace(target.parent, expectedBytes - start);
      }
      // al massimo una ripartenza da zero (parte non valida: 416 con un'altra
      // dimensione, 206 con un altro intervallo)
      for (var attempt = 0; ; attempt++) {
        var uri = url;
        HttpClientResponse res;
        // Segue i reindirizzamenti (GitHub e Hugging Face usano CDN).
        for (var hops = 0; ; hops++) {
          final req = await client.getUrl(uri).timeout(idle);
          req.followRedirects = false;
          if (start > 0) {
            req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
          }
          res = await req.close().timeout(idle);
          if (res.isRedirect && hops < 8) {
            final loc = res.headers.value(HttpHeaders.locationHeader);
            await _drain(res, idle);
            if (loc == null) break;
            uri = uri.resolve(loc);
            // mai da https a http (o ad altri schemi) durante un download
            if (!uri.isScheme('https') && url.isScheme('https')) {
              throw HttpException(
                'reindirizzamento non sicuro verso ${uri.host} (rete con '
                'pagina di accesso?)',
                uri: uri,
              );
            }
            continue;
          }
          break;
        }
        final code = res.statusCode;
        final range = res.headers.value(HttpHeaders.contentRangeHeader);
        if (code == 416) {
          await _drain(res, idle);
          // «bytes */N»: la parte è il file intero solo se è lunga N
          final size = int.tryParse(
            RegExp(r'\*/(\d+)').firstMatch(range ?? '')?.group(1) ?? '',
          );
          if (size != null && size != start && attempt == 0) {
            if (await part.exists()) await part.delete();
            start = 0;
            continue;
          }
          break; // già completo
        }
        if (code != 200 && code != 206) {
          await _drain(res, idle);
          throw DownloadException(_statusMessage(url, res));
        }
        // Wi‑Fi con pagina di accesso (o proxy): una pagina HTML al posto
        // del file non sostituisce la parte già scaricata
        if (res.headers.contentType?.mimeType == 'text/html') {
          await _drain(res, idle);
          throw DownloadException(
            'Al posto del file è arrivata una pagina web da ${uri.host}: se '
            'sei su una rete Wi‑Fi pubblica, accedi dalla sua pagina nel '
            'browser e riprova.',
          );
        }
        if (code == 206 &&
            range != null &&
            !range.trim().startsWith('bytes $start-') &&
            attempt == 0) {
          // intervallo diverso da quello chiesto: si riparte da zero (senza
          // Content-Range si crede al server)
          await _drain(res, idle);
          if (await part.exists()) await part.delete();
          start = 0;
          continue;
        }
        if (code == 200) start = 0;
        final total = res.contentLength < 0 ? null : start + res.contentLength;
        if (expectedBytes == null && total != null) {
          await _checkSpace(target.parent, total - start);
        }
        // scrittura attesa pezzo per pezzo: un errore del disco (pieno,
        // cartella sparita) arriva subito e i dati non si accumulano in
        // memoria se la rete è più veloce del disco
        final out = await part.open(
          mode: code == 206 ? FileMode.append : FileMode.write,
        );
        var got = start;
        var lastPct = -1;
        yield DownloadProgress(got, total);
        try {
          await for (final chunk in res.timeout(idle)) {
            if (cancel?.isCancelled ?? false) throw DownloadCancelled();
            await out.writeFrom(chunk);
            got += chunk.length;
            final pct = total == null ? got ~/ (1 << 20) : got * 100 ~/ total;
            if (pct != lastPct) {
              lastPct = pct;
              yield DownloadProgress(got, total);
            }
          }
          await out.flush();
        } finally {
          await out.close();
        }
        if (cancel?.isCancelled ?? false) throw DownloadCancelled();
        if (total != null && got != total) {
          throw HttpException('ricevuti $got byte di $total', uri: uri);
        }
        break;
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
    } on DownloadException {
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
    } on TimeoutException {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      throw DownloadException(
        'Download fermo: nessun dato da ${url.host} per ${idle.inSeconds} s. '
        'Controlla la connessione: riprovando riparte da dove si era fermato.',
      );
    } on TlsException catch (e) {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      throw DownloadException(
        'Connessione sicura con ${url.host} non riuscita (${e.message}): se '
        'sei su una rete Wi‑Fi pubblica, accedi dalla sua pagina nel browser '
        'e riprova.',
      );
    } on FileSystemException catch (e) {
      if (cancel?.isCancelled ?? false) throw DownloadCancelled();
      // 28 = ENOSPC (Android, macOS, Linux), 112 = ERROR_DISK_FULL (Windows)
      final full = const {28, 112}.contains(e.osError?.errorCode);
      throw DownloadException(
        full
            ? 'Spazio sul disco esaurito durante il download: libera spazio e '
                  'riprova (riparte da dove si era fermato).'
            : 'Impossibile scrivere il file scaricato (${e.message}'
                  '${e.path == null ? '' : ': ${e.path}'}). Riprova.',
      );
    } finally {
      cancel?.removeListener(abort);
      client.close(force: true);
    }
  }

  /// Corpo di una risposta che non serve, con un limite di tempo.
  static Future<void> _drain(HttpClientResponse res, Duration idle) =>
      res.drain<void>().timeout(idle).catchError((_) {});

  /// Messaggio per uno stato HTTP di errore (429/503 con `Retry-After`).
  static String _statusMessage(Uri url, HttpClientResponse res) {
    final code = res.statusCode;
    if (code == 429 || code == 503) {
      final secs = int.tryParse(
        res.headers.value(HttpHeaders.retryAfterHeader)?.trim() ?? '',
      );
      final when = secs == null || secs <= 0
          ? 'più tardi'
          : secs < 90
          ? 'fra $secs secondi'
          : 'fra ${(secs / 60).ceil()} minuti';
      return code == 429
          ? 'Troppe richieste a ${url.host} (errore 429): riprova $when.'
          : '${url.host} è momentaneamente non disponibile (errore 503): '
                'riprova $when.';
    }
    return switch (code) {
      404 => 'File non trovato su ${url.host} (errore 404).',
      401 || 403 => 'Download negato da ${url.host} (errore $code).',
      >= 500 =>
        '${url.host} ha un problema (errore $code): riprova più tardi.',
      _ => 'Download non riuscito (errore $code) da ${url.host}.',
    };
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
