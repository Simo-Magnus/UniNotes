import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/electives.dart';
import '../../core/academic/plan_scope.dart';
import '../../core/constants/enums.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/services/app_services.dart';
import '../../core/reminders/system_calendar.dart';
import '../../core/services/calendar_export.dart';
import '../../models/course.dart';
import '../../models/exam.dart';
import '../../repositories/exam_repository.dart';
import '../../utils/exclusion_filter.dart';
import '../../widgets/common.dart';
import '../../widgets/reminders_prompt.dart';
import 'exam_ui.dart';
import 'study_materials_editor.dart';
import 'exam_materials.dart';
import '../../core/constants/text_limits.dart';

/// Apre il modulo di creazione/modifica di un esame o di una prova in itinere.
/// Restituisce true se è stato salvato.
Future<bool> openExamForm(
  BuildContext context, {
  Exam? exam,
  int? courseId,
  ExamKind kind = ExamKind.finalExam,
}) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => ExamFormPage(
        exam: exam,
        initialCourseId: courseId,
        initialKind: kind,
      ),
    ),
  );
  return saved ?? false;
}

/// Impostazione «Non chiedere più» della conferma di eliminazione di una
/// prova (le chiavi `dont_ask_` si ripristinano tutte da Impostazioni →
/// «Ripristina le domande»).
const String kDontAskDeleteExamKey = 'dont_ask_delete_exam';

/// Chiede conferma ed elimina l'esame: «Annulla» ed «Elimina», più la
/// casella «Non chiedere più». Con la casella spuntata le eliminazioni
/// successive non chiedono più, tranne quella dell'esame finale di un
/// insegnamento a scelta, che toglie l'insegnamento dal piano. Restituisce
/// true se eliminato.
Future<bool> deleteExamWithConfirm(BuildContext context, Exam exam) async {
  final what = exam.kind == ExamKind.midterm
      ? 'la prova in itinere o l\'esonero'
      : 'l\'esame';
  final services = context.read<AppServices>();
  final course = await services.courses.byId(exam.courseId);
  final elective =
      exam.kind == ExamKind.finalExam && course?.mandatory == false;
  var skip = false;
  if (!elective) {
    try {
      skip = await services.settings.get(kDontAskDeleteExamKey) == '1';
    } catch (_) {
      // impostazioni non leggibili: si chiede
    }
  }
  if (!context.mounted) return false;
  final ok =
      skip ||
      await _confirmDeleteExam(
        context,
        services,
        'Vuoi eliminare $what «${exam.title ?? exam.kind.label}»'
        '${course == null ? '' : ' di «${course.name}»'}? Voto, data, '
        'argomenti e materiali della prova si perdono.'
        '${elective ? '\n\n«${course!.name}» è un insegnamento a scelta: '
                  'senza esame sparisce anche da Registra, Studio, Libri '
                  'e Home (i dati restano; lo riprendi aggiungendo di nuovo '
                  'l\'esame).' : ''}',
      );
  if (!ok || !context.mounted || exam.id == null) return false;
  await services.exams.delete(exam.id!);
  final dropped = await dropElectiveWithoutExam(services, exam.courseId);
  services.revision.bump();
  if (context.mounted) {
    showSnack(
      context,
      dropped ? 'Eliminato: «${course!.name}» tolto dal piano' : 'Eliminato',
    );
  }
  return true;
}

/// Dialogo «Eliminare la prova?» con la casella «Non chiedere più».
Future<bool> _confirmDeleteExam(
  BuildContext context,
  AppServices services,
  String message,
) async {
  var dontAsk = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) {
      final scheme = Theme.of(c).colorScheme;
      return StatefulBuilder(
        builder: (c, setLocal) => AlertDialog(
          icon: Icon(Icons.delete_outline, color: scheme.error),
          title: const Text('Eliminare la prova?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 8),
              CheckboxListTile(
                key: const Key('exam-delete-dont-ask'),
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
              key: const Key('exam-delete-confirm'),
              style: FilledButton.styleFrom(
                backgroundColor: scheme.error,
                foregroundColor: scheme.onError,
              ),
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Elimina'),
            ),
          ],
        ),
      );
    },
  );
  if (ok == true && dontAsk) {
    try {
      await services.settings.set(kDontAskDeleteExamKey, '1');
    } catch (_) {}
  }
  return ok ?? false;
}

/// Insegnamenti proposti nel menù «Corso» di una prova nuova: quelli del
/// corso di laurea nell'anno che lo studente frequenta (non quelli degli anni
/// successivi), più gli arretrati degli anni passati con l'esame ancora da
/// superare: dall'anno di partenza in poi, e degli anni prima solo quelli
/// che lo studente ha segnato «Da sostenere» (non quelli «Da completare»,
/// [toComplete]); senza quelli esclusi in Impostazioni → Esclusioni (OFA,
/// inglese, facoltativi), riconosciuti dal nome ufficiale. Senza percorso
/// tutti.
bool offeredInExamForm(
  Course c, {
  required PlanScope scope,
  required ExclusionFilter exclusions,
  required bool passed,
  bool toComplete = false,
}) {
  if (!scope.inDegree(c)) return false;
  if (exclusions.isExcluded([c.officialName])) return false;
  final current = scope.profile?.currentYear;
  final y = c.year;
  if (current == null || y == null) return true;
  if (y == current) return true;
  return y < current && !passed && !toComplete;
}

/// Esame finale nuovo [typed] salvato sull'esame finale già presente
/// [existing] dello stesso insegnamento: stato, voto e lode sono quelli
/// scelti ora; gli altri campi lasciati vuoti tengono il valore di prima (id
/// del database dei corsi, argomenti, materiali…).
Exam mergeIntoExistingFinal(Exam existing, Exam typed) => Exam(
  id: existing.id,
  externalId: existing.externalId,
  courseId: existing.courseId,
  kind: ExamKind.finalExam,
  title: typed.title ?? existing.title,
  date: typed.date ?? existing.date,
  time: typed.date != null ? typed.time : existing.time,
  location: typed.location ?? existing.location,
  examType: typed.examType ?? existing.examType,
  status: typed.status,
  grade: typed.grade,
  laude: typed.laude,
  cfu: typed.cfu ?? existing.cfu,
  topics: typed.topics ?? existing.topics,
  studyMaterials: typed.studyMaterials.isEmpty
      ? existing.studyMaterials
      : typed.studyMaterials,
  notes: typed.notes ?? existing.notes,
  source: existing.source,
);

class ExamFormPage extends StatefulWidget {
  const ExamFormPage({
    super.key,
    this.exam,
    this.initialCourseId,
    this.initialKind = ExamKind.finalExam,
  });

  final Exam? exam;
  final int? initialCourseId;
  final ExamKind initialKind;

  @override
  State<ExamFormPage> createState() => _ExamFormPageState();
}

class _ExamFormPageState extends State<ExamFormPage> {
  final _formKey = GlobalKey<FormState>();

  /// Insegnamenti del menù «Corso» (vedi [offeredInExamForm]; archiviati
  /// compresi, così un insegnamento a scelta rimosso si può riprendere
  /// aggiungendo l'esame). Quello della prova e quello da cui si è aperto il
  /// modulo ci sono sempre. Insieme si legge l'esame finale di ogni
  /// insegnamento, che una prova nuova aggiorna invece di farne un doppione.
  late final Future<List<Course>> _courses = () async {
    final s = context.read<AppServices>();
    final scope = s.scope;
    final exclusions = ExclusionFilter(await s.settings.exclusionPatterns());
    final finals = <int, List<Exam>>{};
    for (final e in await s.exams.all()) {
      if (e.kind == ExamKind.finalExam) {
        finals.putIfAbsent(e.courseId, () => []).add(e);
      }
    }
    _finalByCourse = {
      for (final f in finals.entries) f.key: primaryFinal(f.value)!,
    };
    final keep = {widget.exam?.courseId, widget.initialCourseId};
    return [
      for (final c in await s.courses.all())
        if (keep.contains(c.id) ||
            offeredInExamForm(
              c,
              scope: scope,
              exclusions: exclusions,
              passed: _finalByCourse[c.id]?.status == ExamStatus.passed,
              toComplete: _finalByCourse[c.id]?.status.isToComplete ?? false,
            ))
          c,
    ];
  }();

  /// Esame finale di ogni insegnamento (id → esame).
  Map<int, Exam> _finalByCourse = const {};

  /// Esame finale già presente dell'insegnamento scelto, se si sta creando un
  /// esame finale: salvando si aggiorna quello (un esame, uno stato).
  Exam? get _existingFinal {
    final id = _courseId;
    if (!_isNew || _kind != ExamKind.finalExam || id == null) return null;
    return _finalByCourse[id];
  }

  late final _title = TextEditingController(text: widget.exam?.title);
  late final _location = TextEditingController(text: widget.exam?.location);
  late final _cfu = TextEditingController(
    text: widget.exam?.cfu == null
        ? ''
        : widget.exam!.cfu!.toString().replaceAll(RegExp(r'\.0$'), ''),
  );

  /// Esame finale senza CFU propri: si propongono quelli del corso.
  void _prefillCfu(List<Course> courses) {
    _courseList = courses;
    if (_kind != ExamKind.finalExam) return;
    // si riempie solo se vuoto o con il valore proposto prima (cambio corso)
    final now = _cfu.text.trim();
    if (now.isNotEmpty && now != _cfuPrefilled) return;
    final c = courses.where((c) => c.id == _courseId).firstOrNull;
    final v = c?.cfu == null
        ? ''
        : c!.cfu!.toString().replaceAll(RegExp(r'\.0$'), '');
    _cfu.text = v;
    _cfuPrefilled = v;
  }

  /// Valore dei CFU proposto dal corso (non scritto dallo studente).
  String? _cfuPrefilled;
  List<Course> _courseList = const [];
  double? _ownCfu() {
    final v = double.tryParse(_cfu.text.trim().replaceAll(',', '.'));
    final course = _courseList.where((c) => c.id == _courseId).firstOrNull;
    if (v != null && course?.cfu == v && widget.exam?.cfu == null) return null;
    return v;
  }

  late final _topics = TextEditingController(text: widget.exam?.topics);
  late final _notes = TextEditingController(text: widget.exam?.notes);

  late int? _courseId = widget.exam?.courseId ?? widget.initialCourseId;
  late ExamKind _kind = widget.exam?.kind ?? widget.initialKind;
  late DateTime? _date = widget.exam?.date;
  late String? _time = widget.exam?.time;
  late String? _examType = widget.exam?.examType;
  late ExamStatus _status = widget.exam?.status ?? ExamStatus.planned;
  late int? _grade =
      widget.exam?.grade ?? (widget.exam?.laude == true ? 30 : null);
  late bool _laude = widget.exam?.laude ?? false;

  /// Punteggio della prova in itinere o dell'esonero.
  late final _points = TextEditingController(
    text: _status == ExamStatus.passed ? (_grade?.toString() ?? '') : '',
  );
  late List<String> _materials = [...?widget.exam?.studyMaterials];
  bool _saving = false;

  /// «Aggiungi al calendario» con un file .ics (predefinito
  /// dall'impostazione): solo dove il calendario di sistema non si può
  /// collegare (macOS); altrove le prove vi arrivano da sole, una volta
  /// collegato (vedi [offerExamCalendar]).
  bool _calendar = false;
  late final bool _icsOnly = !context
      .read<AppServices>()
      .reminders
      .calendar
      .supported;

  /// Esame a scelta fuori piano (nome e CFU): l'insegnamento si crea al
  /// salvataggio. Nel menù del corso è la voce [_extraId].
  (String, double?)? _extra;
  static const _extraId = -1;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppServices>();
    CalendarExport(s).enabled().then((v) {
      if (mounted && v) setState(() => _calendar = true);
    });
  }

  /// Voce «Esame a scelta (fuori piano)»: nome e CFU dell'insegnamento che
  /// non è nel piano.
  Future<void> _pickExtra() async {
    final r = await showDialog<(String, double?)>(
      context: context,
      builder: (c) => const _ExtraExamDialog(),
    );
    if (!mounted) return;
    setState(() {
      if (r != null) {
        _extra = r;
        _courseId = _extraId;
        if (r.$2 != null) {
          _cfu.text = formatCfuText(r.$2);
          _cfuPrefilled = _cfu.text;
        }
      }
    });
  }

  bool get _isNew => widget.exam?.id == null;

  @override
  void dispose() {
    for (final c in [_title, _location, _cfu, _topics, _notes, _points]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final d = await showDatePicker(
      context: context,
      initialDate: _date ?? now,
      firstDate: DateTime(now.year - 10),
      lastDate: DateTime(now.year + 5),
    );
    if (d != null) setState(() => _date = d);
  }

  Future<void> _pickTime() async {
    TimeOfDay initial = const TimeOfDay(hour: 9, minute: 0);
    final parts = _time?.split(':');
    if (parts != null && parts.length >= 2) {
      initial = TimeOfDay(
        hour: int.tryParse(parts[0]) ?? 9,
        minute: int.tryParse(parts[1]) ?? 0,
      );
    }
    final t = await showTimePicker(context: context, initialTime: initial);
    if (t != null) {
      setState(
        () => _time =
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}',
      );
    }
  }

  void _setStatus(ExamStatus s) {
    setState(() {
      _status = s;
      if (s != ExamStatus.passed) {
        _grade = null;
        _laude = false;
        _points.clear();
      }
    });
  }

  String? _nullIfEmpty(String s) => s.trim().isEmpty ? null : s.trim();

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final midterm = _kind == ExamKind.midterm;
    final gradeError = validateExamGrade(
      _status,
      _grade,
      _laude,
      midterm: midterm,
    );
    if (gradeError != null) {
      showSnack(context, gradeError);
      return;
    }
    final old = widget.exam;
    // esame finale nuovo di un insegnamento che ne ha già uno: si aggiorna
    // quello, così l'esame resta uno con un solo stato
    final existing = _existingFinal;
    final services = context.read<AppServices>();
    var courseId = _courseId!;
    final extra = _extra;
    if (courseId == _extraId && extra != null) {
      // esame a scelta fuori piano: prima l'insegnamento (anno scelto,
      // percorso dello studente)
      final profile = services.profile.value;
      courseId = await services.courses.insert(
        Course(
          name: extra.$1,
          cfu: extra.$2,
          year: services.selectedYear.value,
          universityId: profile?.universityId,
          degreeId: profile?.degreeId,
          mandatory: false,
        ),
      );
      if (!mounted) return;
      _courseId = courseId;
      _extra = null;
    }
    final typed = Exam(
      id: old?.id,
      externalId: old?.externalId,
      courseId: courseId,
      kind: _kind,
      title: _nullIfEmpty(_title.text),
      date: _date,
      time: _date == null ? null : _time,
      location: _nullIfEmpty(_location.text),
      examType: _examType,
      status: _status,
      grade: _status == ExamStatus.passed ? _grade : null,
      laude: !midterm && _status == ExamStatus.passed && _grade == 30 && _laude,
      // le prove in itinere e gli esoneri non hanno CFU
      // CFU uguali a quelli del corso: non si salvano (seguono il corso)
      cfu: midterm ? null : _ownCfu(),
      topics: _nullIfEmpty(_topics.text),
      studyMaterials: _materials,
      notes: _nullIfEmpty(_notes.text),
      source: old?.source,
    );
    final exam = existing == null
        ? typed
        : mergeIntoExistingFinal(existing, typed);
    setState(() => _saving = true);
    final int id;
    try {
      id = await services.exams.save(exam);
      await restoreElective(services, exam.courseId);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showSnack(context, 'Errore nel salvataggio: $e');
      }
      return;
    }
    // L'esame è salvato: calendario e materiali non devono farlo risalvare
    // (un nuovo «Salva» creerebbe un doppione).
    try {
      if (_calendar && _icsOnly && exam.date != null) {
        final r = await CalendarExport(services).open([
          Exam.fromMap({...exam.toMap(), 'id': id}),
        ], name: exam.title ?? 'esame');
        if (mounted) showLaunchResult(context, r);
      }
      await shareExamMaterials(
        services,
        courseId: exam.courseId,
        added: [
          for (final m in _materials)
            if (looksLikePath(m) && !(old?.studyMaterials.contains(m) ?? false))
              m,
        ],
      );
    } catch (e) {
      if (mounted) showSnack(context, 'Esame salvato, ma: $e');
    }
    final before = old ?? existing;
    // esame degli anni precedenti diventato da sostenere: tornano anche le
    // sue prove in itinere
    if ((before?.status.isToComplete ?? false) &&
        exam.kind == ExamKind.finalExam &&
        exam.status.isPending) {
      try {
        await services.exams.moveMidterms(
          exam.courseId,
          ExamStatus.toComplete,
          ExamStatus.planned,
        );
      } catch (_) {}
    }
    services.revision.bump();
    // esame appena superato: il traguardo ha il suo suono; gli altri
    // salvataggi una conferma discreta
    final passedNow =
        exam.status == ExamStatus.passed && before?.status != ExamStatus.passed;
    unawaited(
      services.feedback.play(
        passedNow ? FeedbackEvent.complete : FeedbackEvent.confirm,
      ),
    );
    // prima prova con una data: si propongono gli avvisi e il calendario
    // (una volta sola ciascuno)
    if (mounted && exam.date != null && exam.status.isPending) {
      await offerExamReminders(context, services);
      if (mounted) await offerExamCalendar(context, services);
    }
    if (!mounted) return;
    if (existing != null) {
      showSnack(context, 'Aggiornato l\'esame finale già presente');
    }
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final kindLabel = _kind == ExamKind.midterm
        ? 'prova in itinere o esonero'
        : 'esame';
    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isNew
              ? (_kind == ExamKind.midterm
                    ? 'Nuova $kindLabel'
                    : 'Nuovo $kindLabel')
              : 'Modifica $kindLabel',
        ),
      ),
      body: FutureBuilder<List<Course>>(
        future: _courses,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final courses = snap.data!;
          _prefillCfu(courses);
          if (courses.isEmpty) {
            return const EmptyState(
              icon: Icons.school_outlined,
              message: 'Prima aggiungi almeno un insegnamento nella sezione Insegnamenti.',
            );
          }
          return Form(
            key: _formKey,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: _fields(courses),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _fields(List<Course> courses) {
    const gap = SizedBox(height: 16);
    final validCourse =
        courses.any((c) => c.id == _courseId) ||
            (_courseId == _extraId && _extra != null)
        ? _courseId
        : null;
    // Telefono: etichette brevi e senza icone, così stanno su una riga.
    final narrow = MediaQuery.sizeOf(context).width < kNarrowFilters;
    return [
      SegmentedButton<ExamKind>(
        showSelectedIcon: !narrow,
        segments: [
          ButtonSegment(
            value: ExamKind.finalExam,
            label: const Text('Esame finale'),
            icon: narrow ? null : const Icon(Icons.flag_outlined),
          ),
          ButtonSegment(
            value: ExamKind.midterm,
            label: Text(
              narrow ? 'Itinere o esonero' : 'Prova in itinere o Esonero',
            ),
            icon: narrow ? null : const Icon(Icons.timelapse),
          ),
        ],
        selected: {_kind},
        onSelectionChanged: (s) => setState(() => _kind = s.first),
      ),
      gap,
      DropdownButtonFormField<int>(
        key: ValueKey('course-$validCourse-${_extra?.$1}'),
        style: Theme.of(context).textTheme.bodyLarge,
        initialValue: validCourse,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Corso *'),
        items: [
          for (final c in courses)
            DropdownMenuItem(
              value: c.id,
              child: Text(c.name, overflow: TextOverflow.ellipsis),
            ),
          // un insegnamento che non è nel piano (solo esami finali nuovi)
          if (_isNew && _kind == ExamKind.finalExam)
            DropdownMenuItem(
              key: const Key('extra-exam'),
              value: _extraId,
              child: Text(
                _extra == null
                    ? 'Esame a scelta (fuori piano)…'
                    : 'Fuori piano: ${_extra!.$1}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
        onChanged: (v) {
          if (v == _extraId) {
            _pickExtra();
          } else {
            setState(() => _courseId = v);
          }
        },
        validator: (v) => v == null ? 'Scegli il corso' : null,
      ),
      if (_existingFinal case final e?)
        Padding(
          key: const Key('existing-final'),
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'L\'insegnamento ha già il suo esame finale '
                  '(«${e.status.label}»): salvando lo aggiorni, senza '
                  'crearne un altro.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      gap,
      TextFormField(
        controller: _title,
        inputFormatters: TextLimits.max(TextLimits.examTitle),
        decoration: InputDecoration(
          labelText: 'Titolo',
          hintText: _kind == ExamKind.midterm
              ? 'es. Prima prova in itinere'
              : 'es. Appello di gennaio',
        ),
      ),
      gap,
      Row(
        children: [
          Expanded(
            child: _PickerField(
              label: 'Data',
              value: _date == null ? null : formatDate(_date!),
              icon: Icons.calendar_today,
              onTap: _pickDate,
              onClear: _date == null
                  ? null
                  : () => setState(() => _date = null),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _PickerField(
              label: 'Ora',
              value: _time,
              icon: Icons.schedule,
              onTap: _pickTime,
              onClear: _time == null
                  ? null
                  : () => setState(() => _time = null),
            ),
          ),
        ],
      ),
      gap,
      TextFormField(
        controller: _location,
        inputFormatters: TextLimits.max(TextLimits.location),
        decoration: const InputDecoration(
          labelText: 'Luogo',
          hintText: 'Aula, sede…',
        ),
      ),
      gap,
      DropdownButtonFormField<String>(
        style: Theme.of(context).textTheme.bodyLarge,
        initialValue: kExamTypes.containsKey(_examType) ? _examType : null,
        decoration: const InputDecoration(labelText: 'Tipo di prova'),
        items: [
          const DropdownMenuItem<String>(
            value: null,
            child: Text('Non indicato'),
          ),
          for (final e in kExamTypes.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) => setState(() => _examType = v),
      ),
      gap,
      DropdownButtonFormField<ExamStatus>(
        // si aggiorna anche quando lo stato cambia dal voto
        key: ValueKey('exam-status-$_status'),
        style: Theme.of(context).textTheme.bodyLarge,
        initialValue: _status,
        decoration: const InputDecoration(labelText: 'Stato'),
        items: [
          // «Da completare» solo per l'esame che lo è già (anni precedenti)
          for (final s in ExamStatus.values)
            if (!s.isToComplete || widget.exam?.status == s)
              DropdownMenuItem(
                value: s,
                child: Row(
                  children: [
                    Icon(
                      examStatusIcon(s),
                      size: 18,
                      color: examStatusColor(context, s),
                    ),
                    const SizedBox(width: 8),
                    Text(s.label),
                  ],
                ),
              ),
        ],
        onChanged: (v) => _setStatus(v ?? ExamStatus.planned),
      ),
      gap,
      _gradeFields(),
      if (_kind == ExamKind.finalExam) ...[
        gap,
        TextFormField(
          controller: _cfu,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'CFU'),
          validator: (v) {
            if (v == null || v.trim().isEmpty) return null;
            final n = double.tryParse(v.trim().replaceAll(',', '.'));
            if (n == null || n < 0 || n > 60) return 'Valore CFU non valido';
            return null;
          },
        ),
      ],
      gap,
      TextFormField(
        controller: _topics,
        minLines: 2,
        maxLines: 8,
        maxLength: TextLimits.examTopics,
        decoration: const InputDecoration(
          labelText: 'Argomenti oggetto della prova',
          alignLabelWithHint: true,
        ),
      ),
      gap,
      StudyMaterialsEditor(
        items: _materials,
        onChanged: (l) => setState(() => _materials = l),
      ),
      gap,
      TextFormField(
        controller: _notes,
        minLines: 2,
        maxLines: 6,
        maxLength: TextLimits.notes,
        decoration: const InputDecoration(
          labelText: 'Note',
          alignLabelWithHint: true,
        ),
      ),
      if (_icsOnly)
        CheckboxListTile(
          key: const Key('exam-calendar'),
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _calendar,
          onChanged: (v) => setState(() => _calendar = v ?? false),
          title: const Text('Aggiungi al calendario'),
          subtitle: _date == null
              ? const Text('Serve la data della prova')
              : null,
        ),
      const SizedBox(height: 12),
      FilledButton.icon(
        onPressed: _saving ? null : _save,
        icon: const Icon(Icons.save),
        label: const Text('Salva'),
      ),
      const SizedBox(height: 24),
    ];
  }

  /// Voto o punteggio: scriverlo segna la prova come superata. Esame finale:
  /// nel menù anche «Non superato», «Idoneità (senza voto)» e nessun voto (in
  /// attesa dell'esito), che cambiano lo stato qui sopra.
  Widget _gradeFields() {
    if (_kind == ExamKind.midterm) {
      final failed = _status == ExamStatus.failed;
      return TextFormField(
        key: const Key('exam-points'),
        controller: _points,
        enabled: !failed,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(
          labelText: 'Punteggio',
          helperText: failed
              ? 'Prova non superata'
              : 'Con il punteggio la prova risulta superata',
        ),
        onChanged: (v) => setState(() {
          _grade = int.tryParse(v.trim());
          if (_grade != null) {
            _status = ExamStatus.passed;
          } else if (_status == ExamStatus.passed) {
            _status = ExamStatus.taken;
          }
        }),
        validator: (_) => _status == ExamStatus.passed
            ? validateExamGrade(_status, _grade, false, midterm: true)
            : null,
      );
    }
    final code = outcomeCode(_status, _grade, laude: _laude);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: 'Voto',
        errorText: validateExamGrade(_status, _grade, _laude),
      ),
      child: Row(
        children: [
          Expanded(
            // Pulsante senza InputDecoration: niente rientro del tema (alignedDropdown).
            child: ButtonTheme.fromButtonThemeData(
              data: ButtonTheme.of(context).copyWith(alignedDropdown: false),
              child: DropdownButton<int>(
                key: const Key('exam-grade'),
                style: Theme.of(context).textTheme.bodyLarge,
                value: code,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                items: [
                  for (final c in kOutcomeCodes)
                    DropdownMenuItem(
                      value: c,
                      child: Text(
                        outcomeLabel(c, _status),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (v) => setState(() {
                  final o = outcomeOf(
                    v ?? kOutcomeNone,
                    current: _status,
                    laude: v == 30 && _laude,
                  );
                  _status = o.status;
                  _grade = o.grade;
                  _laude = o.laude;
                }),
              ),
            ),
          ),
          const SizedBox(width: 12),
          const Text('Lode'),
          Switch(
            value: _laude,
            onChanged: code == 30 ? (v) => setState(() => _laude = v) : null,
          ),
        ],
      ),
    );
  }
}

class _PickerField extends StatelessWidget {
  const _PickerField({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.onClear,
  });

  final String label;
  final String? value;
  final IconData icon;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          prefixIcon: Icon(icon),
          suffixIcon: onClear == null
              ? null
              : IconButton(
                  tooltip: 'Rimuovi',
                  onPressed: onClear,
                  icon: const Icon(Icons.clear),
                ),
        ),
        child: Text(value ?? 'Da definire'),
      ),
    );
  }
}

/// CFU come testo del campo («6», «7.5»).
String formatCfuText(double? v) =>
    v == null ? '' : v.toString().replaceAll(RegExp(r'\.0$'), '');

/// Chiave: collegamento del calendario già proposto (una volta sola).
const kCalendarOfferedKey = 'syscal_offered';

/// Richiesta contestuale del calendario di sistema: la prima volta che si
/// salva una prova con una data, se il calendario si può collegare e non è
/// già collegato. Due scelte; poi si decide da Impostazioni.
Future<void> offerExamCalendar(BuildContext context, AppServices s) async {
  final cal = s.reminders.calendar;
  if (!cal.supported || await cal.enabled()) return;
  if (await s.settings.get(kCalendarOfferedKey) != null) return;
  if (!context.mounted) return;
  final label = cal.backend?.label ?? 'calendario';
  final yes = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Vuoi le prove nel calendario?'),
      content: Text(
        'UniNotes può scrivere esami, prove in itinere ed esoneri nel '
        '$label (calendario «$kCalendarName») e tenerli aggiornati quando '
        'cambi data o stato. Puoi cambiare idea in Impostazioni.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: const Text('Non ora'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(c, true),
          child: const Text('Collega'),
        ),
      ],
    ),
  );
  await s.settings.set(kCalendarOfferedKey, '1');
  if (yes != true) return;
  try {
    await s.reminders.enableCalendar();
    if (context.mounted) showSnack(context, 'Calendario collegato.');
  } catch (e) {
    if (context.mounted) showSnack(context, '$e');
  }
}

/// Nome e CFU di un esame a scelta che non è nel piano.
class _ExtraExamDialog extends StatefulWidget {
  const _ExtraExamDialog();

  @override
  State<_ExtraExamDialog> createState() => _ExtraExamDialogState();
}

class _ExtraExamDialogState extends State<_ExtraExamDialog> {
  final _name = TextEditingController();
  final _cfu = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _cfu.dispose();
    super.dispose();
  }

  void _ok() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (
      name,
      double.tryParse(_cfu.text.trim().replaceAll(',', '.')),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Esame a scelta'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            textCapitalization: TextCapitalization.sentences,
            inputFormatters: TextLimits.max(TextLimits.courseName),
            decoration: const InputDecoration(
              labelText: 'Insegnamento',
              helperText: 'Un insegnamento che non è nel tuo piano',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _cfu,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'CFU'),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _ok, child: const Text('Aggiungi')),
      ],
    );
  }
}
