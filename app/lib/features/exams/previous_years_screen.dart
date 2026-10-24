import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/academic_year.dart';
import '../../core/constants/enums.dart';
import '../../core/feedback/app_modals.dart';
import '../../core/feedback/motion.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/exam.dart';
import '../../widgets/adaptive_row.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/undo_snack_bar.dart';
import 'exam_detail.dart';
import 'exam_status.dart' show GradeDialog;
import 'exam_ui.dart';
import 'previous_years.dart';

/// Apre Esami → Anni precedenti.
Future<void> openPreviousYears(BuildContext context) => Navigator.of(context)
    .push<void>(MaterialPageRoute(builder: (_) => const PreviousYearsScreen()));

/// «1 esame» / «3 esami».
String examsCount(int n) => n == 1 ? '1 esame' : '$n esami';

/// Esami → Anni precedenti: gli insegnamenti degli anni prima dell'anno di
/// partenza, divisi per anno. Ogni riga ha due scelte: «Sostenuto» (poi
/// voto, lode o idoneità, facoltativi; toccandolo di nuovo si cambia
/// l'esito) e «Da sostenere» (diventa un arretrato; toccandolo di nuovo
/// l'esame torna «Da completare»). Per ogni anno
/// «Segna tutti come sostenuti». Quando non resta nulla da completare la
/// pagina resta come riepilogo modificabile.
class PreviousYearsScreen extends StatelessWidget {
  const PreviousYearsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Anni precedenti')),
      body: RevisionBuilder<PreviousYearsData?>(
        load: loadPreviousYears,
        builder: (context, data) {
          if (data == null || !data.applies) {
            return const EmptyState(
              icon: Icons.history_edu_rounded,
              message:
                  'Nessun esame degli anni precedenti: hai iniziato a usare '
                  'UniNotes dal 1° anno.',
            );
          }
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: [
                  _Intro(data: data),
                  for (final y in data.years)
                    if (y.courses.isNotEmpty) ..._year(context, data, y),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _year(
    BuildContext context,
    PreviousYearsData d,
    PreviousYear y,
  ) {
    final t = context.tokens;
    return [
      SectionHeader(
        d.profile.yearChipLabel(y.year),
        trailing: y.toComplete == 0
            ? null
            : TextButton.icon(
                key: Key('previous-all-${y.year}'),
                onPressed: () => _markAll(context, y),
                icon: const Icon(Icons.done_all_rounded, size: 18),
                label: const Text('Segna tutti come sostenuti'),
              ),
      ),
      if (y.mandatory.isNotEmpty) _RowsCard(courses: y.mandatory),
      if (y.electives.isNotEmpty) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 10, 20, 2),
          child: Text(
            'A scelta',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: t.textSecondary,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 2),
          child: Text(
            'Indica solo quelli che hai scelto: gli altri restano così e non '
            'contano.',
            style: TextStyle(fontSize: 12, color: t.textMuted),
          ),
        ),
        _RowsCard(courses: y.electives),
      ],
    ];
  }

  Future<void> _markAll(BuildContext context, PreviousYear y) async {
    final s = context.read<AppServices>();
    if (!await _confirmMarkAll(context, s, y)) return;
    // esami com'erano, per «Annulla»
    final before = [
      for (final c in y.mandatoryToComplete)
        if (c.exam?.id != null) c.exam!,
    ];
    final done = await markPreviousYearTaken(s, y);
    s.feedback.complete();
    if (context.mounted && done > 0) {
      showUndoSnackBar(
        context,
        '${done == 1 ? 'Segnato come sostenuto' : 'Segnati come sostenuti'}: '
        '${examsCount(done)} del ${planYearLabel(y.year)}',
        undoneMessage: 'Esami di nuovo da completare.',
        onUndo: () async {
          for (final e in before) {
            await s.exams.update(e);
          }
          s.revision.bump();
        },
      );
    }
  }
}

/// Conferma di «Segna tutti come sostenuti»: «Annulla» e «Segna tutti», con
/// la casella «Non chiedere più».
Future<bool> _confirmMarkAll(
  BuildContext context,
  AppServices s,
  PreviousYear y,
) async {
  try {
    if (await s.settings.get(PreviousYearsPrompt.dontAskMarkAllKey) == '1') {
      return true;
    }
  } catch (_) {}
  if (!context.mounted) return false;
  final n = y.toComplete;
  var dontAsk = false;
  final ok = await showAppDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        // scorre se lo spazio è poco (finestra bassa, caratteri grandi)
        scrollable: true,
        icon: const Icon(Icons.done_all_rounded),
        title: const Text('Segnare tutti come sostenuti?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${n == 1 ? 'L\'esame obbligatorio' : 'I $n esami obbligatori'} '
              'del ${planYearLabel(y.year)} ancora da completare '
              '${n == 1 ? 'diventa superato' : 'diventano superati'}, senza '
              'voto: puoi aggiungere i voti toccando ciascun esame.'
              '${y.electives.isEmpty ? '' : ' Gli insegnamenti a scelta '
                        'restano da indicare uno per uno.'}',
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('previous-all-dont-ask'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: dontAsk,
              onChanged: (v) => setLocal(() => dontAsk = v ?? false),
              title: const Text('Non chiedere più'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            key: const Key('previous-all-confirm'),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Segna tutti'),
          ),
        ],
      ),
    ),
  );
  if (ok == true && dontAsk) {
    try {
      await s.settings.set(PreviousYearsPrompt.dontAskMarkAllKey, '1');
    } catch (_) {}
  }
  return ok ?? false;
}

/// Spiegazione in cima e contatore («3 da completare» o «Completati»).
class _Intro extends StatelessWidget {
  const _Intro({required this.data});
  final PreviousYearsData data;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final n = data.toComplete;
    final done = n == 0;
    final start = planYearLabel(data.startYear);
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  done ? Icons.check_circle_outline : Icons.history_edu_rounded,
                  color: t.cyanSoft,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    done
                        ? 'Anni precedenti completati'
                        : 'Esami prima del $start',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              done
                  ? 'Gli esami ${data.yearsLabel} sono tutti indicati: '
                        '${data.taken} sostenuti, ${data.toTake} da '
                        'sostenere. Puoi sempre cambiarli qui.'
                  : 'Hai iniziato a usare UniNotes al $start. Per ogni esame '
                        '${data.yearsLabel} indica se l\'hai già sostenuto '
                        '(il voto è facoltativo) o se è ancora da sostenere: '
                        'solo quelli da sostenere diventano arretrati. Finché '
                        'non scegli, non contano in medie, CFU e prove da '
                        'sostenere.',
              style: TextStyle(fontSize: 13, color: t.textSecondary),
            ),
            if (!done) ...[
              const SizedBox(height: 10),
              _Pill(
                key: const Key('previous-count'),
                label: '$n da completare',
                icon: Icons.pending_actions_outlined,
                color: const Color(0xFFF57C00),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Pillola colorata (contatore).
class _Pill extends StatelessWidget {
  const _Pill({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
  });
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fg = dark
        ? Color.lerp(color, Colors.white, 0.45)!
        : readableOn(color, Brightness.light);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.25 : 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

class _RowsCard extends StatelessWidget {
  const _RowsCard({required this.courses});
  final List<PreviousCourse> courses;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlassCard(
      child: Column(
        children: [
          for (final (i, c) in courses.indexed) ...[
            if (i > 0) Divider(height: 1, color: t.innerBorder),
            _CourseRow(key: ValueKey('previous-${c.course.id}'), entry: c),
          ],
        ],
      ),
    );
  }
}

/// Riga di un insegnamento: solo il nome, lo stato e le due scelte.
class _CourseRow extends StatelessWidget {
  const _CourseRow({super.key, required this.entry});
  final PreviousCourse entry;

  String _statusLine(Exam? e) {
    if (e == null) return 'Nessun esame finale: scegli per crearlo';
    return switch (e.status) {
      ExamStatus.toComplete => 'Da completare',
      ExamStatus.passed when e.laude => 'Superato con 30 e lode',
      ExamStatus.passed when e.grade != null => 'Superato con ${e.grade}',
      ExamStatus.passed => 'Superato, senza voto',
      ExamStatus.taken => 'Sostenuto, in attesa dell\'esito',
      ExamStatus.failed => 'Non superato: da sostenere di nuovo',
      ExamStatus.planned => 'Da sostenere (arretrato)',
      ExamStatus.booked => 'Prenotato',
      ExamStatus.cancelled => 'Annullato: da sostenere',
    };
  }

  /// Insegnamenti con una scelta in corso di salvataggio: un doppio tocco
  /// (o due dialoghi del voto aperti uno sopra l'altro) creerebbe due esami
  /// finali per lo stesso insegnamento.
  static final Set<int?> _saving = {};

  Future<void> _choose(BuildContext context, PreviousChoice? to) async {
    final id = entry.course.id;
    if (!_saving.add(id)) return;
    try {
      await _apply(context, to);
    } catch (e) {
      if (context.mounted) showSnack(context, 'Scelta non salvata: $e');
    } finally {
      _saving.remove(id);
    }
  }

  Future<void> _apply(BuildContext context, PreviousChoice? to) async {
    final s = context.read<AppServices>();
    final e = entry.exam;
    switch (to) {
      case null:
        if (!entry.canReset) {
          showSnack(
            context,
            'Ha una data o una prenotazione: cambialo dal dettaglio della prova.',
          );
          return;
        }
        await resetPreviousToComplete(s, entry);
        s.feedback.toggle();
      case PreviousChoice.taken:
        final r = await showAppDialog<ExamOutcome>(
          context: context,
          builder: (_) => GradeDialog(
            midterm: false,
            // «Sostenuto»: superato, il voto è facoltativo
            status:
                e?.status == ExamStatus.passed ||
                    e?.status == ExamStatus.failed ||
                    e?.status == ExamStatus.taken
                ? e!.status
                : ExamStatus.passed,
            grade: e?.status == ExamStatus.passed ? e?.grade : null,
            laude: e?.status == ExamStatus.passed && (e?.laude ?? false),
            title: 'Com\'è andato?',
          ),
        );
        if (r == null || !context.mounted) return;
        await setPreviousTaken(s, entry, r);
        r.status == ExamStatus.passed
            ? s.feedback.complete()
            : s.feedback.toggle();
      case PreviousChoice.toTake:
        await setPreviousToTake(s, entry);
        s.feedback.toggle();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final e = entry.exam;
    final choice = entry.choice;
    final status = e?.status ?? ExamStatus.toComplete;
    final color = readableOn(
      examStatusColor(context, status),
      Theme.of(context).brightness,
    );
    final picker = SegmentedButton<PreviousChoice>(
      key: ValueKey('previous-choice-${entry.course.id}'),
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      segments: const [
        ButtonSegment(
          value: PreviousChoice.taken,
          icon: Icon(Icons.check_rounded, size: 18),
          label: Text('Sostenuto'),
        ),
        ButtonSegment(
          value: PreviousChoice.toTake,
          icon: Icon(Icons.event_note_outlined, size: 18),
          label: Text('Da sostenere'),
        ),
      ],
      selected: {?choice},
      // toccando di nuovo «Sostenuto» si cambia l'esito (il voto resta
      // finché non lo si cambia); toccando di nuovo «Da sostenere» la scelta
      // si toglie e l'esame torna «Da completare»
      onSelectionChanged: (sel) => _choose(
        context,
        sel.firstOrNull ??
            (choice == PreviousChoice.taken ? PreviousChoice.taken : null),
      ),
    );
    final info = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          entry.course.name,
          style: Theme.of(context).textTheme.titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        AnimatedSwitcher(
          duration: motion(context, const Duration(milliseconds: 180)),
          child: Row(
            key: ValueKey('${e?.status.key}-${e?.grade}-${e?.laude}'),
            children: [
              Icon(examStatusIcon(status), size: 15, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  _statusLine(e),
                  style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    return InkWell(
      // il dettaglio della prova (data, note, voto…) quando c'è una scelta
      onTap: e?.id == null || choice == null
          ? null
          : () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ExamDetailScreen(examId: e!.id!),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: LayoutBuilder(
          // il selettore cresce con i caratteri: la soglia con lui
          builder: (context, c) =>
              c.maxWidth >=
                  560 *
                      max(1.0, MediaQuery.textScalerOf(context).scale(14) / 14)
              ? Row(
                  children: [
                    Expanded(child: info),
                    const SizedBox(width: 12),
                    picker,
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    info,
                    const SizedBox(height: 8),
                    Align(alignment: Alignment.centerRight, child: picker),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Riquadro in cima a «Da sostenere»: quanti esami degli anni precedenti
/// sono da completare, con «Completa»; quando non ne restano, un
/// riepilogo con «Modifica». Niente se l'anno di partenza è il 1°.
class PreviousYearsBanner extends StatelessWidget {
  const PreviousYearsBanner({super.key, required this.data});
  final PreviousYearsData? data;

  @override
  Widget build(BuildContext context) {
    final d = data;
    if (d == null || !d.applies) return const SizedBox.shrink();
    final t = context.tokens;
    final n = d.toComplete;
    final done = n == 0;
    return GlassCard(
      key: const Key('previous-years-banner'),
      child: InkWell(
        onTap: () => openPreviousYears(context),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, done ? 8 : 12, 12, done ? 8 : 12),
          child: AdaptiveActionRow(
            leading: Icon(
              done ? Icons.check_circle_outline : Icons.history_edu_rounded,
              color: t.cyanSoft,
            ),
            gap: 12,
            actionLabel: done ? 'Modifica' : 'Completa',
            action: done
                ? TextButton(
                    key: const Key('previous-years-open'),
                    onPressed: () => openPreviousYears(context),
                    child: const Text('Modifica'),
                  )
                : FilledButton.tonal(
                    key: const Key('previous-years-open'),
                    onPressed: () => openPreviousYears(context),
                    child: const Text('Completa'),
                  ),
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  done ? 'Anni precedenti completati' : 'Anni precedenti',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: t.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  done
                      ? '${d.taken} sostenuti · ${d.toTake} da sostenere'
                      : '${examsCount(n)} ${d.yearsLabel} da completare: '
                            'indica se ${n == 1 ? 'l\'hai già sostenuto' : 'li hai già sostenuti'}.',
                  style: TextStyle(fontSize: 12.5, color: t.textSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
