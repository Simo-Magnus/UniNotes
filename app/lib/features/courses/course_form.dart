import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/catalog/path_setup.dart';
import '../../core/catalog/teaching_language.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/university.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'course_ui.dart';
import '../../core/constants/text_limits.dart';

/// Apre il modulo corso. Restituisce l'id del corso salvato (o null se annullato).
Future<int?> openCourseForm(BuildContext context, {Course? course}) {
  return Navigator.of(context).push<int>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CourseFormPage(course: course),
    ),
  );
}

/// Chiede conferma ed elimina il corso (con esami, prove e materiali collegati).
Future<bool> deleteCourseWithConfirm(
  BuildContext context,
  Course course,
) async {
  var withData = true;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setState) => AlertDialog(
        title: const Text('Elimina corso'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Vuoi eliminare "${course.name}"?'),
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: withData,
              onChanged: (v) => setState(() => withData = v ?? true),
              title: const Text(
                'Elimina anche esami, prove in itinere, moduli di studio e '
                'materiale didattico collegati.',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Annulla'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(c).colorScheme.error,
              foregroundColor: Theme.of(c).colorScheme.onError,
            ),
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Elimina'),
          ),
        ],
      ),
    ),
  );
  if (ok != true || !context.mounted || course.id == null) return false;
  final services = context.read<AppServices>();
  if (withData) {
    await services.courses.delete(course.id!);
    await PathSetupService(services).rememberRemoved(course.externalId);
  } else {
    // Esami, prove, moduli e materiali dipendono dal corso: per tenerli il
    // corso si archivia (sparisce da elenchi e medie) invece di cancellarlo.
    await services.courses.update(
      course.copyWith(status: CourseStatus.archived),
    );
  }
  services.revision.bump();
  if (context.mounted) {
    showSnack(
      context,
      withData ? 'Corso eliminato' : 'Corso eliminato dagli elenchi: esami, prove, moduli e materiali restano (archiviato).',
    );
  }
  return true;
}

class _FormData {
  const _FormData(this.universities, this.degrees, this.language);
  final List<University> universities;
  final List<Degree> degrees;

  /// Versioni italiana/inglese dal catalogo (null se non ce ne sono).
  final TeachingLanguage? language;
}

class CourseFormPage extends StatefulWidget {
  const CourseFormPage({super.key, this.course});
  final Course? course;

  @override
  State<CourseFormPage> createState() => _CourseFormPageState();
}

class _CourseFormPageState extends State<CourseFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final Future<_FormData> _data = _loadData();

  Course? get _c => widget.course;

  late final _name = TextEditingController(text: _c?.name);
  late final _code = TextEditingController(text: _c?.code);
  late final _teacher = TextEditingController(text: _c?.teacher);
  late final _year = TextEditingController(text: _c?.year?.toString());
  late final _cfu = TextEditingController(text: _num(_c?.cfu));
  late final _description = TextEditingController(text: _c?.description);
  late final _lectureHours = TextEditingController(
    text: _num(_c?.lectureHours),
  );
  late final _examStructure = TextEditingController(text: _c?.examStructure);
  late final _optionalOral = TextEditingController(text: _c?.optionalOralInfo);

  /// Università e corso di laurea non si cambiano dal modulo: quelli
  /// dell'insegnamento o, per uno nuovo, quelli dello studente.
  late final String? _universityId =
      _c?.universityId ??
      (_c == null
          ? context.read<AppServices>().profile.value?.universityId
          : null);
  late final String? _degreeId =
      _c?.degreeId ??
      (_c == null ? context.read<AppServices>().profile.value?.degreeId : null);
  late String? _semester = _c?.semester;
  late int? _color = _c?.color;
  late CourseStatus _status = _c?.status ?? CourseStatus.active;
  late double? _difficulty = _c?.difficulty;
  late String? _examMode = _c?.examMode;
  bool _saving = false;

  static String _num(double? v) =>
      v == null ? '' : formatNumber(v).replaceAll(',', '.');

  Future<_FormData> _loadData() async {
    final services = context.read<AppServices>();
    final s = services.courses;
    final c = _c;
    final lang = c == null ? null : await TeachingLanguage.of(services, c);
    if (lang != null && lang.hasEnglish && c != null) {
      _english = _initialEnglish = lang.isEnglish(c);
    }
    return _FormData(
      await s.universities(),
      await s.degrees(),
      (lang?.hasEnglish ?? false) ? lang : null,
    );
  }

  /// Lingua dell'esame scelta (solo per gli insegnamenti offerti anche in
  /// inglese).
  bool _english = false;
  bool _initialEnglish = false;
  TeachingLanguage? _language;

  void _setEnglish(bool v, TeachingLanguage lang) {
    final c = _c;
    if (c == null) return;
    final n = lang.apply(c, english: v);
    setState(() {
      _english = v;
      _name.text = n.name;
      _code.text = n.code ?? '';
      _teacher.text = n.teacher ?? '';
    });
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _code,
      _teacher,
      _year,
      _cfu,
      _description,
      _lectureHours,
      _examStructure,
      _optionalOral,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String? _text(TextEditingController c) =>
      c.text.trim().isEmpty ? null : c.text.trim();
  double? _double(TextEditingController c) =>
      double.tryParse(c.text.trim().replaceAll(',', '.'));

  String? _validateNumber(
    String? v, {
    double min = 0,
    double max = 10000,
    bool integer = false,
  }) {
    if (v == null || v.trim().isEmpty) return null;
    final n = integer
        ? int.tryParse(v.trim())?.toDouble()
        : double.tryParse(v.trim().replaceAll(',', '.'));
    if (n == null) return 'Numero non valido';
    if (n < min || n > max) {
      return 'Valore tra ${formatNumber(min)} e ${formatNumber(max)}';
    }
    return null;
  }

  Future<void> _save() async {
    // dati non ancora caricati (o errore): niente da salvare
    final form = _formKey.currentState;
    if (form == null || !form.validate()) return;
    final old = _c;
    final course = Course(
      id: old?.id,
      externalId: old?.externalId,
      universityId: _universityId,
      degreeId: _degreeId,
      name: _name.text.trim(),
      code: _text(_code),
      teacher: _text(_teacher),
      year: int.tryParse(_year.text.trim()),
      semester: _semester,
      cfu: _double(_cfu),
      description: _text(_description),
      color: _color,
      status: _status,
      lectureHours: _double(_lectureHours),
      difficulty: _difficulty,
      examMode: _examMode,
      examStructure: _text(_examStructure),
      optionalOralInfo: _text(_optionalOral),
      materialsFound: old?.materialsFound,
      materialsNote: old?.materialsNote,
      source: old?.source,
      updatedAt: old?.updatedAt,
      // dati del catalogo che il modulo non mostra: restano com'erano
      booksStatus: old?.booksStatus,
      examsStatus: old?.examsStatus,
      syllabusUrl: _language == null
          ? old?.syllabusUrl
          : _language!.apply(old!, english: _english).syllabusUrl,
      ssd: old?.ssd,
      mandatory: old?.mandatory,
      curriculum: old?.curriculum,
      examLanguage: _language == null
          ? old?.examLanguage
          : (_english ? 'en' : null),
    );
    setState(() => _saving = true);
    final services = context.read<AppServices>();
    try {
      final changed =
          old != null &&
          (old.name != course.name ||
              old.code != course.code ||
              old.teacher != course.teacher ||
              old.year != course.year ||
              old.semester != course.semester ||
              old.cfu != course.cfu ||
              old.examMode != course.examMode);
      // il cambio di lingua non conta come modifica a mano
      final languageOnly =
          _language != null &&
          _english != _initialEnglish &&
          course.name == _language!.apply(old!, english: _english).name;
      final toSave =
          (old != null && (old.userEdited || (changed && !languageOnly)))
          ? course.withUserEdited()
          : course;
      final id = await services.courses.save(toSave);
      if (old != null && old.name != toSave.name) {
        await services.notes.renameCourse(old, toSave);
      }
      final lang = _language;
      if (lang != null && _english != _initialEnglish) {
        await lang.replaceBooks(services, course, english: _english);
      }
      services.revision.bump();
      if (mounted) Navigator.pop(context, id);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Errore nel salvataggio: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_c?.id == null ? 'Nuovo corso' : 'Modifica corso'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('Salva'),
          ),
        ],
      ),
      body: FutureBuilder<_FormData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyState(
              icon: Icons.error_outline,
              message: 'Errore: ${snap.error}',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          return Form(
            key: _formKey,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: _fields(snap.data!),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _fields(_FormData d) {
    const gap = SizedBox(height: 16);
    final unis = {for (final u in d.universities) u.id: u};
    final degree = d.degrees.where((x) => x.id == _degreeId).firstOrNull;
    const semesters = {
      '1': '1° semestre',
      '2': '2° semestre',
      'annuale': 'Annuale',
    };
    final semesterValue = semesters.containsKey(_semester) ? _semester : null;
    final lang = _language = d.language;

    return [
      if (lang != null) ...[
        Text(
          'Lingua dell\'esame',
          style: Theme.of(context).textTheme.labelLarge,
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          key: const Key('exam-language'),
          segments: const [
            ButtonSegment(value: false, label: Text('Italiano')),
            ButtonSegment(value: true, label: Text('Inglese')),
          ],
          selected: {_english},
          onSelectionChanged: (s) => _setEnglish(s.first, lang),
        ),
        const SizedBox(height: 4),
        Text(
          'Cambia nome, codice, docenti e libri dell\'insegnamento con '
          'quelli della versione scelta.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        gap,
      ],
      TextFormField(
        controller: _name,
        inputFormatters: TextLimits.max(TextLimits.courseName),
        decoration: const InputDecoration(labelText: 'Nome del corso *'),
        textCapitalization: TextCapitalization.sentences,
        validator: (v) =>
            (v == null || v.trim().isEmpty) ? 'Inserisci il nome' : null,
      ),
      gap,
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _code,
              inputFormatters: TextLimits.max(TextLimits.courseCode),
              decoration: const InputDecoration(labelText: 'Codice'),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: _teacher,
              inputFormatters: TextLimits.max(TextLimits.teacher),
              decoration: const InputDecoration(labelText: 'Docente'),
            ),
          ),
        ],
      ),
      gap,
      // università e corso di laurea: solo da leggere (si cambiano con il
      // cambio di corso di laurea, non insegnamento per insegnamento)
      _ReadOnlyField(
        key: const Key('course-university'),
        label: 'Università',
        value: _universityId == null
            ? 'Nessuna / altra'
            : (unis[_universityId]?.name ?? _universityId),
      ),
      gap,
      _ReadOnlyField(
        key: const Key('course-degree'),
        label: 'Corso di laurea',
        value: degree == null
            ? (_degreeId ?? 'Non indicato')
            : (degree.classCode == null
                  ? degree.name
                  : '${degree.name} (${degree.classCode})'),
      ),
      gap,
      Row(
        children: [
          Expanded(
            child: TextFormField(
              controller: _year,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Anno'),
              validator: (v) =>
                  _validateNumber(v, min: 1, max: 6, integer: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonFormField<String>(
              style: Theme.of(context).textTheme.bodyLarge,
              initialValue: _semester,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Semestre'),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text('—')),
                for (final e in semesters.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
                if (_semester != null && semesterValue == null)
                  DropdownMenuItem(value: _semester, child: Text(_semester!)),
              ],
              onChanged: (v) => setState(() => _semester = v),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextFormField(
              controller: _cfu,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(labelText: 'CFU'),
              validator: (v) => _validateNumber(v, max: 60),
            ),
          ),
        ],
      ),
      gap,
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Archivia'),
        subtitle: Text(
          _status == CourseStatus.archived
              ? CourseStatus.archived.description
              : 'Stato: ${_status.label} (${_status.description.toLowerCase()})',
        ),
        value: _status == CourseStatus.archived,
        onChanged: (v) => setState(
          () => _status = v ? CourseStatus.archived : CourseStatus.active,
        ),
      ),
      gap,
      Text(
        'Colore identificativo',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      const SizedBox(height: 8),
      ColorPaletteField(
        value: _color,
        defaultColor: universityColor(_universityId, unis),
        onChanged: (c) => setState(() => _color = c),
      ),
      gap,
      TextFormField(
        controller: _description,
        minLines: 3,
        maxLines: 10,
        maxLength: TextLimits.longText,
        decoration: const InputDecoration(
          labelText: 'Descrizione / argomenti',
          alignLabelWithHint: true,
        ),
      ),
      gap,
      GlassCard(
        margin: EdgeInsets.zero,
        child: ExpansionTile(
          initiallyExpanded: _c?.examMode != null || _c?.difficulty != null,
          title: const Text('Esame e carico di studio'),
          subtitle: const Text(
            'Ore di lezione, difficoltà, modalità e struttura dell\'esame',
          ),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            TextFormField(
              controller: _lectureHours,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Ore di lezione totali',
              ),
              validator: (v) => _validateNumber(v, max: 2000),
            ),
            gap,
            Row(
              children: [
                const Text('Difficoltà'),
                Expanded(
                  child: Slider(
                    value: _difficulty ?? 0,
                    min: 0,
                    max: 5,
                    divisions: 10,
                    label: _difficulty == null
                        ? 'Non indicata'
                        : formatNumber(_difficulty),
                    onChanged: (v) => setState(() => _difficulty = v),
                  ),
                ),
                Text(
                  _difficulty == null ? '—' : '${formatNumber(_difficulty)}/5',
                ),
                IconButton(
                  tooltip: 'Non indicata',
                  onPressed: _difficulty == null
                      ? null
                      : () => setState(() => _difficulty = null),
                  icon: const Icon(Icons.clear),
                ),
              ],
            ),
            gap,
            DropdownButtonFormField<String>(
              style: Theme.of(context).textTheme.bodyLarge,
              initialValue: kExamModes.containsKey(_examMode)
                  ? _examMode
                  : null,
              decoration: const InputDecoration(labelText: 'Modalità d\'esame'),
              items: [
                const DropdownMenuItem<String>(
                  value: null,
                  child: Text('Non indicata'),
                ),
                for (final e in kExamModes.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => setState(() => _examMode = v),
            ),
            gap,
            TextFormField(
              controller: _examStructure,
              minLines: 3,
              maxLines: 12,
              maxLength: TextLimits.notes,
              decoration: const InputDecoration(
                labelText: 'Struttura dell\'esame',
                alignLabelWithHint: true,
              ),
            ),
            gap,
            TextFormField(
              controller: _optionalOral,
              minLines: 2,
              maxLines: 8,
              maxLength: TextLimits.notes,
              decoration: const InputDecoration(
                labelText: 'Orale (facoltativo)',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 24),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.save),
        label: const Text('Salva'),
      ),
      const SizedBox(height: 24),
    ];
  }
}

/// Campo solo da leggere, con l'aspetto degli altri campi del modulo.
class _ReadOnlyField extends StatelessWidget {
  const _ReadOnlyField({super.key, required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        enabled: false,
        suffixIcon: const Icon(Icons.lock_outline, size: 18),
      ),
      child: Text(value, overflow: TextOverflow.ellipsis),
    );
  }
}
