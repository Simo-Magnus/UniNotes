import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/constants/text_limits.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';
import '../../widgets/math_text.dart';
import '../courses/course_ui.dart';
import 'exam_form.dart';
import 'exam_materials.dart';
import 'exam_status.dart';
import 'exam_ui.dart';
import 'study_materials_editor.dart';

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
        onDeleted: () => Navigator.maybePop(context),
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

  Future<void> _save(Exam next, {bool quiet = false}) async {
    final s = context.read<AppServices>();
    await s.exams.update(next);
    s.revision.bump();
    if (quiet) return;
    // voto registrato ora: traguardo, con suono e vibrazione
    final passedNow =
        next.status == ExamStatus.passed && exam.status != ExamStatus.passed;
    passedNow ? s.feedback.complete() : s.feedback.toggle();
  }

  /// Testo libero (titolo, luogo, note, CFU): "" = tolto, null = annullato.
  Future<String?> _askText(
    String title,
    String label,
    String? initial, {
    int maxLength = TextLimits.notes,
    bool multiline = false,
    TextInputType? keyboard,
  }) => showDialog<String>(
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

  /// Data e ora direttamente dalla card.
  Future<void> _editWhen() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: exam.date ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 5),
    );
    if (d == null || !mounted) return;
    final parts = exam.time?.split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.tryParse(parts?.first ?? '') ?? 9,
        minute:
            int.tryParse(parts != null && parts.length > 1 ? parts[1] : '') ??
            0,
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
    final v = await showDialog<String>(
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

  /// Esame finale o prova in itinere/esonero: le due scelte.
  Future<void> _editKind() async {
    final v = await showModalBottomSheet<ExamKind>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final k in ExamKind.values)
              ListTile(
                leading: Icon(
                  k == ExamKind.midterm ? Icons.timelapse : Icons.flag_outlined,
                ),
                title: Text(
                  k == ExamKind.midterm
                      ? 'Prova in itinere o esonero'
                      : 'Esame finale',
                ),
                trailing: k == exam.kind ? const Icon(Icons.check) : null,
                onTap: () => Navigator.pop(c, k),
              ),
          ],
        ),
      ),
    );
    if (v == null || v == exam.kind || !mounted) return;
    // le prove in itinere non hanno lode
    await _save(
      exam.copyWith(kind: v, laude: v == ExamKind.midterm ? false : null),
    );
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
    final n = double.tryParse(v.replaceAll(',', '.'));
    if (v.isNotEmpty && (n == null || n < 0 || n > 60)) {
      showSnack(context, 'Valore CFU non valido');
      return;
    }
    await _save(_withText(cfu: n, clearCfu: n == null));
  }

  /// Voto (esame finale: 18-30 e lode) o punteggio (prova in itinere o
  /// esonero): inserirlo segna la prova come superata, toglierlo («—») la
  /// riporta in attesa di esito.
  Future<void> _editGrade() async {
    final r = await showDialog<({int? grade, bool laude})>(
      context: context,
      builder: (c) => GradeDialog(
        midterm: _midterm,
        grade: exam.grade,
        laude: exam.laude,
        allowEmpty: exam.grade != null,
      ),
    );
    if (r == null || !mounted) return;
    await _save(
      r.grade == null
          ? exam.copyWith(
              clearGrade: true,
              laude: false,
              status: exam.status == ExamStatus.passed
                  ? ExamStatus.taken
                  : exam.status,
            )
          : exam.copyWith(
              grade: r.grade,
              laude: r.laude,
              status: ExamStatus.passed,
            ),
    );
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
    await _save(exam.copyWith(studyMaterials: list), quiet: true);
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
                  children: [
                    InkWell(
                      key: const Key('detail-title'),
                      onTap: _editTitle,
                      borderRadius: BorderRadius.circular(4),
                      child: Text(
                        exam.title ?? exam.kind.label,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // solo il nome dell'insegnamento
                    Text(course?.name ?? 'Corso sconosciuto'),
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
              Tooltip(
                message: 'Cambia tipo',
                child: InkWell(
                  onTap: _editKind,
                  borderRadius: BorderRadius.circular(12),
                  child: ExamKindChip(exam.kind),
                ),
              ),
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
        editable(
          InfoRow.text(
            icon: Icons.event,
            label: 'Data e ora',
            value: examDateLabel(exam),
          ),
          _editWhen,
          'Cambia data e ora',
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
            value: grade == null
                ? (_midterm ? 'Nessun punteggio' : 'Nessun voto')
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
