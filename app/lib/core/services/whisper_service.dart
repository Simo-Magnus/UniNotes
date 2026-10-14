import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../features/links/whisper_models.dart';
import '../../repositories/settings_repository.dart';
import 'audio_codec.dart';
import 'file_downloader.dart';
import 'whisper_plugin_engine.dart';

export '../../features/links/whisper_models.dart';
export 'file_downloader.dart' show CancelToken, DownloadCancelled;

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

/// Motore di trascrizione: audio + file del modello → segmenti.
abstract class WhisperEngine {
  String get name;
  Future<List<WhisperSegment>> transcribe(
    File audio,
    File model, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
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
  const WhisperProgress(this.phase, this.fraction);
  final String phase;
  final double? fraction;
}

/// Segmento della trascrizione con l'istante d'inizio (e di fine, se il
/// motore lo indica).
class WhisperSegment {
  const WhisperSegment(this.start, this.text, {this.end});
  final Duration start;
  final Duration? end;
  final String text;
}

/// Whisper pronto per la trascrizione dal vivo: pezzi brevi (WAV mono
/// 16 kHz) uno alla volta, con il modello tenuto in memoria quando si può.
/// Lavora fuori dal thread dell'interfaccia (processo `whisper-cli` o
/// isolate di whisper.cpp), così la registrazione non rallenta.
abstract class LiveWhisper {
  String get modelId;
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
class WhisperService {
  WhisperService({
    this._settings,
    Future<Directory> Function()? baseDir,
    HttpClient Function()? httpClientFactory,
    Future<int?> Function(Directory dir)? freeSpace,
    Uri? binariesUrl,
    Uri? ffmpegUrl,
    Uri Function(WhisperModelInfo)? modelUrl,
    this.processStarter = Process.start,
    this.processRunner = _run,
    WhisperHost? host,
    WhisperEngine? pluginEngine,
    List<String>? macCliCandidates,
    this._nativeDecoder,
    this._livePlugin,
  }) : _baseDir = baseDir ?? getApplicationSupportDirectory,
       _downloader = FileDownloader(
         httpClientFactory: httpClientFactory,
         freeSpace: freeSpace,
       ),
       binariesUrl = binariesUrl ?? defaultBinariesUrl,
       ffmpegUrl = ffmpegUrl ?? defaultFfmpegUrl,
       _modelUrl = modelUrl ?? ((m) => m.downloadUrl),
       host = host ?? currentHost,
       _plugin = pluginEngine,
       _macCandidates = macCliCandidates ?? defaultMacCliCandidates;

  final SettingsRepository? _settings;
  final Future<Directory> Function() _baseDir;
  final FileDownloader _downloader;
  final Uri binariesUrl;
  final Uri ffmpegUrl;
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

  /// Impostazione: percorso di un `whisper-cli` scelto a mano.
  static const cliPathKey = 'whisper_cli_path';

  /// Binari ufficiali per Windows x64 (CPU), versione fissata.
  static final defaultBinariesUrl = Uri.parse(
    'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-bin-x64.zip',
  );

  /// ffmpeg per Windows (solo per convertire le registrazioni .m4a del
  /// telefono): build LGPL ufficiale di BtbN, ~170 MB, scaricata a richiesta.
  static final defaultFfmpegUrl = Uri.parse(
    'https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-lgpl.zip',
  );

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
  }) async* {
    try {
      await for (final d in _downloader.download(
        url,
        target,
        cancel: cancel,
        expectedBytes: expectedBytes,
        sha1: sha1,
      )) {
        yield WhisperProgress('$label (${d.label})', d.fraction);
      }
    } on DownloadException catch (e) {
      throw WhisperException(e.message);
    }
  }

  /// Scarica ffmpeg (Windows) ed estrae solo l'eseguibile.
  Stream<WhisperProgress> installFfmpeg({CancelToken? cancel}) async* {
    final dir = await _dir('ffmpeg');
    final zip = File(p.join(dir.path, 'ffmpeg.zip'));
    yield* _download(
      ffmpegUrl,
      zip,
      'Scarico il convertitore ffmpeg',
      cancel: cancel,
    );
    yield const WhisperProgress('Estraggo ffmpeg…', null);
    final input = InputFileStream(zip.path);
    try {
      final archive = ZipDecoder().decodeStream(input);
      final entry = archive.files.where(
        (f) => f.isFile && p.basename(f.name) == _ffmpegName,
      );
      if (entry.isEmpty) {
        throw WhisperException('ffmpeg non trovato nell\'archivio scaricato.');
      }
      final out = OutputFileStream(p.join(dir.path, _ffmpegName));
      entry.first.writeContent(out);
      await out.close();
    } finally {
      await input.close();
      if (await zip.exists()) await zip.delete();
    }
    if (host != WhisperHost.windows) {
      await Process.run('chmod', ['+x', p.join(dir.path, _ffmpegName)]);
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
    if (await findCli() != null) return;
    if (!canDownloadCli && host != WhisperHost.linux) {
      throw WhisperException(
        'Su questo sistema whisper-cli non si scarica dall\'app: installalo con '
        'Homebrew («brew install whisper-cpp») oppure indica il file.',
      );
    }
    yield const WhisperProgress('Scarico whisper.cpp…', 0);
    final bin = await _dir('bin');
    final zip = File(p.join(bin.path, 'whisper.zip'));
    yield* _download(binariesUrl, zip, 'Scarico whisper.cpp', cancel: cancel);
    yield const WhisperProgress('Estraggo whisper.cpp…', null);
    try {
      await extractFileToDisk(zip.path, bin.path);
    } catch (e) {
      throw WhisperException('Archivio di whisper.cpp non valido: $e');
    } finally {
      if (await zip.exists()) await zip.delete();
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

  Future<String?> selectedModelId() async =>
      (await _settings?.get(SettingKeys.whisperModel))?.trim();

  Future<void> setSelectedModel(String? id) async =>
      _settings?.set(SettingKeys.whisperModel, id);

  /// Ordine di preferenza fra i modelli scaricati (adatti all'italiano).
  static const _preference = [
    'large-v3-turbo-q5_0',
    'large-v3-turbo',
    'large-v3-turbo-q8_0',
    'large-v3',
    'large-v3-q5_0',
    'large-v2',
    'large-v2-q8_0',
    'large-v2-q5_0',
    'medium',
    'medium-q8_0',
    'medium-q5_0',
    'large-v1',
    'small',
    'base',
    'tiny',
  ];

  /// Modello da usare: [requested], poi quello scelto, poi il migliore
  /// scaricato.
  Future<WhisperModelInfo?> pickModel(
    Set<String> installed, {
    String? requested,
  }) async {
    for (final id in [requested, await selectedModelId()]) {
      if (id != null && installed.contains(id)) return whisperModelById(id);
    }
    final phoneFirst = isPhone
        ? [kRecommendedPhoneModel, kLightPhoneModel, ..._preference]
        : _preference;
    for (final id in phoneFirst) {
      if (installed.contains(id)) return whisperModelById(id);
    }
    return installed.isEmpty ? null : whisperModelById(installed.first);
  }

  // ------------------------------------------------------- dal vivo

  /// Modelli preferiti per la trascrizione dal vivo: abbastanza veloci da
  /// stare al passo con il parlato, ma buoni in italiano.
  static const _livePreference = [
    'large-v3-turbo-q5_0',
    'small',
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

  /// Whisper per la trascrizione dal vivo, null se non è installato (manca
  /// il modello o `whisper-cli`).
  Future<LiveWhisper?> liveEngine() async {
    final st = await status();
    final m = pickLiveModel(st.models);
    if (!st.engineReady || m == null) return null;
    final model = await modelFile(m);
    if (st.engine == WhisperEngineKind.plugin) {
      return (_livePlugin ?? PluginLiveWhisper.new)(model, m.id);
    }
    return _CliLiveWhisper(this, st.cli!, model, m.id);
  }

  // ------------------------------------------------------------ trascrizione

  /// Trascrive [audio] in italiano. Restituisce i segmenti con l'orario.
  Future<List<WhisperSegment>> transcribe(
    File audio, {
    String? model,
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final st = await status();
    final m = await pickModel(st.models, requested: model);
    if (!st.engineReady || m == null) {
      throw WhisperException(
        'Whisper non è pronto: scarica un modello da Collegamenti → '
        'Trascrizione → Whisper.',
      );
    }
    if (!await audio.exists()) {
      throw WhisperException('File audio non trovato: ${audio.path}');
    }
    final modelPath = await modelFile(m);
    if (st.engine == WhisperEngineKind.plugin) {
      return _pluginEngine.transcribe(
        audio,
        modelPath,
        onProgress: onProgress,
        cancel: cancel,
      );
    }
    return _transcribeCli(
      st.cli!,
      modelPath,
      audio,
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  Future<List<WhisperSegment>> _transcribeCli(
    File cli,
    File model,
    File audio, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
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
    );
  }

  Future<List<WhisperSegment>> _runCli(
    File cli,
    File model,
    File audio,
    Directory out, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
  }) async {
    final outBase = p.join(out.path, 'trascrizione');
    final threads = (Platform.numberOfProcessors - 1).clamp(1, 16);
    final args = [
      '-m',
      model.path,
      '-f',
      audio.path,
      '-l',
      'it',
      '-t',
      '$threads',
      '-pp',
      '-oj',
      '-of',
      outBase,
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
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .forEach(onLine),
      proc.stdout
          .transform(utf8.decoder)
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
      return parseSegments(await json.readAsString());
    } finally {
      await out.delete(recursive: true);
    }
  }

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
    return [
      for (final s in list.whereType<Map<Object?, Object?>>())
        if ('${s['text'] ?? ''}'.trim().isNotEmpty)
          WhisperSegment(
            Duration(
              milliseconds:
                  ((s['offsets'] as Map?)?['from'] as num?)?.toInt() ?? 0,
            ),
            '${s['text']}'.trim(),
            end: switch ((s['offsets'] as Map?)?['to']) {
              final num to => Duration(milliseconds: to.toInt()),
              _ => null,
            },
          ),
    ];
  }
}

/// Trascrizione in Markdown: un paragrafo ogni ~2 minuti con [hh:mm:ss].
String segmentsToMarkdown(
  List<WhisperSegment> segments, {
  required String title,
  String? subtitle,
  Duration every = const Duration(minutes: 2),
}) {
  String ts(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '[${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}]';
  }

  final b = StringBuffer('# $title\n\n');
  if (subtitle != null) b.write('_${subtitle}_\n\n');
  Duration? paraStart;
  final para = <String>[];
  void flush() {
    if (para.isEmpty) return;
    b.write('${ts(paraStart!)} ${para.join(' ')}\n\n');
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
class _CliLiveWhisper implements LiveWhisper {
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
        '-l',
        'it',
        '-t',
        '$threads',
        '-np',
        '-oj',
        '-of',
        base,
      ]);
      final json = File('$base.json');
      if (r.exitCode != 0 || !await json.exists()) {
        throw WhisperException('Whisper si è fermato (codice ${r.exitCode})');
      }
      return WhisperService.parseSegments(await json.readAsString());
    } finally {
      try {
        await out.delete(recursive: true);
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {}
}
