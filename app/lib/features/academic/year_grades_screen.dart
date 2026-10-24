import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/plan_scope.dart';
import '../../core/academic/academic_year.dart';
import '../../core/academic/year_completion.dart';
import '../../core/constants/enums.dart';
import '../../core/router/safe_pop.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../courses/course_ui.dart';

/// Insegnamenti del percorso con anno [year] (quelli senza anno esclusi).
Future<List<Course>> yearCourses(AppServices s, int year) async {
  final scope = PlanScope(profile: s.profile.value, year: year);
  return [
    for (final c in await s.courses.all())
      if (c.year == year &&
          scope.inPath(c) &&
          c.status != CourseStatus.archived)
        c,
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// Riga della schermata dei voti: un insegnamento e il suo esame finale.
class GradeEntry {
  GradeEntry(this.course, this.exam)
    : kind =
          (exam != null &&
              exam.status == ExamStatus.passed &&
              exam.grade == null &&
              !exam.laude)
          ? GradeKind.pass
          : GradeKind.grade,
      grade = exam?.status == ExamStatus.passed
          ? (exam!.laude ? 30 : exam.grade)
          : null,
      laude = exam?.status == ExamStatus.passed && (exam?.laude ?? false),
      passed = exam?.status == ExamStatus.passed,
      cfu = exam?.cfu ?? course.cfu;

  final Course course;

  /// Esame finale esistente (null = da creare).
  final Exam? exam;
  GradeKind kind;

  /// Voto 18–30 (null = non ancora sostenuto).
  int? grade;
  bool laude;

  /// Solo per l'idoneità: superato sì/no.
  bool passed;
  double? cfu;

  /// L'esame risulta superato con questa scelta.
  bool get isPassed => kind == GradeKind.pass ? passed : isValidGrade(grade);

  /// Esame da salvare, oppure null se non c'è nulla da cambiare.
  /// Voto fuori dalla scala 18–30 già salvato (per esempio una prova in
  /// itinere diventata esame finale, o dati importati): resta com'è finché
  /// lo studente non sceglie un voto.
  int? get outOfScaleGrade {
    final g = exam?.status == ExamStatus.passed ? exam?.grade : null;
    return g != null && !isValidGrade(g) ? g : null;
  }

  Exam? toExam() {
    final base = exam ?? Exam(courseId: course.id!, kind: ExamKind.finalExam);
    // CFU: si salvano sull'esame solo se diversi da quelli del corso (o se
    // l'esame li aveva già), così restano quelli del catalogo.
    final cfuChanged = cfu != null && (cfu != course.cfu || base.cfu != null);
    // voto fuori scala non toccato: nessun cambio (non si perde l'esito)
    if (kind == GradeKind.grade &&
        outOfScaleGrade != null &&
        grade == outOfScaleGrade) {
      return cfuChanged && cfu != base.cfu ? base.copyWith(cfu: cfu) : null;
    }
    if (!isPassed) {
      if (exam == null && !cfuChanged) return null;
      if (base.status != ExamStatus.passed && !cfuChanged) return null;
      return base.copyWith(
        status: base.status == ExamStatus.passed
            ? ExamStatus.planned
            : base.status,
        clearGrade: true,
        laude: false,
        cfu: cfuChanged ? cfu : null,
      );
    }
    final withLaude = kind == GradeKind.grade && grade == 30 && laude;
    return base.copyWith(
      status: ExamStatus.passed,
      grade: kind == GradeKind.grade ? grade : null,
      clearGrade: kind == GradeKind.pass,
      laude: withLaude,
      cfu: cfuChanged ? cfu : null,
    );
  }
}

/// Salva i voti e, se [markYear], lo stato dell'anno: `completato` se ogni
/// esame ha un esito, altrimenti `completato_parziale`.
Future<YearCompletion> saveYearGrades(
  AppServices s,
  int year,
  List<GradeEntry> entries, {
  required bool markYear,
}) async {
  for (final e in entries) {
    final exam = e.toExam();
    if (exam != null) await s.exams.save(exam);
  }
  final courses = [for (final e in entries) e.course];
  final completion = YearCompletion.evaluate(courses, await s.exams.all());
  if (markYear) await s.profiles.setYearStatus(year, completion.status);
  s.revision.bump();
  return completion;
}

/// Apre la schermata dei voti dell'anno [year]. Per gli anni passati salva
/// anche lo stato dell'anno (completato / completato in parte).
Future<YearCompletion?> openYearGrades(
  BuildContext context,
  int year, {
  bool? markYear,
  String? title,
}) {
  final s = context.read<AppServices>();
  final p = s.profile.value;
  final mark = markYear ?? (p != null && year < p.currentYear);
  return Navigator.of(context).push<YearCompletion>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          YearGradesScreen(year: year, markYear: mark, title: title),
    ),
  );
}

/// "Segna come completato": chiede **solo** i voti degli esami dell'anno
/// (18–30 e lode, oppure idoneità) e i CFU, già compilati dal catalogo.
class YearGradesScreen extends StatefulWidget {
  const YearGradesScreen({
    super.key,
    required this.year,
    this.markYear = true,
    this.title,
  });

  final int year;
  final bool markYear;
  final String? title;

  @override
  State<YearGradesScreen> createState() => _YearGradesScreenState();
}

class _YearGradesScreenState extends State<YearGradesScreen> {
  late final AppServices _s = context.read<AppServices>();
  late final Future<List<GradeEntry>> _entries = _load();
  bool _saving = false;

  Future<List<GradeEntry>> _load() async {
    final courses = await yearCourses(_s, widget.year);
    final exams = await _s.exams.all();
    return [
      for (final c in courses)
        GradeEntry(
          c,
          exams
                  .where(
                    (e) =>
                        e.courseId == c.id &&
                        e.kind == ExamKind.finalExam &&
                        e.status == ExamStatus.passed,
                  )
                  .firstOrNull ??
              exams
                  .where(
                    (e) => e.courseId == c.id && e.kind == ExamKind.finalExam,
                  )
                  .firstOrNull,
        ),
    ];
  }

  Future<void> _save(List<GradeEntry> entries) async {
    // doppio tocco su «Salva» prima che il pulsante si spenga: la seconda
    // chiusura toglierebbe anche la schermata sotto
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final r = await saveYearGrades(
        _s,
        widget.year,
        entries,
        markYear: widget.markYear,
      );
      if (!mounted) return;
      showSnack(
        context,
        !widget.markYear
            ? 'Voti salvati.'
            : r.isComplete
            ? '${planYearLabel(widget.year)} completato.'
            : 'Completato in parte: ${r.missingSummary.toLowerCase()}.',
      );
      // Indietro durante il salvataggio: la pagina sotto resta
      popIfCurrent(context, r);
    } catch (e) {
      // gli esami già scritti restano: un nuovo «Salva» completa il resto
      if (mounted) showSnack(context, 'Salvataggio non riuscito: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _s.profile.value;
    final aa = p?.academicYearOf(widget.year).label;
    return FutureBuilder<List<GradeEntry>>(
      future: _entries,
      builder: (context, snap) {
        final entries = snap.data;
        return Scaffold(
          appBar: AppBar(
            title: Text(
              widget.title ??
                  (widget.markYear
                      ? 'Segna come completato'
                      : 'Voti del ${planYearLabel(widget.year)}'),
            ),
          ),
          body: snap.hasError
              ? EmptyState(
                  icon: Icons.error_outline,
                  message: 'Voti non leggibili: ${snap.error}',
                )
              : entries == null
              ? const Center(child: CircularProgressIndicator())
              : _body(context, entries, aa),
          bottomNavigationBar: entries == null || entries.isEmpty
              ? null
              : SafeArea(
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    heightFactor: 1,
                    child: FilledButton.icon(
                      key: const Key('grades-save'),
                      onPressed: _saving ? null : () => _save(entries),
                      icon: const Icon(Icons.check),
                      label: Text(
                        widget.markYear ? 'Salva e completa l\'anno' : 'Salva',
                      ),
                    ),
                  ),
                ),
        );
      },
    );
  }

  Widget _body(BuildContext context, List<GradeEntry> entries, String? aa) {
    final t = context.tokens;
    if (entries.isEmpty) {
      return const EmptyState(
        icon: Icons.school_outlined,
        message:
            'Nessun insegnamento in questo anno. Aggiungili dalla sezione '
            'Insegnamenti o con "Aggiungi esame" in Esami.',
      );
    }
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.only(bottom: 24),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Text(
                '${planYearLabel(widget.year)}${aa == null ? '' : ' · $aa'}: '
                'inserisci solo i voti. Gli esami senza voto restano da '
                'fare e l\'anno risulta completato in parte (puoi riprendere '
                'quando vuoi).',
                style: TextStyle(fontSize: 13, color: t.textSecondary),
              ),
            ),
            for (final e in entries)
              _GradeRow(entry: e, onChanged: () => setState(() {})),
          ],
        ),
      ),
    );
  }
}

class _GradeRow extends StatefulWidget {
  const _GradeRow({required this.entry, required this.onChanged});
  final GradeEntry entry;
  final VoidCallback onChanged;

  @override
  State<_GradeRow> createState() => _GradeRowState();
}

class _GradeRowState extends State<_GradeRow> {
  late final _cfu = TextEditingController(
    text: widget.entry.cfu == null ? '' : _fmt(widget.entry.cfu!),
  );

  static String _fmt(double v) => !v.isFinite
      ? ''
      : v == v.roundToDouble()
      ? v.toInt().toString()
      : '$v'.replaceAll('.', ',');

  /// CFU scritti non validi (fuori 0–60, «Infinity»…): non si salvano.
  String? _cfuError;

  @override
  void dispose() {
    _cfu.dispose();
    super.dispose();
  }

  void _set(VoidCallback f) {
    setState(f);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final t = context.tokens;
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    e.course.name,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                ),
                Text(
                  e.isPassed ? 'Superato' : '- -',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: e.isPassed ? t.cyanSoft : t.textMuted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<GradeKind>(
                  showSelectedIcon: false,
                  segments: [
                    for (final k in GradeKind.values)
                      ButtonSegment(value: k, label: Text(k.label)),
                  ],
                  selected: {e.kind},
                  onSelectionChanged: (v) => _set(() => e.kind = v.first),
                ),
                if (e.kind == GradeKind.grade)
                  SizedBox(
                    // segue la grandezza dei caratteri
                    width: MediaQuery.textScalerOf(context).scale(120),
                    child: DropdownButtonFormField<int?>(
                      key: Key('grade-${e.course.id}'),
                      style: Theme.of(context).textTheme.bodyLarge,
                      initialValue: e.grade,
                      isDense: true,
                      decoration: const InputDecoration(labelText: 'Voto'),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('- -')),
                        // voto già salvato fuori scala: una voce sua, se no
                        // il menù non ha il valore iniziale (errore)
                        if (e.outOfScaleGrade case final g?)
                          DropdownMenuItem(value: g, child: Text('$g')),
                        for (var g = 18; g <= 30; g++)
                          DropdownMenuItem(value: g, child: Text('$g')),
                      ],
                      onChanged: (v) => _set(() {
                        e.grade = v;
                        if (v != 30) e.laude = false;
                      }),
                    ),
                  ),
                if (e.kind == GradeKind.grade && e.grade == 30)
                  FilterChip(
                    label: const Text('Lode'),
                    selected: e.laude,
                    onSelected: (v) => _set(() => e.laude = v),
                  ),
                if (e.kind == GradeKind.pass)
                  FilterChip(
                    key: Key('pass-${e.course.id}'),
                    label: const Text('Superato'),
                    selected: e.passed,
                    onSelected: (v) => _set(() => e.passed = v),
                  ),
                SizedBox(
                  width: 90,
                  child: TextField(
                    controller: _cfu,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'CFU',
                      isDense: true,
                      errorText: _cfuError,
                    ),
                    onChanged: (v) {
                      final n = parseCfu(v);
                      e.cfu = n;
                      final err = v.trim().isNotEmpty && n == null
                          ? 'Non valido'
                          : null;
                      if (err != _cfuError) setState(() => _cfuError = err);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
