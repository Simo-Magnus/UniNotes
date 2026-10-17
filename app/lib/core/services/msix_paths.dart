import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Percorsi dei file nel pacchetto MSIX (build del Microsoft Store).
///
/// Installata dallo Store, l'app gira con un'identità di pacchetto e Windows
/// scrive i file **nuovi** che crea in AppData (database, libri, materiali,
/// modelli Whisper, cache, file temporanei) nella cartella privata
/// `%LOCALAPPDATA%\Packages\<famiglia>\LocalCache\Roaming|Local\…`, pur
/// mostrandoli all'app (e ai programmi che avvia) al percorso di sempre
/// (`%APPDATA%\UniNotes\UniNotes`…). Gli altri programmi (Esplora file, il
/// lettore PDF, il browser che incolla un file) non li vedono lì: quando un
/// percorso esce dall'app si passa quello vero ([forOtherApps]). I file in
/// Documenti non sono toccati. Alla disinstallazione Windows elimina la
/// cartella del pacchetto.
class MsixPaths {
  MsixPaths._();

  static String? _family;
  static bool _familyRead = false;

  /// Nome della famiglia del pacchetto (es. `12345Nome.UniNotes_abc123`),
  /// null se l'app non è installata da un pacchetto MSIX.
  static String? packageFamilyName() {
    if (_familyRead) return _family;
    _familyRead = true;
    if (!Platform.isWindows) return null;
    try {
      _family = _readFamilyName();
    } catch (_) {
      _family = null;
    }
    return _family;
  }

  /// `GetCurrentPackageFamilyName` (kernel32, Windows 8 e successivi);
  /// memoria presa con `LocalAlloc` per non dipendere da altri pacchetti.
  static String? _readFamilyName() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final getName = k32
        .lookupFunction<
          Int32 Function(Pointer<Uint32>, Pointer<Uint16>),
          int Function(Pointer<Uint32>, Pointer<Uint16>)
        >('GetCurrentPackageFamilyName');
    final alloc = k32
        .lookupFunction<
          Pointer<Void> Function(Uint32, IntPtr),
          Pointer<Void> Function(int, int)
        >('LocalAlloc');
    final free = k32
        .lookupFunction<
          Pointer<Void> Function(Pointer<Void>),
          Pointer<Void> Function(Pointer<Void>)
        >('LocalFree');
    const chars = 256; // il nome è al massimo di 64 + 1 + 13 caratteri
    const lptr = 0x0040; // LPTR: memoria fissa azzerata
    final len = alloc(lptr, 4).cast<Uint32>();
    final buf = alloc(lptr, chars * 2).cast<Uint16>();
    try {
      if (len.address == 0 || buf.address == 0) return null;
      len.value = chars;
      // 0 = ERROR_SUCCESS; 15700 = APPMODEL_ERROR_NO_PACKAGE
      if (getName(len, buf) != 0) return null;
      final units = <int>[];
      for (var i = 0; i < chars; i++) {
        final u = buf[i];
        if (u == 0) break;
        units.add(u);
      }
      return units.isEmpty ? null : String.fromCharCodes(units);
    } finally {
      if (len.address != 0) free(len.cast());
      if (buf.address != 0) free(buf.cast());
    }
  }

  /// [path] come lo vedono gli altri programmi: per l'app installata dallo
  /// Store un file creato dall'app in AppData diventa il suo percorso nella
  /// cartella del pacchetto; altrimenti resta com'è.
  static String forOtherApps(String path) {
    final family = packageFamilyName();
    if (family == null) return path;
    final env = Platform.environment;
    final roaming = env['APPDATA'];
    final local = env['LOCALAPPDATA'];
    if (roaming == null || local == null) return path;
    return mapPath(
          path,
          family: family,
          roaming: roaming,
          local: local,
          exists: (x) =>
              FileSystemEntity.typeSync(x) != FileSystemEntityType.notFound,
        ) ??
        path;
  }

  /// Percorso nella cartella del pacchetto per [path] sotto [roaming]
  /// (`%APPDATA%`) o [local] (`%LOCALAPPDATA%`), se lì esiste ([exists]);
  /// null se [path] non è in AppData o non è stato scritto dall'app
  /// (es. file di un'installazione precedente con UniNotes_setup.exe, che
  /// l'app usa al loro posto).
  @visibleForTesting
  static String? mapPath(
    String path, {
    required String family,
    required String roaming,
    required String local,
    required bool Function(String path) exists,
  }) {
    final ctx = p.Context(style: p.Style.windows);
    final packages = ctx.join(local, 'Packages');
    if (ctx.equals(path, packages) || ctx.isWithin(packages, path)) {
      return null;
    }
    final base = ctx.join(packages, family, 'LocalCache');
    String? candidate;
    for (final (root, sub) in [(roaming, 'Roaming'), (local, 'Local')]) {
      if (ctx.isWithin(root, path)) {
        candidate = ctx.join(base, sub, ctx.relative(path, from: root));
        break;
      }
    }
    if (candidate == null || !exists(candidate)) return null;
    return candidate;
  }
}
