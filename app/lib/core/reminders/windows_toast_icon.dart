import 'dart:io';

import 'windows_aumid.dart';

/// Icona dell'app in cima ai toast di Windows (accanto a «UniNotes»).
///
/// Per un'app non pacchettizzata Windows prende nome e icona dalla chiave
/// `HKCU\Software\Classes\AppUserModelId\<AUMID>` (DisplayName, IconUri):
/// flutter_local_notifications la scrive a ogni avvio, all'inizializzazione
/// e quindi prima di qualsiasi toast, con il percorso del logo
/// (`iconPath`). È vuota se il percorso non gli arriva: rete di sicurezza,
/// dopo l'inizializzazione l'app controlla la chiave e, se l'IconUri manca o
/// punta a un file che non c'è più (cartella spostata, vecchia
/// installazione), la riscrive con il percorso assoluto del PNG dell'app
/// (`data\flutter_assets\assets\notifiche\uninotes.png` accanto
/// all'eseguibile). Windows memorizza nome e icona di un AUMID al primo
/// toast: per questo l'AUMID è cambiato (vedi [WindowsAumid]).
abstract final class WindowsToastIcon {
  /// Chiave del registro dell'AUMID [aumid].
  static String keyFor(String aumid) =>
      r'HKCU\Software\Classes\AppUserModelId\' + aumid;

  /// IconUri letto dall'output di `reg query <chiave> /v IconUri` (null =
  /// assente o vuoto).
  static String? iconUriOf(String regQueryOutput) {
    for (final line in regQueryOutput.split('\n')) {
      final m = RegExp(r'^\s*IconUri\s+REG_(?:EXPAND_)?SZ\s*(.*)$')
          .firstMatch(line.trimRight());
      if (m == null) continue;
      final v = m.group(1)!.trim();
      return v.isEmpty ? null : v;
    }
    return null;
  }

  /// Serve riscrivere l'IconUri? Sì se manca o il file non c'è più, oppure
  /// è diverso da [wanted] (es. installazione spostata).
  static bool needsUpdate(String? current, String wanted, bool currentExists) =>
      current == null || !currentExists || current.toLowerCase() != wanted.toLowerCase();

  /// Controlla e corregge la chiave dell'AUMID [aumid] (errori ignorati: il
  /// toast resta solo senza logo).
  static Future<void> ensure(
    String? iconPath, {
    String aumid = WindowsAumid.current,
  }) async {
    if (!Platform.isWindows || iconPath == null) return;
    final key = keyFor(aumid);
    try {
      if (!await File(iconPath).exists()) return;
      final q = await Process.run('reg', ['query', key, '/v', 'IconUri']);
      final current = q.exitCode == 0 ? iconUriOf('${q.stdout}') : null;
      final exists = current != null && await File(current).exists();
      if (!needsUpdate(current, iconPath, exists)) return;
      await Process.run('reg', [
        'add',
        key,
        '/v',
        'IconUri',
        '/t',
        'REG_SZ',
        '/d',
        iconPath,
        '/f',
      ]);
    } catch (_) {}
  }
}
