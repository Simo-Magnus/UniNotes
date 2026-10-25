import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart' show ByteData, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/links/whisper_device.dart';
import '../../features/links/whisper_models.dart';
import '../../features/notes/recorder/speech_language.dart';
import '../../repositories/settings_repository.dart';
import 'audio_codec.dart';
import 'file_downloader.dart';
import 'parakeet_service.dart';
import 'power.dart';
import 'whisper_plugin_engine.dart';
import 'whisper_prompt.dart';

export '../../features/links/whisper_device.dart';
export '../../features/links/whisper_models.dart';
export 'file_downloader.dart' show CancelToken, DownloadCancelled;
export 'parakeet_service.dart' show ParakeetService;
export 'whisper_prompt.dart';

class WhisperException implements Exception {
  WhisperException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sistema su cui gira l'app (sostituibile nei test).
enum WhisperHost { windows, linux, macos, android, ios }

/// Motore che esegue la trascrizione.
enum WhisperEngineKind {
  /// `whisper-cli` di whisper.cpp come processo separato (PC, Mac con
  /// Homebrew): legge lezioni di ore senza problemi di memoria.
  cli,

  /// whisper.cpp dentro l'app (telefono, Mac senza `whisper-cli`).
  plugin,
}

/// Opzioni di whisper.cpp per una trascrizione: vocabolario del corso
/// ([prompt], `initial_prompt`), rilevatore di voce Silero ([vad]: niente
/// testo nei silenzi) e soppressione dei token non verbali («[Musica]»,
/// «[BLANK_AUDIO]»), sempre attiva. La lingua ([language]) è sempre fissata:
/// italiano, o inglese per gli insegnamenti in inglese; mai il rilevamento
/// automatico (che con audio lontano o rumoroso sceglie lingue a caso).
class WhisperOptions {
  const WhisperOptions({this.prompt, this.vad, this.language = 'it'});
  final String? prompt;
  final File? vad;

  /// Lingua della lezione: si usa come «it» o «en» ([whisperLanguage]).
  final String language;

  /// «it» o «en» (qualunque altro valore, anche «auto», diventa «it»).
  String get whisperLanguage => lectureLanguage(language);

  static const none = WhisperOptions();

  /// Argomenti di `whisper-cli` (v1.9: `-l`, `--prompt`, `--suppress-nst`,
  /// `--vad`, `--vad-model`).
  List<String> get cliArgs => [
    '-l',
    whisperLanguage,
    '--suppress-nst',
    if (prompt != null && prompt!.trim().isNotEmpty) ...[
      '--prompt',
      prompt!.trim(),
    ],
    if (vad != null) ...['--vad', '--vad-model', vad!.path],
  ];
}

/// Motore di trascrizione: audio + file del modello → segmenti.
abstract class WhisperEngine {
  String get name;
  Future<List<WhisperSegment>> transcribe(
    File audio,
    File model, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    WhisperOptions options = WhisperOptions.none,
  });
}

class WhisperStatus {
  const WhisperStatus({
    required this.engine,
    required this.cli,
    required this.models,
  });

  final WhisperEngineKind engine;

  /// `whisper-cli` trovato (solo motore [WhisperEngineKind.cli]).
  final File? cli;

  /// Id dei modelli scaricati (vedi [kWhisperModels]).
  final Set<String> models;

  bool get engineReady => engine == WhisperEngineKind.plugin || cli != null;
  bool get ready => engineReady && models.isNotEmpty;
}

/// Avanzamento di download o trascrizione (0–1, null = indeterminato).
class WhisperProgress {
  const WhisperProgress(this.phase, this._fraction);
  final String phase;
  final double? _fraction;

  /// Sempre tra 0 e 1, oppure null: un valore non numerico o infinito
  /// (divisione per zero a monte) è «indeterminato», non un NaN che arriva
  /// alle barre e a `floor()`.
  double? get fraction {
    final v = _fraction;
    return v == null || !v.isFinite ? null : v.clamp(0.0, 1.0).toDouble();
  }
}

/// Segmento della trascrizione con l'istante d'inizio (e di fine, se il
/// motore lo indica).
class WhisperSegment {
  const WhisperSegment(this.start, this.text, {this.end});
  final Duration start;
  final Duration? end;
  final String text;
}

/// Trascrizione finita: segmenti e modello usato davvero (può essere il
/// modello integrato se quello scelto non si poteva usare).
class WhisperResult {
  const WhisperResult(this.segments, this.model);
  final List<WhisperSegment> segments;
  final WhisperModelInfo model;
}

/// Whisper pronto per la trascrizione dal vivo: pezzi brevi (WAV mono
/// 16 kHz) uno alla volta, con il modello tenuto in memoria quando si può.
/// Lavora fuori dal thread dell'interfaccia (processo `whisper-cli` o
/// isolate di whisper.cpp), così la registrazione non rallenta.
abstract class LiveWhisper {
  String get modelId;

  /// Modello dal vivo ([kLiveWhisperModel]): abbastanza veloce per
  /// ritrascrivere ogni ~2 s il tratto in corso.
  bool get quick => modelId == kLiveWhisperModel.id;

  /// Vocabolario del corso e VAD (impostati da chi avvia il testo dal vivo).
  WhisperOptions options = WhisperOptions.none;
  Future<List<WhisperSegment>> transcribeWav(File wav16k);
  Future<void> close();
}

/// Trascrizione locale con whisper.cpp, in italiano, senza internet.
///
/// - **Windows**: l'app scarica i binari ufficiali di whisper.cpp
///   (`whisper-bin-x64.zip` dalle release GitHub) ed esegue `whisper-cli`.
/// - **macOS**: whisper.cpp non pubblica binari per macOS. Se è installato
///   con Homebrew (`brew install whisper-cpp`, che fornisce `whisper-cli`
///   con Metal) l'app lo trova in `/opt/homebrew/bin` o `/usr/local/bin`;
///   si può anche indicare a mano un `whisper-cli` compilato dai sorgenti
///   (`cmake -B build && cmake --build build -j --config Release`). Senza
///   `whisper-cli` si usa whisper.cpp incluso nell'app ([WhisperPluginEngine]).
/// - **Android/iOS**: whisper.cpp incluso nell'app ([WhisperPluginEngine]).
/// - **Linux** (sviluppo): `whisper-cli` nel PATH o nella cartella dell'app.
///
/// I modelli ggml si scaricano da Hugging Face (tabella [kWhisperModels]).
/// Su PC e Mac c'è anche **Parakeet** ([parakeet]): fa il testo istantaneo
/// e, scaricato, compare fra i motori di «Trascrivi con…» (id
/// [kParakeetId]); il modello Whisper integrato (base q5_1) resta solo sul
/// telefono. Le app per PC e Mac includono invece **Whisper small q5_1**
/// ([kDesktopWhisperModel], [includedModelFile]): ritrascrive nella lingua
/// della lezione le frasi di Parakeet in un'altra lingua e fa da ripiego
/// quando Parakeet non può girare, senza download.
class WhisperService {
  WhisperService({
    this._settings,
    Future<Directory> Function()? baseDir,
    HttpClient Function()? httpClientFactory,
    Future<int?> Function(Directory dir)? freeSpace,
    Uri? binariesUrl,
    String? binariesSha256,
    Uri? ffmpegUrl,
    String? ffmpegSha256,
    Uri Function(WhisperModelInfo)? modelUrl,
    this.processStarter = Process.start,
    this.processRunner = _run,
    WhisperHost? host,
    WhisperEngine? pluginEngine,
    List<String>? macCliCandidates,
    this._nativeDecoder,
    this._livePlugin,
    Directory? Function()? bundledModels,
    this._cpuSupportsPlugin,
    Future<ByteData> Function(String key)? assetLoader,
    this._builtInAsset,
    this._deviceProbe,
    ParakeetService? parakeet,
    this._includedBytes,
  }) : _parakeetOverride = parakeet,
       _bundledModels = bundledModels ?? _defaultBundledModels,
       _assetLoader = assetLoader ?? rootBundle.load,
       _baseDir = baseDir ?? getApplicationSupportDirectory,
       _downloader = FileDownloader(
         httpClientFactory: httpClientFactory,
         freeSpace: freeSpace,
       ),
       _freeSpace = freeSpace ?? FileDownloader.defaultFreeSpace,
       binariesUrl = binariesUrl ?? defaultBinariesUrl,
       binariesSha256 =
           binariesSha256 ??
           (binariesUrl == null ? defaultBinariesSha256 : null),
       ffmpegUrl = ffmpegUrl ?? defaultFfmpegUrl,
       ffmpegSha256 =
           ffmpegSha256 ?? (ffmpegUrl == null ? defaultFfmpegSha256 : null),
       _modelUrl = modelUrl ?? ((m) => m.downloadUrl),
       host = host ?? currentHost,
       _plugin = pluginEngine,
       _macCandidates = macCliCandidates ?? defaultMacCliCandidates;

  final SettingsRepository? _settings;
  final Future<int?> Function(Directory dir) _freeSpace;
  final Future<Directory> Function() _baseDir;
  final FileDownloader _downloader;
  final Uri binariesUrl;

  /// Impronta SHA-256 attesa per l'archivio di [binariesUrl] (null = nessun
  /// controllo, solo per un indirizzo scelto a mano, es. nei test).
  final String? binariesSha256;
  final Uri ffmpegUrl;

  /// Impronta SHA-256 attesa per l'archivio di [ffmpegUrl] (null = nessun
  /// controllo, solo per un indirizzo scelto a mano, es. nei test).
  final String? ffmpegSha256;
  final Uri Function(WhisperModelInfo) _modelUrl;
  final Future<Process> Function(String, List<String>) processStarter;

  /// Comandi brevi (`which`, `where`, `chmod`, conversione con ffmpeg).
  final Future<ProcessResult> Function(String, List<String>) processRunner;
  final WhisperHost host;

  static Future<ProcessResult> _run(String exe, List<String> args) =>
      Process.run(exe, args);
  final WhisperEngine? _plugin;
  final List<String> _macCandidates;

  /// Conversione in WAV con gli strumenti del sistema (Media Foundation su
  /// Windows, afconvert su macOS): prima scelta per i formati che
  /// whisper-cli non legge (es. le registrazioni .m4a); ffmpeg resta come
  /// riserva.
  final Future<bool> Function(File input, File wav)? _nativeDecoder;
  final LiveWhisper Function(File model, String modelId)? _livePlugin;

  /// Cartella dei modelli inclusi nell'app (PC e Mac: `data/whisper/`
  /// accanto a uninotes.exe, `Contents/Resources/whisper/` sul Mac), null se
  /// non c'è.
  final Directory? Function() _bundledModels;

  /// Dimensione attesa del modello incluso nell'app desktop (null = quella
  /// di [kDesktopWhisperModel]; sostituibile nei test).
  final int? _includedBytes;
  final bool Function()? _cpuSupportsPlugin;

  /// Lettura dell'asset del modello integrato (sostituibile nei test).
  final Future<ByteData> Function(String key) _assetLoader;
  final bool? _builtInAsset;
  final Future<DeviceProfile> Function()? _deviceProbe;
  final ParakeetService? _parakeetOverride;

  /// Parakeet (PC e Mac): testo istantaneo e «Trascrivi con Parakeet».
  late final ParakeetService parakeet =
      _parakeetOverride ??
      ParakeetService(
        baseDir: _baseDir,
        host: host,
        downloader: _downloader,
        assetLoader: _assetLoader,
        device: deviceProfile,
        toWav: wavFor,
      );

  /// Parakeet si può usare adesso: PC o Mac, modello scaricato, RAM
  /// sufficiente.
  Future<bool> parakeetReady() async {
    try {
      final pk = parakeet;
      return pk.platformSupported &&
          await pk.installed() &&
          await pk.unavailableReason() == null;
    } catch (_) {
      return false;
    }
  }

  /// Cartella dei modelli Whisper inclusi nell'app desktop: `data/whisper/`
  /// accanto all'eseguibile (Windows, Linux: windows/CMakeLists.txt la
  /// riempie durante la build), `Contents/Resources/whisper/` nel bundle
  /// (macOS: tool/prepara_modello_whisper_desktop.py prima della firma).
  /// null sul telefono, dove il modello integrato è un asset.
  static Directory? _defaultBundledModels() {
    try {
      final exe = p.dirname(Platform.resolvedExecutable);
      if (Platform.isMacOS) {
        return Directory(
          p.normalize(p.join(exe, '..', 'Resources', 'whisper')),
        );
      }
      if (Platform.isWindows || Platform.isLinux) {
        return Directory(p.join(exe, 'data', 'whisper'));
      }
    } catch (_) {}
    return null;
  }

  /// Il modello Whisper incluso nell'app desktop ([kDesktopWhisperModel],
  /// small q5_1): il file con la dimensione giusta (lo SHA-256 si controlla
  /// durante la build) e un modo per usarlo (whisper.cpp dentro l'app, che
  /// su Windows vuole una CPU con AVX2, oppure `whisper-cli`). null sul
  /// telefono, nelle build senza il modello e se non si può usare. Si legge
  /// da lì, senza copiarlo: non si scarica né si elimina.
  Future<File?> includedModelFile() async {
    if (isPhone) return null;
    final dir = _bundledModels();
    if (dir == null) return null;
    final m = whisperModelById(kDesktopWhisperModel)!;
    final f = File(p.join(dir.path, m.fileName));
    try {
      if (!await f.exists() ||
          await f.length() != (_includedBytes ?? m.approxBytes)) {
        return null;
      }
    } catch (_) {
      return null;
    }
    if (!liveModelSupported && await findCli() == null) return null;
    return f;
  }

  Future<bool> _decodeNative(File input, File wav) async {
    try {
      final custom = _nativeDecoder;
      if (custom != null) return await custom(input, wav);
      final native =
          (host == WhisperHost.windows && Platform.isWindows) ||
          (host == WhisperHost.macos && Platform.isMacOS);
      if (native) return await AudioCodec.instance.toWav(input, wav);
    } catch (_) {
      // conversione nativa non disponibile: si prova ffmpeg
    }
    return false;
  }

  /// [audio] in WAV 16 kHz mono dentro [tmp] (strumenti del sistema, poi
  /// ffmpeg se c'è); null se non si riesce. Per Parakeet.
  Future<File?> wavFor(File audio, Directory tmp) async {
    final wav = File(p.join(tmp.path, 'audio.wav'));
    if (await _decodeNative(audio, wav) && await wav.exists()) return wav;
    final ff = await ffmpeg();
    if (ff == null) return null;
    try {
      final r = await processRunner(ff, [
        '-nostdin',
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        audio.path,
        '-ar',
        '16000',
        '-ac',
        '1',
        wav.path,
      ]);
      return r.exitCode == 0 && await wav.exists() ? wav : null;
    } catch (_) {
      return null;
    }
  }

  /// Impostazione: percorso di un `whisper-cli` scelto a mano.
  static const cliPathKey = 'whisper_cli_path';

  /// Binari ufficiali per Windows x64 (CPU), versione fissata.
  static final defaultBinariesUrl = Uri.parse(
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip',
  );

  /// SHA-256 di [defaultBinariesUrl] (impronta pubblicata da GitHub per
  /// l'allegato della release v1.9.2): l'archivio contiene programmi che
  /// l'app poi avvia, quindi un file diverso (allegato sostituito, rete
  /// manipolata) non si estrae. Va aggiornata insieme alla versione.
  static const defaultBinariesSha256 =
      '49dcc16de826f20bd53d44f947a1ae49dfa81f86cad67a64d80820cb192d674a';

  /// ffmpeg per Windows (solo per convertire le registrazioni .m4a del
  /// telefono): build LGPL ufficiale di BtbN, ~170 MB, scaricata a richiesta.
  /// Versione fissa (ffmpeg 9.0.2, build di fine mese del 30/09/2026, che
  /// BtbN conserva nel tempo, al contrario di «latest» che cambia ogni
  /// giorno), così l'archivio si controlla con [defaultFfmpegSha256].
  static final defaultFfmpegUrl = Uri.parse(
    'https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2026-09-30-13-08/ffmpeg-n9.0.2-17-g2a571b6068-win64-lgpl-9.0.zip',
  );

  /// SHA-256 di [defaultFfmpegUrl] (impronta pubblicata da GitHub per
  /// l'allegato, verificata sul file scaricato il 25/10/2026): ffmpeg è un
  /// programma che l'app avvia, quindi un archivio diverso non si estrae. Va
  /// aggiornata insieme all'indirizzo.
  static const defaultFfmpegSha256 =
      '6b264b9e6019103f601d98c292bd332fd87acf1c5e941ddff4fb71760fe63432';

  /// `whisper-cli` di Homebrew (Apple Silicon e Intel).
  static const defaultMacCliCandidates = [
    '/opt/homebrew/bin/whisper-cli',
    '/usr/local/bin/whisper-cli',
  ];

  /// Formati audio letti da whisper-cli.
  static const supportedAudio = {'.wav', '.flac', '.mp3', '.ogg'};

  static WhisperHost get currentHost {
    if (Platform.isWindows) return WhisperHost.windows;
    if (Platform.isMacOS) return WhisperHost.macos;
    if (Platform.isAndroid) return WhisperHost.android;
    if (Platform.isIOS) return WhisperHost.ios;
    return WhisperHost.linux;
  }

  bool get isPhone => host == WhisperHost.android || host == WhisperHost.ios;

  WhisperPlatform get platform => switch (host) {
    WhisperHost.android || WhisperHost.ios => WhisperPlatform.phone,
    WhisperHost.macos => WhisperPlatform.mac,
    _ => WhisperPlatform.pc,
  };

  /// L'app sa scaricare da sola il programma `whisper-cli`.
  bool get canDownloadCli => host == WhisperHost.windows;

  WhisperEngine get _pluginEngine => _plugin ?? WhisperPluginEngine();

  Future<Directory> _dir(String sub) async {
    final d = Directory(p.join((await _baseDir()).path, 'whisper', sub));
    await d.create(recursive: true);
    return d;
  }

  String get _cliName =>
      host == WhisperHost.windows ? 'whisper-cli.exe' : 'whisper-cli';

  /// `whisper-cli`: scelto a mano, scaricato dall'app, Homebrew o PATH.
  Future<File?> findCli() async {
    if (isPhone) return null;
    final custom = (await _settings?.get(cliPathKey))?.trim();
    if (custom != null && custom.isNotEmpty && await File(custom).exists()) {
      return File(custom);
    }
    final bin = await _dir('bin');
    await for (final e in bin.list(recursive: true)) {
      if (e is File && p.basename(e.path) == _cliName) return e;
    }
    if (host == WhisperHost.macos) {
      for (final c in _macCandidates) {
        if (await File(c).exists()) return File(c);
      }
    }
    if (host == WhisperHost.linux || host == WhisperHost.macos) {
      try {
        final r = await processRunner('which', ['whisper-cli']);
        final path = '${r.stdout}'.trim();
        if (r.exitCode == 0 && path.isNotEmpty) return File(path);
      } on ProcessException {
        // ignorato
      }
    }
    return null;
  }

  Future<void> setCliPath(String? path) async =>
      _settings?.set(cliPathKey, path?.trim());

  Future<WhisperEngineKind> engineKind() async {
    if (isPhone) return WhisperEngineKind.plugin;
    if (host == WhisperHost.macos && await findCli() == null) {
      return WhisperEngineKind.plugin;
    }
    return WhisperEngineKind.cli;
  }

  String get _ffmpegName =>
      host == WhisperHost.windows ? 'ffmpeg.exe' : 'ffmpeg';

  /// ffmpeg scaricato dall'app, di Homebrew o presente nel PATH.
  Future<String?> ffmpeg() async {
    if (isPhone) return null;
    final f = File(p.join((await _dir('ffmpeg')).path, _ffmpegName));
    if (await f.exists()) return f.path;
    if (host == WhisperHost.macos) {
      for (final c in ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']) {
        if (await File(c).exists()) return c;
      }
    }
    try {
      final r = await processRunner(
        host == WhisperHost.windows ? 'where' : 'which',
        ['ffmpeg'],
      );
      if (r.exitCode == 0) {
        final first = '${r.stdout}'.split(RegExp(r'[\r\n]+')).first.trim();
        if (first.isNotEmpty) return first;
      }
    } on ProcessException {
      // ignorato
    }
    return null;
  }

  Stream<WhisperProgress> _download(
    Uri url,
    File target,
    String label, {
    CancelToken? cancel,
    int? expectedBytes,
    String? sha1,
    String? sha256,
  }) async* {
    try {
      await for (final d in _downloader.download(
        url,
        target,
        cancel: cancel,
        expectedBytes: expectedBytes,
        sha1: sha1,
        sha256: sha256,
      )) {
        yield WhisperProgress('$label (${d.label})', d.fraction);
      }
    } on DownloadException catch (e) {
      throw WhisperException(e.message);
    }
  }

  /// Installazioni in corso di whisper.cpp e di ffmpeg: due installazioni
  /// insieme (due modelli scaricati subito, doppio tocco) scaricherebbero e
  /// estrarrebbero lo stesso archivio; la seconda aspetta la prima.
  Completer<void>? _cliInstall, _ffmpegInstall;

  /// Scarica ffmpeg (Windows) ed estrae solo l'eseguibile.
  Stream<WhisperProgress> installFfmpeg({CancelToken? cancel}) async* {
    for (var o = _ffmpegInstall; o != null; o = _ffmpegInstall) {
      yield const WhisperProgress('Attendo l\'altro download di ffmpeg…', null);
      await o.future;
    }
    // (subito, prima di qualsiasi attesa: un'altra installazione partita
    // nello stesso momento deve vederla)
    final lock = _ffmpegInstall = Completer<void>();
    final File exe;
    try {
      final dir = await _dir('ffmpeg');
      exe = File(p.join(dir.path, _ffmpegName));
      if (await exe.exists()) {
        yield const WhisperProgress('Pronto', 1);
        return;
      }
      final zip = File(p.join(dir.path, 'ffmpeg.zip'));
      yield* _download(
        ffmpegUrl,
        zip,
        'Scarico il convertitore ffmpeg',
        cancel: cancel,
        sha256: ffmpegSha256,
      );
      yield const WhisperProgress('Estraggo ffmpeg…', null);
      // prima in un file temporaneo: un'estrazione interrotta (disco pieno,
      // archivio troncato) non lascia un ffmpeg a metà che sembra installato
      final tmp = File('${exe.path}.part');
      InputFileStream? input;
      try {
        input = InputFileStream(zip.path);
        final archive = ZipDecoder().decodeStream(input);
        final entry = archive.files.where(
          (f) => f.isFile && p.basename(f.name) == _ffmpegName,
        );
        if (entry.isEmpty) {
          throw WhisperException(
            'ffmpeg non trovato nell\'archivio scaricato.',
          );
        }
        final out = OutputFileStream(tmp.path);
        try {
          entry.first.writeContent(out);
        } finally {
          await out.close();
        }
        await tmp.rename(exe.path);
      } on WhisperException {
        rethrow;
      } catch (e) {
        throw WhisperException('Archivio di ffmpeg non valido: $e');
      } finally {
        await input?.close();
        for (final f in [zip, tmp]) {
          try {
            if (await f.exists()) await f.delete();
          } catch (_) {}
        }
      }
    } finally {
      _ffmpegInstall = null;
      lock.complete();
    }
    if (host != WhisperHost.windows) {
      await Process.run('chmod', ['+x', exe.path]);
    }
    yield const WhisperProgress('Pronto', 1);
  }

  Future<File> modelFile(WhisperModelInfo m) async =>
      File(p.join((await _dir('models')).path, m.fileName));

  Future<WhisperStatus> status() async {
    final models = <String>{};
    for (final m in kWhisperModels) {
      if (await (await modelFile(m)).exists()) models.add(m.id);
    }
    final kind = await engineKind();
    return WhisperStatus(
      engine: kind,
      cli: kind == WhisperEngineKind.cli ? await findCli() : null,
      models: models,
    );
  }

  /// Download di `whisper-cli` (solo Windows: binari ufficiali).
  Stream<WhisperProgress> installCli({CancelToken? cancel}) async* {
    for (var o = _cliInstall; o != null; o = _cliInstall) {
      yield const WhisperProgress(
        'Attendo l\'altro download di whisper.cpp…',
        null,
      );
      await o.future;
    }
    // (subito, prima di qualsiasi attesa: un'altra installazione partita
    // nello stesso momento deve vederla)
    final lock = _cliInstall = Completer<void>();
    try {
      if (await findCli() != null) return;
      if (!canDownloadCli && host != WhisperHost.linux) {
        throw WhisperException(
          'Su questo sistema whisper-cli non si scarica dall\'app: installalo '
          'con Homebrew («brew install whisper-cpp») oppure indica il file.',
        );
      }
      yield const WhisperProgress('Scarico whisper.cpp…', 0);
      final bin = await _dir('bin');
      final zip = File(p.join(bin.parent.path, 'whisper.zip'));
      yield* _download(
        binariesUrl,
        zip,
        'Scarico whisper.cpp',
        cancel: cancel,
        sha256: binariesSha256,
      );
      yield const WhisperProgress('Estraggo whisper.cpp…', null);
      // prima in una cartella a parte, poi al posto di «bin»: un'estrazione
      // interrotta (disco pieno, archivio troncato) non lascia un
      // whisper-cli a metà che sembra installato
      final staging = Directory(p.join(bin.parent.path, 'bin.part'));
      try {
        try {
          if (await staging.exists()) await staging.delete(recursive: true);
          await extractFileToDisk(zip.path, staging.path);
          if (!await staging
              .list(recursive: true)
              .any((e) => e is File && p.basename(e.path) == _cliName)) {
            throw WhisperException(
              'whisper-cli non trovato nell\'archivio scaricato.',
            );
          }
        } on WhisperException {
          rethrow;
        } catch (e) {
          throw WhisperException('Archivio di whisper.cpp non valido: $e');
        }
        // (più tentativi: un controllo dello stato nel frattempo ricrea
        // «bin» vuota)
        for (var i = 0; ; i++) {
          try {
            if (await bin.exists()) await bin.delete(recursive: true);
            await staging.rename(bin.path);
            break;
          } on FileSystemException catch (e) {
            if (i < 2) continue;
            throw WhisperException(
              'Installazione di whisper.cpp non riuscita (${e.message}): '
              'chiudi eventuali trascrizioni in corso e riprova.',
            );
          }
        }
      } finally {
        for (final e in <FileSystemEntity>[zip, staging]) {
          try {
            if (await e.exists()) await e.delete(recursive: true);
          } catch (_) {}
        }
      }
    } finally {
      _cliInstall = null;
      lock.complete();
    }
    final cli = await findCli();
    if (cli == null) {
      throw WhisperException(
        'whisper-cli non trovato nell\'archivio scaricato.',
      );
    }
    if (host != WhisperHost.windows) {
      try {
        await Process.run('chmod', ['+x', cli.path]);
      } on ProcessException {
        // chmod assente (es. test eseguiti su Windows): niente da fare
      }
    }
  }

  /// Scarica solo il file del modello [m] (riprende i download interrotti,
  /// controlla lo spazio libero e, se noto, lo SHA-1).
  Stream<WhisperProgress> downloadModel(
    WhisperModelInfo m, {
    CancelToken? cancel,
  }) async* {
    final target = await modelFile(m);
    if (!await target.exists()) {
      yield* _download(
        _modelUrl(m),
        target,
        'Scarico ${m.id}',
        cancel: cancel,
        expectedBytes: m.approxBytes,
        sha1: m.sha1,
        sha256: m.sha256,
      );
    }
    yield const WhisperProgress('Pronto', 1);
  }

  /// Programma (se serve e si può scaricare) e modello [m].
  Stream<WhisperProgress> install(
    WhisperModelInfo m, {
    CancelToken? cancel,
  }) async* {
    if (await engineKind() == WhisperEngineKind.cli &&
        await findCli() == null &&
        (canDownloadCli || host == WhisperHost.linux)) {
      yield* installCli(cancel: cancel);
    }
    yield* downloadModel(m, cancel: cancel);
  }

  Future<void> deleteModel(WhisperModelInfo m) async {
    final f = await modelFile(m);
    if (await f.exists()) await f.delete();
    final part = File('${f.path}.part');
    if (await part.exists()) await part.delete();
  }

  /// Byte già scaricati di un download interrotto (per «Riprendi»).
  Future<int> partialBytes(WhisperModelInfo m) async {
    final part = File('${(await modelFile(m)).path}.part');
    return await part.exists() ? part.length() : 0;
  }

  // ------------------------------------------------------------ modello

  /// Modello predefinito scelto in Collegamenti → Whisper (null =
  /// automatico: il più accurato fra quelli scaricati che il dispositivo
  /// regge).
  Future<String?> selectedModelId() async {
    final v = (await _settings?.get(SettingKeys.whisperModel))?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  Future<void> setSelectedModel(String? id) async =>
      _settings?.set(SettingKeys.whisperModel, id);

  Future<DeviceProfile>? _device;

  /// RAM, core e piattaforma (letti una volta; veloce, senza processi).
  Future<DeviceProfile> deviceProfile() => _device ??= () async {
    final probe = _deviceProbe;
    if (probe != null) return probe();
    return probeDevice(platform);
  }();

  /// Modello da scaricare consigliato per questo dispositivo (RAM, core,
  /// piattaforma e spazio libero nella cartella dei modelli).
  Future<WhisperRecommendation> recommendation() async {
    final d = await deviceProfile();
    int? free = d.freeBytes;
    if (free == null) {
      try {
        free = await _freeSpace(await _dir('models'));
      } catch (_) {
        free = null;
      }
    }
    return recommendWhisperModel(
      DeviceProfile(
        platform: d.platform,
        ramBytes: d.ramBytes,
        cores: d.cores,
        freeBytes: free,
      ),
    );
  }

  /// Modello da usare fra quelli di [installed] (id, anche quello
  /// integrato):
  /// 1. [requested] (scelto per questa trascrizione);
  /// 2. il modello predefinito delle impostazioni;
  /// 3. il più accurato che il dispositivo regge ([deviceCanRun]);
  /// 4. il più accurato in assoluto (RAM sconosciuta o tutti troppo
  ///    pesanti: meglio provare che non trascrivere).
  Future<WhisperModelInfo?> pickModel(
    Set<String> installed, {
    String? requested,
    DeviceProfile? device,
  }) async {
    for (final id in [requested, await selectedModelId()]) {
      if (id != null && installed.contains(id)) return whisperModelById(id);
    }
    final known = [
      for (final id in installed)
        if (whisperModelById(id) case final m? when m.italianOk) m,
    ]..sort(_byAccuracy);
    if (known.isEmpty) {
      return installed.isEmpty ? null : whisperModelById(installed.first);
    }
    var d = device;
    if (d == null) {
      try {
        d = await deviceProfile();
      } catch (_) {
        d = null;
      }
    }
    if (d != null) {
      for (final m in known) {
        if (deviceCanRun(m, d)) return m;
      }
    }
    return known.first;
  }

  static int _byAccuracy(WhisperModelInfo a, WhisperModelInfo b) =>
      whisperAccuracyRank(a.id).compareTo(whisperAccuracyRank(b.id));

  /// Motori con cui si può trascrivere adesso: i modelli scaricati (se il
  /// programma c'è), Parakeet su PC e Mac (se scaricato), Whisper small
  /// q5_1 incluso nell'app desktop e il modello integrato sul telefono, dal
  /// più accurato.
  Future<List<WhisperModelInfo>> availableModels({WhisperStatus? known}) async {
    final st = known ?? await status();
    final builtIn = await builtInModelFile() != null;
    final pk = await parakeetReady();
    final downloaded = st.engineReady ? st.models : const <String>{};
    final included =
        !downloaded.contains(kDesktopWhisperModel) &&
        await includedModelFile() != null;
    return [
      for (final id in downloaded) ?whisperModelById(id),
      if (included) whisperModelById(kDesktopWhisperModel)!,
      if (pk) kParakeetModel,
      if (builtIn) kBuiltInWhisperModel,
    ]..sort(_byAccuracy);
  }

  /// Il modello che userebbe «Trascrivi con Whisper» ([requested] se c'è,
  /// altrimenti la scelta automatica); null se non si può trascrivere.
  Future<WhisperModelInfo?> resolveModel({String? requested}) async {
    final ids = {for (final m in await availableModels()) m.id};
    return pickModel(ids, requested: requested);
  }

  // ------------------------------------------------------- dal vivo

  /// Modelli preferiti per la trascrizione dal vivo: abbastanza veloci da
  /// stare al passo con il parlato, ma buoni in italiano.
  static const _livePreference = [
    'large-v3-turbo-q5_0',
    'small',
    // incluso nell'app desktop (kDesktopWhisperModel)
    'small-q5_1',
    'medium-q5_0',
    'large-v3-turbo',
    'large-v3-turbo-q8_0',
    'medium',
    'medium-q8_0',
    'base',
    'tiny',
  ];
  static const _livePhonePreference = [
    'small',
    'base',
    'large-v3-turbo-q5_0',
    'tiny',
    'medium-q5_0',
  ];

  /// Modello per la trascrizione dal vivo fra quelli scaricati (null se
  /// nessuno).
  WhisperModelInfo? pickLiveModel(Set<String> installed) {
    for (final id in isPhone ? _livePhonePreference : _livePreference) {
      if (installed.contains(id)) return whisperModelById(id);
    }
    return installed.isEmpty ? null : whisperModelById(installed.first);
  }

  /// whisper.cpp dentro l'app si può usare per il testo dal vivo. Su
  /// Windows è compilato per CPU con AVX2 (whisper_ggml): su processori più
  /// vecchi (prima del 2013) si userebbe un'istruzione che non hanno.
  bool get liveModelSupported {
    final check = _cpuSupportsPlugin;
    if (check != null) return check();
    if (host != WhisperHost.windows || !Platform.isWindows) return true;
    return _windowsHasAvx2();
  }

  static bool? _avx2;
  static bool _windowsHasAvx2() => _avx2 ??= () {
    try {
      final k32 = DynamicLibrary.open('kernel32.dll');
      final present = k32
          .lookupFunction<Int32 Function(Uint32), int Function(int)>(
            'IsProcessorFeaturePresent',
          );
      // PF_AVX2_INSTRUCTIONS_AVAILABLE
      return present(40) != 0;
    } catch (_) {
      return false;
    }
  }();

  /// Percorso dell'asset con il modello integrato (solo Android e iOS).
  static const builtInAssetKey = 'assets/whisper/ggml-base-q5_1.bin';

  /// Il modello integrato c'è (telefono; vedi `pubspec.yaml`, asset con
  /// `platforms: [android, ios]`). Su PC e Mac il testo istantaneo è di
  /// Parakeet.
  bool get builtInSupported => isPhone;

  /// La build include l'asset (sostituibile nei test: false = build senza
  /// il modello, che si scarica quando serve).
  bool get _hasBuiltInAsset => _builtInAsset ?? true;

  Future<File?>? _copying;
  bool _assetMissing = false;

  /// Il modello integrato (telefono): già copiato o scaricato nella
  /// cartella dei modelli, oppure copiato adesso dall'asset dell'app (la
  /// prima volta). null su PC e Mac e se la build non lo include e non è
  /// ancora stato scaricato.
  Future<File?> builtInModelFile() async {
    if (!builtInSupported) return null;
    final bundled = _bundledModels();
    if (bundled != null) {
      final f = File(p.join(bundled.path, kBuiltInWhisperModel.fileName));
      try {
        if (await f.exists()) return f;
      } catch (_) {}
    }
    final f = await modelFile(kBuiltInWhisperModel);
    if (await f.exists()) return f;
    if (!_hasBuiltInAsset || _assetMissing) return null;
    return _copying ??= _copyBuiltIn(f).whenComplete(() => _copying = null);
  }

  /// Copia l'asset del modello integrato in [target] (file temporaneo poi
  /// rinominato: un'interruzione non lascia un modello a metà).
  Future<File?> _copyBuiltIn(File target) async {
    final tmp = File('${target.path}.copia');
    try {
      final data = await _assetLoader(builtInAssetKey);
      await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      final sha = kBuiltInWhisperModel.sha1;
      if (sha != null && await FileDownloader.sha1Of(tmp) != sha) {
        await tmp.delete();
        _assetMissing = true;
        return null;
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (_) {
      // build senza il modello (asset assente): si scarica quando serve
      _assetMissing = true;
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
      return null;
    }
  }

  /// Il modello dal vivo (= il modello integrato, telefono); null se manca.
  Future<File?> liveModelFile() async =>
      liveModelSupported ? builtInModelFile() : null;

  /// Scarica il modello dal vivo (57 MiB, una volta sola; riprende un
  /// download interrotto).
  Stream<WhisperProgress> downloadLiveModel({CancelToken? cancel}) =>
      downloadModel(kLiveWhisperModel, cancel: cancel);

  /// Whisper per la trascrizione dal vivo: il modello dal vivo con
  /// whisper.cpp dentro l'app (telefono); senza (PC e Mac, dove il primo
  /// motore è Parakeet), il più adatto fra i modelli scaricati dall'utente
  /// e Whisper small q5_1 incluso nell'app desktop ([includedModelFile]).
  /// È anche il motore che ritrascrive le frasi di Parakeet in un'altra
  /// lingua. null se non c'è nessun modello. [options]: vocabolario del
  /// corso, VAD e lingua della lezione.
  Future<LiveWhisper?> liveEngine({
    WhisperOptions options = WhisperOptions.none,
  }) async {
    LiveWhisper? e;
    if (liveModelSupported) {
      final quick = await liveModelFile();
      if (quick != null) {
        e = (_livePlugin ?? PluginLiveWhisper.new)(quick, kLiveWhisperModel.id);
      }
    }
    if (e == null) {
      final st = await status();
      final downloaded = st.engineReady ? st.models : const <String>{};
      final included = downloaded.contains(kDesktopWhisperModel)
          ? null
          : await includedModelFile();
      final m = pickLiveModel({
        ...downloaded,
        if (included != null) kDesktopWhisperModel,
      });
      if (m == null) return null;
      final plugin = _livePlugin ?? PluginLiveWhisper.new;
      final cli = st.cli;
      if (downloaded.contains(m.id)) {
        final model = await modelFile(m);
        e = st.engine == WhisperEngineKind.plugin
            ? plugin(model, m.id)
            : _CliLiveWhisper(this, cli!, model, m.id);
      } else {
        // modello incluso nell'app desktop: whisper-cli se c'è, altrimenti
        // whisper.cpp dentro l'app
        e = cli != null
            ? _CliLiveWhisper(this, cli, included!, m.id)
            : plugin(included!, m.id);
      }
    }
    return e..options = options;
  }

  // ---------------------------------------------------- VAD di whisper.cpp

  Future<File?>? _vadCopy;

  /// Silero VAD in formato ggml per whisper.cpp (asset dell'app, copiato
  /// nella cartella di Whisper al primo uso): niente testo nei silenzi.
  /// null se l'asset manca.
  Future<File?> whisperVadModel() => _vadCopy ??= () async {
    try {
      final target = File(
        p.join((await _dir('vad')).path, 'ggml-silero-v5.1.2.bin'),
      );
      if (await target.exists() && await target.length() == kWhisperVadBytes) {
        return target;
      }
      final data = await _assetLoader(kWhisperVadAsset);
      final tmp = File('${target.path}.copia');
      await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      if (await FileDownloader.sha256Of(tmp) != kWhisperVadSha256) {
        await tmp.delete();
        return null;
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }();

  /// Opzioni di whisper.cpp con il vocabolario del corso [prompt] (vedi
  /// `buildWhisperPrompt`), il VAD, se c'è, e la lingua della lezione
  /// ([language]: «it» o «en», vedi `lectureLanguage`).
  Future<WhisperOptions> optionsFor(
    String? prompt, {
    String language = 'it',
  }) async => WhisperOptions(
    prompt: prompt,
    vad: await whisperVadModel(),
    language: language,
  );

  // ----------------------------------------- seconda passata (telefono)

  /// Impostazione «Seconda passata con small» ('0' = spenta; predefinita
  /// accesa dove il telefono regge).
  static const secondPassKey = 'whisper_second_pass';

  /// Prova del primo uso: secondi di lavoro per secondo di audio di small
  /// q5_1 su questo telefono.
  static const secondPassProbeKey = 'whisper_second_pass_rtf';

  Future<bool> secondPassEnabled() async =>
      (await _settings?.get(secondPassKey)) != '0';

  Future<void> setSecondPass(bool on) async =>
      _settings?.set(secondPassKey, on ? '1' : '0');

  /// Velocità misurata alla prima seconda passata (null = mai provata).
  Future<double?> secondPassProbe() async =>
      double.tryParse((await _settings?.get(secondPassProbeKey)) ?? '');

  Future<void> recordSecondPassProbe(double rtf) async =>
      _settings?.set(secondPassProbeKey, rtf.toStringAsFixed(3));

  /// Il telefono regge la seconda passata: almeno 6 GB di RAM e 6 core,
  /// abbastanza memoria libera adesso e, se già misurata, velocità con
  /// margine (vedi `SecondPassGovernor`).
  Future<String?> secondPassUnfit() async {
    if (!isPhone) return 'Solo sul telefono.';
    final d = await deviceProfile();
    final ram = d.ramBytes;
    if (ram != null && ram < 6e9 * 0.85 || d.cores < 6) {
      return 'Il telefono non ha abbastanza memoria o processori.';
    }
    final free = await availableRam();
    if (free != null && free < 700 << 20) {
      return 'Poca memoria libera adesso.';
    }
    final probe = await secondPassProbe();
    if (probe != null && probe > kSecondPassMaxRtf) {
      return 'Il telefono è troppo lento per small mentre registra.';
    }
    return null;
  }

  /// small q5_1 per la seconda passata (telefono, impostazione accesa,
  /// modello scaricato, telefono adatto); null altrimenti. Il modello non
  /// resta in memoria fra un blocco e l'altro: whisper.cpp ne tiene uno
  /// solo e quello è il modello del testo istantaneo.
  Future<LiveWhisper?> secondPassEngine({
    WhisperOptions options = WhisperOptions.none,
  }) async {
    if (!isPhone || !await secondPassEnabled()) return null;
    if (await secondPassUnfit() != null) return null;
    final m = whisperModelById(kSecondPassModel)!;
    final f = await modelFile(m);
    if (!await f.exists()) return null;
    final e = (_livePlugin ?? PluginLiveWhisper.new)(f, m.id);
    if (e is PluginLiveWhisper) {
      e
        ..keepLoaded = false
        ..threads = 2;
    }
    return e..options = options;
  }

  /// Scarica small q5_1 per la seconda passata se manca (solo con Wi‑Fi,
  /// impostazione accesa, telefono adatto). Non lancia errori.
  Future<void> ensureSecondPassModel({CancelToken? cancel}) async {
    try {
      if (!isPhone || !await secondPassEnabled()) return;
      if (await secondPassUnfit() != null) return;
      final m = whisperModelById(kSecondPassModel)!;
      if (await (await modelFile(m)).exists()) return;
      if (!await Power.onWifi()) return;
      await downloadModel(m, cancel: cancel).drain<void>();
    } catch (_) {}
  }

  // ------------------------------------------------------------ trascrizione

  /// Trascrive [audio] in italiano (o in inglese, [language] «en»).
  /// Restituisce i segmenti con l'orario.
  Future<List<WhisperSegment>> transcribe(
    File audio, {
    String? model,
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    String? prompt,
    String? language,
  }) async => (await transcribeWith(
    audio,
    model: model,
    onProgress: onProgress,
    cancel: cancel,
    prompt: prompt,
    language: language,
  )).segments;

  /// Trascrive [audio] con [model] (null = scelta automatica, vedi
  /// [pickModel]). Se nessun modello Whisper scaricato si può usare
  /// (nessun download, programma whisper.cpp mancante) si usa Parakeet su
  /// PC e Mac o il modello integrato sul telefono. [prompt]: vocabolario
  /// del corso per Whisper (`buildWhisperPrompt`); con Whisper anche il VAD
  /// e la soppressione dei token non verbali.
  ///
  /// [language]: lingua della lezione («it» se null, «en» per gli
  /// insegnamenti in inglese), sempre fissata. Parakeet non permette di
  /// fissarla: le sue frasi in altre lingue si ritrascrivono con Whisper
  /// nella lingua della lezione (small q5_1 incluso nell'app desktop o un
  /// modello scaricato), altrimenti si tolgono (speech_language.dart).
  Future<WhisperResult> transcribeWith(
    File audio, {
    String? model,
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    String? prompt,
    String? language,
  }) async {
    final lang = lectureLanguage(language);
    final st = await status();
    final builtIn = liveModelSupported ? await builtInModelFile() : null;
    final pk = await parakeetReady();
    final downloaded = st.engineReady ? st.models : const <String>{};
    // Whisper small q5_1 incluso nell'app desktop (se non è anche scaricato)
    final included = downloaded.contains(kDesktopWhisperModel)
        ? null
        : await includedModelFile();
    final usable = {
      ...downloaded,
      if (pk) kParakeetId,
      if (builtIn != null) kBuiltInWhisperModel.id,
      if (included != null) kDesktopWhisperModel,
    };
    final m = await pickModel(usable, requested: model);
    if (m == null) {
      throw WhisperException(
        isPhone
            ? 'Whisper non è pronto: scarica un modello da Collegamenti → '
                  'Trascrizione → Whisper.'
            : 'Nessun motore di trascrizione: scarica Parakeet o un modello '
                  'Whisper da Collegamenti → Whisper.',
      );
    }
    if (!await audio.exists()) {
      throw WhisperException('File audio non trovato: ${audio.path}');
    }
    if (m.id == kParakeetId) {
      LiveWhisper? whisper;
      try {
        final segs = await parakeet.transcribeFile(
          audio,
          onProgress: onProgress,
          cancel: cancel,
          language: lang,
          rescue: downloaded.isNotEmpty || included != null
              ? (wav) async {
                  final w = whisper ??= await liveEngine(
                    options: await optionsFor(prompt, language: lang),
                  );
                  return w == null ? const [] : w.transcribeWav(wav);
                }
              : null,
        );
        return WhisperResult(segs, m);
      } finally {
        await whisper?.close();
      }
    }
    final options = await optionsFor(prompt, language: lang);
    final useIncluded = m.id == kDesktopWhisperModel && included != null;
    // il modello integrato gira sempre con whisper.cpp dentro l'app; quello
    // incluso nell'app desktop con whisper-cli, se c'è
    final usesPlugin =
        st.engine == WhisperEngineKind.plugin ||
        m.id == kBuiltInWhisperModel.id ||
        (useIncluded && st.cli == null);
    final modelPath = m.id == kBuiltInWhisperModel.id
        ? builtIn!
        : (useIncluded ? included : await modelFile(m));
    final segs = usesPlugin
        ? await _pluginEngine.transcribe(
            audio,
            modelPath,
            onProgress: onProgress,
            cancel: cancel,
            options: options,
          )
        : await _transcribeCli(
            st.cli!,
            modelPath,
            audio,
            onProgress: onProgress,
            cancel: cancel,
            options: options,
          );
    return WhisperResult([
      for (final s in segs)
        if (!isPromptEcho(s.text, options.prompt)) s,
    ], m);
  }

  Future<List<WhisperSegment>> _transcribeCli(
    File cli,
    File model,
    File audio, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    WhisperOptions options = WhisperOptions.none,
  }) async {
    final out = await Directory.systemTemp.createTemp('whisper_');
    final ext = p.extension(audio.path).toLowerCase();
    if (!supportedAudio.contains(ext)) {
      // Es. registrazioni .m4a: conversione in WAV 16 kHz mono, prima con
      // gli strumenti del sistema, poi (riserva) con ffmpeg.
      final native = File(p.join(out.path, 'audio.wav'));
      if (await _decodeNative(audio, native)) {
        onProgress?.call(const WhisperProgress('Converto l\'audio…', null));
        return _runCli(
          cli,
          model,
          native,
          out,
          onProgress: onProgress,
          cancel: cancel,
          options: options,
        );
      }
      final ff = await ffmpeg();
      if (ff == null) {
        await out.delete(recursive: true);
        throw WhisperException(
          'Il formato $ext richiede il convertitore ffmpeg: '
          '${host == WhisperHost.macos ? 'installalo con «brew install ffmpeg»' : 'scaricalo da Collegamenti → Whisper'} '
          '(oppure usa Gemini).',
        );
      }
      onProgress?.call(const WhisperProgress('Converto l\'audio…', null));
      final wav = File(p.join(out.path, 'audio.wav'));
      final conv = await processRunner(ff, [
        '-nostdin',
        '-y',
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        audio.path,
        '-ar',
        '16000',
        '-ac',
        '1',
        wav.path,
      ]);
      if (conv.exitCode != 0 || !await wav.exists()) {
        await out.delete(recursive: true);
        throw WhisperException(
          'Conversione dell\'audio non riuscita: ${'${conv.stderr}'.trim()}',
        );
      }
      audio = wav;
    }
    return _runCli(
      cli,
      model,
      audio,
      out,
      onProgress: onProgress,
      cancel: cancel,
      options: options,
    );
  }

  Future<List<WhisperSegment>> _runCli(
    File cli,
    File model,
    File audio,
    Directory out, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    WhisperOptions options = WhisperOptions.none,
  }) async {
    final outBase = p.join(out.path, 'trascrizione');
    final threads = (Platform.numberOfProcessors - 1).clamp(1, 16);
    final args = [
      '-m',
      model.path,
      '-f',
      audio.path,
      '-t',
      '$threads',
      '-pp',
      '-oj',
      '-of',
      outBase,
      ...options.cliArgs,
    ];
    onProgress?.call(const WhisperProgress('Avvio Whisper…', 0));
    final Process proc;
    try {
      proc = await processStarter(cli.path, args);
    } on ProcessException catch (e) {
      await out.delete(recursive: true);
      throw WhisperException('Impossibile avviare Whisper: ${e.message}');
    }
    void kill() => proc.kill();
    cancel?.addListener(kill);
    final tail = <String>[];
    final progress = RegExp(r'progress\s*=\s*(\d+)%');
    void onLine(String line) {
      final mm = progress.firstMatch(line);
      if (mm != null) {
        final pct = int.parse(mm.group(1)!);
        onProgress?.call(
          WhisperProgress('Trascrizione con Whisper: $pct%', pct / 100),
        );
      } else if (line.trim().isNotEmpty) {
        tail.add(line);
        if (tail.length > 8) tail.removeAt(0);
      }
    }

    // forEach crea subito il Future: nessuna corsa con la fine del processo.
    final readers = Future.wait([
      proc.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(onLine),
      proc.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .forEach(onLine),
    ]);
    final code = await proc.exitCode;
    await readers;
    cancel?.removeListener(kill);
    try {
      if (cancel?.isCancelled ?? false) {
        throw WhisperException('Trascrizione annullata.');
      }
      final json = File('$outBase.json');
      if (code != 0 || !await json.exists()) {
        throw WhisperException(
          'Whisper si è fermato (codice $code)'
          '${tail.isEmpty ? '' : ': ${tail.last.trim()}'}',
        );
      }
      return parseSegments(await _readOutput(json));
    } finally {
      await out.delete(recursive: true);
    }
  }

  /// Testo dell'output di whisper-cli: whisper.cpp a volte divide un
  /// carattere accentato fra due token e il JSON non è UTF-8 valido (la
  /// lettura normale falliva e la trascrizione di ore andava persa).
  static Future<String> _readOutput(File json) async =>
      utf8.decode(await json.readAsBytes(), allowMalformed: true);

  /// Legge l'output `-oj` di whisper-cli.
  static List<WhisperSegment> parseSegments(String json) {
    final Object? d;
    try {
      d = jsonDecode(json);
    } on FormatException {
      throw WhisperException('Output di Whisper non leggibile.');
    }
    final list = d is Map ? d['transcription'] : null;
    if (list is! List) return const [];
    Map<Object?, Object?>? offsets(Map<Object?, Object?> s) =>
        s['offsets'] is Map ? s['offsets'] as Map<Object?, Object?> : null;
    return [
      for (final s in list.whereType<Map<Object?, Object?>>())
        if ('${s['text'] ?? ''}'.trim().isNotEmpty)
          WhisperSegment(
            Duration(
              milliseconds: switch (offsets(s)?['from']) {
                final num from when from.isFinite => from.toInt(),
                _ => 0,
              },
            ),
            '${s['text']}'.trim(),
            end: switch (offsets(s)?['to']) {
              final num to when to.isFinite => Duration(
                milliseconds: to.toInt(),
              ),
              _ => null,
            },
          ),
    ];
  }
}

/// Trascrizione in Markdown: un paragrafo ogni ~2 minuti, **senza gli
/// orari** delle frasi (i tempi precisi dei segmenti restano nel `.json`
/// accanto alla registrazione, per il testo sincronizzato con l'audio).
String segmentsToMarkdown(
  List<WhisperSegment> segments, {
  required String title,
  String? subtitle,
  Duration every = const Duration(minutes: 2),
}) {
  final b = StringBuffer('# $title\n\n');
  if (subtitle != null) b.write('_${subtitle}_\n\n');
  Duration? paraStart;
  final para = <String>[];
  void flush() {
    if (para.isEmpty) return;
    b.write('${para.join(' ')}\n\n');
    para.clear();
  }

  for (final s in segments) {
    if (paraStart == null || s.start - paraStart >= every) {
      flush();
      paraStart = s.start;
    }
    para.add(s.text);
  }
  flush();
  return b.toString();
}

/// Trascrizione dal vivo con `whisper-cli` (PC, Mac con Homebrew): un
/// processo separato per ogni pezzo, con pochi thread per lasciare spazio
/// al resto del sistema.
class _CliLiveWhisper extends LiveWhisper {
  _CliLiveWhisper(this._w, this._cli, this._model, this.modelId);
  final WhisperService _w;
  final File _cli;
  final File _model;
  @override
  final String modelId;

  @override
  Future<List<WhisperSegment>> transcribeWav(File wav16k) async {
    final out = await Directory.systemTemp.createTemp('whisper_live_');
    try {
      final threads = (Platform.numberOfProcessors ~/ 2).clamp(1, 4);
      final base = p.join(out.path, 'pezzo');
      final r = await _w.processRunner(_cli.path, [
        '-m',
        _model.path,
        '-f',
        wav16k.path,
        '-t',
        '$threads',
        '-np',
        '-oj',
        '-of',
        base,
        ...options.cliArgs,
      ]);
      final json = File('$base.json');
      if (r.exitCode != 0 || !await json.exists()) {
        throw WhisperException('Whisper si è fermato (codice ${r.exitCode})');
      }
      return [
        for (final s in WhisperService.parseSegments(
          await WhisperService._readOutput(json),
        ))
          if (!isPromptEcho(s.text, options.prompt)) s,
      ];
    } finally {
      try {
        await out.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {}
}
