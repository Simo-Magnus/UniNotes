import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/exam.dart';
import '../../widgets/common.dart' show confirmDialog;
import 'exam_ui.dart';

/// Scelta proposta toccando l'icona di una prova: lo stato e come si
/// presenta.
typedef StatusStep = ({ExamStatus status, String label, String hint});

/// I due passi più probabili dallo stato attuale (nei riquadri al massimo due
/// scelte): avanti lungo la vita della prova oppure un passo indietro.
/// «Sostenuto» chiede subito l'esito (voto, «Non superato» o in attesa), così
/// «Non superato» si raggiunge da «Da prenotare» e da «Prenotato»; una prova
/// non superata si riprenota. Anche dopo l'esito (in attesa o con il voto) si
/// può tornare a «Prenotato» (e da lì a «Da prenotare»): il voto si toglie,
/// con conferma. Tutti gli stati restano raggiungibili in entrambe le
/// direzioni: da prenotare ⇄ prenotato ⇄ sostenuto ⇄ superato / non
/// superato → riprenotato o annullato.
List<StatusStep> nextExamStatuses(ExamStatus s) => switch (s) {
  ExamStatus.planned => const [
    (
      status: ExamStatus.booked,
      label: 'Prenotato',
      hint: 'Ti sei iscritto all\'appello',
    ),
    (
      status: ExamStatus.taken,
      label: 'Sostenuto',
      hint: 'Poi l\'esito: voto, non superato o in attesa',
    ),
  ],
  ExamStatus.booked => const [
    (
      status: ExamStatus.taken,
      label: 'Sostenuto',
      hint: 'Poi l\'esito: voto, non superato o in attesa',
    ),
    (
      status: ExamStatus.planned,
      label: 'Da prenotare',
      hint: 'Annulla la prenotazione',
    ),
  ],
  // «Esito» apre il menù del voto, dove c'è anche «Non superato»
  ExamStatus.taken => const [
    (
      status: ExamStatus.passed,
      label: 'Esito',
      hint: 'Voto, idoneità o non superato',
    ),
    (
      status: ExamStatus.booked,
      label: 'Prenotato',
      hint: 'Torna alla prenotazione',
    ),
  ],
  // «Cambia esito» riapre il menù del voto (voto diverso, in attesa o non
  // superato); «Prenotato» toglie il voto, dopo conferma
  ExamStatus.passed => const [
    (
      status: ExamStatus.taken,
      label: 'Cambia esito',
      hint: 'Voto diverso, in attesa o non superato',
    ),
    (
      status: ExamStatus.booked,
      label: 'Prenotato',
      hint: 'Togli il voto e torna alla prenotazione',
    ),
  ],
  ExamStatus.failed => const [
    (
      status: ExamStatus.booked,
      label: 'Riprenota',
      hint: 'Ti sei iscritto a un nuovo appello',
    ),
    (
      status: ExamStatus.cancelled,
      label: 'Annullato',
      hint: 'Ritirato o prova annullata',
    ),
  ],
  ExamStatus.cancelled => const [
    (
      status: ExamStatus.planned,
      label: 'Da prenotare',
      hint: 'Torna tra le prove da sostenere',
    ),
    (
      status: ExamStatus.taken,
      label: 'Sostenuto',
      hint: 'Poi l\'esito: voto, non superato o in attesa',
    ),
  ],
  // esame di un anno prima dell'anno di partenza, mai compilato
  ExamStatus.toComplete => const [
    (
      status: ExamStatus.passed,
      label: 'Sostenuto',
      hint: 'Poi il voto, facoltativo',
    ),
    (
      status: ExamStatus.planned,
      label: 'Da sostenere',
      hint: 'Diventa un esame arretrato da sostenere',
    ),
  ],
};

/// Prova con lo stato [to] scelto dall'icona: senza voto; una prova non
/// superata che si riprenota perde la data dell'appello già passato.
Exam withStatus(Exam exam, ExamStatus to, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final oldDate = exam.date;
  final retake =
      exam.status == ExamStatus.failed &&
      to.isPending &&
      oldDate != null &&
      oldDate.isBefore(today);
  return exam.copyWith(
    status: to,
    clearGrade: true,
    laude: false,
    clearDate: retake,
  );
}

/// Prova con l'esito [o] (stato, voto e lode).
Exam withOutcome(Exam exam, ExamOutcome o) => exam.copyWith(
  status: o.status,
  grade: o.grade,
  clearGrade: o.grade == null,
  laude: o.laude,
);

/// «Il voto 28/30», «Il punteggio 5», «L'idoneità» di una prova superata.
String _resultText(Exam e) {
  if (e.kind == ExamKind.midterm) {
    return e.grade == null ? 'L\'esito' : 'Il punteggio ${e.grade}';
  }
  if (e.laude) return 'Il voto 30 e lode';
  if (e.grade == null) return 'L\'idoneità';
  return 'Il voto ${e.grade}/30';
}

/// Cambia lo stato di una prova dall'icona laterale: due scelte; con
/// «Sostenuto» o «Superato» si sceglie poi l'esito nel menù del voto.
/// Restituisce true se la prova è stata aggiornata. Lo stato è uno solo,
/// salvato sulla prova: «Da sostenere», «Sostenuti», dettaglio e Home lo
/// rileggono dal database.
Future<bool> changeExamStatus(BuildContext context, Exam exam) async {
  final steps = nextExamStatuses(exam.status);
  final chosen = await showModalBottomSheet<ExamStatus>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      // scorre: con caratteri grandi il foglio non ha altezza per tutte le
      // voci
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Stato: ${exam.status.label}',
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            for (final s in steps)
              ListTile(
                key: ValueKey('status-${s.status.key}'),
                leading: Icon(
                  examStatusIcon(s.status),
                  color: readableOn(
                    examStatusColor(c, s.status),
                    Theme.of(c).brightness,
                  ),
                ),
                title: Text(s.label),
                subtitle: Text(s.hint),
                onTap: () => Navigator.pop(c, s.status),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
  );
  if (chosen == null || !context.mounted) return false;
  var next = withStatus(exam, chosen);
  // dallo stato superato a una prova da sostenere: il voto si toglie, e prima
  // si chiede conferma
  if (exam.status == ExamStatus.passed && chosen.isPending) {
    final ok = await confirmDialog(
      context,
      exam.kind == ExamKind.midterm
          ? 'Togliere il punteggio?'
          : 'Togliere il voto?',
      '${_resultText(exam)} verrà tolto e la prova tornerà «${chosen.label}».',
    );
    if (!ok || !context.mounted) return false;
  }
  if (chosen == ExamStatus.passed || chosen == ExamStatus.taken) {
    // l'esito: voto, idoneità, «Non superato» o in attesa
    // un esame degli anni precedenti segnato «Sostenuto» è già superato:
    // il menù parte da «Idoneità (senza voto)» e il voto è facoltativo
    final previous = exam.status.isToComplete;
    // «Cambia esito» di una prova superata: il menù parte dal voto attuale
    final change = exam.status == ExamStatus.passed;
    final r = await showDialog<ExamOutcome>(
      context: context,
      builder: (_) => GradeDialog(
        midterm: exam.kind == ExamKind.midterm,
        status: change || previous ? ExamStatus.passed : ExamStatus.taken,
        grade: change || chosen == ExamStatus.passed ? exam.grade : null,
        laude: (change || chosen == ExamStatus.passed) && exam.laude,
        title: chosen == ExamStatus.taken || exam.status == ExamStatus.taken
            ? 'Esito'
            : null,
      ),
    );
    if (r == null || !context.mounted) return false;
    next = withOutcome(next, r);
  }
  final s = context.read<AppServices>();
  await s.exams.update(next);
  if (exam.status.isToComplete &&
      next.kind == ExamKind.finalExam &&
      next.status.isPending) {
    // arretrato da sostenere: tornano anche le sue prove in itinere
    await s.exams.moveMidterms(
      next.courseId,
      ExamStatus.toComplete,
      ExamStatus.planned,
    );
  }
  s.revision.bump();
  // voto registrato ora: traguardo, con suono e vibrazione
  next.status == ExamStatus.passed
      ? s.feedback.complete()
      : s.feedback.toggle();
  return true;
}

/// Esito e voto. Esame finale: un menù con «In attesa dell'esito» (o
/// «Nessun voto» per una prova ancora da sostenere), «Non superato»,
/// «Idoneità (senza voto)» e i voti 18-30 (lode con 30). Prova in itinere o
/// esonero: punteggio libero e la casella «Non superata». Solo «Annulla» e
/// «Salva»; restituisce l'esito scelto.
class GradeDialog extends StatefulWidget {
  const GradeDialog({
    super.key,
    required this.midterm,
    required this.status,
    this.grade,
    this.laude = false,
    this.title,
  });
  final bool midterm;

  /// Stato attuale della prova (decide che cosa vuol dire «nessun voto»).
  final ExamStatus status;
  final int? grade;
  final bool laude;

  /// Titolo del dialogo (predefinito «Voto» o «Punteggio»).
  final String? title;

  @override
  State<GradeDialog> createState() => _GradeDialogState();
}

class _GradeDialogState extends State<GradeDialog> {
  late int _code = outcomeCode(
    widget.status,
    widget.grade,
    laude: widget.laude,
  );
  late bool _laude = widget.laude;
  late bool _failed = widget.status == ExamStatus.failed;
  late final _points = TextEditingController(
    text: widget.status == ExamStatus.passed
        ? (widget.grade?.toString() ?? '')
        : '',
  );

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  int? get _pointsValue => int.tryParse(_points.text.trim());

  bool get _valid {
    if (!widget.midterm || _failed) return true;
    final t = _points.text.trim();
    if (t.isEmpty) return true;
    final v = _pointsValue;
    return v != null &&
        validateExamGrade(ExamStatus.passed, v, false, midterm: true) == null;
  }

  ExamOutcome _result() {
    if (!widget.midterm) {
      return outcomeOf(_code, current: widget.status, laude: _laude);
    }
    if (_failed) return outcomeOf(kOutcomeFailed, current: widget.status);
    final v = _pointsValue;
    if (v == null) return outcomeOf(kOutcomeNone, current: widget.status);
    return (status: ExamStatus.passed, grade: v, laude: false);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title ?? (widget.midterm ? 'Punteggio' : 'Voto')),
      content: widget.midterm ? _midtermFields() : _finalFields(),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('grade-save'),
          onPressed: _valid ? () => Navigator.pop(context, _result()) : null,
          child: const Text('Salva'),
        ),
      ],
    );
  }

  Widget _midtermFields() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        key: const Key('grade-points'),
        controller: _points,
        autofocus: !_failed,
        enabled: !_failed,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(
          labelText: 'Punti',
          helperText: 'Vuoto = nessun punteggio',
        ),
        onChanged: (_) => setState(() {}),
      ),
      CheckboxListTile(
        key: const Key('grade-failed'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: _failed,
        onChanged: (v) => setState(() => _failed = v ?? false),
        title: const Text('Non superata'),
      ),
    ],
  );

  Widget _finalFields() => Row(
    children: [
      Expanded(
        // Pulsante senza InputDecoration: niente rientro del tema (alignedDropdown).
        child: ButtonTheme.fromButtonThemeData(
          data: ButtonTheme.of(context).copyWith(alignedDropdown: false),
          child: DropdownButton<int>(
            key: const Key('grade-dropdown'),
            style: Theme.of(context).textTheme.bodyLarge,
            value: _code,
            isExpanded: true,
            items: [
              for (final code in kOutcomeCodes)
                DropdownMenuItem<int>(
                  key: ValueKey('grade-$code'),
                  value: code,
                  child: Text(
                    outcomeLabel(code, widget.status),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() {
              _code = v ?? kOutcomeNone;
              if (_code != 30) _laude = false;
            }),
          ),
        ),
      ),
      const SizedBox(width: 12),
      const Text('Lode'),
      Switch(
        value: _laude,
        onChanged: _code == 30 ? (v) => setState(() => _laude = v) : null,
      ),
    ],
  );
}
