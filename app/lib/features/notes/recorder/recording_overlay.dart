import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/motion.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../widgets/floating_pill.dart';
import '../../study/focus/focus_pill.dart';
import '../../study/study_stats.dart' show formatMinutes;
import '../lecture_recorder.dart';
import '../course_notes_screen.dart';
import '../notes_screen.dart' show openRecorder;
import 'overlay_logic.dart';
import 'recording_meta.dart';
import 'recording_save.dart';
import 'recording_session.dart';
import 'wav.dart';

/// Navigator dell'app: il riquadro della registrazione sta sopra il
/// Navigator e lo usa per dialoghi e pagine.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

const _red = Color(0xFFEF4444);

/// Sopra tutte le schermate dell'app: il riquadro «Registrazione in corso»
/// quando si esce dal registratore (indietro, cambio sezione, Home) e
/// quello della sessione Focus quando si esce dalla sua schermata, i
/// comandi arrivati dalla notifica o dalla Live Activity (Salva, apri) e,
/// all'avvio, il recupero delle registrazioni rimaste da una chiusura
/// improvvisa.
///
/// Il riquadro compare appena si esce dal registratore (anche se il cambio
/// avviene a metà di un fotogramma), segue il dito alla stessa velocità
/// (nessuna soglia né animazione durante il trascinamento) e si allarga o
/// stringe con la maniglia a destra, fino alla larghezza minima in cui i
/// pulsanti restano visibili.
class RecordingOverlayHost extends StatefulWidget {
  const RecordingOverlayHost({super.key, required this.child});
  final Widget child;

  @override
  State<RecordingOverlayHost> createState() => _RecordingOverlayHostState();
}

class _RecordingOverlayHostState extends State<RecordingOverlayHost> {
  late final AppServices _s = context.read<AppServices>();
  StreamSubscription<RecorderCommand>? _commands;

  /// Posizione del gruppo di riquadri (null = predefinita): durante il
  /// trascinamento si ridisegna solo la posizione.
  final _offset = ValueNotifier<Offset?>(null);

  /// Larghezza scelta con la maniglia (null = predefinita).
  double? _width;
  bool _rebuildQueued = false;

  LectureRecorder get _rec => _s.recorder;

  @override
  void initState() {
    super.initState();
    _commands = _rec.commands.listen(_onCommand);
    _rec.addListener(_changed);
    _s.focus.addListener(_changed);
    _s.focus.completed.addListener(_focusCompleted);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkOrphans());
  }

  @override
  void dispose() {
    _commands?.cancel();
    _rec.removeListener(_changed);
    _s.focus.removeListener(_changed);
    _s.focus.completed.removeListener(_focusCompleted);
    _offset.dispose();
    super.dispose();
  }

  /// Registratore o Focus cambiati. Se il cambio arriva mentre si chiude una
  /// pagina (a metà fotogramma) un rebuild normale non chiede un fotogramma
  /// nuovo e il riquadro comparirebbe solo al tocco successivo: si
  /// ricostruisce a fotogramma finito chiedendone subito un altro.
  void _changed() {
    if (!mounted) return;
    final binding = SchedulerBinding.instance;
    final phase = binding.schedulerPhase;
    if (phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks) {
      if (_rebuildQueued) return;
      _rebuildQueued = true;
      binding
        ..addPostFrameCallback((_) {
          _rebuildQueued = false;
          if (mounted) setState(() {});
        })
        ..scheduleFrame();
      return;
    }
    setState(() {});
  }

  BuildContext? get _nav => appNavigatorKey.currentContext;

  void _onCommand(RecorderCommand c) {
    switch (c) {
      case RecorderCommand.save:
        unawaited(_save());
      case RecorderCommand.open:
        _open();
      default:
        break;
    }
  }

  void _open() {
    final nav = _nav;
    if (nav != null) unawaited(openRecorder(nav));
  }

  Future<void> _save() async {
    final courseId = _rec.courseId;
    File? f;
    try {
      f = await saveRecording(_s);
    } catch (e) {
      _snack('Salvataggio non riuscito: $e');
      return;
    }
    if (f == null) return;
    final saved = f;
    final course = courseId == null
        ? null
        : (await _s.courses.mapById())[courseId];
    final nav = _nav;
    if (nav == null || !nav.mounted) return;
    // «Apri» porta alla pagina del corso, alla card delle registrazioni
    ScaffoldMessenger.maybeOf(nav)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Registrazione salvata.'),
          action: course == null
              ? null
              : SnackBarAction(
                  label: 'Apri',
                  onPressed: () => appNavigatorKey.currentState?.push(
                    MaterialPageRoute<void>(
                      builder: (_) => CourseNotesScreen(
                        course: course,
                        justSaved: saved.path,
                      ),
                    ),
                  ),
                ),
        ),
      );
  }

  void _snack(String text) {
    final nav = _nav;
    if (nav == null) return;
    ScaffoldMessenger.maybeOf(nav)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  /// X del riquadro: «Salvare la registrazione?».
  Future<void> _close() async {
    final nav = _nav;
    if (nav == null) return;
    final choice = await askSaveRecording(nav);
    switch (choice) {
      case RecordingCloseChoice.save:
        await _save();
      case RecordingCloseChoice.delete:
        await discardRecording(_s);
        _snack('Registrazione spostata in «Eliminati di recente».');
      case RecordingCloseChoice.cancel:
        break;
    }
  }

  /// Registrazioni rimaste da una chiusura improvvisa: si propone di
  /// salvarle.
  Future<void> _checkOrphans() async {
    List<RecordingSession> list;
    try {
      list = await _rec.orphans();
    } catch (_) {
      return;
    }
    for (final session in list) {
      if (!mounted) return;
      if (session.savedAs != null) {
        // già salvata: restavano solo i file di lavoro
        await recoverSession(_s, session);
        continue;
      }
      final info = await readWavInfo(session.wav);
      if (info == null || info.dataLength == 0) {
        await session.delete();
        continue;
      }
      final nav = _nav;
      if (nav == null || !nav.mounted) return;
      final when = DateFormat(
        "d MMMM 'alle' HH:mm",
        'it_IT',
      ).format(session.started);
      // due pulsanti; chiudendo il dialogo si decide più tardi
      final choice = await showDialog<RecordingCloseChoice>(
        context: nav,
        builder: (c) => AlertDialog(
          title: const Text('Registrazione da recuperare'),
          content: Text(
            'UniNotes si è chiusa durante la registrazione di '
            '${session.course.isEmpty ? 'una lezione' : '«${session.course}»'} '
            '(iniziata il $when, ${clockLabel(info.duration)}). L\'audio è al '
            'sicuro: vuoi salvarla? (Tocca fuori per decidere più tardi.)',
          ),
          actions: [
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(c).colorScheme.error,
              ),
              onPressed: () => Navigator.pop(c, RecordingCloseChoice.delete),
              child: const Text('Elimina'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, RecordingCloseChoice.save),
              child: const Text('Salva'),
            ),
          ],
        ),
      );
      if (choice == RecordingCloseChoice.save) {
        try {
          await recoverSession(_s, session);
          _snack('Registrazione recuperata e salvata.');
        } catch (e) {
          _snack('Recupero non riuscito: $e');
        }
      } else if (choice == RecordingCloseChoice.delete) {
        final nav2 = _nav;
        if (nav2 == null || !nav2.mounted) return;
        if (await confirmDeleteRecording(nav2)) {
          await trashSession(_s, session, duration: info.duration);
          _snack('Registrazione spostata in «Eliminati di recente».');
        }
      }
    }
  }

  /// Sessione Focus finita mentre si era in un'altra schermata: avviso con
  /// i minuti salvati.
  void _focusCompleted() {
    final r = _s.focus.completed.value;
    if (r == null || _s.focus.screenVisible) return;
    if (r.focusMinutes < 1) return;
    final nav = _nav;
    if (nav == null || !nav.mounted) return;
    showSuccessSnack(
      nav,
      '${r.completed ? 'Sessione Focus completata' : 'Sessione Focus salvata'}'
      ': ${formatMinutes(r.focusMinutes)} di concentrazione.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final focus = _s.focus;
    final media = MediaQuery.of(context);
    final screen = media.size;
    final safe = media.padding;
    // un solo gruppo trascinabile: registrazione sopra, Focus sotto
    final pills = <Widget Function(ValueChanged<Offset> drag)>[
      if (showRecordingPill(
        recording: _rec.active,
        recorderVisible: _rec.screenVisible,
        saving: _rec.saving,
      ))
        (drag) => _RecordingPill(
          rec: _rec,
          onOpen: _open,
          onToggle: () => unawaited(_rec.togglePause()),
          onSave: () => unawaited(_save()),
          onClose: () => unawaited(_close()),
          onDrag: drag,
        ),
      if (showFocusPill(
        active: focus.active,
        screenVisible: focus.screenVisible,
      ))
        (drag) => FocusPill(focus: focus, onDrag: drag),
    ];
    if (pills.isEmpty) return widget.child;
    const pillHeight = 64.0, gap = 8.0;
    final width = pillWidth(_width, screen.width);
    final size = Size(
      width + kPillHandleWidth,
      pills.length * pillHeight + (pills.length - 1) * gap,
    );
    final reserve = context.isWide ? 0.0 : kPillBottomReserve;
    Offset clamp(Offset o) =>
        clampPillOffset(o, screen, size, safe: safe, bottomReserve: reserve);
    // la posizione segue il dito: si aggiorna solo il riquadro, senza
    // ricostruire il resto
    void drag(Offset d) => _offset.value = clamp(
      (_offset.value ?? defaultPillOffset(screen, size, safe)) + d,
    );
    void resize(double dx) {
      final w = pillWidth(width + dx, screen.width);
      if (w != width) setState(() => _width = w);
    }

    final group = SizedBox(
      width: size.width,
      height: size.height,
      child: Row(
        children: [
          SizedBox(
            width: width,
            child: Column(
              children: [
                for (var i = 0; i < pills.length; i++) ...[
                  if (i > 0) const SizedBox(height: gap),
                  SizedBox(height: pillHeight, child: pills[i](drag)),
                ],
              ],
            ),
          ),
          _ResizeHandle(onResize: resize),
        ],
      ),
    );
    return Stack(
      children: [
        widget.child,
        ValueListenableBuilder<Offset?>(
          valueListenable: _offset,
          child: group,
          builder: (context, o, child) {
            final off = clamp(o ?? defaultPillOffset(screen, size, safe));
            return Positioned(
              left: off.dx,
              top: off.dy,
              width: size.width,
              height: size.height,
              child: child!,
            );
          },
        ),
      ],
    );
  }
}

/// Maniglia a destra del riquadro: trascinandola si allarga o si stringe
/// (segue il dito, nessuna soglia).
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onResize});
  final ValueChanged<double> onResize;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      label: 'Ridimensiona il riquadro',
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerMove: (e) => onResize(e.delta.dx),
          child: SizedBox(
            width: kPillHandleWidth,
            child: Center(
              child: Container(
                width: 4,
                height: 28,
                decoration: BoxDecoration(
                  color: t.textSecondary.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(2),
                  boxShadow: const [
                    BoxShadow(color: Color(0x66000000), blurRadius: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// «Salvare la registrazione?»: Salva o Elimina (con conferma); toccando
/// fuori dal dialogo la registrazione continua.
Future<RecordingCloseChoice> askSaveRecording(BuildContext context) async {
  final choice = await showDialog<RecordingCloseChoice>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Salvare la registrazione?'),
      content: const Text(
        'La registrazione si ferma. Puoi salvarla negli appunti del corso o '
        'eliminarla. Tocca fuori per continuare a registrare.',
      ),
      actions: [
        TextButton(
          key: const Key('recording-delete'),
          style: TextButton.styleFrom(
            foregroundColor: Theme.of(c).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(c, RecordingCloseChoice.delete),
          child: const Text('Elimina'),
        ),
        FilledButton(
          key: const Key('recording-save'),
          onPressed: () => Navigator.pop(c, RecordingCloseChoice.save),
          child: const Text('Salva'),
        ),
      ],
    ),
  );
  if (choice == RecordingCloseChoice.delete) {
    if (!context.mounted) return RecordingCloseChoice.cancel;
    return await confirmDeleteRecording(context)
        ? RecordingCloseChoice.delete
        : RecordingCloseChoice.cancel;
  }
  return choice ?? RecordingCloseChoice.cancel;
}

/// Conferma chiara prima di eliminare una registrazione.
Future<bool> confirmDeleteRecording(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return AlertDialog(
        icon: Icon(Icons.delete_outline, color: scheme.error),
        title: const Text('Eliminare la registrazione?'),
        content: const Text(
          'La registrazione va in «Eliminati di recente»: per 30 giorni puoi '
          'ancora recuperarla, poi viene cancellata.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('recording-delete-confirm'),
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Elimina'),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

/// Il riquadro: pallino rosso, corso, tempo, livello del microfono, Pausa
/// o Riprendi, Salva e X. Tocco → registratore; si trascina.
class _RecordingPill extends StatelessWidget {
  const _RecordingPill({
    required this.rec,
    required this.onOpen,
    required this.onToggle,
    required this.onSave,
    required this.onClose,
    required this.onDrag,
  });

  final LectureRecorder rec;
  final VoidCallback onOpen;
  final VoidCallback onToggle;
  final VoidCallback onSave;
  final VoidCallback onClose;
  final ValueChanged<Offset> onDrag;

  static String _clock(Duration d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.inHours)}:${two(d.inMinutes % 60)}:${two(d.inSeconds % 60)}';
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final saving = rec.saving;
    final paused = rec.paused;
    final course = rec.courseName ?? 'Registrazione';
    final status = saving
        ? 'Salvataggio…'
        : '${_clock(rec.elapsed)}${paused ? ' · In pausa' : ''}';
    return FloatingPill(
      semanticsLabel:
          'Registrazione in corso: $course, $status. Tocca per tornare al '
          'registratore',
      leading: _PulseDot(active: !paused && !saving),
      title: course,
      status: status,
      trailing: _LevelMeter(level: paused ? 0 : rec.level, color: t.cyan),
      onOpen: onOpen,
      onDrag: onDrag,
      actions: [
        PillButton(
          icon: paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          label: paused ? 'Riprendi la registrazione' : 'Metti in pausa',
          onTap: saving ? null : onToggle,
        ),
        PillButton(
          icon: Icons.check_rounded,
          label: 'Salva la registrazione',
          color: t.cyan,
          onTap: saving ? null : onSave,
        ),
        PillButton(
          icon: Icons.close_rounded,
          label: 'Chiudi: salva o elimina la registrazione',
          onTap: saving ? null : onClose,
        ),
      ],
    );
  }
}

/// Pallino rosso che pulsa mentre si registra (fermo in pausa).
class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.active});
  final bool active;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(_PulseDot old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final reduce = WidgetsBinding
        .instance
        .platformDispatcher
        .accessibilityFeatures
        .disableAnimations;
    if (widget.active && !reduce) {
      if (!_c.isAnimating) _c.repeat(reverse: true);
    } else {
      _c
        ..stop()
        ..value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
    child: Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: widget.active ? _red : _red.withValues(alpha: 0.6),
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: _red.withValues(alpha: 0.6), blurRadius: 8),
        ],
      ),
    ),
  );
}

/// Livello del microfono: quattro barrette.
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.color});
  final double level;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 26,
    height: 22,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (var i = 0; i < 4; i++)
          Container(
            width: 3,
            height:
                4 + 18 * (level > (i + 0.5) / 5 ? 1 : 0.15) * (0.55 + i * 0.15),
            decoration: BoxDecoration(
              color: level > (i + 0.5) / 5
                  ? color
                  : color.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
      ],
    ),
  );
}
