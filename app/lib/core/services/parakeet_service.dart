import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../features/notes/recorder/recording_meta.dart';
import '../../features/notes/recorder/speech_language.dart';
import '../../features/notes/recorder/vad_segmenter.dart';
import '../../features/notes/recorder/wav.dart';
import 'file_downloader.dart';
import 'parakeet_engine.dart';
import 'whisper_service.dart';

export '../../features/links/parakeet_model.dart';

/// NVIDIA Parakeet TDT 0.6B v3 su PC e Mac (Windows, macOS, Linux): il testo
/// istantaneo del registratore e il ripiego di «Trascrivi con…».
///
/// - **Consegna**: i quattro file ONNX int8 (639 MiB) sono **inclusi nelle
///   build desktop** ([bundledModelDir]): su Windows (e Linux) in
///   `data/parakeet/` accanto all'eseguibile (windows/CMakeLists.txt li
///   scarica durante la build e li installa lì: installatore, zip e MSIX),
///   su macOS in `UniNotes.app/Contents/Resources/parakeet/` (copiati dal
///   workflow prima della firma, tool/prepara_modello_parakeet.py). Si
///   leggono da lì, senza copiarli. Solo se mancano o sono incompleti
///   (build fatte a mano senza modello) si scaricano da Hugging Face alla
///   prima registrazione o dalla card dei collegamenti, uno per uno, con
///   ripresa (`.part`), spazio libero controllato prima di iniziare,
///   SHA-256 verificato e annullamento ([download]); un solo download alla
///   volta, condiviso fra card e registratore.
/// - **Silero VAD** (643 KB): incluso accanto al modello; altrimenti asset
///   delle build desktop, copiato nella cartella del download ([vadModel]).
/// - **Motore**: un isolate con sherpa-onnx ([ParakeetWorker]) e il
///   modello in memoria finché qualcuno lo usa ([liveEngine],
///   [transcribeFile]).
class ParakeetService {
  ParakeetService({
    required this._baseDir,
    required this.host,
    FileDownloader? downloader,
    this._assetLoader,
    this._device,
    Future<ParakeetWorker> Function(ParakeetPaths paths)? workerFactory,
    Uri Function(ParakeetFile f)? fileUrl,
    this._toWav,
    this.files = kParakeetFiles,
    Directory? Function()? bundledDir,
  }) : _bundledDir = bundledDir ?? defaultBundledDir,
       _downloader = downloader ?? FileDownloader(),
       _workerFactory =
           workerFactory ?? ((paths) => ParakeetWorker.start(paths)),
       _fileUrl = fileUrl ?? parakeetFileUrl;

  final Future<Directory> Function() _baseDir;
  final WhisperHost host;
  final FileDownloader _downloader;
  final Future<ByteData> Function(String key)? _assetLoader;
  final Future<DeviceProfile> Function()? _device;
  final Future<ParakeetWorker> Function(ParakeetPaths paths) _workerFactory;
  final Uri Function(ParakeetFile f) _fileUrl;
  final Future<File?> Function(File audio, Directory tmp)? _toWav;

  /// File del modello (sostituibili nei test).
  final List<ParakeetFile> files;

  /// Parakeet c'è solo nelle build desktop (sul telefono resta Whisper).
  bool get platformSupported =>
      host == WhisperHost.windows ||
      host == WhisperHost.macos ||
      host == WhisperHost.linux;

  final Directory? Function() _bundledDir;

  /// Cartella del modello incluso nella build: `data/parakeet/` accanto
  /// all'eseguibile (Windows, Linux), `Contents/Resources/parakeet/` nel
  /// bundle (macOS). null se non si sa.
  static Directory? defaultBundledDir() {
    try {
      final exe = p.dirname(Platform.resolvedExecutable);
      if (Platform.isMacOS) {
        return Directory(
          p.normalize(p.join(exe, '..', 'Resources', 'parakeet')),
        );
      }
      if (Platform.isWindows || Platform.isLinux) {
        return Directory(p.join(exe, 'data', 'parakeet'));
      }
    } catch (_) {}
    return null;
  }

  Future<Directory?>? _bundled;

  /// Il modello incluso nell'app, se c'è tutto (file con la dimensione
  /// giusta: lo SHA-256 si controlla durante la build). Letto una volta.
  Future<Directory?> bundledModelDir() => _bundled ??= () async {
    if (!platformSupported) return null;
    final d = _bundledDir();
    if (d == null) return null;
    for (final f in files) {
      if (!await _complete(f, d)) return null;
    }
    return d;
  }();

  /// Il modello è quello incluso nell'app (niente da scaricare né eliminare).
  Future<bool> isBundled() async => await bundledModelDir() != null;

  /// Cartella del modello scaricato dall'app (ripiego).
  Future<Directory> downloadDir() async {
    final d = Directory(
      p.join((await _baseDir()).path, 'parakeet', kParakeetDir),
    );
    await d.create(recursive: true);
    return d;
  }

  /// Cartella da cui si legge il modello: quello incluso, altrimenti quello
  /// scaricato.
  Future<Directory> modelDir() async =>
      await bundledModelDir() ?? await downloadDir();

  Future<File> _file(ParakeetFile f) async =>
      File(p.join((await downloadDir()).path, f.name));

  Future<bool> _complete(ParakeetFile f, [Directory? dir]) async {
    final file = dir == null ? await _file(f) : File(p.join(dir.path, f.name));
    try {
      return await file.exists() && await file.length() == f.bytes;
    } catch (_) {
      return false;
    }
  }

  /// Il modello c'è: incluso nell'app o scaricato (file con la dimensione
  /// giusta: lo SHA-256 si controlla a fine download).
  Future<bool> installed() async {
    if (!platformSupported) return false;
    if (await isBundled()) return true;
    for (final f in files) {
      if (!await _complete(f)) return false;
    }
    return true;
  }

  /// Byte già scaricati (file completi e parti), per «Riprendi».
  Future<int> downloadedBytes() async {
    var n = 0;
    for (final f in files) {
      final file = await _file(f);
      if (await _complete(f)) {
        n += f.bytes;
        continue;
      }
      final part = File('${file.path}.part');
      if (await part.exists()) n += await part.length();
    }
    return n;
  }

  /// Perché Parakeet non può girare qui (null = può): sistema, RAM.
  Future<String?> unavailableReason() async {
    if (!platformSupported) return 'Parakeet si usa solo su PC e Mac.';
    try {
      final d = await _device?.call();
      final ram = d?.ramBytes;
      if (ram != null && ram < kParakeetMinRam * 0.9) {
        return 'Parakeet richiede almeno 4 GB di RAM (questo dispositivo ne '
            'ha ${d!.ramGb}).';
      }
    } catch (_) {}
    return null;
  }

  // -------------------------------------------------------------- download

  _SharedDownload? _running;

  /// Download in corso (dalla card o dal registratore).
  bool get downloading => _running != null;

  /// Avanzamento del download in corso (0–1).
  double? get progress => _running?.last?.fraction;

  /// Scarica i file che mancano. Se un download è già in corso si segue
  /// quello; [cancel] lo annulla (la parte scaricata resta per riprendere).
  Stream<WhisperProgress> download({CancelToken? cancel}) {
    final r = _running ??= _SharedDownload(_downloadAll)
      ..done.whenComplete(() => _running = null).ignore();
    if (cancel != null) r.follow(cancel);
    return r.stream();
  }

  Future<void> _downloadAll(
    void Function(WhisperProgress) report,
    CancelToken cancel,
  ) async {
    // modello incluso nell'app: niente da scaricare
    if (await isBundled()) {
      report(const WhisperProgress('Pronto', 1));
      return;
    }
    final dir = await downloadDir();
    var missing = 0;
    var done = 0;
    for (final f in files) {
      if (await _complete(f)) {
        done += f.bytes;
        continue;
      }
      final part = File('${(await _file(f)).path}.part');
      missing += f.bytes - (await part.exists() ? await part.length() : 0);
    }
    try {
      await _downloader.checkSpace(dir, missing);
      final total = files.fold(0, (a, f) => a + f.bytes);
      report(WhisperProgress(_label(done, total), done / total));
      for (final f in files) {
        if (await _complete(f)) continue;
        await for (final d in _downloader.download(
          _fileUrl(f),
          await _file(f),
          cancel: cancel,
          expectedBytes: f.bytes,
          sha256: f.sha256,
        )) {
          final got = done + d.received;
          report(WhisperProgress(_label(got, total), got / total));
        }
        done += f.bytes;
      }
    } on DownloadException catch (e) {
      throw WhisperException(e.message);
    }
    report(const WhisperProgress('Pronto', 1));
  }

  static String _label(int got, int total) =>
      'Scarico Parakeet (${DownloadProgress.mb(got)} di '
      '${DownloadProgress.mb(total)})';

  /// Elimina il modello scaricato (si potrà riscaricare); quello incluso
  /// nell'app non si tocca.
  Future<void> delete() async {
    _running?.cancel();
    final d = await downloadDir();
    for (final f in files) {
      for (final path in [
        p.join(d.path, f.name),
        p.join(d.path, '${f.name}.part'),
      ]) {
        try {
          final file = File(path);
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
  }

  // ------------------------------------------------------------------ VAD

  Future<File?>? _vad;

  /// Silero VAD: quello incluso accanto al modello, altrimenti l'asset
  /// dell'app copiato nella cartella del download.
  Future<File?> vadModel() => _vad ??= _copyVad().then((f) {
    if (f == null) _vad = null;
    return f;
  });

  Future<File?> _copyVad() async {
    final inc = await bundledModelDir();
    if (inc != null) {
      final f = File(p.join(inc.path, 'silero_vad.onnx'));
      try {
        if (await f.exists() && await f.length() == kSileroVadBytes) return f;
      } catch (_) {}
    }
    final target = File(p.join((await downloadDir()).path, 'silero_vad.onnx'));
    try {
      if (await target.exists() && await target.length() == kSileroVadBytes) {
        return target;
      }
      final load = _assetLoader;
      if (load == null) return null;
      final data = await load(kSileroVadAsset);
      final tmp = File('${target.path}.copia');
      await tmp.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
      if (await FileDownloader.sha256Of(tmp) != kSileroVadSha256) {
        await tmp.delete();
        return null;
      }
      if (await target.exists()) await target.delete();
      await tmp.rename(target.path);
      return target;
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------------------- motore

  Future<ParakeetWorker>? _worker;
  int _users = 0;
  int _nextSession = 0;

  Future<ParakeetWorker> _acquire() async {
    _users++;
    try {
      return await (_worker ??= _startWorker());
    } catch (e) {
      _users--;
      _worker = null;
      rethrow;
    }
  }

  Future<ParakeetWorker> _startWorker() async {
    final vad = await vadModel();
    if (vad == null) {
      throw ParakeetException('Manca il rilevatore di voce (Silero VAD).');
    }
    if (!await installed()) {
      throw ParakeetException('Il modello Parakeet non è scaricato.');
    }
    final d = (await modelDir()).path;
    return _workerFactory(
      ParakeetPaths(
        encoder: p.join(d, 'encoder.int8.onnx'),
        decoder: p.join(d, 'decoder.int8.onnx'),
        joiner: p.join(d, 'joiner.int8.onnx'),
        tokens: p.join(d, 'tokens.txt'),
        vad: vad.path,
      ),
    );
  }

  Future<void> _release() async {
    _users--;
    if (_users > 0) return;
    _users = 0;
    final w = _worker;
    _worker = null;
    try {
      await (await w)?.dispose();
    } catch (_) {}
  }

  /// Parakeet per il testo dal vivo (errore se non può partire: modello
  /// mancante o danneggiato, libreria nativa assente).
  Future<VadLiveEngine> liveEngine() async {
    final w = await _acquire();
    final session = _nextSession++;
    try {
      await w.open(session);
    } catch (e) {
      await _release();
      rethrow;
    }
    return _ParakeetLive(this, w, session);
  }

  /// Trascrive [from]–[to] del WAV [wav] in una sessione a parte (blocchi
  /// da 30 s, frasi guidate dal VAD, senza testo provvisorio).
  Future<List<TranscriptSegment>> _transcribeWav(
    ParakeetWorker w,
    File wav,
    WavInfo info,
    Duration from,
    Duration to, {
    void Function(double fraction)? progress,
    CancelToken? cancel,
  }) async {
    final session = _nextSession++;
    await w.open(session);
    try {
      final out = <TranscriptSegment>[];
      const block = Duration(seconds: 30);
      var next = durationToSamples(from);
      final total = (to - from).inMilliseconds;
      for (var t = from; t < to; t += block) {
        if (cancel?.isCancelled ?? false) {
          throw WhisperException('Trascrizione annullata.');
        }
        final e = t + block < to ? t + block : to;
        final raw = await readWavRange(wav, info, t, e);
        if (raw.isEmpty) break;
        final mono = toMono16k(raw, info.sampleRate, info.channels);
        final step = await w.feed(
          session,
          next,
          int16ToFloat(mono),
          partial: false,
        );
        next += mono.length;
        out.addAll(step.committed);
        if (total > 0) {
          progress?.call(((e - from).inMilliseconds / total).clamp(0, 1));
        }
      }
      out.addAll((await w.flush(session)).committed);
      return out;
    } finally {
      try {
        await w.closeSession(session);
      } catch (_) {}
    }
  }

  /// Il tratto della frase [s] (con 0,2 s di margine) ritrascritto da
  /// [rescue]; le frasi ancora fuori lingua si tolgono.
  Future<List<WhisperSegment>> _rescue(
    File wav,
    WavInfo info,
    TranscriptSegment s,
    Directory tmp,
    Future<List<WhisperSegment>> Function(File wav16k) rescue,
    String language,
  ) async {
    const pad = Duration(milliseconds: 200);
    final from = s.start > pad ? s.start - pad : Duration.zero;
    final raw = await readWavRange(wav, info, from, s.end + pad);
    if (raw.isEmpty) return const [];
    final piece = File(p.join(tmp.path, 'frase_${s.start.inMilliseconds}.wav'));
    await writeWav16k(piece, toMono16k(raw, info.sampleRate, info.channels));
    try {
      return [
        for (final r in await rescue(piece))
          if (r.text.trim().isNotEmpty &&
              !outsideLecture(r.text, lecture: language))
            WhisperSegment(
              from + r.start,
              r.text.trim(),
              end: r.end == null ? s.end : from + r.end!,
            ),
      ];
    } finally {
      try {
        await piece.delete();
      } catch (_) {}
    }
  }

  /// «Trascrivi con Parakeet»: tutto [audio] (anche ore), a blocchi.
  ///
  /// Parakeet sceglie da solo la lingua di ogni frase (sherpa-onnx non
  /// permette di fissarla): le frasi che non sono nella lingua della
  /// lezione [language] (`outsideLecture`) si ritrascrivono
  /// con [rescue] (Whisper con la lingua fissata, su un WAV mono a 16 kHz
  /// del solo tratto) se c'è, altrimenti si tolgono.
  Future<List<WhisperSegment>> transcribeFile(
    File audio, {
    void Function(WhisperProgress)? onProgress,
    CancelToken? cancel,
    String language = 'it',
    Future<List<WhisperSegment>> Function(File wav16k)? rescue,
  }) async {
    if (!await audio.exists()) {
      throw WhisperException('File audio non trovato: ${audio.path}');
    }
    onProgress?.call(const WhisperProgress('Preparo l\'audio…', null));
    final tmp = await Directory.systemTemp.createTemp('parakeet_');
    try {
      var wav = audio;
      var info = p.extension(audio.path).toLowerCase() == '.wav'
          ? await readWavInfo(audio)
          : null;
      if (info == null) {
        final conv = await _toWav?.call(audio, tmp);
        if (conv == null) {
          throw WhisperException(
            'Conversione dell\'audio non riuscita: prova a trascrivere con '
            'Gemini.',
          );
        }
        wav = conv;
        info = await readWavInfo(wav);
        if (info == null) {
          throw WhisperException('Audio vuoto o non leggibile.');
        }
      }
      onProgress?.call(const WhisperProgress('Avvio Parakeet…', 0));
      final ParakeetWorker w;
      try {
        w = await _acquire();
      } on ParakeetException catch (e) {
        throw WhisperException(e.message);
      }
      try {
        final segs = await _transcribeWav(
          w,
          wav,
          info,
          Duration.zero,
          info.duration,
          cancel: cancel,
          progress: (f) => onProgress?.call(
            WhisperProgress(
              'Trascrizione con Parakeet: ${(f * 100).round()}%',
              f,
            ),
          ),
        );
        final out = <WhisperSegment>[];
        for (final s in segs) {
          if (!outsideLecture(s.text, lecture: language)) {
            out.add(WhisperSegment(s.start, s.text, end: s.end));
            continue;
          }
          if (rescue == null) continue;
          try {
            out.addAll(await _rescue(wav, info, s, tmp, rescue, language));
          } catch (_) {
            // la frase in un'altra lingua resta fuori
          }
        }
        return out;
      } on ParakeetException catch (e) {
        throw WhisperException('Parakeet non è riuscito a trascrivere: $e');
      } finally {
        await _release();
      }
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    }
  }
}

/// Parakeet per il testo dal vivo: una sessione sul modello condiviso.
class _ParakeetLive implements VadLiveEngine {
  _ParakeetLive(this._s, this._w, this._session);
  final ParakeetService _s;
  final ParakeetWorker _w;
  final int _session;
  bool _closed = false;

  @override
  String get modelId => kParakeetId;

  @override
  Future<LiveStep> feed(
    int start,
    Float32List samples, {
    bool partial = true,
  }) => _w.feed(_session, start, samples, partial: partial);

  @override
  Future<List<TranscriptSegment>> transcribeRange(
    File wav,
    Duration start,
    Duration end,
  ) async {
    final info = await readWavInfo(wav);
    if (info == null) return const [];
    final to = end < info.duration ? end : info.duration;
    if (to <= start) return const [];
    return _s._transcribeWav(_w, wav, info, start, to);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _w.closeSession(_session);
    } catch (_) {}
    await _s._release();
  }
}

/// Un download seguito da più parti dell'app (card e registratore): ultimo
/// avanzamento, fine (o errore) e annullamento condivisi.
class _SharedDownload {
  _SharedDownload(
    Future<void> Function(void Function(WhisperProgress), CancelToken) run,
  ) {
    done = run((pr) {
      last = pr;
      _events.add(pr);
    }, _cancel).whenComplete(() => _events.close());
    done.ignore();
  }

  final _cancel = CancelToken();
  final _events = StreamController<WhisperProgress>.broadcast();
  late final Future<void> done;
  WhisperProgress? last;

  void follow(CancelToken t) => t.addListener(cancel);
  void cancel() => _cancel.cancel();

  Stream<WhisperProgress> stream() async* {
    final l = last;
    if (l != null) yield l;
    if (!_events.isClosed) {
      yield* _events.stream;
    }
    try {
      await done;
    } on DownloadCancelled {
      throw WhisperException('Download annullato.');
    }
  }
}
