import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/electives.dart';

import '../../core/constants/enums.dart';
import '../../core/constants/text_limits.dart';
import '../../core/feedback/app_modals.dart';
import '../../core/router/safe_pop.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';
import '../../widgets/math_text.dart';
import '../../widgets/undo_snack_bar.dart';
import '../courses/course_rename.dart';
import '../courses/course_ui.dart';
import 'exam_form.dart';
import 'exam_materials.dart';
import 'exam_status.dart';
import 'exam_ui.dart';
import 'study_materials_editor.dart';
import '../../widgets/date_pick.dart';

class _ExamDetailData {
  const _ExamDetailData(this.exam, this.course, this.universities);
  final Exam? exam;
  final Course? course;
  final Map<String, University> universities;
}

/// Pagina di dettaglio (layout stretto).
class ExamDetailScreen extends StatelessWidget {
  const ExamDetailScreen({super.key, required this.examId});
  final int examId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Dettaglio prova')),
      body: ExamDetailView(
        examId: examId,
        // dopo l'eliminazione: solo questa pagina (non quella sotto se
        // si è già tornati indietro)
        onDeleted: () => popIfCurrent(context),
      ),
    );
  }
}

/// Dettaglio di un esame/prova, incorporabile nel pannello destro su schermi larghi.
class ExamDetailView extends StatelessWidget {
  const ExamDetailView({super.key, required this.examId, this.onDeleted});
  final int examId;
  final VoidCallback? onDeleted;

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<_ExamDetailData>(
      deps: [examId],
      load: (s) async {
        final exam = await s.exams.byId(examId);
        final course = exam == null
            ? null
            : await s.courses.byId(exam.courseId);
        return _ExamDetailData(
          exam,
          course,
          await s.courses.universitiesById(),
        );
      },
      builder: (context, d) {
        final exam = d.exam;
        if (exam == null) {
          return const EmptyState(
            icon: Icons.assignment_outlined,
            message: 'Prova non trovata.',
          );
        }
        return _ExamDetailBody(
          exam: exam,
          course: d.course,
          onDeleted: onDeleted,
        );
      },
    );
  }
}

/// Dettaglio di una prova, tutto modificabile sul posto (niente pulsante
/// «Modifica»): l'icona e lo stato cambiano lo stato, le righe dei dettagli
/// aprono la loro scelta, «Argomenti» e «Materiali da studiare» diventano
/// campi da modificare toccandoli.
class _ExamDetailBody extends StatefulWidget {
  const _ExamDetailBody({
    required this.exam,
    required this.course,
    this.onDeleted,
  });

  final Exam exam;
  final Course? course;
  final VoidCallback? onDeleted;

  @override
  State<_ExamDetailBody> createState() => _ExamDetailBodyState();
}

class _ExamDetailBodyState extends State<_ExamDetailBody> {
  Exam get exam => widget.exam;
  Course? get course => widget.course;
  bool get _midterm => exam.kind == ExamKind.midterm;

  /// Argomenti in modifica (campo di testo al posto del testo).
  bool _editingTopics = false;
  late final _topics = TextEditingController(text: exam.topics);
  final _topicsFocus = FocusNode();

  /// Materiali in modifica (l'editor della lista al posto della lista).
  bool _editingMaterials = false;

  @override
  void initState() {
    super.initState();
    // uscendo dal campo gli argomenti si salvano da soli
    _topicsFocus.addListener(() {
      if (!_topicsFocus.hasFocus && _editingTopics) _saveTopics();
    });
  }

  @override
  void dispose() {
    _topics.dispose();
    _topicsFocus.dispose();
    super.dispose();
  }

  /// false se non si è salvato (lo si dice: prima la modifica spariva
  /// senza avviso, es. con il disco pieno).
  Future<bool> _save(Exam next, {bool quiet = false}) async {
    final s = context.read<AppServices>();
    try {
      await s.exams.update(next);
    } catch (e) {
      if (mounted) showSnack(context, 'Modifica non salvata: $e');
      return false;
    }
    s.revision.bump();
    if (quiet) return true;
    // voto registrato ora: traguardo, con suono e vibrazione
    final passedNow =
        next.status == ExamStatus.passed && exam.status != ExamStatus.passed;
    passedNow ? s.feedback.complete() : s.feedback.toggle();
    return true;
  }

  /// Testo libero (titolo, luogo, note, CFU): "" = tolto, null = annullato.
  Future<String?> _askText(
    String title,
    String label,
    String? initial, {
    int maxLength = TextLimits.notes,
    bool multiline = false,
    TextInputType? keyboard,
  }) => showAppDialog<String>(
    context: context,
    builder: (_) => _TextEditDialog(
      title: title,
      label: label,
      initial: initial ?? '',
      maxLength: maxLength,
      multiline: multiline,
      keyboard: keyboard,
    ),
  );

  Future<void> _editTitle() async {
    final v = await _askText(
      'Titolo',
      _midterm ? 'es. Prima prova in itinere' : 'es. Appello di gennaio',
      exam.title,
      maxLength: TextLimits.examTitle,
    );
    if (v == null || !mounted) return;
    await _save(_withText(title: v));
  }

  /// Insegnamento di una prova in itinere o esonero: solo uno di quelli del
  /// corso (anche quelli aggiunti dallo studente), come nel modulo. Il nome
  /// libero si scrive nel titolo; il nome dell'insegnamento si cambia dalla
  /// sua scheda o dal suo esame finale.
  Future<void> _pickCourse() async {
    final s = context.read<AppServices>();
    final (courses, _) = await examCourseChoices(s, keep: {exam.courseId});
    if (!mounted) return;
    final id = await showAppDialog<int>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Insegnamento'),
        children: [
          for (final course in courses)
            ListTile(
              key: Key('pick-course-${course.id}'),
              leading: Icon(
                course.id == exam.courseId
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(course.name),
              onTap: () => Navigator.pop(c, course.id),
            ),
        ],
      ),
    );
    if (id == null || id == exam.courseId || !mounted) return;
    if (!await _save(exam.copyWith(courseId: id))) return;
    // insegnamento a scelta tolto dal piano: con la prova torna nel piano
    try {
      await restoreElective(s, id);
      s.revision.bump();
    } catch (_) {}
  }

  /// Data e ora direttamente dalla card.
  Future<void> _editWhen() async {
    final now = DateTime.now();
    final d = await showSafeDatePicker(
      context: context,
      initialDate: exam.date ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null || !mounted) return;
    final parts = exam.time?.split(':');
    final t = await showSafeTimePicker(
      context: context,
      initialTime: TimeOfDay(
        // ora salvata strana («99:99» da dati importati): dentro il quadrante
        hour: (int.tryParse(parts?.first ?? '') ?? 9).clamp(0, 23),
        minute:
            (int.tryParse(parts != null && parts.length > 1 ? parts[1] : '') ??
                    0)
                .clamp(0, 59),
      ),
    );
    if (!mounted) return;
    String two(int v) => v.toString().padLeft(2, '0');
    await _save(
      exam.copyWith(
        date: d,
        time: t == null ? exam.time : '${two(t.hour)}:${two(t.minute)}',
      ),
    );
  }

  /// «Rimuovi data» / «Rimuovi orario» (icona accanto a «Data e ora»): con
  /// l'orario un foglio con le due scelte, senza orario si toglie subito la
  /// data. Si salva subito, con «Annulla» nell'avviso in basso (un tocco
  /// sbagliato non perde la data). Calendario e promemoria seguono alla
  /// prossima sincronizzazione: evento tolto, o di tutto il giorno.
  Future<void> _removeWhen() async {
    if (exam.date == null) return;
    var timeOnly = false;
    if (exam.time != null) {
      final choice = await showRemoveWhenSheet(context, exam);
      if (choice == null || !mounted) return;
      timeOnly = choice == RemoveWhen.time;
    }
    final before = exam;
    final s = context.read<AppServices>();
    if (!await _save(timeOnly ? before.withoutTime() : before.withoutDate())) {
      return;
    }
    if (!mounted) return;
    showUndoSnackBar(
      context,
      timeOnly ? 'Orario tolto: la prova è di tutto il giorno' : 'Data tolta',
      undoneMessage: timeOnly ? 'Orario ripristinato.' : 'Data ripristinata.',
      onUndo: () => restoreExamWhen(s, before),
    );
  }

  Future<void> _editLocation() async {
    final v = await _askText(
      'Luogo',
      'Aula, edificio o «online»',
      exam.location,
      maxLength: TextLimits.location,
    );
    if (v == null || !mounted) return;
    await _save(_withText(location: v));
  }

  Future<void> _editNotes() async {
    final v = await _askText('Note', 'Note', exam.notes, multiline: true);
    if (v == null || !mounted) return;
    await _save(_withText(notes: v));
  }

  Future<void> _editType() async {
    final v = await showAppDialog<String>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('Tipo di prova'),
        children: [
          for (final e in kExamTypes.entries)
            ListTile(
              leading: Icon(
                e.key == exam.examType
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(e.value),
              onTap: () => Navigator.pop(c, e.key),
            ),
        ],
      ),
    );
    if (v != null && mounted) await _save(exam.copyWith(examType: v));
  }

  /// CFU propri dell'esame finale (vuoto = quelli dell'insegnamento).
  Future<void> _editCfu() async {
    final v = await _askText(
      'CFU',
      'Vuoto = quelli dell\'insegnamento',
      exam.cfu == null ? null : formatNumber(exam.cfu),
      maxLength: 5,
      keyboard: const TextInputType.numberWithOptions(decimal: true),
    );
    if (v == null || !mounted) return;
    final n = parseCfu(v);
    if (v.trim().isNotEmpty && n == null) {
      showSnack(context, 'Valore CFU non valido');
      return;
    }
    await _save(_withText(cfu: n, clearCfu: n == null));
  }

  /// Voto (esame finale: 18-30 e lode, idoneità, «Non superato») o
  /// punteggio (prova in itinere o esonero, oppure «Non superata»): il voto
  /// segna la prova come superata, «Non superato» la lascia tra quelle da
  /// sostenere, nessun voto la riporta in attesa di esito.
  Future<void> _editGrade() async {
    final r = await showAppDialog<ExamOutcome>(
      context: context,
      builder: (c) => GradeDialog(
        midterm: _midterm,
        status: exam.status,
        grade: exam.grade,
        laude: exam.laude,
      ),
    );
    if (r == null || !mounted) return;
    await _save(withOutcome(exam, r));
  }

  Future<void> _saveTopics() async {
    final t = _topics.text.trim();
    setState(() => _editingTopics = false);
    if (t == (exam.topics ?? '')) return;
    await _save(_withText(topics: t), quiet: true);
  }

  /// Ogni modifica dei materiali si salva subito; i file nuovi vanno anche
  /// tra i materiali dell'insegnamento (come dal modulo della prova).
  Future<void> _saveMaterials(List<String> list) async {
    final s = context.read<AppServices>();
    final added = [
      for (final m in list)
        if (looksLikePath(m) && !exam.studyMaterials.contains(m)) m,
    ];
    if (!await _save(exam.copyWith(studyMaterials: list), quiet: true)) return;
    if (added.isEmpty) return;
    try {
      await shareExamMaterials(s, courseId: exam.courseId, added: added);
    } catch (e) {
      if (mounted) showSnack(context, 'Materiale salvato, ma: $e');
    }
  }

  /// Copia con un campo di testo cambiato: "" lo toglie (copyWith non sa
  /// rimettere null).
  Exam _withText({
    String? title,
    String? location,
    String? notes,
    String? topics,
    double? cfu,
    bool clearCfu = false,
  }) {
    String? pick(String? v, String? old) =>
        v == null ? old : (v.isEmpty ? null : v);
    final m = exam.toMap()
      ..['title'] = pick(title, exam.title)
      ..['location'] = pick(location, exam.location)
      ..['notes'] = pick(notes, exam.notes)
      ..['topics'] = pick(topics, exam.topics)
      ..['cfu'] = clearCfu ? null : (cfu ?? exam.cfu);
    return Exam.fromMap(m);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cfu = exam.cfu ?? course?.cfu;
    final grade = gradeLabel(exam);
    final hint = TextStyle(color: theme.colorScheme.outline);
    Widget editable(Widget row, VoidCallback onTap, String tooltip) => InkWell(
      onTap: onTap,
      child: Row(
        children: [
          Expanded(child: row),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Tooltip(
              message: tooltip,
              child: Icon(
                Icons.edit_outlined,
                size: 18,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Tooltip(
                message: 'Cambia stato',
                child: InkResponse(
                  key: const Key('detail-status'),
                  radius: 30,
                  onTap: () => changeExamStatus(context, exam),
                  child: GradeBadge(exam, size: 52),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  // esame finale: il nome dell'insegnamento è il titolo
                  // (toccandolo lo si cambia, in tutta l'app) e sotto la
                  // tipologia con il titolo scelto dallo studente; prova in
                  // itinere o esonero: il suo titolo e sotto l'insegnamento,
                  // scelto tra quelli del corso
                  children: _midterm
                      ? [
                          _HeaderLine(
                            key: const Key('detail-title'),
                            text: exam.title ?? exam.kind.label,
                            style: theme.textTheme.titleLarge,
                            tooltip: 'Cambia il titolo',
                            onTap: _editTitle,
                          ),
                          const SizedBox(height: 4),
                          _HeaderLine(
                            key: const Key('detail-course-name'),
                            text: course?.name ?? 'Corso sconosciuto',
                            tooltip: 'Cambia insegnamento',
                            onTap: _pickCourse,
                          ),
                        ]
                      : [
                          _HeaderLine(
                            key: const Key('detail-course-name'),
                            text: course?.name ?? 'Corso sconosciuto',
                            style: theme.textTheme.titleLarge,
                            tooltip: 'Cambia il nome dell\'insegnamento',
                            onTap: course == null
                                ? null
                                : () => renameCourseDialog(context, course!),
                          ),
                          const SizedBox(height: 4),
                          _HeaderLine(
                            key: const Key('detail-title'),
                            text: [
                              exam.kind.label,
                              if (exam.title case final t? when t.isNotEmpty) t,
                            ].join(' · '),
                            tooltip: 'Cambia il titolo',
                            onTap: _editTitle,
                          ),
                        ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // esame finale e prova in itinere / esonero non si scambiano:
              // si aggiungono e si eliminano, il tipo resta quello scelto
              // (l'esame finale lo dice già sotto il nome)
              if (_midterm) ExamKindChip(exam.kind),
              Tooltip(
                message: 'Cambia stato',
                child: InkWell(
                  onTap: () => changeExamStatus(context, exam),
                  borderRadius: BorderRadius.circular(12),
                  child: ExamStatusChip(exam.status),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () async {
                  if (await deleteExamWithConfirm(context, exam)) {
                    widget.onDeleted?.call();
                  }
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('Elimina'),
              ),
            ],
          ),
        ),
        const SectionHeader('Dettagli'),
        Row(
          children: [
            Expanded(
              child: editable(
                InfoRow.text(
                  icon: Icons.event,
                  label: 'Data e ora',
                  value: examDateLabel(exam),
                ),
                _editWhen,
                'Cambia data e ora',
              ),
            ),
            // solo con una data: toglie l'orario o la data (area di tocco
            // di 48 dp, etichetta per il lettore di schermo)
            if (exam.date != null)
              IconButton(
                key: const Key('detail-remove-when'),
                tooltip: exam.time != null
                    ? 'Rimuovi data o orario'
                    : 'Rimuovi data',
                onPressed: _removeWhen,
                icon: Icon(
                  Icons.event_busy_outlined,
                  size: 20,
                  color: theme.colorScheme.outline,
                ),
              ),
          ],
        ),
        editable(
          InfoRow.text(
            icon: Icons.place_outlined,
            label: 'Luogo',
            value: exam.location,
          ),
          _editLocation,
          'Cambia luogo',
        ),
        editable(
          InfoRow.text(
            icon: Icons.category_outlined,
            label: 'Tipo di prova',
            value: examTypeLabel(exam.examType),
          ),
          _editType,
          'Cambia tipo di prova',
        ),
        editable(
          InfoRow.text(
            icon: Icons.grade_outlined,
            label: _midterm ? 'Punteggio' : 'Voto',
            value: exam.status == ExamStatus.failed
                ? (_midterm ? 'Non superata' : 'Non superato')
                : grade == null
                ? (exam.status == ExamStatus.passed && !_midterm
                      ? 'Idoneità (senza voto)'
                      : (_midterm ? 'Nessun punteggio' : 'Nessun voto'))
                : (_midterm
                      ? '$grade punti'
                      : '$grade${exam.laude ? '' : '/30'}'),
          ),
          _editGrade,
          _midterm ? 'Inserisci il punteggio' : 'Inserisci il voto',
        ),
        if (!_midterm)
          editable(
            InfoRow.text(
              icon: Icons.school_outlined,
              label: 'CFU',
              value: cfu == null
                  ? null
                  : '${formatNumber(cfu)}${exam.cfu == null ? ' (dal corso)' : ''}',
            ),
            _editCfu,
            'Cambia i CFU',
          ),
        editable(
          InfoRow.text(
            icon: Icons.sticky_note_2_outlined,
            label: 'Note',
            value: exam.notes,
          ),
          _editNotes,
          'Modifica le note',
        ),
        const SectionHeader('Argomenti'),
        if (_editingTopics)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              key: const Key('detail-topics-field'),
              controller: _topics,
              focusNode: _topicsFocus,
              autofocus: true,
              minLines: 2,
              maxLines: 12,
              maxLength: TextLimits.examTopics,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Argomenti oggetto della prova',
                suffixIcon: IconButton(
                  tooltip: 'Fatto',
                  icon: const Icon(Icons.check),
                  onPressed: _saveTopics,
                ),
              ),
            ),
          )
        else
          InkWell(
            key: const Key('detail-topics'),
            onTap: () => setState(() {
              _topics.text = exam.topics ?? '';
              _editingTopics = true;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: (exam.topics ?? '').isEmpty
                    ? Text('Tocca per aggiungere gli argomenti.', style: hint)
                    : mayContainMath(exam.topics!)
                    ? MathText(exam.topics!)
                    : Text(exam.topics!),
              ),
            ),
          ),
        SectionHeader(
          'Materiali da studiare',
          trailing: _editingMaterials
              ? TextButton(
                  key: const Key('detail-materials-done'),
                  onPressed: () => setState(() => _editingMaterials = false),
                  child: const Text('Fatto'),
                )
              : null,
        ),
        if (_editingMaterials)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: StudyMaterialsEditor(
              items: exam.studyMaterials,
              showTitle: false,
              onChanged: _saveMaterials,
            ),
          )
        else if (exam.studyMaterials.isEmpty)
          InkWell(
            key: const Key('detail-materials'),
            onTap: () => setState(() => _editingMaterials = true),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: Text('Tocca per aggiungere i materiali.', style: hint),
              ),
            ),
          )
        else
          // i file si aprono toccandoli; le righe di testo aprono la modifica
          StudyMaterialsList(
            key: const Key('detail-materials'),
            exam.studyMaterials,
            onEdit: () => setState(() => _editingMaterials = true),
          ),
      ],
    );
  }
}

/// Cosa togliere dalla riga «Data e ora» del dettaglio.
enum RemoveWhen { time, date }

/// Foglio della riga «Data e ora» di una prova con data e orario: due
/// scelte, «Rimuovi orario» e «Rimuovi data» (null = chiuso senza scegliere).
/// Le spiegazioni nominano calendario e promemoria solo per le prove da
/// sostenere, le sole che ci sono.
Future<RemoveWhen?> showRemoveWhenSheet(BuildContext context, Exam exam) {
  final pending = exam.status.isPending;
  return showAppSheet<RemoveWhen>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      // scorre: con caratteri grandi il foglio non ha altezza per tutto
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                examDateLabel(exam),
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            ListTile(
              key: const Key('when-remove-time'),
              leading: const Icon(Icons.timer_off_outlined),
              title: const Text('Rimuovi orario'),
              subtitle: Text(
                pending
                    ? 'Resta la data: la prova è di tutto il giorno, anche '
                          'nel calendario'
                    : 'Resta la data: la prova è di tutto il giorno',
              ),
              onTap: () => Navigator.pop(c, RemoveWhen.time),
            ),
            ListTile(
              key: const Key('when-remove-date'),
              leading: const Icon(Icons.event_busy_outlined),
              title: const Text('Rimuovi data'),
              subtitle: Text(
                pending
                    ? 'Si toglie anche l\'orario; la prova esce dal '
                          'calendario e dai promemoria'
                    : 'Si toglie anche l\'orario',
              ),
              onTap: () => Navigator.pop(c, RemoveWhen.date),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
}

/// «Annulla» di «Rimuovi data» / «Rimuovi orario»: rimette data e orario di
/// [before] sulla prova com'è ora (le altre modifiche fatte nel frattempo
/// restano; se la prova è stata eliminata non fa nulla). Il calendario
/// riscrive l'evento alla prossima sincronizzazione.
Future<void> restoreExamWhen(AppServices s, Exam before) async {
  final id = before.id;
  if (id == null || before.date == null) return;
  final now = await s.exams.byId(id);
  if (now == null) return;
  await s.exams.update(now.copyWith(date: before.date, time: before.time));
  s.revision.bump();
}

/// Testo da modificare: «Annulla» e «Salva»; vuoto toglie il valore
/// (restituisce "").
class _TextEditDialog extends StatefulWidget {
  const _TextEditDialog({
    required this.title,
    required this.label,
    required this.initial,
    required this.maxLength,
    required this.multiline,
    this.keyboard,
  });
  final String title;
  final String label;
  final String initial;
  final int maxLength;
  final bool multiline;
  final TextInputType? keyboard;

  @override
  State<_TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<_TextEditDialog> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _ok() => Navigator.pop(context, _ctrl.text.trim());

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        minLines: 1,
        maxLines: widget.multiline ? 8 : 1,
        keyboardType: widget.keyboard,
        maxLength: widget.multiline ? widget.maxLength : null,
        inputFormatters: widget.multiline
            ? null
            : TextLimits.max(widget.maxLength),
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: widget.label),
        onSubmitted: widget.multiline ? null : (_) => _ok(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _ok, child: const Text('Salva')),
      ],
    );
  }
}

/// Riga dell'intestazione del dettaglio che si tocca per cambiarla (titolo,
/// insegnamento), con la matita accanto; senza [onTap] solo il testo.
class _HeaderLine extends StatelessWidget {
  const _HeaderLine({
    super.key,
    required this.text,
    required this.tooltip,
    this.style,
    this.onTap,
  });

  final String text;
  final String tooltip;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = Text(text, style: style);
    if (onTap == null) return label;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: label),
            const SizedBox(width: 4),
            Icon(
              Icons.edit_outlined,
              size: style == null ? 14 : 18,
              color: Theme.of(context).colorScheme.outline,
            ),
          ],
        ),
      ),
    );
  }
}
