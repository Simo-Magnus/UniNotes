import 'dart:io';

/// Icona dell'app in cima ai toast di Windows (accanto a «UniNotes»).
///
/// Per un'app non pacchettizzata Windows prende nome e icona dalla chiave
/// `HKCU\Software\Classes\AppUserModelId\<AUMID>` (DisplayName, IconUri):
/// flutter_local_notifications la scrive a ogni avvio, ma con l'IconUri
/// vuoto se il percorso dell'immagine non gli arriva (così era sui PC degli
/// studenti: toast senza logo). Dopo l'inizializzazione delle notifiche
/// l'app controlla la chiave e, se l'IconUri manca o punta a un file che non
/// c'è più (cartella spostata, vecchia installazione), la riscrive con il
/// percorso assoluto del PNG dell'app (`data\flutter_assets\assets\
/// notifiche\uninotes.png` accanto all'eseguibile). Vale anche per chi ha
/// già l'app installata: basta un avvio della versione nuova.
abstract final class WindowsToastIcon {
  static const aumid = 'io.github.simomagnus.universitynotes';
  static const key = r'HKCU\Software\Classes\AppUserModelId\' + aumid;

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

  /// Controlla e corregge la chiave (errori ignorati: il toast resta solo
  /// senza logo).
  static Future<void> ensure(String? iconPath) async {
    if (!Platform.isWindows || iconPath == null) return;
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
