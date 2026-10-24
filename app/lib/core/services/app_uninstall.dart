import 'dart:io';

import 'package:flutter/services.dart';

import '../constants/build_flags.dart';

/// Parti dell'installazione che dipendono dalla piattaforma (codice nativo
/// nel canale [channel]: MainFlutterWindow.swift su macOS). L'app non ha un
/// tasto per disinstallarsi: la disinstallazione la fa il sistema. Qui restano
/// l'argomento del disinstallatore di Windows (Inno Setup, vedi
/// [StoreRules.windowsUninstaller]) e l'identità dell'installazione.
class AppUninstall {
  AppUninstall._();

  /// L'avvio [arg] (`--disinstalla`) del disinstallatore di Inno Setup va
  /// gestito: mai nella build del Microsoft Store, dove nessun
  /// disinstallatore lo usa (un avvio con quell'argomento apre l'app).
  static bool handlesUninstallArg(
    List<String> args,
    String arg, {
    StoreRules rules = const StoreRules(),
  }) => rules.windowsUninstaller && args.contains(arg);

  static const channel = MethodChannel(
    'io.github.simomagnus.universitynotes/disinstalla',
  );

  /// Identità dell'installazione: cambia reinstallando l'app, non
  /// aggiornandola sul posto. Windows: data di creazione della cartella del
  /// programma (Inno Setup la ricrea solo dopo una disinstallazione); macOS:
  /// data di creazione e numero di file (inode) del pacchetto UniNotes.app.
  /// Android e iOS: null, perché le preferenze si eliminano con l'app e la
  /// loro assenza basta a riconoscere una nuova installazione.
  /// Microsoft Store: null come su Android e iOS (la disinstallazione
  /// elimina i dati dell'app, e la cartella del programma cambia a ogni
  /// aggiornamento).
  static Future<String?> installIdentity({
    StoreRules rules = const StoreRules(),
  }) async {
    if (rules.microsoftStore) return null;
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
}
