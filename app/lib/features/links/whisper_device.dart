import 'dart:ffi';
import 'dart:io';

import '../../core/services/file_downloader.dart';
import 'whisper_models.dart';

/// Il dispositivo su cui gira l'app, per consigliare il modello Whisper da
/// scaricare («Consigliato per questo dispositivo») e scegliere fra i
/// modelli scaricati quello che regge: RAM, core della CPU, piattaforma e
/// spazio libero. Senza pacchetti in più: RAM letta da `/proc/meminfo`
/// (Android, Linux), `GlobalMemoryStatusEx` (Windows) e `sysctl hw.memsize`
/// (macOS, iOS).
class DeviceProfile {
  const DeviceProfile({
    required this.platform,
    this.ramBytes,
    this.cores = 4,
    this.freeBytes,
  });

  final WhisperPlatform platform;

  /// RAM totale (null = non si sa).
  final int? ramBytes;
  final int cores;

  /// Spazio libero nella cartella dei modelli (null = non si sa).
  final int? freeBytes;

  bool get phone => platform == WhisperPlatform.phone;

  /// RAM in GB arrotondata («8 GB»), null se non si sa.
  int? get ramGb => ramBytes == null ? null : (ramBytes! / 1e9).round();

  /// «RAM 16 GB · 8 core · 120 GB liberi».
  String get summary => [
    if (ramGb != null) 'RAM $ramGb GB',
    '$cores core',
    if (freeBytes != null) '${(freeBytes! / 1e9).floor()} GB liberi',
  ].join(' · ');
}

/// Il dispositivo [d] regge il modello [m]: piattaforma giusta e RAM
/// sufficiente (al massimo il 40% della RAM sul telefono, il 60% su PC e
/// Mac, perché l'app e il sistema restano aperti).
bool deviceCanRun(WhisperModelInfo m, DeviceProfile d) {
  if (!m.runsOn(d.platform)) return false;
  final ram = d.ramBytes;
  if (ram == null) return true;
  return m.ramBytes <= ram * (d.phone ? 0.4 : 0.6);
}

/// Modello consigliato e perché.
class WhisperRecommendation {
  const WhisperRecommendation(this.model, this.reason);
  final WhisperModelInfo model;
  final String reason;
}

const _gb = 1000 * 1000 * 1000;

/// Margine di spazio da lasciare libero dopo il download.
const _spaceMargin = 500 * 1024 * 1024;

/// Il modello da scaricare più adatto a [d]:
/// - **telefono**: small con almeno 6 GB di RAM e 6 core (discreto in
///   italiano, un'ora di lezione in 20–60 minuti), altrimenti base;
/// - **PC e Mac**: large-v3-turbo q5_0 con almeno 8 GB e 4 core (ottimo in
///   italiano e veloce anche solo con la CPU), small con almeno 4 GB,
///   altrimenti base;
/// - se lo spazio libero non basta si scende al modello più piccolo che ci
///   sta.
///
/// Il modello integrato (base q5_1) c'è già: non si consiglia mai tiny, che
/// in italiano è peggiore.
WhisperRecommendation recommendWhisperModel(DeviceProfile d) {
  final ram = d.ramBytes;
  final String id;
  final String why;
  final ramText = d.ramGb == null ? '' : '${d.ramGb} GB di RAM e ';
  if (d.phone) {
    if (ram == null || ram >= 6 * _gb * 0.85 && d.cores >= 6) {
      id = kRecommendedPhoneModel;
      why = ram == null
          ? 'buon compromesso fra qualità e tempi sul telefono'
          : '$ramText${d.cores} core: qualità discreta in tempi accettabili';
    } else {
      id = kLightPhoneModel;
      why =
          '$ramText${d.cores} core: un modello più grande sarebbe troppo lento';
    }
  } else if (ram == null || ram >= 8 * _gb * 0.85 && d.cores >= 4) {
    id = kRecommendedDesktopModel;
    why = ram == null
        ? 'ottimo in italiano e veloce anche senza scheda video'
        : '$ramText${d.cores} core: ottimo in italiano e veloce';
  } else if (ram >= 4 * _gb * 0.85) {
    id = 'small';
    why = '$ramText${d.cores} core: i modelli large sarebbero troppo pesanti';
  } else {
    id = 'base';
    why = '${ramText}poca memoria: un modello leggero';
  }
  var model = whisperModelById(id)!;
  final free = d.freeBytes;
  if (free != null && model.approxBytes + _spaceMargin > free) {
    // si scende finché il modello ci sta (dal più accurato al più leggero)
    final smaller =
        [
          for (final m in kWhisperModels)
            if (m.italianOk &&
                m.id != 'tiny' &&
                m.approxBytes < model.approxBytes &&
                deviceCanRun(m, d))
              m,
        ]..sort(
          (a, b) =>
              whisperAccuracyRank(a.id).compareTo(whisperAccuracyRank(b.id)),
        );
    final fits = smaller
        .where((m) => m.approxBytes + _spaceMargin <= free)
        .firstOrNull;
    if (fits != null) {
      model = fits;
      return WhisperRecommendation(
        model,
        'spazio libero ${(free / _gb).toStringAsFixed(1).replaceAll('.', ',')} GB: '
        '$id non ci starebbe',
      );
    }
  }
  return WhisperRecommendation(model, why);
}

/// Legge RAM, core e spazio libero (nella cartella [dir]).
Future<DeviceProfile> probeDevice(
  WhisperPlatform platform, {
  Directory? dir,
}) async {
  int? free;
  if (dir != null) {
    try {
      free = await FileDownloader.defaultFreeSpace(dir);
    } catch (_) {
      free = null;
    }
  }
  return DeviceProfile(
    platform: platform,
    ramBytes: await totalRam(),
    cores: Platform.numberOfProcessors,
    freeBytes: free,
  );
}

/// RAM totale del dispositivo in byte (null se non si riesce a leggerla).
Future<int?> totalRam() async {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      return parseMemInfo(await File('/proc/meminfo').readAsString());
    }
    if (Platform.isWindows) return _windowsRam();
    if (Platform.isMacOS || Platform.isIOS) return _appleRam();
  } catch (_) {
    // non disponibile: si consiglia senza conoscere la RAM
  }
  return null;
}

/// RAM libera adesso in byte (`MemAvailable` su Android e Linux,
/// `os_proc_available_memory` su iOS); null se non si sa.
Future<int?> availableRam() async {
  try {
    if (Platform.isAndroid || Platform.isLinux) {
      return parseMemAvailable(await File('/proc/meminfo').readAsString());
    }
    if (Platform.isIOS) {
      final f = DynamicLibrary.process()
          .lookupFunction<Size Function(), int Function()>(
            'os_proc_available_memory',
          );
      final v = f();
      return v > 0 ? v : null;
    }
  } catch (_) {}
  return null;
}

/// `MemAvailable` di `/proc/meminfo` in byte.
int? parseMemAvailable(String meminfo) {
  final m = RegExp(
    r'^MemAvailable:\s+(\d+)\s*kB',
    multiLine: true,
  ).firstMatch(meminfo);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

/// `MemTotal` di `/proc/meminfo` in byte.
int? parseMemInfo(String meminfo) {
  final m = RegExp(
    r'^MemTotal:\s+(\d+)\s*kB',
    multiLine: true,
  ).firstMatch(meminfo);
  return m == null ? null : int.parse(m.group(1)!) * 1024;
}

/// `GlobalMemoryStatusEx` (MEMORYSTATUSEX da 64 byte, `ullTotalPhys` a 8).
int? _windowsRam() {
  final k32 = DynamicLibrary.open('kernel32.dll');
  final alloc = k32
      .lookupFunction<
        Pointer<Uint8> Function(Uint32, IntPtr),
        Pointer<Uint8> Function(int, int)
      >('LocalAlloc');
  final free = k32
      .lookupFunction<
        Pointer<Void> Function(Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Uint8>)
      >('LocalFree');
  final status = k32
      .lookupFunction<
        Int32 Function(Pointer<Uint8>),
        int Function(Pointer<Uint8>)
      >('GlobalMemoryStatusEx');
  const size = 64;
  final buf = alloc(0x0040, size); // LPTR: memoria azzerata
  if (buf.address == 0) return null;
  try {
    Pointer<Uint32>.fromAddress(buf.address).value = size;
    if (status(buf) == 0) return null;
    return Pointer<Uint64>.fromAddress(buf.address + 8).value;
  } finally {
    free(buf);
  }
}

/// `sysctlbyname("hw.memsize")`.
int? _appleRam() {
  final libc = DynamicLibrary.process();
  final malloc = libc
      .lookupFunction<
        Pointer<Uint8> Function(IntPtr),
        Pointer<Uint8> Function(int)
      >('malloc');
  final free = libc
      .lookupFunction<
        Void Function(Pointer<Uint8>),
        void Function(Pointer<Uint8>)
      >('free');
  final sysctl = libc
      .lookupFunction<
        Int32 Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<IntPtr>,
          Pointer<Void>,
          IntPtr,
        ),
        int Function(
          Pointer<Uint8>,
          Pointer<Uint8>,
          Pointer<IntPtr>,
          Pointer<Void>,
          int,
        )
      >('sysctlbyname');
  const name = 'hw.memsize';
  final buf = malloc(64);
  if (buf.address == 0) return null;
  try {
    // nome (ASCII, terminato da 0), valore a 32, lunghezza a 48
    for (var k = 0; k < name.length; k++) {
      Pointer<Uint8>.fromAddress(buf.address + k).value = name.codeUnitAt(k);
    }
    Pointer<Uint8>.fromAddress(buf.address + name.length).value = 0;
    final value = Pointer<Uint8>.fromAddress(buf.address + 32);
    final len = Pointer<IntPtr>.fromAddress(buf.address + 48)..value = 8;
    if (sysctl(buf, value, len, nullptr, 0) != 0) return null;
    return Pointer<Uint64>.fromAddress(value.address).value;
  } finally {
    free(buf);
  }
}
