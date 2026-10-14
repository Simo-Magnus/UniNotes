import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../core/services/whisper_service.dart';
import 'recorder/background_controls.dart';
import 'recorder/live_transcriber.dart';
import 'recorder/recording_meta.dart';
import 'recorder/recording_session.dart';
import 'recorder/system_speech.dart';
import 'recorder/wav.dart';

export 'recorder/background_controls.dart'
    show RecorderCommand, recordingServiceCallback;

class RecorderException implements Exception {
  RecorderException(this.message);
  final String message;
  @override
  String toString() => message;
}

enum RecorderPhase { idle, recording, paused }

/// Registratore delle lezioni, come Memo Vocali: audio PCM 16 kHz mono dal
/// microfono (`record`, flusso PCM su Android, iOS, macOS e Windows)
/// scritto man mano in un WAV di lavoro (niente audio perso se l'app si
/// chiude), forma d'onda, segnalibri e trascrizione dal vivo (riconoscimento
/// vocale del sistema in streaming, altrimenti Whisper a pezzi).
/// Al salvataggio (recorder/recording_save.dart) il WAV diventa un `.m4a`.
///
/// Con l'app in background la registrazione continua: servizio in primo
/// piano con notifica su Android, Live Activity su iOS, icona nell'area di
/// notifica sul PC.
class LectureRecorder extends ChangeNotifier {
  LectureRecorder({
    AudioRecorder Function()? recorder,
    Future<Directory> Function()? workDir,
    this._whisper,
    BackgroundControls Function()? controls,
    SystemSpeech? speech,
  }) : _factory = recorder ?? AudioRecorder.new,
       _workDir = workDir ?? _defaultWorkDir,
       _controlsFactory = controls ?? BackgroundControls.forPlatform,
       _speech = speech ?? SystemSpeech();

  final AudioRecorder Function() _factory;
  final Future<Directory> Function() _workDir;
  final WhisperService? _whisper;
  final BackgroundControls Function() _controlsFactory;
  final SystemSpeech _speech;

  // il registratore del sistema si crea al primo uso (nei test non serve)
  AudioRecorder? _rec;
  AudioRecorder get _audio => _rec ??= _factory();
  BackgroundControls? _controls;
  BackgroundControls get _bg =>
      _controls ??= _controlsFactory()..onCommand = _onCommand;

  static Future<Directory> _defaultWorkDir() async => Directory(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'registrazioni_in_corso',
    ),
  );

  /// Cartella del WAV di lavoro e dei suoi dati.
  Future<Directory> workDir() => _workDir();

  RecorderPhase phase = RecorderPhase.idle;

  /// Percorso previsto della registrazione salvata (.m4a).
  String? path;
  String? courseName;
  int? courseId;
  RecordingSession? session;
  WavWriter? _writer;
  StreamSubscription<Uint8List>? _pcm;
  StreamSubscription<RecordState>? _state;
  LevelBinner? _binner;

  /// Trascrizione dal vivo (null a registratore fermo).
  LiveTranscriber? live;

  /// Schermata del registratore aperta (il riquadro sopra le altre
  /// schermate si nasconde).
  bool _screenVisible = false;
  bool get screenVisible => _screenVisible;
  set screenVisible(bool v) {
    if (v == _screenVisible) return;
    _screenVisible = v;
    // Uscendo dal registratore il valore cambia mentre la pagina si chiude,
    // a metà di un fotogramma: lì un rebuild non chiede un fotogramma nuovo
    // e il riquadro comparirebbe solo al tocco successivo. Si avvisa a
    // fotogramma finito, chiedendone subito un altro.
    final binding = _binding;
    if (binding != null &&
        binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding
        ..addPostFrameCallback((_) => notifyListeners())
        ..scheduleFrame();
      return;
    }
    notifyListeners();
  }

  static SchedulerBinding? get _binding {
    try {
      return SchedulerBinding.instance;
    } catch (_) {
      return null;
    }
  }

  /// Salvataggio in corso (compressione).
  bool _saving = false;
  bool get saving => _saving;
  set saving(bool v) {
    if (v == _saving) return;
    _saving = v;
    notifyListeners();
  }

  /// Livello d'ingresso 0–1 per l'indicatore.
  double level = 0;

  /// Livelli recenti (uno ogni [sampleEvery]): la forma d'onda che scorre
  /// mentre si registra.
  final List<double> history = [];
  static const sampleEvery = Duration(milliseconds: 100);
  static const maxHistory = 600;

  /// Forma d'onda dell'intera registrazione (0–255 ogni [sampleEvery]).
  final BytesBuilder _peaks = BytesBuilder(copy: false);

  final List<Bookmark> bookmarks = [];

  /// Comandi da fuori dell'app che richiedono l'interfaccia (salvare,
  /// aprire il registratore). Pausa e ripresa li esegue il registratore.
  final _commands = StreamController<RecorderCommand>.broadcast();
  Stream<RecorderCommand> get commands => _commands.stream;

  /// Primo errore di scrittura (es. spazio esaurito).
  String? writeError;

  /// Con l'app in background (schermo spento, altra app) nessuno vede la
  /// forma d'onda: l'interfaccia si aggiorna una volta al secondo.
  static const backgroundEvery = Duration(seconds: 1);
  bool _background = false;
  AppLifecycleListener? _lifecycle;
  Timer? _ticker;

  Duration get elapsed => _writer?.duration ?? Duration.zero;
  bool get active => phase != RecorderPhase.idle;
  bool get paused => phase == RecorderPhase.paused;

  void _listenLifecycle() {
    if (_lifecycle != null) return;
    try {
      _lifecycle = AppLifecycleListener(
        onStateChange: (st) {
          _background = st != AppLifecycleState.resumed;
          if (active) _startTicker();
        },
      );
    } catch (_) {
      // nessun binding (test)
    }
  }

  /// Orologio dell'interfaccia (l'audio arriva a pezzi irregolari).
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(
      _background ? backgroundEvery : sampleEvery,
      (_) => notifyListeners(),
    );
  }

  /// Formato del file finale.
  Future<String> extension([Object? _]) async => '.m4a';

  /// Avvia la registrazione. [outputPath] è dove verrà salvata (cartella
  /// Registrazioni del corso, nome della lezione): fino al salvataggio
  /// l'audio sta nel WAV di lavoro.
  Future<void> start(
    String outputPath, {
    required String course,
    int? courseId,
    String? language,
  }) async {
    if (active || saving) {
      throw RecorderException('Una registrazione è già in corso.');
    }
    final AudioRecorder audio;
    try {
      audio = _audio;
      if (!await audio.hasPermission()) {
        throw RecorderException(
          'Permesso del microfono negato: abilitalo nelle impostazioni del '
          'sistema (App → UniNotes → Autorizzazioni).',
        );
      }
    } on RecorderException {
      rethrow;
    } catch (e) {
      throw RecorderException('Microfono non disponibile: $e');
    }
    final dir = await _workDir();
    await dir.create(recursive: true);
    final now = DateTime.now();
    final wavFile = File(
      p.join(dir.path, 'registrazione_${now.millisecondsSinceEpoch}.wav'),
    );
    final s = RecordingSession(
      wav: wavFile,
      targetDir: p.dirname(outputPath),
      baseName: p.basenameWithoutExtension(outputPath),
      course: course,
      courseId: courseId,
      started: now,
    );
    final writer = await WavWriter.create(
      wavFile,
      sampleRate: 16000,
      channels: 1,
    );
    await s.save();

    final bgError = await _bg.start(
      course: course,
      elapsed: Duration.zero,
      paused: false,
    );
    if (bgError != null) {
      await writer.close();
      await s.delete();
      throw RecorderException(bgError);
    }
    await audio.setOnConfigChanged((c) {
      // formato scelto dal sistema (prima dei dati)
      writer.setFormat(c.sampleRate, c.numChannels);
      s
        ..sampleRate = c.sampleRate
        ..channels = c.numChannels;
      _binner = LevelBinner(sampleRate: c.sampleRate, channels: c.numChannels);
      live?.setFormat(c.sampleRate, c.numChannels);
      unawaited(s.save());
    });
    final Stream<Uint8List> stream;
    try {
      stream = await audio.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          noiseSuppress: true,
          // iOS: la registrazione continua in background (UIBackgroundModes
          // audio) e si mette in pausa durante le telefonate
          iosConfig: IosRecordConfig(
            categoryOptions: [
              IosAudioCategoryOption.defaultToSpeaker,
              IosAudioCategoryOption.allowBluetooth,
              IosAudioCategoryOption.allowBluetoothA2DP,
            ],
          ),
        ),
      );
    } catch (e) {
      await _bg.stop();
      await writer.close();
      await s.delete();
      throw RecorderException('Impossibile avviare la registrazione: $e');
    }
    _writer = writer;
    session = s;
    path = outputPath;
    courseName = course;
    this.courseId = courseId;
    phase = RecorderPhase.recording;
    writeError = null;
    history.clear();
    bookmarks.clear();
    _peaks.clear();
    level = 0;
    _binner = LevelBinner(
      sampleRate: writer.sampleRate,
      channels: writer.channels,
    );
    _pcm = stream.listen(
      _onPcm,
      onError: (Object e) {
        debugPrint('Flusso del microfono: $e');
      },
    );
    _state = audio.onStateChanged().listen(_onState, onError: (_) {});
    final lt = LiveTranscriber(
      _whisper,
      speech: _speech,
      locale: speechLocaleFor(language),
    )..onSegments = _saveSessionSoon;
    live = lt;
    unawaited(
      lt.begin(
        wavFile,
        sampleRate: writer.sampleRate,
        channels: writer.channels,
      ),
    );
    _listenLifecycle();
    _startTicker();
    notifyListeners();
  }

  void _onPcm(Uint8List data) {
    final w = _writer;
    if (w == null || phase != RecorderPhase.recording) return;
    w.add(data);
    live?.onPcm(data);
    if (w.error != null && writeError == null) {
      writeError = 'Scrittura dell\'audio non riuscita: ${w.error}';
      unawaited(pause());
    }
    final samples = pcm16(data);
    final levels = _binner?.add(samples) ?? const <double>[];
    for (final l in levels) {
      level = l;
      _peaks.addByte((l * 255).round());
      if (!_background) {
        history.add(l);
        if (history.length > maxHistory) history.removeAt(0);
      }
    }
    live?.onAudio(w.duration);
  }

  /// Pausa decisa dal sistema (es. telefonata su iOS).
  void _onState(RecordState st) {
    if (st == RecordState.pause && phase == RecorderPhase.recording) {
      phase = RecorderPhase.paused;
      level = 0;
      live?.pause();
      unawaited(_afterPauseChange());
      notifyListeners();
    }
  }

  Future<void> _afterPauseChange() async {
    await _writer?.updateHeader();
    await session?.save();
    await _bg.update(elapsed: elapsed, paused: paused);
  }

  Future<void> pause() async {
    if (phase != RecorderPhase.recording) return;
    try {
      await _audio.pause();
    } catch (e) {
      debugPrint('Pausa non riuscita: $e');
    }
    phase = RecorderPhase.paused;
    level = 0;
    live?.pause();
    notifyListeners();
    await _afterPauseChange();
  }

  Future<void> resume() async {
    if (phase != RecorderPhase.paused) return;
    if (writeError != null) return;
    await _audio.resume();
    phase = RecorderPhase.recording;
    live?.resume();
    notifyListeners();
    await _bg.update(elapsed: elapsed, paused: false);
  }

  Future<void> togglePause() => paused ? resume() : pause();

  /// «Segna»: segnalibro all'istante attuale (nota facoltativa).
  Bookmark addBookmark([String note = '']) {
    final b = Bookmark(elapsed, note.trim());
    bookmarks.add(b);
    _syncBookmarks();
    notifyListeners();
    return b;
  }

  void setBookmarkNote(Bookmark b, String note) {
    final i = bookmarks.indexOf(b);
    if (i < 0) return;
    bookmarks[i] = b.withNote(note);
    _syncBookmarks();
    notifyListeners();
  }

  void removeBookmark(Bookmark b) {
    if (!bookmarks.remove(b)) return;
    _syncBookmarks();
    notifyListeners();
  }

  void _syncBookmarks() {
    final s = session;
    if (s != null) {
      s.bookmarks
        ..clear()
        ..addAll(bookmarks);
    }
    _saveSessionSoon();
  }

  Timer? _sessionSave;
  void _saveSessionSoon() {
    _sessionSave?.cancel();
    _sessionSave = Timer(const Duration(seconds: 2), () {
      final s = session;
      if (s == null) return;
      s.segments = [...?live?.segments];
      unawaited(s.save().catchError((_) {}));
    });
  }

  void _onCommand(RecorderCommand c) {
    switch (c) {
      case RecorderCommand.pause:
        unawaited(pause());
      case RecorderCommand.resume:
        unawaited(resume());
      case RecorderCommand.toggle:
        unawaited(togglePause());
      case RecorderCommand.save || RecorderCommand.open:
        _commands.add(c);
    }
  }

  /// Comando dall'icona nell'area di notifica del PC.
  void command(RecorderCommand c) => _onCommand(c);

  /// Ferma la registrazione e restituisce l'audio da salvare (WAV di lavoro
  /// con intestazione aggiornata, segnalibri, trascrizione).
  Future<RecordingTake?> stop() async {
    if (!active) return null;
    try {
      await _audio.stop();
    } catch (e) {
      debugPrint('Arresto del microfono: $e');
    }
    await _pcm?.cancel();
    _pcm = null;
    await _state?.cancel();
    _state = null;
    _ticker?.cancel();
    _ticker = null;
    _sessionSave?.cancel();
    final w = _writer!;
    await w.close();
    final s = session!;
    final lt = live;
    final duration = w.duration;
    // ultimo testo del riconoscitore del sistema (mai bloccante)
    try {
      await lt?.flush();
    } catch (_) {}
    final pending = lt?.finish(duration) ?? const [];
    s.bookmarks
      ..clear()
      ..addAll(bookmarks);
    s.segments = [...?lt?.segments];
    await s.save();
    await _bg.stop();
    final take = RecordingTake(
      session: s,
      duration: duration,
      peaks: _peaks.takeBytes(),
      live: lt,
      pending: pending,
    );
    _writer = null;
    session = null;
    live = null;
    phase = RecorderPhase.idle;
    level = 0;
    history.clear();
    bookmarks.clear();
    path = null;
    courseName = null;
    courseId = null;
    notifyListeners();
    return take;
  }

  /// Registrazioni rimaste da una chiusura improvvisa dell'app.
  Future<List<RecordingSession>> orphans() async =>
      RecordingSession.orphans(await _workDir(), except: session?.wav.path);

  @override
  void dispose() {
    _ticker?.cancel();
    _sessionSave?.cancel();
    _pcm?.cancel();
    _state?.cancel();
    _lifecycle?.dispose();
    unawaited(_commands.close());
    unawaited(_rec?.dispose());
    super.dispose();
  }
}
