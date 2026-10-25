import 'dart:io';

import 'package:window_manager/window_manager.dart';

import 'loopback_oauth.dart';
import 'msix_paths.dart';
import 'windows_tools.dart';

/// Ritorno nell'app dopo l'accesso nel browser (OneDrive, Google Drive,
/// calendario Outlook, Google Picker) su PC e Mac.
///
/// - Il server locale riceve il ritorno del browser e chiama
///   [onBrowserReturn]: la finestra dell'app torna in primo piano (anche se
///   era ridotta a icona o nell'area di notifica) e mostra l'esito.
/// - La pagina nel browser apre subito `uninotes://auth` ([kAppReturnUrl]):
///   su Windows lo schema si registra qui per l'utente corrente (oltre che
///   dall'installatore e dal manifest del Microsoft Store) e la seconda
///   istanza aperta dal browser porta in primo piano la prima e si chiude
///   (windows/runner/main.cpp); su macOS lo schema è nell'Info.plist e il
///   sistema riattiva l'app già aperta.
abstract final class AppReturn {
  static Future<void> init() async {
    if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return;
    onBrowserReturn = bringToFront;
    if (Platform.isWindows && MsixPaths.packageFamilyName() == null) {
      await registerWindowsScheme(Platform.resolvedExecutable);
    }
  }

  /// Finestra dell'app davanti al browser. Windows non lascia prendere il
  /// primo piano a un'app in secondo piano: «sempre in primo piano» per un
  /// attimo la porta comunque sopra il browser.
  static Future<void> bringToFront() async {
    if (await windowManager.isMinimized()) await windowManager.restore();
    if (!await windowManager.isVisible()) await windowManager.show();
    await windowManager.setAlwaysOnTop(true);
    await windowManager.focus();
    await windowManager.setAlwaysOnTop(false);
  }

  /// Chiave dello schema per l'utente corrente.
  static const schemeKey = r'HKCU\Software\Classes\uninotes';

  /// Comandi `reg` che registrano `uninotes://` per [exe] (Windows).
  static List<List<String>> registerCommands(String exe) => [
    ['add', schemeKey, '/ve', '/d', 'URL:UniNotes', '/f'],
    ['add', schemeKey, '/v', 'URL Protocol', '/d', '', '/f'],
    ['add', '$schemeKey\\DefaultIcon', '/ve', '/d', '"$exe",0', '/f'],
    [
      'add',
      '$schemeKey\\shell\\open\\command',
      '/ve',
      '/d',
      '"$exe" "%1"',
      '/f',
    ],
  ];

  /// Programma a cui punta lo schema nell'output di `reg query` (null =
  /// non registrato).
  static String? registeredExe(String regQueryOutput) =>
      RegExp(r'"([^"]+\.exe)"', caseSensitive: false)
          .firstMatch(regQueryOutput)
          ?.group(1);

  /// Registra lo schema se manca o punta a un programma che non c'è più
  /// (cartella spostata, vecchia installazione); se è già registrato
  /// (dall'installatore o da questa copia) non si tocca. Errori ignorati:
  /// senza schema resta il pulsante della pagina e la finestra torna
  /// comunque davanti.
  static Future<void> registerWindowsScheme(String exe) async {
    try {
      final q = await Process.run(WindowsTools.reg, [
        'query',
        r'HKCR\uninotes\shell\open\command',
        '/ve',
      ]);
      final current = q.exitCode == 0 ? registeredExe('${q.stdout}') : null;
      if (current != null && await File(current).exists()) return;
      for (final args in registerCommands(exe)) {
        await Process.run(WindowsTools.reg, args);
      }
    } catch (_) {}
  }
}
