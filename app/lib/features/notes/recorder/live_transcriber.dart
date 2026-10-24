import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../core/services/power.dart';
import '../../../core/services/whisper_service.dart';
import '../spoken_math.dart';
import 'live_agreement.dart';
import 'live_transcript.dart';
import 'recording_meta.dart';
import 'second_pass.dart';
import 'speech_language.dart';
import 'system_speech.dart';
import 'vad_segmenter.dart';
import 'wav.dart';

/// Stato della trascrizione dal vivo (card «Trascrizione» del registratore).
enum LiveState {
  /// Non avviata.
  off,

  /// Nessun motore disponibile: la registrazione va avanti senza testo.
  unavailable,

  /// Avvio del riconoscitore, download o caricamento del modello.
  starting,

  /// Al passo con il parlato.
  running,

  /// Il motore è indietro: alcuni tratti si recuperano a fine registrazione.
  lagging,

  /// Errore del motore (la registrazione continua).
  failed,
}

/// Chi trascrive dal vivo.
enum LiveEngine {
  none,

  /// Riconoscimento vocale del sistema in streaming (testo istantaneo).
  system,

  /// Whisper sul dispositivo: finestre di ~2 s con il modello dal vivo
  /// (telefono), pezzi da ~10 s con un modello più pesante (ripiego).
  whisper,

  /// Parakeet (PC e Mac): frasi guidate dalle pause (Silero VAD).
  parakeet,
}

/// Motori del testo dal vivo, nell'ordine in cui si provano: **l'unico
/// punto da cambiare** per scegliere il motore per piattaforma (se c'è
/// [LiveEngine.system], LectureRecorder crea anche il riconoscitore del
/// sistema). Ogni motore che non può partire passa al successivo; Whisper
/// è sempre l'ultimo (modello integrato o scaricato, altrimenti nessun
/// testo).
/// - Mac con macOS 26 o successivo ([appleSpeech]): il riconoscitore nuovo
///   di Apple (SpeechAnalyzer, sul Mac, nella lingua della lezione), poi
///   Parakeet se non ha la lingua, il modello della lingua non è ancora sul
///   Mac (si scarica in background per la volta dopo), non risponde o si
///   ferma, infine il modello Whisper scaricato;
/// - Windows, Linux e Mac precedenti: Parakeet, poi il modello Whisper
///   scaricato a pezzi; niente riconoscitore del sistema (su Windows con
///   «Riconoscimento vocale online» il testo non arrivava);
/// - telefono (Android, iOS): il riconoscitore del sistema (Google/Apple,
///   sul dispositivo dove c'è, come nelle build fino al 19/10/2026), poi
///   Whisper base integrato migliorato (VAD, soppressione dei token non
///   verbali, vocabolario del corso) se il riconoscitore manca, non ha la
///   lingua o si ferma; con Whisper base la seconda passata con small dove
///   il telefono regge. Test: test/parakeet_live_test.dart («scelta del
///   motore per piattaforma»).
List<LiveEngine> liveEngineOrder({
  required bool phone,
  bool appleSpeech = false,
}) => phone
    ? const [LiveEngine.system, LiveEngine.whisper]
    : appleSpeech
    ? const [LiveEngine.system, LiveEngine.parakeet, LiveEngine.whisper]
    : const [LiveEngine.parakeet, LiveEngine.whisper];

/// Trascrizione dal vivo durante la registrazione.
///
/// **Parole stabili confermate subito** (live_agreement.dart, per tutti i
/// motori): a ogni nuova decodifica del tratto in corso le parole iniziali
/// uguali nelle ultime due decodifiche diventano confermate ed entrano nei
/// [segments] (modificabili, ~1–2 s dopo essere state dette); in grigio
/// ([partial]) resta solo il resto. A fine frase il testo definitivo del
/// motore le sostituisce (punteggiatura, maiuscole, frasi con i tempi),
/// salvo le frasi già corrette a mano.
///
/// 1. **PC e Mac: Parakeet** (NVIDIA Parakeet TDT 0.6B v3 con sherpa-onnx,
///    core/services/parakeet_service.dart). L'audio della registrazione
///    ([onPcm]) passa dal rilevatore di voce Silero: mentre si parla, ogni
///    ~0,75 s si decodifica la frase in corso (un'ipotesi); a una pausa (o
///    dopo ~18 s di parlato continuo) diventa definitiva; i silenzi non
///    producono testo ([VadLiveSegmenter]). Parakeet sceglie da solo la
///    lingua: le frasi che escono in una lingua diversa da quella della
///    lezione ([language], anche l'inglese in una lezione in italiano e
///    viceversa; nomi e termini tecnici dentro una frase restano) si
///    tolgono e si ritrascrivono con il modello Whisper scaricato, fissato
///    sulla lingua della lezione, se c'è (speech_language.dart). Il modello (639
///    MiB) è incluso nell'app e si usa subito; solo se manca (build fatta
///    a mano) si scarica alla prima registrazione, con la barra nella card:
///    intanto si registra e quei tratti si trascrivono con Parakeet dopo il
///    salvataggio ([recover]). Se Parakeet non può girare (RAM, file
///    mancante, errore) si usa il modello Whisper scaricato dall'utente a
///    pezzi, altrimenti niente testo dal vivo.
/// 2. **Telefono e Mac con macOS 26: riconoscimento del sistema**
///    (recorder/system_speech.dart, Google/Apple sul dispositivo dove c'è;
///    sul Mac solo SpeechAnalyzer, [appleSpeech], prima di Parakeet):
///    riceve l'audio della registrazione man mano ([onPcm]); il testo
///    provvisorio si aggiorna e diventa un segmento quando il sistema lo
///    stabilizza.
/// 3. **Telefono, ripiego: Whisper** con il modello integrato (base q5_1),
///    se il riconoscitore manca o si ferma: ogni ~2 s ritrascrive dal WAV
///    di lavoro il tratto non ancora definitivo ([LiveWindowPlanner]), con
///    il vocabolario del corso ([vocabulary]), il VAD di whisper.cpp e la
///    soppressione dei token non verbali.
///
/// Sul telefono, con Whisper base e dove regge, una **seconda passata** con
/// small q5_1 ritrascrive in background i tratti confermati a blocchi da
/// ~30 s (second_pass.dart; non sul testo del riconoscitore del sistema,
/// già preciso almeno quanto small); si ferma da sola se resta indietro, se
/// il telefono rallenta (si scalda) o con la batteria sotto il 20%.
/// L'ordine dei motori è in [liveEngineOrder].
///
/// Non blocca mai la registrazione: ogni errore ferma solo la trascrizione
/// (o fa passare al motore successivo).
///
/// Mentre si registra lo studente può **correggere** le frasi già scritte
/// ([editSegment]) e attivare **«Formule (LaTeX)»** ([formulas]): le
/// formule dette a voce diventano LaTeX (`spoken_math.dart`). Correzioni e
/// formule si applicano a [segments], che finiscono nella trascrizione
/// salvata; il testo originale resta in [merger] per unire bene i pezzi
/// successivi.
class LiveTranscriber extends ChangeNotifier {
  LiveTranscriber(
    this._whisper, {
    LiveWindowPlanner? planner,
    this.speech,
    this.locale = 'it-IT',
    this.vocabulary = const [],
    this.appleSpeech = false,
  }) : _customPlanner = planner,
       planner = planner ?? LiveWindowPlanner() {
    // maiuscole a inizio pezzo: restano solo per i nomi propri noti
    merger.english = language == 'en';
    for (final v in vocabulary) {
      merger.properNames.addAll(midSentenceNames(v));
    }
  }

  final WhisperService? _whisper;

  /// Riconoscimento vocale del sistema (telefono e Mac con macOS 26; null =
  /// solo i modelli dell'app).
  final SystemSpeech? speech;

  /// Mac con macOS 26 o successivo: prima il riconoscitore nuovo di Apple
  /// (solo SpeechAnalyzer con il modello della lingua già sul Mac), poi
  /// Parakeet ([liveEngineOrder]).
  final bool appleSpeech;
  final LiveWindowPlanner? _customPlanner;

  /// Finestre di Whisper (scelte in base al modello all'avvio di Whisper).
  LiveWindowPlanner planner;
  final TranscriptMerger merger = TranscriptMerger();

  /// Lingua del riconoscimento (es. «it-IT»).
  final String locale;

  /// Lingua di Whisper e del controllo della lingua di Parakeet: «it» o
  /// «en» (dalla lingua del riconoscimento).
  String get language => lectureLanguage(locale);

  /// Conferma delle parole stabili del tratto in corso.
  late final LiveAgreement _agree = LiveAgreement(
    merger,
    isEdited: (k) => _edits.containsKey(k),
  );

  /// Ultimo testo provvisorio completo del riconoscitore del sistema.
  String _sysHyp = '';

  /// Frasi di Parakeet in un'altra lingua: tolte ([foreignDropped]) e
  /// ritrascritte con Whisper nella lingua della lezione
  /// ([foreignRescued]): Whisper small q5_1 incluso nell'app desktop o un
  /// modello scaricato (`WhisperService.liveEngine`).
  int foreignDropped = 0;
  int foreignRescued = 0;
  bool _rescueUnavailable = false;
  LiveWhisper? _rescueEngine;
  final List<LiveChunk> _rescueQueue = [];
  Future<void>? _rescueInFlight;

  /// Ultimo salvataggio chiesto (onSegments): mentre le parole si
  /// confermano una alla volta si salva al massimo ogni 3 s.
  DateTime? _savedAt;

  void _segmentsChanged({bool force = false, int? recaseFrom}) {
    // maiuscole a inizio pezzo senza punto prima, per tutti i motori: le
    // parole confermate e il testo definitivo non passano da merger.add
    merger.recase(
      from: recaseFrom ?? merger.segments.length - 8,
      skip: (s) => _edits.containsKey(s.start.inMilliseconds),
    );
    final now = DateTime.now();
    final last = _savedAt;
    if (!force && last != null && now.difference(last).inSeconds < 3) return;
    _savedAt = now;
    onSegments?.call();
  }

  /// Nome dell'insegnamento, moduli e argomenti (il più pertinente prima):
  /// vocabolario per Whisper (`buildWhisperPrompt`).
  final List<String> vocabulary;

  LiveState state = LiveState.off;
  LiveEngine engine = LiveEngine.none;
  String? modelId;
  String? error;

  /// Whisper usa il modello dal vivo (testo provvisorio ogni ~2 s).
  bool quick = false;

  /// Testo provvisorio (la frase in corso).
  String partial = '';

  /// Il riconoscitore del sistema lavora sul dispositivo.
  bool onDevice = false;

  /// Perché il riconoscitore del sistema non è disponibile (codice di
  /// [SpeechSupport.reason]).
  String? systemUnavailable;

  /// La lingua manca fra quelle del riconoscitore del sistema.
  bool systemLanguageMissing = false;

  /// Perché Parakeet non si usa (null = si usa o non è un PC).
  String? parakeetUnavailable;

  /// Download del modello dal vivo in corso ([downloadProgress] 0–1, null
  /// se non si sa); [downloadWhat] dice quale («Parakeet (639 MiB)»).
  bool downloading = false;
  double? downloadProgress;
  String? downloadError;
  String downloadWhat = '';

  /// Quanto ha impiegato il motore per l'ultimo pezzo.
  Duration? lastTook;

  LiveWhisper? _engine;
  File? _wav;
  int _sampleRate = 16000;
  int _channels = 1;
  Directory? _tmp;
  Future<void>? _inFlight;
  bool _closed = false;
  bool _finished = false;
  CancelToken? _download;
  CancelToken? _pkDownload;
  Future<void>? _starting;

  bool _feeds = false;
  StreamSubscription<SpeechEvent>? _sub;
  Duration _recorded = Duration.zero;
  Duration? _partialStart;
  Completer<void>? _ended;

  // Parakeet
  VadLiveEngine? _vad;
  bool _vadWanted = false;
  final PcmBacklog _backlog = PcmBacklog();
  int _samples16k = 0;
  Duration _stable = Duration.zero;
  Future<void>? _vadInFlight;
  int _lagSkips = 0;

  /// Tratti saltati da Parakeet (download, PC indietro, errore), da
  /// recuperare alla fine.
  final List<LiveChunk> _extraPending = [];
  int _extraIndex = 1 << 20;

  // seconda passata (telefono)
  LiveWhisper? _second;
  SecondPassGovernor? _gov;
  final SecondPassPlanner _sp = SecondPassPlanner();
  Future<void>? _secondInFlight;

  /// Blocchi già migliorati con small.
  int secondPassBlocks = 0;

  /// Chiamato a ogni nuovo segmento (salvataggio nel file di sessione).
  VoidCallback? onSegments;

  /// Correzioni dello studente (inizio del segmento in ms → testo).
  final Map<int, String> _edits = {};

  /// Formule dette a voce → LaTeX.
  bool _formulas = false;
  bool get formulas => _formulas;
  set formulas(bool v) {
    if (v == _formulas) return;
    _formulas = v;
    onSegments?.call();
    notifyListeners();
  }

  /// Conversioni già fatte (il testo si ridisegna spesso).
  final Map<String, String> _latex = {};

  String _shown(String raw) {
    if (!_formulas) return raw;
    final hit = _latex[raw];
    if (hit != null) return hit;
    // il limite cresce con la lezione: con più di 400 frasi (oltre un'ora)
    // la memoria si svuotava a ogni disegno e tutte le frasi si
    // riconvertivano dieci volte al secondo (interfaccia bloccata)
    if (_latex.length > 400 + merger.segments.length * 2) _latex.clear();
    return _latex[raw] = spokenMathToLatex(raw);
  }

  /// Segmenti come li vede (e li salva) lo studente: con le sue correzioni
  /// e, se attive, le formule in LaTeX.
  List<TranscriptSegment> get segments => [
    for (final s in merger.segments)
      s.copyWith(text: _edits[s.start.inMilliseconds] ?? _shown(s.text)),
  ];

  /// Testo provvisorio come si mostra (formule comprese).
  String get partialShown => partial.isEmpty ? '' : _shown(partial);

  String get text => segments.map((s) => s.text).join(' ');

  /// Il segmento [index] è stato corretto a mano.
  bool isEdited(int index) =>
      index >= 0 &&
      index < merger.segments.length &&
      _edits.containsKey(merger.segments[index].start.inMilliseconds);

  /// Correzione del segmento [index] (testo vuoto = frase tolta).
  void editSegment(int index, String text) {
    if (index < 0 || index >= merger.segments.length) return;
    replaceSegments([merger.segments[index].start.inMilliseconds], text);
  }

  /// Modifica dal campo di testo della trascrizione (come in un editor): i
  /// segmenti che iniziano a [startsMs] diventano uno solo con [text]
  /// (inizio del primo, fine dell'ultimo); testo vuoto = tolti. Gli altri
  /// segmenti tengono testo e tempi.
  void replaceSegments(List<int> startsMs, String text) {
    // indici distinti: la stessa chiave due volte (o due frasi con lo stesso
    // inizio) non deve togliere due volte la stessa frase
    final idx = <int>{
      for (final k in startsMs)
        if (merger.segments.indexWhere((s) => s.start.inMilliseconds == k)
            case final i when i >= 0)
          i,
    }.toList()..sort();
    if (idx.isEmpty) return;
    final first = idx.first;
    final lastEnd = merger.segments[idx.last].end;
    // dal fondo, così l'indice del primo non cambia
    for (final i in idx.skip(1).toList().reversed) {
      _edits.remove(merger.segments[i].start.inMilliseconds);
      merger.segments.removeAt(i);
    }
    final seg = merger.segments[first];
    final key = seg.start.inMilliseconds;
    final t = text.trim();
    if (t.isEmpty) {
      merger.segments.removeAt(first);
      _edits.remove(key);
    } else {
      if (lastEnd > seg.end) {
        merger.segments[first] = seg.copyWith(end: lastEnd);
      }
      _edits[key] = t;
    }
    onSegments?.call();
    notifyListeners();
  }

  bool get active =>
      state == LiveState.running ||
      state == LiveState.lagging ||
      state == LiveState.starting;

  /// Fonte del testo, salvata con la trascrizione.
  String get sourceLabel => switch (engine) {
    LiveEngine.system =>
      'trascrizione dal vivo con il riconoscimento vocale del sistema',
    LiveEngine.parakeet => 'trascrizione dal vivo con Parakeet',
    _ when modelId != null && secondPassBlocks > 0 =>
      'trascrizione dal vivo con Whisper $modelId e $kSecondPassModel',
    _ when modelId != null => 'trascrizione dal vivo con Whisper $modelId',
    _ => 'trascrizione dal vivo',
  };

  /// Seconda passata con small in corso (telefono, con Whisper base).
  bool get secondPassActive => _second != null && (_gov?.active ?? false);

  /// Perché la seconda passata si è fermata (null = attiva o mai partita):
  /// solo per i registri, la card non lo scrive più (si ferma da sola e il
  /// testo istantaneo resta).
  SecondPassStop? get secondPassStopped =>
      _second == null ? null : _gov?.stopped;

  /// Frasi di Parakeet in un'altra lingua, per la card «Trascrizione» (null
  /// se non ce ne sono).
  String? get languageNote {
    final n = foreignDropped;
    if (n == 0) return null;
    final lang = language == 'en' ? 'inglese' : 'italiano';
    final one = n == 1;
    final what = one
        ? 'Parakeet ha scritto una frase in un\'altra lingua'
        : 'Parakeet ha scritto $n frasi in un\'altra lingua';
    if (!_rescueUnavailable) {
      return '$what: Whisper ${one ? 'la' : 'le'} ritrascrive in $lang.';
    }
    return '$what (non permette di fissare la lingua): '
        '${one ? 'è stata tolta' : 'sono state tolte'}. Con un modello '
        'Whisper (Collegamenti → Whisper) si ritrascrivono in $lang.';
  }

  /// Avvisi sotto il testo (lingua), null se nessuno.
  String? get note => languageNote;

  /// Avvia il riconoscitore: sistema (se c'è), Parakeet (PC e Mac),
  /// Whisper. Senza motori lo stato diventa [LiveState.unavailable].
  Future<void> begin(
    File wav, {
    required int sampleRate,
    required int channels,
  }) {
    _wav = wav;
    _sampleRate = sampleRate;
    _channels = channels;
    state = LiveState.starting;
    notifyListeners();
    return _starting = _begin();
  }

  Future<void> _begin() async {
    final order = liveEngineOrder(phone: _phone, appleSpeech: appleSpeech);
    // un riconoscitore del sistema passato da fuori (test) va per primo
    final engines = [
      if (speech != null && !order.contains(LiveEngine.system))
        LiveEngine.system,
      ...order,
    ];
    for (final e in engines) {
      if (_closed) return;
      switch (e) {
        case LiveEngine.system:
          if (await _beginSystem()) return;
        case LiveEngine.parakeet:
          if (await _beginParakeet()) return;
        case LiveEngine.whisper:
          await _beginWhisper(Duration.zero);
          return;
        case LiveEngine.none:
          break;
      }
    }
    if (_closed) return;
    state = LiveState.unavailable;
    notifyListeners();
  }

  bool get _phone =>
      _whisper?.isPhone ?? (Platform.isAndroid || Platform.isIOS);

  /// Solo il riconoscitore nuovo di Apple (Mac con macOS 26): mai
  /// SFSpeechRecognizer, che sul Mac chiede la Dettatura e può usare la rete.
  bool get _analyzerOnly => appleSpeech && !_phone;

  Future<bool> _beginSystem() async {
    final sp = speech;
    if (sp == null) return false;
    try {
      final sup = await sp.support(locale, prepare: _analyzerOnly);
      if (_closed) return false;
      systemLanguageMissing = !sup.languageOk;
      if (!sup.available) {
        systemUnavailable = sup.reason;
        return false;
      }
      if (_analyzerOnly && sup.analyzer != 'installed') {
        // modello della lingua non ancora sul Mac (si scarica adesso, in
        // background, per la prossima registrazione) o lingua mancante:
        // trascrive Parakeet
        systemUnavailable = sup.analyzer == 'unsupported'
            ? 'analyzer-unsupported'
            : (sup.analyzer == null ? 'analyzer' : 'analyzer-downloading');
        return false;
      }
      _sub ??= sp.events.listen(_onSpeech);
      final ok = await sp.start(locale: locale, analyzerOnly: _analyzerOnly);
      if (_closed) {
        if (ok) unawaited(sp.stop());
        return false;
      }
      if (!ok) {
        systemUnavailable =
            sp.lastStartError ?? (_analyzerOnly ? 'analyzer' : null);
        return false;
      }
      _feeds = sup.feedsAudio;
      onDevice = sup.onDevice;
      engine = LiveEngine.system;
      state = LiveState.running;
      notifyListeners();
      // niente seconda passata con small sul testo del riconoscitore del
      // sistema: Google e Apple sul dispositivo sono già almeno precisi
      // quanto small, che costerebbe batteria e calore per tutta la lezione
      // (docs/registratore.md, «Seconda passata»)
      return true;
    } catch (e) {
      debugPrint('Riconoscimento vocale del sistema: $e');
      return false;
    }
  }

  // ------------------------------------------------------------ Parakeet

  /// Parakeet su PC e Mac: scarica il modello se manca (l'audio intanto si
  /// accumula e i tratti saltati si recuperano alla fine) e lo avvia.
  /// false = non si usa (telefono, RAM, download non riuscito o annullato,
  /// errore all'avvio): si passa a Whisper.
  /// [fromNow]: il riconoscitore di Apple si è fermato a metà lezione, il
  /// testo fin qui c'è già e Parakeet continua da adesso.
  Future<bool> _beginParakeet({bool fromNow = false}) async {
    final w = _whisper;
    if (w == null) return false;
    final ParakeetService pk;
    try {
      pk = w.parakeet;
      if (!pk.platformSupported) return false;
      parakeetUnavailable = await pk.unavailableReason();
      if (parakeetUnavailable != null) return false;
    } catch (_) {
      return false;
    }
    if (_closed) return false;
    engine = LiveEngine.parakeet;
    modelId = kParakeetId;
    _vadWanted = true;
    if (fromNow) {
      _stable = samplesToDuration(_samples16k);
    } else if (_samples16k > 0) {
      // l'audio arrivato prima di adesso si recupera alla fine
      _skipSamples(0, _samples16k);
    }
    notifyListeners();
    try {
      if (!await pk.installed()) {
        if (!await _downloadParakeet(pk)) {
          _vadGiveUp();
          return false;
        }
      }
      if (_closed) return true;
      final e = await pk.liveEngine();
      if (_closed) {
        unawaited(e.close());
        return true;
      }
      _vad = e;
    } catch (e) {
      debugPrint('Parakeet: $e');
      parakeetUnavailable = '$e';
      _vadGiveUp();
      return false;
    }
    if (_finished) return true;
    state = _lagSkips > 0 ? LiveState.lagging : LiveState.running;
    notifyListeners();
    _pumpVad();
    return true;
  }

  /// Parakeet non si usa: l'audio accumulato diventa un tratto da
  /// recuperare con il motore successivo.
  void _vadGiveUp() {
    _vadWanted = false;
    _backlog.clear();
    engine = LiveEngine.none;
    modelId = null;
    partial = '';
  }

  Future<bool> _downloadParakeet(ParakeetService pk) async {
    final cancel = _pkDownload = CancelToken();
    downloading = true;
    downloadProgress = pk.progress ?? 0;
    downloadWhat = 'Parakeet (${kParakeetModel.disk})';
    downloadError = null;
    notifyListeners();
    var shown = -1;
    try {
      await for (final pr in pk.download(cancel: cancel)) {
        if (_closed) break;
        downloadProgress = pr.fraction;
        final pct = ((pr.fraction ?? 0) * 100).floor();
        if (pct != shown) {
          shown = pct;
          notifyListeners();
        }
      }
      return !_closed && await pk.installed();
    } catch (e) {
      if (!cancel.isCancelled) downloadError = '$e';
      return false;
    } finally {
      _pkDownload = null;
      downloading = false;
      downloadProgress = null;
      if (!_closed) notifyListeners();
    }
  }

  /// «Annulla» sotto la barra del download: si registra senza testo dal
  /// vivo (o con il modello Whisper scaricato) e la parte già scaricata
  /// resta per la prossima volta.
  void cancelDownload() {
    _pkDownload?.cancel();
    _download?.cancel();
  }

  LiveChunk _extraChunk(Duration from, Duration to) {
    const overlap = Duration(milliseconds: 300);
    final s = from - overlap;
    return LiveChunk(_extraIndex++, s < Duration.zero ? Duration.zero : s, to);
  }

  /// Tratto da [fromSample] a [toSample] saltato (da recuperare alla fine).
  void _skipSamples(int fromSample, int toSample) {
    final from = samplesToDuration(fromSample);
    var start = _stable < from ? _stable : from;
    final end = samplesToDuration(toSample);
    // le parole già confermate restano: si recupera dopo di loro
    final done = _agree.confirmedEnd;
    if (_agree.open) {
      _agree.close();
      partial = '';
      if (done != null && done > start) start = done;
    }
    if (end - start >= const Duration(milliseconds: 600)) {
      _extraPending.add(_extraChunk(start, end));
    }
    _stable = end;
  }

  void _pumpVad() {
    final e = _vad;
    if (e == null || _vadInFlight != null || _closed || _finished) return;
    if (state == LiveState.failed) return;
    final batch = _backlog.take();
    if (batch == null) return;
    final d = batch.dropped;
    if (d != null) {
      _skipSamples(d.from, d.to);
      _lagSkips++;
    }
    _vadInFlight = _vadStep(e, batch.start, batch.samples).whenComplete(() {
      _vadInFlight = null;
      if (!_closed) _pumpVad();
    });
  }

  Future<void> _vadStep(VadLiveEngine e, int start, Float32List s) async {
    try {
      final step = await e.feed(start, s);
      if (_finished || _closed) return;
      lastTook = step.took;
      if (step.stableUntil > _stable) _stable = step.stableUntil;
      final now = samplesToDuration(start + s.length);
      if (step.committed.isNotEmpty) {
        // fine frase: il testo definitivo sostituisce le parole confermate
        _agree.finish(_inLanguage(step.committed), now: now);
        _segmentsChanged(force: true);
      }
      final pt = step.partial;
      if (pt != null) {
        if (pt.isEmpty) {
          if (step.committed.isEmpty) _agree.close();
          partial = '';
        } else if (outsideLecture(pt, lecture: language)) {
          // ipotesi in un'altra lingua: non si conferma e non si mostra
          partial = '';
        } else {
          final words = step.partialWords.isEmpty
              ? wordsOfText(pt)
              : step.partialWords;
          if (_agree.hypothesis(words, now: now)) _segmentsChanged();
          partial = _agree.pending;
        }
      }
      state = _lagSkips > 0 ? LiveState.lagging : LiveState.running;
      notifyListeners();
    } catch (err) {
      if (_finished || _closed) return;
      debugPrint('Parakeet dal vivo: $err');
      error = '$err';
      partial = '';
      _vad = null;
      unawaited(e.close().catchError((_) {}));
      // si continua con il modello Whisper scaricato, se c'è, dal punto
      // in cui il testo era definitivo (dopo le parole già confermate)
      var from = _stable;
      final done = _agree.confirmedEnd;
      if (done != null && done > from) from = done;
      _agree.close();
      _vadGiveUp();
      state = LiveState.starting;
      notifyListeners();
      await _beginWhisper(from);
      if (_engine == null && !_closed) {
        state = LiveState.failed;
        notifyListeners();
      }
    }
  }

  /// Frasi di Parakeet nella lingua della lezione: le altre
  /// si tolgono e il loro tratto si ritrascrive con Whisper, nella lingua
  /// della lezione, con il modello incluso nell'app desktop o uno scaricato
  /// ([_pumpRescue]).
  List<TranscriptSegment> _inLanguage(
    List<TranscriptSegment> segs, {
    File? source,
  }) {
    final out = <TranscriptSegment>[];
    for (final s in segs) {
      if (!outsideLecture(s.text, lecture: language)) {
        out.add(s);
        continue;
      }
      debugPrint('Parakeet, frase in un\'altra lingua: ${s.text}');
      foreignDropped++;
      if (!_rescueUnavailable) {
        _rescueQueue.add(LiveChunk(_extraIndex++, s.start, s.end));
      }
    }
    if (_rescueQueue.isNotEmpty) _pumpRescue(source: source);
    return out;
  }

  void _pumpRescue({File? source}) {
    if (_rescueInFlight != null || _closed || _rescueQueue.isEmpty) return;
    final c = _rescueQueue.removeAt(0);
    _rescueInFlight = _rescueOne(c, source: source).whenComplete(() {
      _rescueInFlight = null;
      if (!_closed) _pumpRescue(source: source);
    });
  }

  Future<void> _rescueOne(LiveChunk c, {File? source}) async {
    try {
      var e = _rescueEngine;
      if (e == null) {
        final w = _whisper;
        e = w == null
            ? null
            : await w.liveEngine(
                options: await w.optionsFor(
                  buildWhisperPrompt(vocabulary),
                  language: language,
                ),
              );
        if (_closed) {
          unawaited(e?.close());
          return;
        }
        if (e == null) {
          _rescueUnavailable = true;
          _rescueQueue.clear();
          notifyListeners();
          return;
        }
        _rescueEngine = e;
      }
      const pad = Duration(milliseconds: 200);
      final from = c.start > pad ? c.start - pad : Duration.zero;
      final segs = (await _run(
        LiveChunk(c.index, from, c.end + pad),
        source: source,
        using: e,
      )).segments;
      if (_closed) return;
      final kept = [
        for (final s in segs)
          if (!outsideLecture(s.text, lecture: language)) s,
      ];
      if (kept.isNotEmpty) {
        merger.add(kept);
        foreignRescued++;
        _segmentsChanged(force: true);
        notifyListeners();
      }
    } catch (err) {
      debugPrint('Ritrascrizione con Whisper: $err');
    }
  }

  // ------------------------------------------------------------- Whisper

  /// Whisper dal punto [from] della registrazione in poi. Se manca il
  /// modello dal vivo (telefono) lo scarica (barra nella card); l'audio
  /// registrato nel frattempo si trascrive dopo il salvataggio.
  Future<void> _beginWhisper(Duration from) async {
    final w = _whisper;
    if (w != null && !_finished) await _ensureLiveModel(w);
    if (_closed) return;
    var options = WhisperOptions.none;
    try {
      if (w != null) {
        options = await w.optionsFor(
          buildWhisperPrompt(vocabulary),
          language: language,
        );
      }
      _engine = await w?.liveEngine(options: options);
    } catch (e) {
      _engine = null;
    }
    if (_closed) {
      unawaited(_engine?.close());
      return;
    }
    final eng = _engine;
    if (eng == null) {
      if (engine != LiveEngine.parakeet) engine = LiveEngine.none;
      state = LiveState.unavailable;
    } else {
      engine = LiveEngine.whisper;
      modelId = eng.modelId;
      quick = eng.quick;
      final pl = planner =
          _customPlanner ??
          (eng.quick ? LiveWindowPlanner() : LiveWindowPlanner.slow());
      pl.startAt(from);
      pl.skipTo(_recorded);
      state = LiveState.running;
      try {
        _tmp ??= await Directory.systemTemp.createTemp('uninotes_live_');
      } catch (e) {
        // disco pieno: si riprova al primo pezzo (_run), dove un errore
        // ferma solo il testo dal vivo
        debugPrint('Cartella temporanea del testo dal vivo: $e');
      }
      if (eng.quick && w != null && w.isPhone && !_finished) {
        unawaited(_beginSecondPass(w, options));
      }
    }
    notifyListeners();
    _pump();
  }

  /// Scarica il modello dal vivo se manca (sul telefono solo con Wi‑Fi:
  /// con i dati mobili si usa il modello già scaricato, se c'è).
  Future<void> _ensureLiveModel(WhisperService w) async {
    try {
      if (!w.builtInSupported) return;
      if (!w.liveModelSupported || await w.liveModelFile() != null) return;
      if (w.isPhone && !await Power.onWifi()) return;
    } catch (_) {
      return;
    }
    if (_closed) return;
    final cancel = _download = CancelToken();
    downloading = true;
    downloadProgress = 0;
    downloadWhat =
        'il modello per il testo dal vivo (${kLiveWhisperModel.disk})';
    notifyListeners();
    var shown = -1;
    try {
      await for (final pr in w.downloadLiveModel(cancel: cancel)) {
        if (_closed) break;
        downloadProgress = pr.fraction;
        final pct = ((pr.fraction ?? 0) * 100).floor();
        if (pct != shown) {
          shown = pct;
          notifyListeners();
        }
      }
    } catch (e) {
      if (!cancel.isCancelled) downloadError = '$e';
    } finally {
      _download = null;
      downloading = false;
      downloadProgress = null;
      if (!_closed) notifyListeners();
    }
  }

  // ---------------------------------------------- seconda passata (small)

  Future<void> _beginSecondPass(WhisperService w, WhisperOptions o) async {
    if (_second != null || _secondStarting) return;
    _secondStarting = true;
    try {
      await w.ensureSecondPassModel();
      if (_closed || _finished) return;
      final e = await w.secondPassEngine(options: o);
      if (e == null) return;
      if (_closed || _finished) {
        unawaited(e.close());
        return;
      }
      _second = e;
      _gov = SecondPassGovernor(
        probe: await w.secondPassProbe(),
        maxRtf: kSecondPassMaxRtf,
      );
      notifyListeners();
      _pumpSecond();
    } catch (e) {
      debugPrint('Seconda passata: $e');
    } finally {
      _secondStarting = false;
    }
  }

  bool _secondStarting = false;

  /// Fin dove il testo istantaneo non cambia più: l'inizio del tratto
  /// provvisorio di Whisper o, con il riconoscitore del sistema, la fine
  /// dell'ultima frase stabilizzata.
  Duration get _secondStable {
    final s = engine == LiveEngine.system
        ? (merger.segments.isEmpty ? Duration.zero : merger.segments.last.end)
        : planner.anchor;
    // la frase in corso (parole confermate per accordo) può ancora cambiare
    final open = _agree.openFrom;
    return open != null && open < s ? open : s;
  }

  void _pumpSecond() {
    final e = _second;
    final g = _gov;
    if (e == null || g == null || _secondInFlight != null) return;
    if (_closed || _finished) return;
    g.checkBehind(_recorded, _sp.done);
    if (!g.active && g.stopped != SecondPassStop.battery) return;
    final b = _sp.next(merger.segments, stableUntil: _secondStable);
    if (b == null) return;
    _secondInFlight = _secondBlock(e, g, b.start, b.end).whenComplete(() {
      _secondInFlight = null;
      if (!_closed) _pumpSecond();
    });
  }

  Future<void> _secondBlock(
    LiveWhisper e,
    SecondPassGovernor g,
    Duration start,
    Duration end,
  ) async {
    final was = g.stopped;
    g.checkBattery(
      level: await Power.batteryLevel(),
      charging: await Power.charging(),
    );
    if (g.stopped != was) notifyListeners();
    if (!g.active) {
      // batteria bassa: si riprova fra un minuto (con il caricabatterie
      // si riprende)
      for (var i = 0; i < 60 && !_closed && !_finished; i++) {
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      return;
    }
    final sw = Stopwatch()..start();
    try {
      final segs = (await _run(LiveChunk(-1, start, end), using: e)).segments;
      final rtf = sw.elapsed.inMicroseconds / (end - start).inMicroseconds;
      if (g.record(rtf)) {
        unawaited(_whisper?.recordSecondPassProbe(rtf));
      }
      _sp.markDone(end);
      if (_finished || _closed) return;
      final before = merger.segments.length;
      final next = replaceRange(
        merger.segments,
        start,
        end,
        segs,
        edited: (s) => _edits.containsKey(s.start.inMilliseconds),
      );
      if (segs.isNotEmpty || next.length != before) {
        merger.segments
          ..clear()
          ..addAll(next);
        secondPassBlocks++;
        final at = merger.segments.indexWhere((s) => s.end > start);
        _segmentsChanged(force: true, recaseFrom: at < 0 ? 0 : at);
      }
      notifyListeners();
    } catch (err) {
      debugPrint('Seconda passata: $err');
      _sp.markDone(end);
      g.stopped = SecondPassStop.behind;
      notifyListeners();
    }
  }

  // ------------------------------------------------- sistema (spento)

  void _onSpeech(SpeechEvent e) {
    if (_closed && e.kind != SpeechEventKind.ended) return;
    switch (e.kind) {
      case SpeechEventKind.partial:
        final t = e.text.trim();
        if (t.isEmpty || t == _sysHyp) return;
        // la frase è iniziata poco prima del primo testo provvisorio
        final from = _partialStart ??= _startOfSpeech();
        _sysHyp = t;
        // parole uguali in due testi provvisori di fila: confermate subito
        final words = wordsOfText(t, from: from, to: _recorded);
        if (_agree.hypothesis(words, now: _recorded)) _segmentsChanged();
        partial = _agree.pending;
        notifyListeners();
      case SpeechEventKind.result:
        _commit(e.text);
      case SpeechEventKind.error:
        if (!e.fatal) return;
        debugPrint('Riconoscimento vocale del sistema: ${e.text}');
        error = e.text;
        // il motivo resta visibile nella card (es. Dettatura disattivata)
        systemUnavailable ??= e.text;
        _commit(_sysHyp);
        _fallbackToWhisper();
      case SpeechEventKind.ended:
        final done = _ended;
        if (done != null && !done.isCompleted) done.complete();
    }
  }

  Duration _startOfSpeech() {
    final last = segments.isEmpty ? Duration.zero : segments.last.end;
    final guess = _recorded - const Duration(seconds: 1);
    return guess < last ? last : guess;
  }

  /// Testo stabilizzato dal sistema: sostituisce le parole confermate della
  /// frase e diventa una o più frasi (alla punteggiatura) con i tempi della
  /// registrazione.
  void _commit(String raw) {
    final t = raw.trim();
    final start = _partialStart ?? _startOfSpeech();
    _partialStart = null;
    _sysHyp = '';
    partial = '';
    if (t.isEmpty || isHallucination(t)) {
      // niente testo definitivo: le parole confermate restano
      _agree.close();
      notifyListeners();
      return;
    }
    final end = _recorded > start
        ? _recorded
        : start + const Duration(milliseconds: 500);
    _agree.finish(splitTextSentences(t, start, end), now: _recorded);
    _segmentsChanged(force: true);
    notifyListeners();
  }

  /// Il riconoscitore del sistema si è fermato: si continua dal punto
  /// attuale (il testo già riconosciuto resta) con Parakeet sul Mac,
  /// altrimenti (o se Parakeet non parte) con Whisper.
  void _fallbackToWhisper() {
    if (engine != LiveEngine.system) return;
    engine = LiveEngine.none;
    _feeds = false;
    unawaited(_sub?.cancel());
    _sub = null;
    unawaited(speech?.stop());
    state = LiveState.starting;
    notifyListeners();
    final order = liveEngineOrder(phone: _phone, appleSpeech: appleSpeech);
    unawaited(() async {
      if (order.contains(LiveEngine.parakeet) &&
          await _beginParakeet(fromNow: true)) {
        return;
      }
      if (!_closed) await _beginWhisper(_recorded);
    }());
  }

  // ------------------------------------------------------------- audio

  /// Il formato del WAV è cambiato prima dei dati (scelta del sistema).
  void setFormat(int sampleRate, int channels) {
    if (sampleRate <= 0 || channels <= 0) return;
    _sampleRate = sampleRate;
    _channels = channels;
  }

  /// Audio appena registrato (PCM 16 bit nel formato del WAV): al
  /// riconoscitore del sistema o a Parakeet, mono a 16 kHz.
  void onPcm(Uint8List data) {
    if (_closed) return;
    final frames = data.length ~/ (2 * _channels);
    final n16 = _sampleRate == 16000
        ? frames
        : (frames * 16000 / _sampleRate).floor();
    final at = _samples16k;
    _samples16k += n16;
    final toSystem = _feeds && engine == LiveEngine.system;
    final toVad = _vadWanted && !_finished;
    if (!toSystem && !toVad) return;
    try {
      final samples = pcm16(data);
      final mono = _sampleRate == 16000 && _channels == 1
          ? samples
          : toMono16k(samples, _sampleRate, _channels);
      if (toSystem) speech?.feed(mono);
      if (toVad) {
        _backlog.add(at, int16ToFloat(mono));
        if (_vad == null) {
          // modello non ancora pronto (download): si tiene l'audio recente
          final d = _backlog.trim();
          if (d != null) _skipSamples(d.from, d.to);
        } else {
          _pumpVad();
        }
      }
    } catch (_) {
      // un pezzo perso non ferma niente
    }
  }

  /// Nuovo audio registrato fino a [recorded].
  void onAudio(Duration recorded) {
    _recorded = recorded;
    _pumpSecond();
    if (_engine == null || _closed || _finished) return;
    if (state == LiveState.failed) return;
    final next = planner.lagSkips > 0 ? LiveState.lagging : LiveState.running;
    if (next != state) {
      state = next;
      notifyListeners();
    }
    _pump();
  }

  /// Pausa e ripresa della registrazione.
  void pause() {
    if (engine == LiveEngine.system) unawaited(speech?.pause());
  }

  void resume() {
    if (engine == LiveEngine.system) unawaited(speech?.resume());
  }

  void _pump() {
    if (_inFlight != null || _closed || _finished || _engine == null) return;
    if (state == LiveState.failed) return;
    // Whisper troppo indietro (il tratto vecchio si salta e si recupera
    // alla fine): le parole già confermate restano, si salta da lì
    if (_agree.open &&
        !planner.busy &&
        _recorded - planner.anchor > planner.maxWindow * 3) {
      final done = _agree.confirmedEnd;
      _agree.close();
      partial = '';
      if (done != null) planner.startAt(done);
    }
    final c = planner.next(_recorded);
    if (c == null) return;
    _inFlight = _window(c).whenComplete(() {
      _inFlight = null;
      if (!_closed) _pump();
    });
  }

  /// Trascrive la finestra [c]: testo provvisorio e segmenti definitivi.
  Future<void> _window(LiveChunk c) async {
    final sw = Stopwatch()..start();
    try {
      final r = await _run(c);
      if (_finished || _closed) {
        planner.abandon();
        return;
      }
      lastTook = sw.elapsed;
      final out = planner.done(
        c,
        r.segments,
        silentTail: r.silentTail,
        took: sw.elapsed,
      );
      // frasi della finestra (come le vede il pianificatore)
      final segs = [
        for (final s in r.segments)
          if (!isHallucination(s.text)) s.copyWith(text: s.text.trim()),
      ];
      if (out.committed.isNotEmpty) {
        // finestra definitiva: sostituisce le parole confermate; con la
        // finestra piena l'ultima frase resta provvisoria (e le sue parole
        // già confermate passano alla finestra dopo)
        final carry = out.provisional.isNotEmpty;
        _agree.finish(out.committed, carry: carry, now: c.end);
        if (carry && segs.isNotEmpty) {
          _agree.hypothesis(wordsOfSegments([segs.last]), now: c.end);
        }
        _segmentsChanged(force: true);
        partial = carry ? _agree.pending : '';
      } else if (out.provisional.isNotEmpty) {
        // ipotesi: le parole uguali alla finestra di prima si confermano
        if (_agree.hypothesis(wordsOfSegments(segs), now: c.end)) {
          _segmentsChanged();
        }
        partial = _agree.pending;
      } else {
        // silenzio: se la finestra riparte da qui la frase è finita
        if (planner.anchor >= c.end) _agree.close();
        partial = '';
      }
      notifyListeners();
      _pumpSecond();
    } catch (e) {
      planner.abandon();
      debugPrint('Trascrizione dal vivo: $e');
      error = '$e';
      partial = '';
      state = LiveState.failed;
      notifyListeners();
    }
  }

  Future<void> _process(LiveChunk c, {File? source}) async {
    try {
      final segs = await transcribeChunk(c, source: source);
      if (_recovered(c, segs)) {
        _segmentsChanged(force: true);
        notifyListeners();
      }
    } catch (e) {
      debugPrint('Trascrizione dal vivo: $e');
      error = '$e';
      state = LiveState.failed;
      notifyListeners();
    }
  }

  /// Trascrive il tratto [c] del WAV (tempi riferiti alla registrazione).
  /// I pezzi silenziosi non vanno a Whisper (eviterebbe frasi inventate).
  Future<List<TranscriptSegment>> transcribeChunk(
    LiveChunk c, {
    File? source,
  }) async => (await _run(c, source: source)).segments;

  Future<({List<TranscriptSegment> segments, bool silentTail})> _run(
    LiveChunk c, {
    File? source,
    LiveWhisper? using,
  }) async {
    const none = (segments: <TranscriptSegment>[], silentTail: true);
    final engine = using ?? _engine;
    final wav = source ?? _wav;
    if (engine == null || wav == null) return none;
    final info = source == null
        ? WavInfo(
            sampleRate: _sampleRate,
            channels: _channels,
            dataLength: 1 << 40,
          )
        : await readWavInfo(source);
    if (info == null) return none;
    final raw = await readWavRange(wav, info, c.start, c.end);
    if (raw.isEmpty) return none;
    final mono = toMono16k(raw, info.sampleRate, info.channels);
    if (pcmLevel(mono) < 0.12) return none;
    final silentTail = endsInPause(mono);
    final dir = _tmp ??= await Directory.systemTemp.createTemp(
      'uninotes_live_',
    );
    final name = using == null
        ? 'pezzo_${c.index}'
        : 'seconda_${c.start.inMilliseconds}';
    final file = File(p.join(dir.path, '$name.wav'));
    await writeWav16k(file, mono);
    try {
      final out = await engine.transcribeWav(file);
      return (
        segments: [
          for (var i = 0; i < out.length; i++)
            TranscriptSegment(
              c.start + out[i].start,
              c.start +
                  (out[i].end ??
                      (i + 1 < out.length
                          ? out[i + 1].start
                          : c.end - c.start)),
              out[i].text,
            ),
        ],
        silentTail: silentTail,
      );
    } finally {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Fine dell'audio del riconoscitore del sistema: attende l'ultimo testo
  /// (al massimo [timeout]); quello ancora provvisorio diventa definitivo.
  Future<void> flush({Duration timeout = const Duration(seconds: 2)}) async {
    if (engine != LiveEngine.system) return;
    final sp = speech;
    if (sp == null) return;
    final done = _ended = Completer<void>();
    _feeds = false;
    await sp.stop();
    try {
      await done.future.timeout(timeout);
    } on TimeoutException {
      // il sistema non ha risposto: resta il testo provvisorio
    }
    if (_sysHyp.trim().isNotEmpty) {
      _commit(_sysHyp);
    } else {
      _agree.close();
    }
  }

  /// Fine registrazione a [recorded]: tratti ancora da trascrivere (saltati
  /// e quello non ancora definitivo). Il testo provvisorio sparisce: il suo
  /// tratto si ritrascrive dopo il salvataggio. Il download di Parakeet, se
  /// è in corso, continua: alla fine i tratti si trascrivono con Parakeet.
  List<LiveChunk> finish(Duration recorded) {
    _download?.cancel();
    _finished = true;
    partial = '';
    const minTail = Duration(milliseconds: 600);
    if (_vadWanted || _vad != null) {
      _backlog.clear();
      final out = [..._extraPending];
      _extraPending.clear();
      if (recorded - _stable >= minTail) {
        // la frase in corso: il suo testo definitivo arriva dal recupero e
        // sostituisce le parole confermate ([_recovered])
        out.add(_extraChunk(_stable, recorded));
      } else {
        _agree.close();
      }
      _stable = recorded;
      return out..sort((a, b) => a.start.compareTo(b.start));
    }
    if (_engine == null) {
      _agree.close();
      return const [];
    }
    if (recorded - planner.anchor < minTail) _agree.close();
    return [..._extraPending, ...planner.finish(recorded, minTail: minTail)]
      ..sort((a, b) => a.start.compareTo(b.start));
  }

  /// Testo [segs] del tratto recuperato [c]: se è quello della frase in
  /// corso sostituisce le parole confermate, altrimenti si inserisce al
  /// suo posto. true se i segmenti sono cambiati.
  bool _recovered(LiveChunk c, List<TranscriptSegment> segs) {
    final from = _agree.openFrom ?? _agree.confirmedEnd;
    if (_agree.open && from != null && c.end > from) {
      return _agree.finish(segs);
    }
    if (segs.isEmpty) return false;
    merger.add(segs);
    return true;
  }

  /// Il motore sta trascrivendo un pezzo (o Parakeet si sta ancora
  /// scaricando: i tratti si trascriveranno dopo).
  bool get busy =>
      _inFlight != null ||
      _vadInFlight != null ||
      _rescueInFlight != null ||
      _rescueQueue.isNotEmpty ||
      (_vadWanted && _vad == null && !_closed);

  /// Attende il pezzo in corso.
  Future<void> settle() async {
    await _inFlight;
    await _vadInFlight;
  }

  /// Attende le frasi in un'altra lingua ancora da ritrascrivere ([source]:
  /// il WAV da cui leggerle dopo il salvataggio).
  Future<void> _settleRescue(File? source) async {
    while (!_closed && (_rescueInFlight != null || _rescueQueue.isNotEmpty)) {
      if (_rescueInFlight == null) _pumpRescue(source: source);
      await _rescueInFlight;
    }
  }

  /// Recupera i tratti [chunks] leggendo da [source] (il WAV della
  /// registrazione). [progress] riceve (fatti, totale). Con Parakeet ancora
  /// in download si aspetta che finisca.
  Future<void> recover(
    List<LiveChunk> chunks,
    File source, {
    void Function(int done, int total)? progress,
  }) async {
    await settle();
    try {
      await _starting;
    } catch (_) {}
    if (state == LiveState.failed) return;
    final vad = _vad;
    if (vad != null) {
      for (var i = 0; i < chunks.length; i++) {
        progress?.call(i, chunks.length);
        try {
          final segs = await vad.transcribeRange(
            source,
            chunks[i].start,
            chunks[i].end,
          );
          if (_recovered(chunks[i], _inLanguage(segs, source: source))) {
            _segmentsChanged(force: true);
            notifyListeners();
          }
        } catch (e) {
          debugPrint('Parakeet, recupero: $e');
          error = '$e';
          state = LiveState.failed;
          notifyListeners();
          return;
        }
      }
      await _settleRescue(source);
      progress?.call(chunks.length, chunks.length);
      return;
    }
    if (_engine == null) {
      await _settleRescue(source);
      return;
    }
    for (var i = 0; i < chunks.length; i++) {
      progress?.call(i, chunks.length);
      await _process(chunks[i], source: source);
      if (state == LiveState.failed) return;
    }
    await _settleRescue(source);
    progress?.call(chunks.length, chunks.length);
  }

  /// Libera il riconoscitore, i modelli e i file temporanei.
  Future<void> close() async {
    _closed = true;
    _feeds = false;
    _download?.cancel();
    _pkDownload?.cancel();
    final sub = _sub;
    _sub = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    if (engine == LiveEngine.system) {
      final ended = _ended;
      if (ended == null) unawaited(speech?.stop());
    }
    try {
      await _inFlight;
    } catch (_) {}
    try {
      await _vadInFlight;
    } catch (_) {}
    try {
      await _engine?.close();
    } catch (_) {}
    _engine = null;
    try {
      await _vad?.close();
    } catch (_) {}
    _vad = null;
    try {
      await _second?.close();
    } catch (_) {}
    _second = null;
    _rescueQueue.clear();
    try {
      await _rescueInFlight;
    } catch (_) {}
    try {
      await _rescueEngine?.close();
    } catch (_) {}
    _rescueEngine = null;
    final tmp = _tmp;
    _tmp = null;
    try {
      if (tmp != null && await tmp.exists()) await tmp.delete(recursive: true);
    } catch (_) {}
  }

  /// Segmenti già trascritti (da un file di sessione dopo un riavvio).
  void restore(List<TranscriptSegment> segs) {
    _agree.close();
    merger.segments
      ..clear()
      ..addAll(segs);
  }
}

/// La finestra [mono16k] finisce in una pausa: l'ultimo mezzo secondo è
/// molto più basso del resto (~10 dB) o quasi silenzioso. Lì il testo
/// diventa definitivo.
bool endsInPause(
  Int16List mono16k, {
  Duration tail = const Duration(milliseconds: 500),
}) {
  final n = tail.inMilliseconds * 16;
  if (mono16k.length < n * 2) return false;
  final end = pcmLevel(Int16List.sublistView(mono16k, mono16k.length - n));
  final all = pcmLevel(Int16List.sublistView(mono16k, 0, mono16k.length - n));
  return end < 0.15 || end < all - 0.17;
}
