import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/services/app_services.dart';
import '../../core/services/audio_codec.dart';
import '../../core/services/whisper_service.dart'
    show WhisperModelInfo, whisperModelLabel;
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/find_bar.dart';
import '../../widgets/math_text.dart';
import '../../widgets/share_files.dart';
import '../../widgets/undo_snack_bar.dart';
import '../reader/views/media_view.dart' show readerMediaEnabled;
import '../study/study_widgets.dart' show promptText;
import 'background_jobs.dart';
import 'course_notes_screen.dart' show ReferenceAiButton, TranscriptButton;
import 'lesson_transcripts.dart';
import 'note_viewer_screen.dart';
import 'notes_actions.dart';
import 'notes_store.dart';
import 'recorder/recording_meta.dart';
import 'recorder/recording_save.dart' show writeTranscriptFor;
import 'recorder/wav.dart';
import 'recorder/waveform.dart';
import 'recycle_bin.dart' show moveFile;
import 'spell_check.dart'
    show ReadingSpellChecker, misspelledSpans, spellLanguageOf;

/// Una registrazione, come in Memo Vocali: forma d'onda che scorre sotto la
/// linea di lettura (trascinabile, fluida a ogni fotogramma), indietro e
/// avanti di 15 e 30 s, velocità 0,5–2×, «Salta silenzi», segnalibri e la
/// trascrizione sincronizzata (il segmento in corso è evidenziato, un tocco
/// salta a quel punto).
///
/// Il nome si rinomina toccandolo, il cestino elimina (in «Eliminati di
/// recente»). Il riquadro della trascrizione ha i suoi comandi: cerca,
/// copia, «Apri in» (l'AI di riferimento) e, se ci sono sia quella di Whisper
/// sia quella di Gemini, la scelta fra le due (con i loro colori).
class RecordingPlayerScreen extends StatefulWidget {
  const RecordingPlayerScreen({
    super.key,
    required this.course,
    required this.file,
    this.justRecorded = false,
    this.query,
    this.transcript,
  });

  final Course course;
  final File file;

  /// Aperta subito dopo il salvataggio.
  final bool justRecorded;

  /// Testo da cercare all'apertura (ricerca fra tutte le trascrizioni).
  final String? query;

  /// Trascrizione da mostrare (null = Whisper o dal vivo, altrimenti Gemini).
  final TranscriptKind? transcript;

  @override
  State<RecordingPlayerScreen> createState() => _RecordingPlayerScreenState();
}

const kPlaybackSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

enum _Menu { shareAudio, shareText, shareBoth, summarize, trim, whisper }

/// Posizione di riproduzione aggiornata a ogni fotogramma: fra due
/// posizioni del lettore (che arrivano a intervalli irregolari) si avanza
/// con il tempo trascorso e la velocità. Solo chi la ascolta si ridisegna.
class PlaybackClock extends ValueNotifier<Duration> {
  PlaybackClock(TickerProvider vsync) : super(Duration.zero) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  final _since = Stopwatch();
  Duration _reported = Duration.zero;
  bool _playing = false;
  double rate = 1;
  Duration total = Duration.zero;

  /// Massimo anticipo sull'ultima posizione del lettore (se il lettore si
  /// blocca, la forma d'onda non scappa avanti).
  static const maxLead = Duration(milliseconds: 600);

  bool get playing => _playing;

  /// Posizione indicata dal lettore.
  void report(Duration d) {
    _reported = d;
    _since
      ..reset()
      ..start();
    if (!_playing) value = d;
  }

  set playing(bool v) {
    if (v == _playing) return;
    _playing = v;
    if (v) {
      _since
        ..reset()
        ..start();
      if (!_ticker.isActive) _ticker.start();
    } else {
      _ticker.stop();
      value = _reported;
    }
  }

  /// Salto (seek): la posizione cambia subito.
  void jump(Duration d) {
    _reported = d;
    _since
      ..reset()
      ..start();
    value = d;
  }

  void _tick(Duration _) {
    var lead = _since.elapsed * rate;
    if (lead > maxLead) lead = maxLead;
    var v = _reported + lead;
    if (total > Duration.zero && v > total) v = total;
    value = v;
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

class _RecordingPlayerScreenState extends State<RecordingPlayerScreen>
    with TickerProviderStateMixin {
  late final AppServices _s = context.read<AppServices>();
  late File _file = widget.file;

  RecordingMeta _meta = RecordingMeta();
  LessonTranscripts _transcripts = LessonTranscripts.none;

  /// Trascrizione mostrata (Whisper o dal vivo = [TranscriptKind.whisper]).
  late TranscriptKind _kind = widget.transcript ?? TranscriptKind.whisper;
  List<TranscriptSegment> _segs = const [];
  String? _plainText;

  /// Modello che userebbe «Trascrivi con Whisper».
  WhisperModelInfo? _whisperModel;
  File? _summary;
  Uint8List _peaks = Uint8List(0);
  bool _peaksLoading = false;

  Player? _player;
  String? _playerError;
  final _subs = <StreamSubscription<Object?>>[];
  late final PlaybackClock _clock = PlaybackClock(this);
  Duration _dur = Duration.zero;
  bool _playing = false;
  double _rate = 1;
  bool _skipSilence = false;
  final _scrub = ValueNotifier<Duration?>(null);

  final _scroll = ScrollController();
  final _list = ListController();
  int _current = -1;

  /// Linea rossa sulle parole errate della trascrizione, come nella modifica.
  late final ReadingSpellChecker _spell = ReadingSpellChecker(
    language: spellLanguageOf(widget.course.examLanguage),
  )..addListener(_spellChanged);

  void _spellChanged() {
    if (mounted) setState(() {});
  }

  bool _searchOpen = false;
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  List<int> _matches = const [];
  int _match = 0;

  NoteFile get _note =>
      NoteFile(_file, NoteFolder.recordings, DateTime.now(), 0);
  String get _name => p.basenameWithoutExtension(_file.path);
  Duration get _pos => _clock.value;
  Duration get _total =>
      _dur > Duration.zero ? _dur : (_meta.duration ?? Duration.zero);

  /// File della trascrizione mostrata.
  File? get _transcript => _kind == TranscriptKind.gemini
      ? _transcripts.gemini
      : (_transcripts.whisper ?? _transcripts.systemLive);

  @override
  void initState() {
    super.initState();
    _s.revision.addListener(_reload);
    _clock.addListener(_onClock);
    final q = widget.query?.trim();
    if (q != null && q.isNotEmpty) {
      _searchOpen = true;
      _query.text = q;
    }
    _load();
    _initPlayer();
    if (widget.justRecorded) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) showSnack(context, 'Registrazione salvata.');
      });
    }
  }

  @override
  void dispose() {
    _s.revision.removeListener(_reload);
    _clock.removeListener(_onClock);
    _closePlayer();
    _clock.dispose();
    _scrub.dispose();
    _scroll.dispose();
    _list.dispose();
    _spell.dispose();
    _query.dispose();
    _queryFocus.dispose();
    super.dispose();
  }

  void _reload() {
    if (mounted) _load();
  }

  // ------------------------------------------------------------ dati

  /// Dati della registrazione letti dal file (fino ad allora i segnalibri in
  /// memoria sono solo quelli aggiunti adesso, vedi [_saveMeta]).
  bool _metaLoaded = false;

  Future<void> _load() async {
    try {
      await _loadData();
    } catch (e) {
      // trascrizione illeggibile, cartella non raggiungibile: la
      // registrazione resta ascoltabile con quello che si è letto
      debugPrint('Dati della registrazione: $e');
      if (!_metaLoaded) {
        final meta = await RecordingMeta.load(_file.path);
        if (!mounted) return;
        setState(() {
          _meta = meta;
          _metaLoaded = true;
          if (meta.peaks != null && meta.peaks!.isNotEmpty) {
            _peaks = meta.peaks!;
          }
        });
      }
    }
  }

  Future<void> _loadData() async {
    if (!await _file.exists()) return;
    final meta = await RecordingMeta.load(_file.path);
    final dir = await _s.notes.courseDir(widget.course, NoteFolder.transcripts);
    final transcripts = await loadLessonTranscripts(
      dir,
      _name,
      audioPath: _file.path,
    );
    WhisperModelInfo? whisperModel;
    try {
      whisperModel = await _s.whisper.resolveModel();
    } catch (_) {
      whisperModel = null;
    }
    final summary = await _s.notes.companion(
      widget.course,
      _note,
      NoteFolder.summaries,
    );
    var kind = _kind;
    if (transcripts.of(kind) == null &&
        !(kind == TranscriptKind.whisper && transcripts.systemLive != null)) {
      kind = transcripts.gemini != null
          ? TranscriptKind.gemini
          : TranscriptKind.whisper;
    }
    final (segs, plain) = await _segmentsOf(kind, meta, transcripts);
    if (!mounted) return;
    setState(() {
      // segnalibri aggiunti mentre si caricava: restano
      final added = _metaLoaded
          ? const <Bookmark>[]
          : [
              for (final b in _meta.bookmarks)
                if (!meta.bookmarks.any((x) => x.at == b.at)) b,
            ];
      _meta = meta;
      if (added.isNotEmpty) {
        _meta.bookmarks = [..._meta.bookmarks, ...added]
          ..sort((a, b) => a.at.compareTo(b.at));
      }
      _metaLoaded = true;
      _transcripts = transcripts;
      _kind = kind;
      _segs = segs;
      _plainText = plain;
      _summary = summary;
      _whisperModel = whisperModel;
      if (meta.peaks != null && meta.peaks!.isNotEmpty) _peaks = meta.peaks!;
      _current = segmentIndexAt(_segs, _pos);
    });
    _updateMatches();
    if (_peaks.isEmpty) unawaited(_computePeaks());
  }

  /// Segmenti con i tempi (o testo semplice) della trascrizione [kind]: per
  /// Whisper e il testo dal vivo quelli salvati accanto all'audio, per
  /// Gemini quelli del Markdown (se ha i tempi).
  Future<(List<TranscriptSegment>, String?)> _segmentsOf(
    TranscriptKind kind,
    RecordingMeta meta,
    LessonTranscripts t,
  ) async {
    if (kind == TranscriptKind.whisper && meta.segments.isNotEmpty) {
      return (meta.segments, null);
    }
    final file = kind == TranscriptKind.gemini
        ? t.gemini
        : (t.whisper ?? t.systemLive);
    if (file == null) return (const <TranscriptSegment>[], null);
    // file non in UTF-8 (Blocco note, altre app): si legge lo stesso
    final md = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    final segs = segmentsFromMarkdown(md, total: meta.duration);
    if (segs.isNotEmpty) return (segs, null);
    final plain = md
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('#'))
        .join('\n')
        .trim();
    return (const <TranscriptSegment>[], plain);
  }

  Future<void> _showKind(TranscriptKind k) async {
    if (k == _kind) return;
    final (segs, plain) = await _segmentsOf(k, _meta, _transcripts);
    if (!mounted) return;
    setState(() {
      _kind = k;
      _segs = segs;
      _plainText = plain;
      _current = segmentIndexAt(_segs, _pos);
    });
    _updateMatches();
  }

  /// Forma d'onda delle registrazioni senza dati salvati: calcolata una
  /// volta (dal WAV, o convertendo l'audio) e salvata accanto all'audio.
  Future<void> _computePeaks() async {
    if (_peaksLoading) return;
    _peaksLoading = true;
    Directory? tmp;
    try {
      var wav = _file;
      if (p.extension(_file.path).toLowerCase() != '.wav') {
        tmp = await Directory.systemTemp.createTemp('uninotes_onda_');
        wav = File(p.join(tmp.path, 'audio.wav'));
        if (!await AudioCodec.instance.toWav(_file, wav)) return;
      }
      final info = await readWavInfo(wav);
      final peaks = await computePeaks(wav);
      if (peaks.isEmpty) return;
      final meta = await RecordingMeta.load(_file.path);
      meta
        ..peaks = peaks
        ..duration ??= info?.duration;
      await meta.save(_file.path);
      if (mounted) {
        setState(() {
          _peaks = peaks;
          _meta = meta;
        });
      }
    } catch (e) {
      debugPrint('Forma d\'onda non calcolata: $e');
    } finally {
      _peaksLoading = false;
      try {
        await tmp?.delete(recursive: true);
      } catch (_) {}
    }
  }

  // ------------------------------------------------------------ lettore

  Future<void> _initPlayer() async {
    if (!readerMediaEnabled) {
      setState(
        () => _playerError = 'Riproduzione non disponibile in questo ambiente.',
      );
      return;
    }
    try {
      MediaKit.ensureInitialized();
      final player = Player();
      _player = player;
      _subs
        ..add(player.stream.position.listen(_onPosition))
        ..add(
          player.stream.duration.listen((d) {
            _clock.total = d;
            if (mounted && d != _dur) setState(() => _dur = d);
          }),
        )
        ..add(
          player.stream.playing.listen((v) {
            _clock.playing = v;
            if (mounted && v != _playing) setState(() => _playing = v);
          }),
        )
        ..add(
          player.stream.rate.listen((v) {
            _clock.rate = v;
            if (mounted && v != _rate) setState(() => _rate = v);
          }),
        )
        ..add(
          player.stream.error.listen(
            (e) => mounted ? setState(() => _playerError = e) : null,
          ),
        );
      await player.open(Media(Uri.file(_file.path).toString()), play: false);
      if (_rate != 1) await player.setRate(_rate);
    } catch (e) {
      if (mounted) {
        setState(() => _playerError = 'Impossibile avviare il lettore: $e');
      }
    }
  }

  /// Chiude il lettore (su Windows un file aperto non si rinomina né si
  /// sposta).
  Future<void> _closePlayer() async {
    _clock.playing = false;
    final subs = [..._subs];
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
    final pl = _player;
    _player = null;
    await pl?.dispose();
  }

  /// Posizione dal lettore: la forma d'onda la segue da sola (orologio a
  /// ogni fotogramma), qui solo «Salta silenzi».
  void _onPosition(Duration d) {
    if (!mounted) return;
    _clock.report(d);
    if (_skipSilence && _playing && _peaks.isNotEmpty) {
      final target = silenceSkipTarget(_peaks, _meta.peakEvery, d);
      if (target != null) unawaited(_player?.seek(target));
    }
  }

  /// La pagina si ricostruisce solo quando cambia il segmento in corso.
  void _onClock() {
    final i = segmentIndexAt(_segs, _clock.value);
    if (i == _current) return;
    setState(() => _current = i);
    if (i >= 0 && !_searchOpen) _showSegment(i);
  }

  void _showSegment(int i) {
    if (!_list.isAttached || !_scroll.hasClients) return;
    _list.animateToItem(
      index: i,
      scrollController: _scroll,
      alignment: 0.3,
      duration: (_) => const Duration(milliseconds: 300),
      curve: (_) => Curves.easeOut,
    );
  }

  Future<void> _seek(Duration d) async {
    var t = d < Duration.zero ? Duration.zero : d;
    if (_total > Duration.zero && t > _total) t = _total;
    _clock.jump(t);
    await _player?.seek(t);
  }

  void _skip(int seconds) => _seek(_pos + Duration(seconds: seconds));

  Future<void> _setRate(double r) async {
    setState(() => _rate = r);
    _clock.rate = r;
    await _player?.setRate(r);
  }

  // ------------------------------------------------------- segnalibri

  /// Segnalibri nel file accanto all'audio. Prima che i dati siano letti
  /// ([_metaLoaded]) quelli in memoria si aggiungono a quelli salvati
  /// (prima li sostituivano: «Segna» appena aperta la registrazione
  /// cancellava i segnalibri della lezione). Un errore (file in uso, disco
  /// pieno) si dice, non chiude niente.
  Future<void> _saveMeta() async {
    try {
      final m = await RecordingMeta.load(_file.path);
      m.bookmarks = _metaLoaded
          ? [..._meta.bookmarks]
          : [
              ...m.bookmarks,
              for (final b in _meta.bookmarks)
                if (!m.bookmarks.any((x) => x.at == b.at)) b,
            ];
      m.bookmarks.sort((a, b) => a.at.compareTo(b.at));
      await m.save(_file.path);
    } catch (e) {
      if (mounted) showSnack(context, 'Segnalibri non salvati: $e');
    }
  }

  Future<void> _addBookmark() async {
    final at = _pos;
    final added = Bookmark(at);
    setState(() {
      _meta.bookmarks = [..._meta.bookmarks, added]
        ..sort((a, b) => a.at.compareTo(b.at));
    });
    await _saveMeta();
    if (!mounted) return;
    showUndoSnackBar(
      context,
      'Segnalibro a ${clockLabel(at)}',
      undoneMessage: 'Segnalibro tolto.',
      onUndo: () async {
        if (!mounted) return;
        setState(() => _meta.bookmarks = [..._meta.bookmarks]..remove(added));
        await _saveMeta();
      },
    );
  }

  Future<void> _editBookmark(Bookmark b) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(
                b.note.isEmpty ? 'Aggiungi una nota' : 'Modifica la nota',
              ),
              onTap: () => Navigator.pop(c, 'nota'),
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_remove_outlined),
              title: const Text('Togli il segnalibro'),
              onTap: () => Navigator.pop(c, 'togli'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'togli') {
      setState(() => _meta.bookmarks = [..._meta.bookmarks]..remove(b));
      await _saveMeta();
      if (!mounted) return;
      showUndoSnackBar(
        context,
        'Segnalibro a ${clockLabel(b.at)} tolto.',
        undoneMessage: 'Segnalibro ripristinato.',
        onUndo: () async {
          if (!mounted) return;
          setState(() {
            _meta.bookmarks = [..._meta.bookmarks, b]
              ..sort((x, y) => x.at.compareTo(y.at));
          });
          await _saveMeta();
        },
      );
      return;
    } else {
      final note = await promptText(
        context,
        title: 'Segnalibro a ${clockLabel(b.at)}',
        label: 'Nota (facoltativa)',
        initial: b.note,
      );
      if (note == null || !mounted) return;
      setState(() {
        _meta.bookmarks = [
          for (final x in _meta.bookmarks)
            identical(x, b) ? x.withNote(note) : x,
        ];
      });
    }
    await _saveMeta();
  }

  // ----------------------------------------------------------- ricerca

  void _openSearch() {
    setState(() => _searchOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _queryFocus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  void _closeSearch() => setState(() {
    _searchOpen = false;
    _query.clear();
    _matches = const [];
  });

  void _updateMatches() {
    final q = _query.text.trim().toLowerCase();
    final m = q.isEmpty
        ? const <int>[]
        : [
            for (var i = 0; i < _segs.length; i++)
              if (_segs[i].text.toLowerCase().contains(q)) i,
          ];
    setState(() {
      _matches = m;
      _match = 0;
    });
    if (m.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showSegment(m[0]));
    }
  }

  void _stepMatch(int d) {
    if (_matches.isEmpty) return;
    setState(() => _match = (_match + d) % _matches.length);
    _showSegment(_matches[_match]);
  }

  // ---------------------------------------------------------- azioni

  String get _transcriptText => _segs.isNotEmpty
      ? _segs.map((s) => s.text).join(' ')
      : (_plainText ?? '');

  NoteFile? get _transcriptNote => _transcript == null
      ? null
      : NoteFile(_transcript!, NoteFolder.transcripts, DateTime.now(), 0);

  Future<void> _copyText() async {
    final text = _transcriptText;
    if (text.isEmpty) {
      showSnack(context, 'Nessuna trascrizione da copiare.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, 'Testo copiato.');
  }

  /// Un tocco sul nome: rinomina (anche trascrizioni e riassunto).
  bool _renaming = false;

  Future<void> _rename() async {
    // doppio tocco sul titolo: un solo «Rinomina» (due lettori aperti
    // tenevano il file bloccato su Windows)
    if (_renaming) return;
    _renaming = true;
    try {
      await _closePlayer();
      if (!mounted) return;
      final n = await renameNote(context, widget.course, _note);
      if (n != null) {
        _file = File(
          p.join(p.dirname(_file.path), '$n${p.extension(_file.path)}'),
        );
      }
      // schermata chiusa durante il riquadro: nessun lettore da riaprire
      if (!mounted) return;
      await _initPlayer();
      if (!mounted) return;
      await _load();
    } finally {
      _renaming = false;
    }
  }

  Future<void> _delete() async {
    await _closePlayer();
    if (!mounted) return;
    final done = await trashNote(context, widget.course, _note);
    if (!mounted) return;
    if (done) {
      Navigator.of(context).pop();
    } else {
      await _initPlayer();
    }
  }

  Future<void> _menu(_Menu m) async {
    switch (m) {
      case _Menu.shareAudio:
        await shareFiles(context, [_file], subject: _name);
      case _Menu.shareText:
        if (_transcript != null) {
          await shareFiles(context, [_transcript!], subject: _name);
        }
      case _Menu.shareBoth:
        await shareFiles(context, [_file, ?_transcript], subject: _name);
      case _Menu.summarize:
        final t = _transcriptNote;
        if (t == null) {
          showSnack(context, 'Prima trascrivi la registrazione.');
          return;
        }
        await summarizeWithGemini(context, widget.course, t);
      case _Menu.trim:
        await _trim();
      case _Menu.whisper:
        await chooseWhisperModelAndTranscribe(
          context,
          widget.course,
          _note,
          again: _transcripts.whisper != null,
          current: _transcripts.whisperModel,
        );
    }
  }

  /// «Taglia»: tiene solo un tratto o lo toglie, ascoltando mentre si
  /// sceglie. L'originale va in «Eliminati di recente» (si può recuperare
  /// per 30 giorni).
  Future<void> _trim() async {
    final total = _total;
    if (total <= Duration.zero) {
      showSnack(context, 'Attendi che la registrazione sia caricata.');
      return;
    }
    final isWav = p.extension(_file.path).toLowerCase() == '.wav';
    if (!isWav && !AudioCodec.instance.supported) {
      showSnack(context, 'Il taglio non è disponibile su questo sistema.');
      return;
    }
    final choice = await showModalBottomSheet<(Duration, Duration, bool)>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (c) => TrimSheet(
        total: total,
        peaks: _peaks,
        clock: _clock,
        player: _player,
      ),
    );
    await _player?.pause();
    if (choice == null || !mounted) return;
    final (a, b, removeInside) = choice;
    final keep = keptRanges(total, a, b, removeInside: removeInside);
    if (keep.isEmpty) {
      showSnack(context, 'Resterebbe una registrazione vuota.');
      return;
    }
    final job = _s.jobs.start(
      'Taglio · $_name',
      courseId: widget.course.id,
      target: _file.path,
      (report) async {
        await _closePlayer();
        final tmp = await Directory.systemTemp.createTemp('uninotes_taglio_');
        try {
          report('Preparo l\'audio…', null);
          var src = _file;
          var info = isWav ? await readWavInfo(_file) : null;
          if (info == null) {
            src = File(p.join(tmp.path, 'originale.wav'));
            if (!await AudioCodec.instance.toWav(_file, src)) {
              throw Exception('conversione non riuscita');
            }
            info = await readWavInfo(src);
          }
          if (info == null) throw Exception('audio non leggibile');
          report('Taglio…', null);
          final cut = File(p.join(tmp.path, 'tagliata.wav'));
          await cutWav(src, info, cut, keep);
          final meta = cutMeta(await RecordingMeta.load(_file.path), keep);
          final dir = p.dirname(_file.path);
          final name = _name;
          // l'originale (con i suoi dati) va nel cestino
          await _s.trash.trash(
            [_file, RecordingMeta.sidecarOf(_file.path)],
            title: '$name (prima del taglio)',
            course: widget.course.name,
          );
          report('Comprimo…', null);
          var out = File(p.join(dir, '$name.m4a'));
          if (!await AudioCodec.instance.compress(cut, out)) {
            out = await moveFile(cut, p.join(dir, '$name.wav'));
          }
          await meta.save(out.path);
          if (meta.segments.isNotEmpty) {
            await writeTranscriptFor(
              out.path,
              meta.segments,
              course: widget.course.name,
              source: meta.transcriptSource ?? 'trascrizione tagliata',
            );
          }
          _file = out;
          return out.path;
        } finally {
          try {
            await tmp.delete(recursive: true);
          } catch (_) {}
        }
      },
      onFinished: (j) async {
        if (!mounted) return;
        if (j.state == JobState.failed) {
          showSnack(context, 'Taglio non riuscito: ${j.error}');
        } else {
          showSnack(
            context,
            'Registrazione tagliata. L\'originale è in «Eliminati di recente».',
          );
        }
        _s.revision.bump();
        await _initPlayer();
        await _load();
      },
    );
    if (job.state == JobState.running) {
      showSnack(context, 'Taglio in corso…');
    }
  }

  // ---------------------------------------------------------- interfaccia

  @override
  Widget build(BuildContext context) {
    final wide = context.isWide;
    return Scaffold(
      appBar: AppBar(
        title: Tooltip(
          message: 'Rinomina',
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _rename,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
              child: Text(
                _name,
                overflow: TextOverflow.ellipsis,
                semanticsLabel: '$_name, tocca per rinominare',
              ),
            ),
          ),
        ),
        actions: [
          IconButton(
            tooltip: 'Elimina la registrazione',
            icon: const Icon(Icons.delete_outline),
            onPressed: _delete,
          ),
          PopupMenuButton<_Menu>(
            tooltip: 'Altre azioni',
            onSelected: _menu,
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: _Menu.shareAudio,
                child: Text('Condividi l\'audio'),
              ),
              if (_transcript != null) ...[
                const PopupMenuItem(
                  value: _Menu.shareText,
                  child: Text('Condividi il testo'),
                ),
                const PopupMenuItem(
                  value: _Menu.shareBoth,
                  child: Text('Condividi audio e testo'),
                ),
              ],
              const PopupMenuItem(
                value: _Menu.summarize,
                child: Text('Riassumi'),
              ),
              PopupMenuItem(
                value: _Menu.whisper,
                child: Text(
                  _transcripts.whisper != null
                      ? 'Trascrivi di nuovo con…'
                      : 'Trascrivi con Whisper con…',
                ),
              ),
              const PopupMenuItem(value: _Menu.trim, child: Text('Taglia…')),
            ],
          ),
        ],
      ),
      body: FindShortcuts(
        onFind: _openSearch,
        onClose: _closeSearch,
        onNext: () => _stepMatch(1),
        onPrevious: () => _stepMatch(-1),
        child: Column(
          children: [
            ListenableBuilder(
              listenable: _s.jobs,
              builder: (context, _) {
                final job = _s.jobs.runningOn(_file.path);
                if (job == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${job.title}: ${job.phase}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      LinearProgressIndicator(value: job.fraction),
                    ],
                  ),
                );
              },
            ),
            Expanded(
              child: wide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 440,
                          child: SingleChildScrollView(child: _header(context)),
                        ),
                        const VerticalDivider(width: 1),
                        Expanded(child: _transcriptBox(context)),
                      ],
                    )
                  : LayoutBuilder(
                      builder: (context, box) => Column(
                        children: [
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: box.maxHeight * 0.58,
                            ),
                            child: SingleChildScrollView(
                              child: _header(context),
                            ),
                          ),
                          const Divider(height: 1),
                          Expanded(child: _transcriptBox(context)),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final ready = _player != null && _playerError == null;
    final every = _meta.peakEvery;
    final mono = theme.textTheme.bodyMedium?.copyWith(
      fontFamily: 'IBMPlexMono',
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final shown = Listenable.merge([_clock, _scrub]);
    Duration shownPos() => _scrub.value ?? _clock.value;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            slider: true,
            label: 'Posizione nella registrazione',
            value: clockLabel(_pos),
            onIncrease: () => _skip(15),
            onDecrease: () => _skip(-15),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) => _scrub.value = _pos,
              onHorizontalDragUpdate: (d) {
                final delta = Duration(
                  microseconds:
                      (-d.delta.dx /
                              PlaybackWavePainter.step *
                              every.inMicroseconds)
                          .round(),
                );
                var v = (_scrub.value ?? _pos) + delta;
                if (v < Duration.zero) v = Duration.zero;
                if (_total > Duration.zero && v > _total) v = _total;
                _scrub.value = v;
              },
              onHorizontalDragEnd: (_) {
                final v = _scrub.value;
                _scrub.value = null;
                if (v != null) _seek(v);
              },
              child: SizedBox(
                height: 104,
                child: _peaks.isEmpty
                    ? Center(
                        child: Text(
                          _peaksLoading ? 'Calcolo la forma d\'onda…' : '',
                          style: theme.textTheme.bodySmall,
                        ),
                      )
                    : RepaintBoundary(
                        child: CustomPaint(
                          painter: PlaybackWavePainter(
                            peaks: _peaks,
                            every: every,
                            positionOf: shownPos,
                            repaint: shown,
                            color: theme.colorScheme.primary,
                            muted: theme.colorScheme.primary.withValues(
                              alpha: 0.35,
                            ),
                            playhead: t.orangeGradient.first,
                            marks: [for (final b in _meta.bookmarks) b.at],
                            markColor: t.orangeGradient.first,
                          ),
                        ),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          RepaintBoundary(
            child: ListenableBuilder(
              listenable: shown,
              builder: (context, _) {
                final pos = shownPos();
                // secondi interi: il testo cambia una volta al secondo
                return Row(
                  children: [
                    Text(clockLabel(pos), style: mono),
                    const Spacer(),
                    Text(
                      '−${clockLabel(_total > pos ? _total - pos : Duration.zero)}',
                      style: mono?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          if (_playerError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _playerError!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final sec in const [-30, -15]) ...[
                IconButton(
                  tooltip: 'Indietro di ${-sec} secondi',
                  iconSize: 32,
                  onPressed: ready ? () => _skip(sec) : null,
                  icon: _SkipIcon(seconds: -sec, forward: false),
                ),
                const SizedBox(width: 2),
              ],
              const SizedBox(width: 8),
              SizedBox.square(
                dimension: 72,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    shape: const CircleBorder(),
                    padding: EdgeInsets.zero,
                  ),
                  onPressed: ready ? () => _player?.playOrPause() : null,
                  child: Icon(
                    _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 40,
                    semanticLabel: _playing ? 'Pausa' : 'Riproduci',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              for (final sec in const [15, 30]) ...[
                const SizedBox(width: 2),
                IconButton(
                  tooltip: 'Avanti di $sec secondi',
                  iconSize: 32,
                  onPressed: ready ? () => _skip(sec) : null,
                  icon: _SkipIcon(seconds: sec, forward: true),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PopupMenuButton<double>(
                tooltip: 'Velocità di riproduzione',
                initialValue: _rate,
                onSelected: _setRate,
                itemBuilder: (_) => [
                  for (final r in kPlaybackSpeeds)
                    PopupMenuItem(value: r, child: Text(_rateLabel(r))),
                ],
                child: Chip(
                  avatar: const Icon(Icons.speed, size: 18),
                  label: Text(_rateLabel(_rate)),
                ),
              ),
              FilterChip(
                label: const Text('Salta silenzi'),
                selected: _skipSilence,
                onSelected: _peaks.isEmpty
                    ? null
                    : (v) => setState(() => _skipSilence = v),
              ),
              ActionChip(
                avatar: Icon(
                  Icons.bookmark_add_outlined,
                  size: 18,
                  color: t.orangeGradient.first,
                ),
                label: const Text('Segna'),
                tooltip: 'Segnalibro in questo punto',
                onPressed: _addBookmark,
              ),
            ],
          ),
          if (_meta.bookmarks.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (final b in _meta.bookmarks)
                  GestureDetector(
                    onLongPress: () => _editBookmark(b),
                    child: ActionChip(
                      avatar: Icon(
                        Icons.bookmark,
                        size: 18,
                        color: t.orangeGradient.first,
                      ),
                      label: Text(
                        b.note.isEmpty
                            ? clockLabel(b.at)
                            : '${clockLabel(b.at)} · ${b.note}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      tooltip:
                          'Vai a ${clockLabel(b.at)} (tieni premuto per '
                          'la nota)',
                      onPressed: () => _seek(b.at),
                    ),
                  ),
              ],
            ),
          ],
          if (_summary != null) ...[
            const SizedBox(height: 8),
            Align(
              child: TextButton.icon(
                onPressed: () => openNote(
                  context,
                  widget.course,
                  NoteFile(_summary!, NoteFolder.summaries, DateTime.now(), 0),
                ),
                icon: const Icon(Icons.summarize_outlined, size: 18),
                label: const Text('Apri il riassunto'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _rateLabel(double r) {
    var v = r.toString();
    if (v.endsWith('.0')) v = v.substring(0, v.length - 2);
    return '${v.replaceAll('.', ',')}×';
  }

  /// Riquadro della trascrizione: intestazione (chi l'ha fatta, scelta
  /// fra Whisper e Gemini, cerca, copia, «Apri in» l'AI di riferimento), barra di ricerca
  /// e testo.
  Widget _transcriptBox(BuildContext context) {
    final theme = Theme.of(context);
    final file = _transcript;
    if (file == null) return _noTranscript(context);
    final both =
        _transcripts.gemini != null &&
        (_transcripts.whisper != null || _transcripts.systemLive != null);
    final live =
        _kind == TranscriptKind.whisper && _transcripts.whisper == null;
    final color = live ? null : transcriptColor(context, _kind);
    final model = _kind == TranscriptKind.whisper && !live
        ? _transcripts.whisperModel
        : null;
    final title = live
        ? 'Trascrizione dal vivo'
        : 'Trascrizione con ${_kind.label}'
              '${model == null ? '' : ' · ${whisperModelLabel(model)}'}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Icon(
                _kind == TranscriptKind.gemini
                    ? Icons.auto_awesome_outlined
                    : Icons.graphic_eq,
                size: 18,
                color: color ?? theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
              IconButton(
                tooltip: 'Cerca nel testo (Ctrl+F)',
                icon: const Icon(Icons.search),
                onPressed: _openSearch,
              ),
              IconButton(
                tooltip: 'Copia il testo',
                icon: const Icon(Icons.copy_outlined),
                onPressed: _copyText,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (both)
                SegmentedButton<TranscriptKind>(
                  showSelectedIcon: false,
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.compact,
                  ),
                  segments: [
                    for (final k in TranscriptKind.values)
                      ButtonSegment(
                        value: k,
                        label: Text(
                          k.label,
                          style: TextStyle(color: transcriptColor(context, k)),
                        ),
                      ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (v) => _showKind(v.first),
                ),
              ReferenceAiButton(
                onPressed: () {
                  final n = _transcriptNote;
                  if (n != null) openNoteInAi(context, widget.course, n);
                },
              ),
            ],
          ),
        ),
        if (_searchOpen)
          FindBar(
            controller: _query,
            focusNode: _queryFocus,
            onChanged: (_) => _updateMatches(),
            onNext: () => _stepMatch(1),
            onPrevious: () => _stepMatch(-1),
            onClose: _closeSearch,
            total: _matches.length,
            current: _matches.isEmpty ? null : _match,
          ),
        const Divider(height: 1),
        Expanded(child: _transcriptView(context)),
      ],
    );
  }

  /// Nessuna trascrizione: «Trascrivi con Whisper» e «Trascrivi con Gemini».
  Widget _noTranscript(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Nessuna trascrizione.', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TranscriptButton(
                      kind: TranscriptKind.whisper,
                      done: false,
                      model: whisperModelShort(_whisperModel?.id),
                      onLongPress: () => chooseWhisperModelAndTranscribe(
                        context,
                        widget.course,
                        _note,
                      ),
                      onPressed: () =>
                          transcribeWithWhisper(context, widget.course, _note),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TranscriptButton(
                      kind: TranscriptKind.gemini,
                      done: false,
                      onPressed: () =>
                          transcribeWithGemini(context, widget.course, _note),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _transcriptView(BuildContext context) {
    final theme = Theme.of(context);
    if (_segs.isEmpty) {
      final plain = _plainText ?? '';
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText.rich(
          TextSpan(
            style: theme.textTheme.bodyLarge,
            children: misspelledSpans(plain, _spell.errorsOf(plain)),
          ),
        ),
      );
    }
    final q = _searchOpen ? _query.text.trim() : '';
    final active = _matches.isEmpty ? -1 : _matches[_match];
    return SuperListView.builder(
      controller: _scroll,
      listController: _list,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 32),
      itemCount: _segs.length,
      itemBuilder: (context, i) {
        final s = _segs[i];
        final current = i == _current;
        final style = theme.textTheme.bodyLarge?.copyWith(
          height: 1.4,
          fontWeight: current ? FontWeight.w600 : null,
        );
        return Semantics(
          button: true,
          label: 'Vai a ${clockLabel(s.start)}',
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => _seek(s.start),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              constraints: const BoxConstraints(minHeight: 44),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: current
                    ? theme.colorScheme.primary.withValues(alpha: 0.14)
                    : (i == active
                          ? context.tokens.orangeGradient.first.withValues(
                              alpha: 0.14,
                            )
                          : null),
              ),
              // senza l'orario di ogni frase: un tocco salta comunque a quel
              // punto dell'audio; le formule ($…$) si disegnano
              child: q.isEmpty && mayContainMath(s.text)
                  ? MathText(s.text, style: style)
                  : Text.rich(
                      _highlight(s.text, q, theme, _spell.errorsOf(s.text)),
                      style: style,
                    ),
            ),
          ),
        );
      },
    );
  }

  /// Frase con i risultati della ricerca evidenziati e le parole errate
  /// ([errors], nelle posizioni di [text]) con la linea ondulata rossa.
  TextSpan _highlight(
    String text,
    String q,
    ThemeData theme,
    List<SuggestionSpan> errors,
  ) {
    if (q.isEmpty) {
      return TextSpan(children: misspelledSpans(text, errors));
    }
    final lower = text.toLowerCase();
    final needle = q.toLowerCase();
    final spans = <TextSpan>[];
    var from = 0;
    while (true) {
      final i = lower.indexOf(needle, from);
      if (i < 0) break;
      if (i > from) {
        spans.addAll(misspelledSpans(text, errors, start: from, end: i));
      }
      spans.addAll(
        misspelledSpans(
          text,
          errors,
          style: TextStyle(
            backgroundColor: context.tokens.orangeGradient.first.withValues(
              alpha: 0.35,
            ),
          ),
          start: i,
          end: i + needle.length,
        ),
      );
      from = i + needle.length;
    }
    spans.addAll(misspelledSpans(text, errors, start: from));
    return TextSpan(children: spans);
  }
}

/// Scelta del tratto da tagliare: forma d'onda intera con i due cursori e
/// ascolto mentre si sceglie (▶ parte dall'inizio del tratto e si ferma
/// alla fine; spostando un cursore si riascolta da lì). Due pulsanti:
/// «Togli il tratto» e «Tieni solo il tratto».
class TrimSheet extends StatefulWidget {
  const TrimSheet({
    super.key,
    required this.total,
    required this.peaks,
    required this.clock,
    required this.player,
  });
  final Duration total;
  final Uint8List peaks;
  final ValueListenable<Duration> clock;
  final Player? player;

  @override
  State<TrimSheet> createState() => _TrimSheetState();
}

class _TrimSheetState extends State<TrimSheet> {
  late RangeValues _range = RangeValues(
    0,
    widget.total.inMilliseconds.toDouble(),
  );

  /// Ascolto del tratto in corso.
  bool _listening = false;

  /// Coda del tratto ascoltata spostando il cursore di fine.
  static const _tail = Duration(seconds: 3);

  Duration _d(double ms) => Duration(milliseconds: ms.round());

  @override
  void initState() {
    super.initState();
    widget.clock.addListener(_onClock);
  }

  @override
  void dispose() {
    widget.clock.removeListener(_onClock);
    if (_listening) unawaited(widget.player?.pause());
    super.dispose();
  }

  /// Arrivato alla fine del tratto, l'ascolto si ferma.
  void _onClock() {
    if (!_listening) return;
    if (widget.clock.value >= _d(_range.end)) {
      unawaited(widget.player?.pause());
      setState(() => _listening = false);
    }
  }

  Future<void> _play(Duration from) async {
    final pl = widget.player;
    if (pl == null) return;
    await pl.seek(from);
    await pl.play();
    if (mounted) setState(() => _listening = true);
  }

  Future<void> _toggle() async {
    if (_listening) {
      await widget.player?.pause();
      // foglio chiuso nel frattempo
      if (mounted) setState(() => _listening = false);
      return;
    }
    await _play(_d(_range.start));
  }

  /// Fine del trascinamento di un cursore: si ascolta da lì (l'inizio dal
  /// cursore, la fine dagli ultimi secondi del tratto).
  void _moved(RangeValues before, RangeValues after) {
    if (widget.player == null) return;
    final startMoved = before.start != after.start;
    var from = startMoved ? _d(after.start) : _d(after.end) - _tail;
    if (from < _d(after.start)) from = _d(after.start);
    unawaited(_play(from));
  }

  RangeValues? _dragFrom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final max = widget.total.inMilliseconds.toDouble();
    final a = _d(_range.start), b = _d(_range.end);
    final canListen = widget.player != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Taglia la registrazione', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Scegli un tratto ascoltandolo: puoi tenere solo quello o '
              'toglierlo. L\'originale resta 30 giorni in «Eliminati di '
              'recente».',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 64,
              child: LayoutBuilder(
                builder: (context, box) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // tocco sulla forma d'onda: si ascolta da quel punto
                  onTapUp: canListen && max > 0 && box.maxWidth > 0
                      ? (d) {
                          final f = (d.localPosition.dx / box.maxWidth).clamp(
                            0.0,
                            1.0,
                          );
                          unawaited(_play(_d(max * f)));
                        }
                      : null,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _OverviewPainter(
                        peaks: widget.peaks,
                        start: max == 0 ? 0 : _range.start / max,
                        end: max == 0 ? 1 : _range.end / max,
                        position: () => max == 0
                            ? 0
                            : widget.clock.value.inMilliseconds / max,
                        repaint: widget.clock,
                        color: theme.colorScheme.primary,
                        muted: theme.colorScheme.outlineVariant,
                        playhead: context.tokens.orangeGradient.first,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            RangeSlider(
              values: _range,
              max: max <= 0 ? 1 : max,
              labels: RangeLabels(clockLabel(a), clockLabel(b)),
              onChangeStart: (v) => _dragFrom = v,
              onChanged: (v) => setState(() => _range = v),
              onChangeEnd: (v) {
                final from = _dragFrom;
                _dragFrom = null;
                if (from != null && from != v) _moved(from, v);
              },
            ),
            Row(
              children: [
                IconButton.filledTonal(
                  tooltip: _listening
                      ? 'Ferma l\'ascolto'
                      : 'Ascolta il tratto',
                  onPressed: canListen ? _toggle : null,
                  icon: Icon(
                    _listening ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${clockLabel(a)} – ${clockLabel(b)} (${clockLabel(b - a)})',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: () => Navigator.pop(context, (a, b, true)),
                  child: const Text('Togli il tratto'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, (a, b, false)),
                  child: const Text('Tieni solo il tratto'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewPainter extends CustomPainter {
  _OverviewPainter({
    required this.peaks,
    required this.start,
    required this.end,
    required this.position,
    required Listenable repaint,
    required this.color,
    required this.muted,
    required this.playhead,
  }) : super(repaint: repaint);
  final Uint8List peaks;
  final double start;
  final double end;

  /// Posizione di ascolto (0–1), letta a ogni disegno.
  final double Function() position;
  final Color color;
  final Color muted;
  final Color playhead;

  @override
  void paint(Canvas canvas, Size size) {
    const bar = 3.0;
    final n = (size.width / bar).floor();
    if (n <= 0) return;
    final paint = Paint()..strokeWidth = 2;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      var v = 0;
      if (peaks.isNotEmpty) {
        final a = (i * peaks.length / n).floor();
        final b = (((i + 1) * peaks.length / n).ceil()).clamp(
          a + 1,
          peaks.length,
        );
        for (var k = a; k < b; k++) {
          if (peaks[k] > v) v = peaks[k];
        }
      }
      final h = (v / 255 * (size.height - 4)).clamp(2.0, size.height);
      final x = i * bar + 1;
      final f = x / size.width;
      paint.color = f >= start && f <= end ? color : muted;
      canvas.drawLine(Offset(x, mid - h / 2), Offset(x, mid + h / 2), paint);
    }
    final x = position().clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = playhead
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_OverviewPainter old) =>
      old.start != start || old.end != end || old.peaks != peaks;
}

/// Icona «15/30 secondi» indietro o avanti.
class _SkipIcon extends StatelessWidget {
  const _SkipIcon({required this.seconds, required this.forward});
  final int seconds;
  final bool forward;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      Icons.replay,
      size: 34,
      color: IconTheme.of(context).color,
    );
    return SizedBox.square(
      dimension: 34,
      child: Stack(
        alignment: Alignment.center,
        children: [
          forward ? Transform.flip(flipX: true, child: icon) : icon,
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '$seconds',
              style: TextStyle(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: IconTheme.of(context).color,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
