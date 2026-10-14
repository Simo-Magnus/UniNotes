import 'dart:io';

import 'package:open_filex/open_filex.dart';
import 'package:url_launcher/url_launcher.dart';

/// Esito di un'apertura esterna, mostrabile all'utente senza crash.
class LaunchResult {
  const LaunchResult.ok() : ok = true, message = null;
  const LaunchResult.error(this.message) : ok = false;
  final bool ok;
  final String? message;
}

/// Apertura di link web e file locali secondo la piattaforma.
class ExternalLauncher {
  /// Schemi che l'app apre all'esterno: web, posta e telefono (link nei
  /// documenti) e i collegamenti di ritorno dagli store. Le mappe non ci
  /// sono più.
  static const allowedSchemes = {
    'http',
    'https',
    'mailto',
    'tel',
    'market',
    'itms-apps',
    'ms-windows-store',
  };

  static Future<LaunchResult> openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (!allowedSchemes.contains(uri.scheme.toLowerCase())) {
        return LaunchResult.error('Link non consentito: $url');
      }
      if (await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        return const LaunchResult.ok();
      }
      return LaunchResult.error('Impossibile aprire $url');
    } catch (e) {
      return LaunchResult.error('Link non valido: $e');
    }
  }

  /// Estensioni di programmi e script: non si avviano mai dall'app (un
  /// percorso arrivato da un file importato potrebbe puntare a un eseguibile).
  static const blockedExtensions = {
    '.exe',
    '.bat',
    '.cmd',
    '.com',
    '.lnk',
    '.ps1',
    '.psm1',
    '.vbs',
    '.vbe',
    '.js',
    '.jse',
    '.wsf',
    '.wsh',
    '.msi',
    '.msp',
    '.scr',
    '.pif',
    '.hta',
    '.reg',
    '.jar',
    '.cpl',
    '.url',
    '.app',
    '.command',
    '.sh',
    '.apk',
  };

  /// Percorso apribile: locale (non di rete, es. «\\server\cartella») e non
  /// un programma.
  static String? unsafePathReason(String path) {
    final t = path.trim();
    if (t.startsWith(r'\\') || t.startsWith('//')) {
      return 'I percorsi di rete non si aprono dall\'app:\n$path';
    }
    final dot = t.lastIndexOf('.');
    final ext = dot < 0 ? '' : t.substring(dot).toLowerCase();
    if (blockedExtensions.contains(ext)) {
      return 'Per sicurezza i programmi non si aprono dall\'app:\n$path';
    }
    return null;
  }

  /// Apre un file locale; se il file non esiste prova ad aprire la cartella
  /// che dovrebbe contenerlo.
  static Future<LaunchResult> openPath(String path) async {
    final unsafe = unsafePathReason(path);
    if (unsafe != null) return LaunchResult.error(unsafe);
    try {
      final file = File(path);
      final dir = Directory(path);
      if (!await file.exists() && !await dir.exists()) {
        final parent = file.parent;
        if (await parent.exists()) {
          await _openWithSystem(parent.path);
          return LaunchResult.error(
            'File non trovato: aperta la cartella in cui dovrebbe trovarsi.\n$path',
          );
        }
        return LaunchResult.error(
          'Percorso non trovato su questo dispositivo:\n$path',
        );
      }
      return await _openWithSystem(path);
    } catch (e) {
      return LaunchResult.error('Impossibile aprire il file: $e');
    }
  }

  /// Messaggio quando nessuna app del sistema sa aprire il file.
  static const noAppMessage =
      'Impossibile aprire file: non è stata rilevata nessuna applicazione in '
      'grado di visualizzare il file';

  static Future<LaunchResult> _openWithSystem(String path) async {
    if (Platform.isWindows) {
      final ok = await launchUrl(Uri.file(path, windows: true));
      return ok
          ? const LaunchResult.ok()
          : const LaunchResult.error(noAppMessage);
    }
    final r = await OpenFilex.open(path);
    return switch (r.type) {
      ResultType.done => const LaunchResult.ok(),
      ResultType.noAppToOpen => const LaunchResult.error(noAppMessage),
      _ => LaunchResult.error('Impossibile aprire il file: ${r.message}'),
    };
  }
}
