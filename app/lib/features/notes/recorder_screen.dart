import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../widgets/app_snack_action.dart';
import '../../core/feedback/app_modals.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/reminders/home_widgets.dart' show HomeWidgetBridge;
import '../../core/reminders/notification_plan.dart' show AppRoutes;
import '../../core/router/safe_pop.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/undo_snack_bar.dart';
import '../study/course_catalog.dart';
import '../study/study_widgets.dart' show promptText;
import 'lecture_recorder.dart';
import 'notes_screen.dart';
import 'course_notes_screen.dart';
import 'recorder/better_transcription.dart';
import 'recorder/course_vocabulary.dart';
import 'recorder/lecture_language.dart';
import 'recorder/live_transcriber.dart';
import 'recorder/live_transcript_editor.dart';
import 'recorder/recording_meta.dart';
import 'recorder/recording_overlay.dart'
    show appNavigatorKey, confirmDeleteRecording;
import 'recorder/recording_save.dart';
import 'recorder/system_speech.dart' show speechNotice;
import 'recorder/waveform.dart';
import 'spell_check.dart' show spellLanguageOf;

export 'recorder/live_transcript_editor.dart'
    show EditableLiveTranscript, TranscriptEdit;

/// Registratore delle lezioni, come Memo Vocali: scegli il corso e
/// registra. Durante la registrazione: tempo, forma d'onda, pausa e
/// ripresa (pulsante grande), «Segna» (segnalibro al tempo attuale, con
/// nota facoltativa) e la card «Trascrizione» con il parlato trascritto in
/// tempo reale (Parakeet su PC e Mac, Whisper con il modello integrato sul
/// telefono) ed «Elimina» (la
/// registrazione in corso va in «Eliminati di recente», con conferma).
/// «Salva» ferma e salva (Appunti → corso → Registrazioni) e porta alla
/// pagina del corso, alla card «Registrazioni delle lezioni».
///
/// Nella card «Trascrizione» il testo si modifica come nel Blocco note (un
/// tocco mette il cursore in quel punto) mentre la registrazione continua,
/// con il controllo ortografico del sistema; «Formule (LaTeX)» scrive in LaTeX le formule
/// dette a voce («due terzi» → ⅔, «integrale da 2 a pi greco» → ∫ da 2 a
/// π) e la scelta resta per le registrazioni successive.
///
/// Uscendo dalla schermata la registrazione continua: un riquadro sopra
/// tutte le schermate (recorder/recording_overlay.dart) mostra tempo e
/// comandi e riporta qui con un tocco. Il riquadro compare appena si
/// inizia a uscire (anche con il gesto Indietro).
class RecorderScreen extends StatefulWidget {
  const RecorderScreen({super.key, this.initialCourse, this.fromCourse});
  final Course? initialCourse;

  /// Aperto dalla pagina di questo corso (id): dopo «Salva» si torna lì.
  final int? fromCourse;

  /// Dopo l'avvio dal widget: ritorno alla schermata Home (Android) e
  /// attesa prima del ritorno. Le prove li sostituiscono.
  @visibleForTesting
  static Future<bool> Function() toBackground = HomeWidgetBridge.moveTaskToBack;
  @visibleForTesting
  static Duration backgroundDelay = const Duration(milliseconds: 700);

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  late final AppServices _s = context.read<AppServices>();
  CourseCatalog? _catalog;
  Course? _course;
  bool _busy = false;

  /// «Formule (LaTeX)» nella trascrizione dal vivo.
  bool _formulas = false;

  /// Lingua della lezione ('it' o 'en'): quella scelta per l'insegnamento,
  /// altrimenti quella dell'onboarding (recorder/lecture_language.dart).
  String _lang = 'it';

  /// Impostazione di «Formule (LaTeX)».
  static const formulasKey = 'live_formulas';

  LectureRecorder get _rec => _s.recorder;

  @override
  void initState() {
    super.initState();
    _course = widget.initialCourse;
    _rec.screenVisible = true;
    _rec.addListener(_onRecorder);
    _load();
  }

  @override
  void dispose() {
    _rec.removeListener(_onRecorder);
    _rec.screenVisible = false;
    super.dispose();
  }

  /// Richiesta d'avvio dal widget arrivata con il registratore già aperto.
  void _onRecorder() {
    if (_rec.quickStartPending) unawaited(_maybeQuickStart());
  }

  /// Avvio dal widget «Registra lezione» (rotta `registra:avvia`, una sola
  /// volta): registra subito con lo stesso percorso del pulsante (corso
  /// scelto qui, lingua delle lezioni, nome «AAAA-MM-GG HH:MM», permesso del
  /// microfono) e, appena la registrazione è partita, torna alla schermata
  /// Home lasciandola continuare in background. Se non parte (permesso
  /// negato, nessun insegnamento) si resta qui con il motivo.
  Future<void> _maybeQuickStart() async {
    if (!mounted || _catalog == null || _busy || !_rec.quickStartPending) {
      return;
    }
    if (!_rec.takeQuickStart() || _rec.active || _rec.saving) return;
    if (_course == null) {
      showSnack(
        context,
        'Nessun insegnamento: aggiungili in Insegnamenti per registrare.',
      );
      return;
    }
    if (!await _start()) return;
    // un attimo per vedere che è partita (e il servizio in primo piano del
    // microfono parte con l'app ancora davanti, come vuole Android 14+),
    // poi la schermata Home
    await Future<void>.delayed(RecorderScreen.backgroundDelay);
    if (_rec.active) await RecorderScreen.toBackground();
  }

  Future<void> _load() async {
    try {
      final formulas = await _s.settings.get(formulasKey) == '1';
      if (mounted) {
        setState(() => _formulas = formulas);
        _rec.live?.formulas = formulas;
      }
    } catch (e) {
      debugPrint('Registra: «Formule» non letto: $e');
    }
    CourseCatalog catalog;
    Course? suggested;
    try {
      catalog = await CourseCatalog.load(_s);
      suggested = _course ?? await NotesScreen.suggestedCourse(_s, catalog);
    } catch (e) {
      // database non leggibile: prima la rotella girava per sempre e,
      // con una registrazione in corso, i comandi non comparivano. Si
      // mostra la schermata (comandi, insegnamento aperto) e si dice perché
      // l'elenco è vuoto.
      catalog = CourseCatalog(const [], const []);
      suggested = _course;
      if (mounted) showSnack(context, 'Insegnamenti non letti: $e');
    }
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _course =
          suggested ?? (catalog.courses.isEmpty ? null : catalog.courses.first);
    });
    await _loadLanguage();
    // aperto dal widget «Registra lezione»: si parte subito
    await _maybeQuickStart();
  }

  /// Lingua dell'insegnamento scelto (o di quello della registrazione in
  /// corso, che non cambia più).
  Future<void> _loadLanguage() async {
    final live = _rec.live;
    if (_rec.active && live != null) {
      if (mounted) setState(() => _lang = live.language);
      return;
    }
    final c = _course;
    final lang = await lectureLanguageOf(_s.settings, c);
    if (mounted && c == _course) setState(() => _lang = lang);
  }

  void _setLanguage(String lang) {
    if (_rec.active || lang == _lang) return;
    setState(() => _lang = lang);
    final id = _course?.id;
    if (id != null) {
      unawaited(
        setCourseLectureLanguage(_s.settings, id, lang).catchError(
          (Object e) => debugPrint('Registra: lingua non salvata: $e'),
        ),
      );
    }
  }

  /// «Registra»: true se la registrazione è partita.
  Future<bool> _start() async {
    final c = _course;
    if (c == null || _busy) return false;
    setState(() => _busy = true);
    try {
      final ext = await _rec.extension(c);
      final path = await _s.notes.newRecordingPath(c, DateTime.now(), ext);
      // segnale d'inizio (breve: parte mentre si apre il microfono)
      unawaited(_s.feedback.play(FeedbackEvent.recordStart));
      await _rec.start(
        path,
        course: c.name,
        courseId: c.id,
        language: _lang,
        vocabulary: await loadCourseVocabulary(_s.study, c.id, c.name),
      );
      _rec.live?.formulas = _formulas;
      return true;
    } on RecorderException catch (e) {
      _s.feedback.warning();
      if (mounted) showSnack(context, e.message);
    } catch (e) {
      // cartella del corso non creabile (permessi, disco pieno), database
      // non leggibile: prima il tocco su «Registra» non faceva nulla
      _s.feedback.warning();
      if (mounted) showSnack(context, 'Registrazione non avviata: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  /// «Salva»: ferma, salva e porta alla pagina del corso (card
  /// «Registrazioni delle lezioni»), non al lettore.
  Future<void> _save() async {
    if (_busy || _rec.saving) return;
    setState(() => _busy = true);
    final courseId = _rec.courseId;
    File? f;
    try {
      f = await saveRecording(_s);
    } catch (e) {
      if (mounted) showSnack(context, 'Salvataggio non riuscito: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted || f == null) return;
    final course = courseId == null ? null : _catalog?.byId[courseId];
    if (course == null) {
      showSnack(context, 'Registrazione salvata.');
      return;
    }
    // modello scaricato più accurato: si propone di trascrivere di nuovo
    // (il riquadro arriva sopra la pagina del corso)
    unawaited(offerBetterTranscription(_s, course, f));
    if (widget.fromCourse == course.id) {
      // la pagina del corso è sotto: ci si torna (se non lo si è già fatto
      // con Indietro durante il salvataggio)
      popIfCurrent(context, f.path);
      return;
    }
    // pagina già in chiusura (Indietro durante il salvataggio) o coperta da
    // un'altra: pushReplacement sostituirebbe la pagina sbagliata
    if (!isCurrentRoute(context)) {
      showSnack(context, 'Registrazione salvata in ${course.name}.');
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CourseNotesScreen(course: course, justSaved: f!.path),
      ),
    );
  }

  /// «Elimina»: dopo la conferma (con «Non chiedere più») ferma la
  /// registrazione e la sposta in «Eliminati di recente», con la
  /// trascrizione fin lì: per 30 giorni si può recuperare.
  Future<void> _delete() async {
    if (_busy || _rec.saving || !_rec.active) return;
    if (!await confirmDeleteRecording(context, inProgress: true)) return;
    if (!_rec.active) return;
    if (mounted) setState(() => _busy = true);
    try {
      final entry = await discardRecording(_s);
      if (mounted) {
        if (entry == null) {
          showSnack(context, 'Registrazione eliminata.');
        } else {
          // «Annulla»: torna tra le registrazioni del corso
          showUndoSnackBar(
            context,
            'Registrazione spostata in «Eliminati di recente».',
            undoneMessage: 'Registrazione ripristinata.',
            onUndo: () async {
              await _s.trash.restore(entry);
              _s.revision.bump();
            },
          );
        }
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Eliminazione non riuscita: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _togglePause() async {
    if (_busy) return;
    await _rec.togglePause();
  }

  /// «Segna»: segnalibro subito, la nota si aggiunge dall'avviso (che
  /// funziona anche dopo essere usciti dal registratore).
  void _mark() {
    final b = _rec.addBookmark();
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text('Segnalibro a ${clockLabel(b.at)}'),
          action: AppSnackBarAction(
            label: 'Aggiungi nota',
            onPressed: () => unawaited(addRecorderBookmarkNote(_rec, b)),
          ),
        ),
      );
  }

  Future<void> _editMark(Bookmark b) async {
    final current = _rec.bookmarks.where((x) => x.at == b.at).firstOrNull;
    if (current == null) return;
    final action = await showAppSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_note),
                title: Text(
                  current.note.isEmpty
                      ? 'Aggiungi una nota'
                      : 'Modifica la nota',
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
      ),
    );
    if (!mounted) return;
    if (action == 'togli') {
      _rec.removeBookmark(current);
    } else if (action == 'nota') {
      final note = await promptText(
        context,
        title: 'Segnalibro a ${clockLabel(current.at)}',
        label: 'Nota (facoltativa)',
        initial: current.note,
      );
      if (note != null) _rec.setBookmarkNote(current, note);
    }
  }

  static String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  void _setFormulas(bool v) {
    setState(() => _formulas = v);
    _rec.live?.formulas = v;
    unawaited(_s.settings.set(formulasKey, v ? '1' : '0'));
  }

  @override
  Widget build(BuildContext context) {
    // uscendo (Indietro, gesto) il riquadro compare subito, non a pagina
    // chiusa
    return PopScope<Object?>(
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) _rec.screenVisible = false;
      },
      child: _body(context),
    );
  }

  Widget _body(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_rec, ?_rec.live]),
      builder: (context, _) {
        final theme = Theme.of(context);
        final active = _rec.active;
        final paused = _rec.paused;
        final saving = _rec.saving;
        return Scaffold(
          appBar: AppBar(title: const Text('Registra lezione')),
          body: _catalog == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 560),
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                      children: [
                        DropdownButtonFormField<int>(
                          style: theme.textTheme.bodyLarge,
                          isExpanded: true,
                          initialValue: active ? _rec.courseId : _course?.id,
                          decoration: const InputDecoration(labelText: 'Corso'),
                          items: [
                            for (final c in _catalog!.courses)
                              DropdownMenuItem(
                                value: c.id,
                                child: Text(
                                  c.name,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: active
                              ? null
                              : (id) {
                                  setState(() => _course = _catalog!.byId[id]);
                                  unawaited(_loadLanguage());
                                },
                        ),
                        const SizedBox(height: 12),
                        _LanguagePicker(
                          value: active
                              ? (_rec.live?.language ?? _lang)
                              : _lang,
                          onChanged: active ? null : _setLanguage,
                        ),
                        const SizedBox(height: 24),
                        Semantics(
                          label: 'Durata della registrazione',
                          child: Text(
                            _clock(active ? _rec.elapsed : Duration.zero),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.displayMedium?.copyWith(
                              fontFamily: 'IBMPlexMono',
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            saving
                                ? 'Salvataggio…'
                                : (!active
                                      ? 'Pronto a registrare'
                                      : (paused
                                            ? 'In pausa'
                                            : 'Registrazione in corso')),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: active && !paused
                                  ? context.tokens.cyanSoft
                                  : theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (_rec.writeError != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '${_rec.writeError} L\'audio fin qui è al sicuro: '
                              'premi «Salva».',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: theme.colorScheme.error),
                            ),
                          ),
                        const SizedBox(height: 16),
                        ExcludeSemantics(
                          child: SizedBox(
                            height: 72,
                            child: CustomPaint(
                              painter: LiveWavePainter(
                                levels: active ? _rec.history : const [],
                                color: theme.colorScheme.primary,
                                idle: theme.colorScheme.outlineVariant,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 28),
                        // i due pulsanti laterali dividono lo spazio che resta
                        // accanto a quello grande (con caratteri grandi la
                        // scritta si accorcia, non esce dalla riga)
                        Row(
                          children: [
                            Expanded(
                              child: Center(
                                child: _SideButton(
                                  key: const Key('recorder-mark'),
                                  icon: Icons.bookmark_add_outlined,
                                  label: 'Segna',
                                  semantics:
                                      'Aggiungi un segnalibro al tempo attuale',
                                  onPressed: active && !saving ? _mark : null,
                                ),
                              ),
                            ),
                            _RecordButton(
                              active: active,
                              paused: paused,
                              busy: _busy || saving,
                              onPressed: active ? _togglePause : _start,
                            ),
                            Expanded(
                              child: Center(
                                child: _SideButton(
                                  key: const Key('recorder-save'),
                                  icon: Icons.check_rounded,
                                  label: 'Salva',
                                  semantics: 'Ferma e salva la registrazione',
                                  blue: true,
                                  onPressed: active && !_busy && !saving
                                      ? _save
                                      : null,
                                ),
                              ),
                            ),
                          ],
                        ),
                        // «Elimina» la registrazione in corso (va in
                        // «Eliminati di recente», recuperabile)
                        if (active)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Center(
                              child: TextButton.icon(
                                key: const Key('recorder-delete'),
                                style: TextButton.styleFrom(
                                  foregroundColor: theme.colorScheme.error,
                                  minimumSize: const Size(48, 48),
                                ),
                                onPressed: !_busy && !saving ? _delete : null,
                                icon: const Icon(Icons.delete_outline),
                                label: const Text('Elimina'),
                              ),
                            ),
                          ),
                        if (_rec.bookmarks.isNotEmpty) ...[
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.center,
                            children: [
                              for (final b in _rec.bookmarks)
                                ActionChip(
                                  avatar: Icon(
                                    Icons.bookmark,
                                    size: 18,
                                    color: context.tokens.orangeGradient.first,
                                  ),
                                  label: Text(
                                    b.note.isEmpty
                                        ? clockLabel(b.at)
                                        : '${clockLabel(b.at)} · ${b.note}',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  tooltip: 'Nota o rimozione del segnalibro',
                                  onPressed: () => _editMark(b),
                                ),
                            ],
                          ),
                        ],
                        const SizedBox(height: 20),
                        _LiveTranscriptCard(
                          live: _rec.live,
                          recording: active,
                          formulas: _formulas,
                          onFormulas: _setFormulas,
                        ),
                        if (Platform.isAndroid || Platform.isIOS) ...[
                          const SizedBox(height: 20),
                          Text(
                            'Puoi spegnere lo schermo, usare altre app o tornare '
                            'alle altre sezioni: la registrazione continua.',
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
        );
      },
    );
  }
}

/// «Aggiungi nota» dall'avviso del segnalibro: usa il Navigator dell'app,
/// così funziona anche se nel frattempo si è passati a un'altra pagina.
Future<void> addRecorderBookmarkNote(LectureRecorder rec, Bookmark b) async {
  final nav = appNavigatorKey.currentContext;
  if (nav == null || !nav.mounted) return;
  final current = rec.bookmarks.where((x) => x.at == b.at).firstOrNull;
  if (current == null) {
    showSnack(
      nav,
      'La registrazione è già stata salvata: aggiungi la nota dal segnalibro '
      'nella registrazione.',
    );
    return;
  }
  final note = await promptText(
    nav,
    title: 'Segnalibro a ${clockLabel(current.at)}',
    label: 'Nota (facoltativa)',
    initial: current.note,
  );
  if (note == null) return;
  final now = rec.bookmarks.where((x) => x.at == current.at).firstOrNull;
  if (now != null) rec.setBookmarkNote(now, note);
}

/// Apre Collegamenti (scheda Whisper) chiudendo le pagine aperte sopra.
void openWhisperLinks(BuildContext context) {
  final s = context.read<AppServices>();
  Navigator.of(context).popUntil((r) => r.isFirst);
  s.openRoute.call(AppRoutes.links);
}

/// Card «Trascrizione»: il parlato trascritto mentre si registra.
class _LiveTranscriptCard extends StatefulWidget {
  const _LiveTranscriptCard({
    required this.live,
    required this.recording,
    required this.formulas,
    required this.onFormulas,
  });
  final LiveTranscriber? live;
  final bool recording;
  final bool formulas;
  final ValueChanged<bool> onFormulas;

  @override
  State<_LiveTranscriptCard> createState() => _LiveTranscriptCardState();
}

class _LiveTranscriptCardState extends State<_LiveTranscriptCard> {
  final _scroll = ScrollController();
  int _shown = 0;

  /// Si sta correggendo una frase: il testo non scorre da solo.
  bool _editing = false;

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final live = widget.live;
    final segs = live?.segments ?? const <TranscriptSegment>[];
    final partial = live?.partialShown ?? '';
    final shown = segs.length + partial.length;
    if (shown != _shown && !_editing) {
      _shown = shown;
      // l'ultimo testo resta in vista
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.animateTo(
            _scroll.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut,
          );
        }
      });
    }
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final state = live?.state ?? LiveState.off;
    Widget body;
    if (segs.isNotEmpty || partial.isNotEmpty) {
      // testo stabilizzato, poi quello provvisorio (più chiaro) che si
      // aggiorna mentre si parla
      final style = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 260),
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            child: EditableLiveTranscript(
              segments: segs,
              partial: partial,
              style: style,
              language: spellLanguageOf(live?.locale),
              onEditing: (v) => _editing = v,
              onEdit: (e) => live?.replaceSegments(e.keys, e.text),
            ),
          ),
        ),
      );
    } else if (live != null && live.downloading) {
      body = _DownloadProgress(
        fraction: live.downloadProgress,
        what: live.downloadWhat,
        onCancel: live.cancelDownload,
      );
    } else {
      body = Text(switch (state) {
        LiveState.off when !widget.recording =>
          'Il parlato comparirà qui mentre registri.',
        LiveState.starting || LiveState.off => 'Avvio la trascrizione…',
        LiveState.unavailable => '',
        LiveState.failed =>
          'Trascrizione dal vivo interrotta: la registrazione continua e potrai '
              'trascriverla dopo averla salvata.',
        _ => 'In ascolto…',
      }, style: muted);
    }
    final notice = live == null || live.engine == LiveEngine.system
        ? null
        : speechNotice(
            live.systemUnavailable,
            mac: Platform.isMacOS,
            languageMissing: live.systemLanguageMissing,
            locale: live.locale,
            whisper: live.engine == LiveEngine.whisper,
          );
    return GlassCard(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  Icons.subtitles_outlined,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Trascrizione',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                // la sorgente cede spazio (puntini) con i caratteri grandi
                if (state == LiveState.running || state == LiveState.lagging)
                  Flexible(
                    child: Text(
                      switch (live!.engine) {
                        LiveEngine.system when live.appleSpeech =>
                          'dal vivo · Apple, sul Mac',
                        LiveEngine.system =>
                          live.onDevice
                              ? 'dal vivo · sul dispositivo'
                              : 'dal vivo',
                        LiveEngine.parakeet => 'dal vivo · Parakeet',
                        _ when live.quick || live.modelId == null =>
                          live.secondPassActive
                              ? 'dal vivo · Whisper integrato + small'
                              : 'dal vivo · Whisper integrato',
                        _ => 'dal vivo · Whisper ${live.modelId}',
                      },
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: context.tokens.cyanSoft,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            // «Formule (LaTeX)»: le formule dette a voce diventano formule
            Align(
              alignment: Alignment.centerLeft,
              child: FilterChip(
                key: const Key('live-formulas'),
                visualDensity: VisualDensity.compact,
                avatar: const Icon(Icons.functions, size: 18),
                label: const Text('Formule (LaTeX)'),
                tooltip:
                    'Scrive come formule quelle dette a voce: «due terzi», '
                    '«integrale da 2 a pi greco»…',
                selected: widget.formulas,
                showCheckmark: false,
                onSelected: widget.onFormulas,
              ),
            ),
            const SizedBox(height: 4),
            if (segs.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  'Tocca il testo per modificarlo: la registrazione continua.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (state == LiveState.unavailable)
              _SetupHint(
                downloadFailed: live?.downloadError != null,
                reason: live?.parakeetUnavailable,
                onOpen: () => openWhisperLinks(context),
              )
            else
              body,
            if (state == LiveState.lagging) ...[
              const SizedBox(height: 8),
              Text(
                '${live?.engine == LiveEngine.parakeet ? 'Parakeet' : 'Whisper'} '
                'è un po\' indietro: i pezzi saltati si completano dopo il '
                'salvataggio.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            // telefono: perché il riconoscitore del sistema non trascrive
            // (lingua, permesso…), anche mentre trascrive Whisper
            if (notice case final n?) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      [n.text, ?n.note].join(' '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (live?.note case final note?) ...[
              const SizedBox(height: 8),
              Text(
                note,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// «Lingua della lezione» sotto l'insegnamento: Italiano o Inglese (la
/// scelta resta per l'insegnamento). Durante la registrazione si vede ma non
/// si cambia.
class _LanguagePicker extends StatelessWidget {
  const _LanguagePicker({required this.value, this.onChanged});
  final String value;
  final ValueChanged<String>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final words = value == 'en' ? 'in inglese' : 'in italiano';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            Text('Lingua della lezione', style: theme.textTheme.bodyMedium),
            SegmentedButton<String>(
              key: const Key('recorder-language'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'it', label: Text('Italiano')),
                ButtonSegment(value: 'en', label: Text('Inglese')),
              ],
              selected: {value},
              onSelectionChanged: onChanged == null
                  ? null
                  : (v) {
                      AppFeedback.of(context).toggle();
                      onChanged!(v.first);
                    },
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'La trascrizione usa solo parole $words, salvo nomi e termini '
          'tecnici.',
          style: muted,
        ),
      ],
    );
  }
}

/// Download del modello per il testo dal vivo (solo la prima volta: Parakeet
/// su PC e Mac, il modello integrato in una build del telefono che non lo
/// include), con «Annulla».
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({this.fraction, required this.what, this.onCancel});
  final double? fraction;
  final String what;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = fraction == null ? '' : ' ${(fraction! * 100).floor()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scarico $what per il testo dal vivo, una volta sola…$pct',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Text(
          'La registrazione è già partita: il parlato di questi minuti si '
          'trascrive dopo il salvataggio.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (onCancel != null)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              key: const Key('live-download-cancel'),
              onPressed: onCancel,
              child: const Text('Annulla'),
            ),
          ),
      ],
    );
  }
}

/// Nessun motore trascrive: perché e come avere il testo dal vivo.
class _SetupHint extends StatelessWidget {
  const _SetupHint({
    required this.onOpen,
    this.downloadFailed = false,
    this.reason,
  });
  final VoidCallback onOpen;
  final bool downloadFailed;

  /// Perché Parakeet non si usa (PC e Mac).
  final String? reason;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          downloadFailed
              ? 'Il modello per il testo dal vivo non si è scaricato (serve '
                    'internet la prima volta): si riprova alla prossima '
                    'registrazione. La registrazione continua.'
              : (reason != null
                    ? '$reason Per il testo dal vivo scarica un modello '
                          'Whisper; la registrazione continua.'
                    : (Platform.isAndroid || Platform.isIOS
                          ? 'Per il testo dal vivo scarica un modello Whisper.'
                          : 'Per il testo dal vivo scarica Parakeet (o un '
                                'modello Whisper).')),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        TextButton(
          onPressed: onOpen,
          child: const Text('Apri Collegamenti → Whisper'),
        ),
      ],
    );
  }
}

/// Pulsante laterale con etichetta (Segna, Salva): area di tocco 64 px.
class _SideButton extends StatelessWidget {
  const _SideButton({
    super.key,
    required this.icon,
    required this.label,
    required this.semantics,
    required this.onPressed,
    this.blue = false,
  });
  final IconData icon;
  final String label;
  final String semantics;
  final VoidCallback? onPressed;
  final bool blue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final enabled = onPressed != null;
    final bg = blue ? t.cyan : theme.colorScheme.surfaceContainerHighest;
    final fg = blue
        ? (bg.computeLuminance() > 0.35
              ? const Color(0xFF02101F)
              : Colors.white)
        : theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: semantics,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 64,
            child: Material(
              color: enabled ? bg : bg.withValues(alpha: 0.3),
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: onPressed,
                child: Icon(
                  icon,
                  size: 28,
                  color: enabled ? fg : fg.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(
              color: enabled
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordButton extends StatelessWidget {
  const _RecordButton({
    required this.active,
    required this.paused,
    required this.busy,
    required this.onPressed,
  });
  final bool active;
  final bool paused;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: !active
          ? 'Avvia registrazione'
          : (paused ? 'Riprendi la registrazione' : 'Metti in pausa'),
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox.square(
            dimension: 96,
            child: FilledButton(
              style: FilledButton.styleFrom(
                shape: const CircleBorder(),
                padding: EdgeInsets.zero,
              ),
              onPressed: busy ? null : onPressed,
              child: busy
                  ? SizedBox.square(
                      dimension: 28,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        color: scheme.onPrimary,
                      ),
                    )
                  : Icon(
                      !active
                          ? Icons.mic
                          : (paused
                                ? Icons.play_arrow_rounded
                                : Icons.pause_rounded),
                      size: 44,
                    ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            !active ? 'Registra' : (paused ? 'Riprendi' : 'Pausa'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}
