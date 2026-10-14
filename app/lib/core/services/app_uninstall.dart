import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Esito dell'avvio della disinstallazione.
class UninstallResult {
  const UninstallResult.started() : started = true, message = null;
  const UninstallResult.manual(this.message) : started = false;

  /// Il sistema ha preso in carico la disinstallazione (l'app si chiude).
  final bool started;

  /// Cosa deve fare l'utente per finire (null se [started]).
  final String? message;
}

/// Parti della disinstallazione che dipendono dalla piattaforma (codice
/// nativo nel canale [channel]: MainActivity.kt su Android,
/// MainFlutterWindow.swift su macOS).
class AppUninstall {
  AppUninstall._();

  static const channel = MethodChannel(
    'io.github.simomagnus.universitynotes/disinstalla',
  );

  /// Nome del disinstallatore di Inno Setup accanto a `uninotes.exe`.
  static const windowsUninstaller = 'unins000.exe';

  /// Segno «pulizia già fatta» nella cartella del programma: il
  /// disinstallatore avviato dall'app rilancia comunque
  /// `uninotes.exe --disinstalla`, che lo trova e si chiude subito.
  static const windowsCleanupMark = '.pulizia_fatta';

  static File _mark() => File(
    p.join(File(Platform.resolvedExecutable).parent.path, windowsCleanupMark),
  );

  /// `--disinstalla`: la pulizia l'ha già fatta l'app (il segno si toglie).
  static Future<bool> takeWindowsCleanupMark() async {
    try {
      final f = _mark();
      if (!await f.exists()) return false;
      await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Parametri del disinstallatore avviato dall'app: senza finestre né
  /// domande.
  static const windowsUninstallerArgs = [
    '/VERYSILENT',
    '/SUPPRESSMSGBOXES',
    '/NORESTART',
  ];

  /// Identità dell'installazione: cambia reinstallando l'app, non
  /// aggiornandola sul posto. Windows: data di creazione della cartella del
  /// programma (Inno Setup la ricrea solo dopo una disinstallazione); macOS:
  /// data di creazione e numero di file (inode) del pacchetto UniNotes.app.
  /// Android e iOS: null, perché le preferenze si eliminano con l'app e la
  /// loro assenza basta a riconoscere una nuova installazione.
  static Future<String?> installIdentity() async {
    try {
      if (Platform.isWindows) {
        final dir = File(Platform.resolvedExecutable).parent;
        // su Windows «changed» è la data di creazione
        return 'win:${(await dir.stat()).changed.millisecondsSinceEpoch}';
      }
      if (Platform.isMacOS) {
        return await channel.invokeMethod<String>('installIdentity');
      }
    } catch (_) {}
    return null;
  }

  /// Avvia la disinstallazione dove il sistema lo permette; altrimenti
  /// spiega come finire.
  static Future<UninstallResult> uninstall() async {
    if (Platform.isWindows) return _windows();
    if (Platform.isAndroid) {
      try {
        if (await channel.invokeMethod<bool>('uninstall') == true) {
          return const UninstallResult.started();
        }
      } catch (_) {}
      try {
        await channel.invokeMethod<void>('appDetails');
      } catch (_) {}
      return const UninstallResult.manual(
        'Nella pagina «Informazioni app» che si è aperta tocca Disinstalla. '
        'Se non si è aperta: Impostazioni del telefono → App → UniNotes → '
        'Disinstalla.',
      );
    }
    if (Platform.isMacOS) {
      try {
        if (await channel.invokeMethod<bool>('trashApp') == true) {
          return const UninstallResult.started();
        }
      } catch (_) {}
      try {
        await channel.invokeMethod<void>('revealApp');
      } catch (_) {}
      return const UninstallResult.manual(
        'macOS non permette all\'app di spostarsi da sola nel Cestino: nel '
        'Finder che si è aperto trascina UniNotes nel Cestino (oppure tasto '
        'destro → Sposta nel Cestino).',
      );
    }
    if (Platform.isIOS) {
      return const UninstallResult.manual(
        'Per finire: nella schermata Home tieni premuta l\'icona di UniNotes '
        '→ Rimuovi app → Elimina app.',
      );
    }
    return const UninstallResult.manual(
      'Per finire, elimina la cartella del programma.',
    );
  }

  /// Comando PowerShell che aspetta la chiusura dell'app e poi avvia il
  /// disinstallatore [path] (codificato per evitare problemi di virgolette).
  static String windowsDelayedCommand(String path) {
    final quoted = path.replaceAll("'", "''");
    final args = windowsUninstallerArgs.map((a) => "'$a'").join(',');
    return 'Start-Sleep -Seconds 3; '
        "Start-Process -FilePath '$quoted' -ArgumentList $args";
  }

  static Future<UninstallResult> _windows() async {
    final dir = File(Platform.resolvedExecutable).parent;
    final unins = File(p.join(dir.path, windowsUninstaller));
    if (!await unins.exists()) {
      return UninstallResult.manual(
        'Questa copia di UniNotes non è stata installata con '
        'UniNotes_setup.exe (versione .zip): per toglierla elimina la '
        'cartella\n${dir.path}',
      );
    }
    try {
      await _mark().writeAsString('1');
    } catch (_) {}
    // L'app si chiude subito: il disinstallatore parte qualche secondo
    // dopo, quando uninotes.exe non è più in uso.
    final script = base64.encode(
      utf16le(windowsDelayedCommand(unins.path)),
    );
    try {
      await Process.start('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-EncodedCommand',
        script,
      ], mode: ProcessStartMode.detached);
    } catch (_) {
      await Process.start(
        unins.path,
        windowsUninstallerArgs,
        mode: ProcessStartMode.detached,
      );
    }
    return const UninstallResult.started();
  }

  /// Testo in UTF-16LE (formato di `powershell -EncodedCommand`).
  static List<int> utf16le(String s) => [
    for (final u in s.codeUnits) ...[u & 0xff, u >> 8],
  ];
}
