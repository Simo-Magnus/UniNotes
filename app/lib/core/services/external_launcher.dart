import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'msix_paths.dart';
import 'windows_tools.dart';

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

  /// «Apri in OneNote» di una pagina letta da Microsoft Graph
  /// (`oneNoteClientUrl`, come `onenote:https://d.docs.live.net/…`): lo
  /// schema `onenote:` non è fra quelli di [openUrl] e si apre solo da qui,
  /// solo seguito da un indirizzo `https:` (mai `onenote:` con un file
  /// locale o di rete). Se l'app OneNote non c'è e [fallbackWebUrl] è
  /// dato, si apre la pagina nel browser.
  static Future<LaunchResult> openOneNote(
    String url, {
    String? fallbackWebUrl,
  }) async {
    if (!isOneNoteClientUrl(url)) {
      return LaunchResult.error('Link non consentito: $url');
    }
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return const LaunchResult.ok();
      }
    } catch (_) {}
    if (fallbackWebUrl != null) return openUrl(fallbackWebUrl);
    return const LaunchResult.error(
      'Impossibile aprire l\'app OneNote: è installata? Prova «Apri nel '
      'browser».',
    );
  }

  /// Indirizzo `onenote:https://…` senza spazi né caratteri di controllo.
  static bool isOneNoteClientUrl(String url) {
    if (!url.toLowerCase().startsWith('onenote:https://')) return false;
    if (url.codeUnits.any((c) => c <= 0x20 || c == 0x7F)) return false;
    try {
      final inner = Uri.parse(url.substring('onenote:'.length));
      return inner.scheme == 'https' && inner.host.isNotEmpty;
    } on FormatException {
      return false;
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
    // altri tipi che Windows o macOS eseguono o installano all'apertura
    '.msc',
    '.msix',
    '.msixbundle',
    '.appx',
    '.appxbundle',
    '.appinstaller',
    '.application',
    '.appref-ms',
    '.gadget',
    '.inf',
    '.jnlp',
    '.library-ms',
    '.ps1xml',
    '.psc1',
    '.scf',
    '.sct',
    '.search-ms',
    '.searchconnector-ms',
    '.settingcontent-ms',
    '.shb',
    '.ws',
    '.wsc',
    '.xbap',
    '.xll',
    '.diagcab',
    '.desktop',
    '.workflow',
    '.terminal',
    '.pkg',
    '.run',
    // Windows Sandbox con comando d'avvio; macOS: script come .command e
    // collegamenti che aprono un file o un'app; Linux: AppImage
    '.wsb',
    '.tool',
    '.fileloc',
    '.inetloc',
    '.appimage',
  };

  /// Script che sul PC e sul Mac si eseguono con un doppio clic se è
  /// installato il loro interprete (Python con il suo «launcher», Perl,
  /// Ruby, Tcl, AutoHotkey, AutoIt) e la Guida HTML compilata (`.chm`, che
  /// può avviare script): con «Apri» non si aprono, con «Apri con…» sì,
  /// perché l'app la sceglie lo studente (un editor). Il lettore di UniNotes
  /// li mostra come testo. Sul telefono nessuno di questi si esegue.
  static const scriptExtensions = {
    '.py',
    '.pyw',
    '.pyz',
    '.pyzw',
    '.pyc',
    '.pyo',
    '.pl',
    '.rb',
    '.rbw',
    '.tcl',
    '.ahk',
    '.au3',
    '.chm',
  };

  /// Estensioni che il sistema può usare per [path]: quella scritta e quella
  /// che resta togliendo ciò che Windows ignora (punti e spazi finali, come
  /// in «setup.exe.», e il flusso NTFS dopo «:», come in «setup.exe::$DATA»).
  static Set<String> _extensionsOf(String path) {
    String ext(String name) {
      final dot = name.lastIndexOf('.');
      return dot < 0 ? '' : name.substring(dot).toLowerCase();
    }

    final name = path.replaceAll(r'\', '/').split('/').last;
    final colon = name.indexOf(':');
    return {
      for (final n in [name, if (colon >= 0) name.substring(0, colon)]) ...{
        ext(n),
        ext(n.replaceAll(RegExp(r'[. ]+$'), '')),
      },
    };
  }

  /// Percorso apribile: locale (non di rete, es. «\\server\cartella») e non
  /// un programma.
  /// Con [explicitChoice] («Apri con…», l'app la sceglie lo studente) gli
  /// [scriptExtensions] sono ammessi.
  static String? unsafePathReason(String path, {bool explicitChoice = false}) {
    final t = path.trim();
    if (t.startsWith(r'\\') || t.startsWith('//')) {
      return 'I percorsi di rete non si aprono dall\'app:\n$path';
    }
    // percorso relativo (libro con un percorso scritto a mano, arrivato da
    // un backup o da un'altra versione): si risolverebbe rispetto alla
    // cartella di lavoro del programma e «Apri cartella» aprirebbe quella
    if (t.isEmpty || p.isRelative(t)) {
      return 'Percorso incompleto (manca la cartella di partenza): non si '
          'può aprire.\n$path';
    }
    if (_extensionsOf(t).any(blockedExtensions.contains)) {
      return 'Per sicurezza i programmi non si aprono dall\'app:\n$path';
    }
    if (!explicitChoice &&
        _desktop(platform()) &&
        _extensionsOf(t).any(scriptExtensions.contains)) {
      return 'Questo script si eseguirebbe aprendolo con il programma '
          'predefinito: usa «Apri con…» e scegli un editor, oppure leggilo '
          'nel lettore di UniNotes.\n$path';
    }
    return null;
  }

  static bool _desktop(TargetPlatform t) =>
      t == TargetPlatform.windows ||
      t == TargetPlatform.macOS ||
      t == TargetPlatform.linux;

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

  /// Canale nativo di «Apri con…» (windows/runner/open_with.cpp,
  /// MainActivity/OpenWith.kt, AppDelegate e MainFlutterWindow).
  static const openWithChannel = MethodChannel(
    'io.github.simomagnus.universitynotes/apri_con',
  );

  /// Piattaforma corrente (sostituibile nei test).
  @visibleForTesting
  static TargetPlatform Function() platform = () => defaultTargetPlatform;

  /// «Apri con…»: la scelta dell'app del sistema, anche se per quel tipo di
  /// file c'è già un'app predefinita (che resta per «Apri»):
  /// - Windows: «Come vuoi aprire questo file?» (SHOpenWithDialog; senza il
  ///   canale `rundll32 shell32.dll,OpenAs_RunDLL`);
  /// - macOS: pannello sulla cartella Applicazioni, poi NSWorkspace;
  /// - Android: Intent.createChooser; iOS: il menu «Apri in…»;
  /// - Linux: `gio open` (l'app predefinita: non c'è una scelta comune a
  ///   tutti i desktop).
  /// Se l'utente chiude la scelta l'esito è ok, senza messaggi.
  static Future<LaunchResult> openWith(String path) async {
    final unsafe = unsafePathReason(path, explicitChoice: true);
    if (unsafe != null) return LaunchResult.error(unsafe);
    final String target;
    try {
      if (!await File(path).exists()) return await openPath(path);
      target = platform() == TargetPlatform.windows
          ? MsixPaths.forOtherApps(path)
          : path;
    } catch (e) {
      // percorso non valido per il sistema (caratteri non ammessi, troppo
      // lungo): esito leggibile invece di un'eccezione
      return LaunchResult.error('Impossibile aprire il file: $e');
    }
    try {
      final r = await openWithChannel.invokeMethod<String>('openWith', {
        'path': target,
      });
      return switch (r) {
        'ok' || 'annullato' => const LaunchResult.ok(),
        'nessuna_app' => const LaunchResult.error(noAppMessage),
        _ => const LaunchResult.error(
          'Impossibile mostrare la scelta dell\'app: il file si apre con '
          'quella predefinita.',
        ),
      };
    } on MissingPluginException {
      return _openWithFallback(target);
    } on PlatformException catch (e) {
      return LaunchResult.error('Impossibile aprire il file: ${e.message}');
    }
  }

  /// Senza il canale nativo (es. build vecchia o Linux).
  static Future<LaunchResult> _openWithFallback(String path) async {
    try {
      switch (platform()) {
        case TargetPlatform.windows:
          // OpenAs_RunDLL legge il resto della riga di comando come percorso
          await Process.start(WindowsTools.rundll32, [
            'shell32.dll,OpenAs_RunDLL',
            path,
          ], mode: ProcessStartMode.detached);
          return const LaunchResult.ok();
        case TargetPlatform.linux:
          // `gio open` usa l'app predefinita, non una scelta: per gli script
          // vale il controllo di «Apri»
          final unsafe = unsafePathReason(path);
          if (unsafe != null) return LaunchResult.error(unsafe);
          await Process.start('gio', [
            'open',
            path,
          ], mode: ProcessStartMode.detached);
          return const LaunchResult.ok();
        default:
          return await openPath(path);
      }
    } catch (_) {
      return openPath(path);
    }
  }

  /// Messaggio quando nessuna app del sistema sa aprire il file.
  static const noAppMessage =
      'Impossibile aprire file: non è stata rilevata nessuna applicazione in '
      'grado di visualizzare il file';

  static Future<LaunchResult> _openWithSystem(String path) async {
    if (Platform.isWindows) {
      // Microsoft Store: il programma che apre il file lo cerca nella
      // cartella vera del pacchetto (vedi MsixPaths)
      final ok = await launchUrl(
        Uri.file(MsixPaths.forOtherApps(path), windows: true),
      );
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
