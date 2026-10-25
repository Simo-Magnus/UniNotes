import 'dart:io';

/// Programmi di sistema di Windows avviati dall'app (`reg`, `cmdkey`,
/// PowerShell, Esplora file), con il percorso completo nella cartella di
/// Windows.
///
/// Con il solo nome («reg») Windows cerca il programma prima nella cartella
/// di uninotes.exe e nella cartella di lavoro del processo, poi in System32:
/// un `reg.exe` messo in una di quelle cartelle partirebbe al posto di quello
/// di sistema (CWE-427). Con il percorso completo parte sempre quello vero.
abstract final class WindowsTools {
  /// Cartella di Windows (`%SystemRoot%`, di solito C:\Windows).
  static String get windowsDir {
    final root =
        Platform.environment['SystemRoot'] ?? Platform.environment['windir'];
    return (root == null || root.isEmpty) ? r'C:\Windows' : root;
  }

  static String _system32(String exe) => '$windowsDir\\System32\\$exe';

  static String get reg => _system32('reg.exe');
  static String get cmdkey => _system32('cmdkey.exe');
  static String get rundll32 => _system32('rundll32.exe');
  static String get powershell =>
      _system32(r'WindowsPowerShell\v1.0\powershell.exe');
  static String get explorer => '$windowsDir\\explorer.exe';
}
