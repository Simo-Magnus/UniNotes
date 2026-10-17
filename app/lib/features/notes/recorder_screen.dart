import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/feedback/feedback_service.dart';
import '../../core/reminders/notification_plan.dart' show AppRoutes;
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../links/whisper_models.dart' show kLiveWhisperModel;
import '../study/course_catalog.dart';
import '../study/study_widgets.dart' show promptText;
import 'lecture_recorder.dart';
import 'notes_screen.dart';
import 'course_notes_screen.dart';
import 'recorder/live_transcriber.dart';
import 'recorder/recording_meta.dart';
import 'recorder/recording_overlay.dart' show appNavigatorKey;
import 'recorder/recording_save.dart';
import 'recorder/system_speech.dart';
import 'recorder/waveform.dart';

/// Registratore delle lezioni, come Memo Vocali: scegli il corso e
/// registra. Durante la registrazione: tempo, forma d'onda, pausa e
/// ripresa (pulsante grande), «Segna» (segnalibro al tempo attuale, con
/// nota facoltativa) e la card «Trascrizione» con il parlato trascritto in
/// tempo reale (riconoscimento vocale del sistema, altrimenti Whisper).
/// «Salva» ferma e salva (Appunti → corso → Registrazioni) e porta alla
/// pagina del corso, alla card «Registrazioni delle lezioni».
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

  @override
  State<RecorderScreen> createState() => _RecorderScreenState();
}

class _RecorderScreenState extends State<RecorderScreen> {
  late final AppServices _s = context.read<AppServices>();
  CourseCatalog? _catalog;
  Course? _course;
  bool _busy = false;

  LectureRecorder get _rec => _s.recorder;

  @override
  void initState() {
    super.initState();
    _course = widget.initialCourse;
    _rec.screenVisible = true;
    _load();
  }

  @override
  void dispose() {
    _rec.screenVisible = false;
    super.dispose();
  }

  Future<void> _load() async {
    final catalog = await CourseCatalog.load(_s);
    final suggested = _course ?? await NotesScreen.suggestedCourse(_s, catalog);
    if (!mounted) return;
    setState(() {
      _catalog = catalog;
      _course =
          suggested ?? (catalog.courses.isEmpty ? null : catalog.courses.first);
    });
  }

  Future<void> _start() async {
    final c = _course;
    if (c == null || _busy) return;
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
        language: c.examLanguage,
      );
    } on RecorderException catch (e) {
      _s.feedback.warning();
      if (mounted) showSnack(context, e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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
    if (widget.fromCourse == course.id) {
      // la pagina del corso è sotto: ci si torna
      Navigator.of(context).pop(f.path);
      return;
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => CourseNotesScreen(course: course, justSaved: f!.path),
      ),
    );
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
          action: SnackBarAction(
            label: 'Aggiungi nota',
            onPressed: () => unawaited(addRecorderBookmarkNote(_rec, b)),
          ),
        ),
      );
  }

  Future<void> _editMark(Bookmark b) async {
    final current = _rec.bookmarks.where((x) => x.at == b.at).firstOrNull;
    if (current == null) return;
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
                current.note.isEmpty ? 'Aggiungi una nota' : 'Modifica la nota',
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
                                  c.label,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: active
                              ? null
                              : (id) => setState(
                                  () => _course = _catalog!.byId[id],
                                ),
                        ),
                        const SizedBox(height: 32),
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
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _SideButton(
                              key: const Key('recorder-mark'),
                              icon: Icons.bookmark_add_outlined,
                              label: 'Segna',
                              semantics:
                                  'Aggiungi un segnalibro al tempo attuale',
                              onPressed: active && !saving ? _mark : null,
                            ),
                            _RecordButton(
                              active: active,
                              paused: paused,
                              busy: _busy || saving,
                              onPressed: active ? _togglePause : _start,
                            ),
                            _SideButton(
                              key: const Key('recorder-save'),
                              icon: Icons.check_rounded,
                              label: 'Salva',
                              semantics: 'Ferma e salva la registrazione',
                              blue: true,
                              onPressed: active && !_busy && !saving
                                  ? _save
                                  : null,
                            ),
                          ],
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
                        _LiveTranscriptCard(live: _rec.live, recording: active),
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
  const _LiveTranscriptCard({required this.live, required this.recording});
  final LiveTranscriber? live;
  final bool recording;

  @override
  State<_LiveTranscriptCard> createState() => _LiveTranscriptCardState();
}

class _LiveTranscriptCardState extends State<_LiveTranscriptCard> {
  final _scroll = ScrollController();
  int _shown = 0;

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
    final partial = live?.partial ?? '';
    final shown = segs.length + partial.length;
    if (shown != _shown) {
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
    final system = live?.engine == LiveEngine.system;
    Widget body;
    if (segs.isNotEmpty || partial.isNotEmpty) {
      // testo stabilizzato, poi quello provvisorio (più chiaro) che si
      // aggiorna mentre si parla
      final style = theme.textTheme.bodyLarge?.copyWith(height: 1.45);
      body = ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: Scrollbar(
          controller: _scroll,
          child: SingleChildScrollView(
            controller: _scroll,
            child: SelectableText.rich(
              TextSpan(
                style: style,
                children: [
                  TextSpan(text: segs.map((s) => s.text).join(' ')),
                  if (partial.isNotEmpty)
                    TextSpan(
                      text: '${segs.isEmpty ? '' : ' '}$partial',
                      style: TextStyle(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
    } else if (live != null && live.downloading) {
      body = _DownloadProgress(fraction: live.downloadProgress);
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
    // perché non c'è il riconoscitore del sistema e come attivarlo (es.
    // «Riconoscimento vocale online» su Windows), anche mentre trascrive
    // Whisper
    final notice = live == null || system
        ? null
        : speechNotice(
            live.systemUnavailable,
            windows: Platform.isWindows,
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
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                if (state == LiveState.running || state == LiveState.lagging)
                  Text(
                    system
                        ? (live!.onDevice
                              ? 'dal vivo · sul dispositivo'
                              : 'dal vivo')
                        : 'dal vivo · Whisper',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: context.tokens.cyanSoft,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            if (state == LiveState.unavailable)
              _SetupHint(
                downloadFailed: live?.downloadError != null,
                onOpen: () => openWhisperLinks(context),
              )
            else
              body,
            if (state == LiveState.lagging) ...[
              const SizedBox(height: 8),
              Text(
                'Whisper è un po\' indietro: i pezzi saltati si completano '
                'dopo il salvataggio.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (notice != null) ...[
              const SizedBox(height: 10),
              SystemSpeechNotice(notice: notice),
            ],
          ],
        ),
      ),
    );
  }
}

/// Download del modello per il testo dal vivo (solo la prima volta, dove
/// non è incluso nell'app).
class _DownloadProgress extends StatelessWidget {
  const _DownloadProgress({this.fraction});
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = fraction == null ? '' : ' ${(fraction! * 100).floor()}%';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scarico il modello per il testo dal vivo '
          '(${kLiveWhisperModel.disk}, una volta sola)…$pct',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        LinearProgressIndicator(value: fraction),
        const SizedBox(height: 6),
        Text(
          'La registrazione è già partita: il parlato di questi secondi si '
          'trascrive dopo il salvataggio.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// Avviso sul riconoscitore del sistema: cosa fare, nota sulla privacy e
/// pulsante per le impostazioni (es. `ms-settings:privacy-speech`).
class SystemSpeechNotice extends StatelessWidget {
  const SystemSpeechNotice({super.key, required this.notice});
  final SpeechNotice notice;

  Future<void> _open(BuildContext context) async {
    final uri = notice.settings;
    if (uri == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    var ok = false;
    try {
      ok = await launchUrl(uri);
    } catch (_) {}
    if (!ok) {
      messenger?.showSnackBar(
        const SnackBar(
          content: Text('Impostazioni non aperte: aprile dal menu Start.'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.info_outline, size: 18, color: muted),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(notice.text, style: theme.textTheme.bodyMedium),
              if (notice.note != null) ...[
                const SizedBox(height: 4),
                Text(
                  notice.note!,
                  style: theme.textTheme.bodySmall?.copyWith(color: muted),
                ),
              ],
              if (notice.action != null && notice.settings != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => _open(context),
                    icon: const Icon(Icons.settings_outlined, size: 18),
                    label: Text(notice.action!),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Né il sistema né Whisper trascrivono: come avere il testo dal vivo.
class _SetupHint extends StatelessWidget {
  const _SetupHint({required this.onOpen, this.downloadFailed = false});
  final VoidCallback onOpen;
  final bool downloadFailed;

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
              : 'Per il testo dal vivo scarica un modello Whisper.',
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
            style: Theme.of(context).textTheme.labelMedium,
          ),
        ],
      ),
    );
  }
}
