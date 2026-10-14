import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/exam.dart';
import 'exam_ui.dart';

/// Scelta proposta toccando l'icona di una prova: lo stato e come si
/// presenta.
typedef StatusStep = ({ExamStatus status, String label, String hint});

/// I due passi più probabili dallo stato attuale (nei riquadri al massimo due
/// scelte): avanti lungo la vita della prova oppure un passo indietro.
/// Tutti gli stati restano raggiungibili:
/// da prenotare → prenotato → sostenuto → superato / non superato → annullato.
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
      hint: 'Fatto, in attesa dell\'esito',
    ),
  ],
  ExamStatus.booked => const [
    (
      status: ExamStatus.taken,
      label: 'Sostenuto',
      hint: 'Fatto, in attesa dell\'esito',
    ),
    (
      status: ExamStatus.planned,
      label: 'Da prenotare',
      hint: 'Annulla la prenotazione',
    ),
  ],
  ExamStatus.taken => const [
    (status: ExamStatus.passed, label: 'Superato', hint: 'Inserisci il voto'),
    (
      status: ExamStatus.failed,
      label: 'Non superato',
      hint: 'Potrai riprovarlo a un altro appello',
    ),
  ],
  ExamStatus.passed => const [
    (
      status: ExamStatus.taken,
      label: 'In attesa',
      hint: 'Togli il voto: esito non ancora definitivo',
    ),
    (status: ExamStatus.failed, label: 'Non superato', hint: 'Togli il voto'),
  ],
  ExamStatus.failed => const [
    (status: ExamStatus.passed, label: 'Superato', hint: 'Inserisci il voto'),
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
      hint: 'In attesa dell\'esito',
    ),
  ],
};

/// Cambia lo stato di una prova dall'icona laterale: due scelte, poi il voto
/// se diventa «Superato». Restituisce true se la prova è stata aggiornata.
Future<bool> changeExamStatus(BuildContext context, Exam exam) async {
  final steps = nextExamStatuses(exam.status);
  final chosen = await showModalBottomSheet<ExamStatus>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
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
  );
  if (chosen == null || !context.mounted) return false;
  var next = exam.copyWith(status: chosen, clearGrade: true, laude: false);
  if (chosen == ExamStatus.passed) {
    final midterm = exam.kind == ExamKind.midterm;
    final r = await showDialog<({int? grade, bool laude})>(
      context: context,
      builder: (_) => GradeDialog(
        midterm: midterm,
        grade: exam.grade,
        laude: exam.laude,
        // esame finale senza voto = idoneità
        allowEmpty: !midterm,
      ),
    );
    if (r == null || !context.mounted) return false;
    next = exam.copyWith(
      status: ExamStatus.passed,
      grade: r.grade,
      clearGrade: r.grade == null,
      laude: r.laude,
    );
  }
  final s = context.read<AppServices>();
  await s.exams.update(next);
  s.revision.bump();
  // voto registrato ora: traguardo, con suono e vibrazione
  chosen == ExamStatus.passed ? s.feedback.complete() : s.feedback.toggle();
  return true;
}

/// Voto dell'esame finale (18-30, lode con 30) o punteggio libero della
/// prova in itinere/esonero. Solo «Annulla» e «Salva»: scegliendo «—» (o
/// lasciando vuoto il punteggio) il voto si toglie, se [allowEmpty].
class GradeDialog extends StatefulWidget {
  const GradeDialog({
    super.key,
    required this.midterm,
    this.grade,
    this.laude = false,
    this.allowEmpty = false,
  });
  final bool midterm;
  final int? grade;
  final bool laude;

  /// «Salva» anche senza voto (togliere il voto, oppure idoneità).
  final bool allowEmpty;

  @override
  State<GradeDialog> createState() => _GradeDialogState();
}

class _GradeDialogState extends State<GradeDialog> {
  late int? _grade = widget.grade;
  late bool _laude = widget.laude;
  late final _points = TextEditingController(
    text: widget.grade?.toString() ?? '',
  );

  @override
  void dispose() {
    _points.dispose();
    super.dispose();
  }

  bool get _valid => _grade == null
      ? widget.allowEmpty
      : validateExamGrade(
              ExamStatus.passed,
              _grade,
              _laude,
              midterm: widget.midterm,
            ) ==
            null;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.midterm ? 'Punteggio' : 'Voto'),
      content: widget.midterm
          ? TextField(
              controller: _points,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Punti'),
              onChanged: (v) => setState(() => _grade = int.tryParse(v.trim())),
            )
          : Row(
              children: [
                Expanded(
                  // Pulsante senza InputDecoration: niente rientro del tema (alignedDropdown).
                  child: ButtonTheme.fromButtonThemeData(
                    data: ButtonTheme.of(context)
                        .copyWith(alignedDropdown: false),
                    child: DropdownButton<int?>(
                      key: const Key('grade-dropdown'),
                      style: Theme.of(context).textTheme.bodyLarge,
                      value: _grade != null && _grade! >= 18 && _grade! <= 30
                          ? _grade
                          : null,
                      isExpanded: true,
                      items: [
                        DropdownMenuItem<int?>(
                          value: null,
                          child: Text(
                            widget.allowEmpty && widget.grade == null
                                ? 'Senza voto (idoneità)'
                                : '—',
                          ),
                        ),
                        for (var g = 18; g <= 30; g++)
                          DropdownMenuItem<int?>(
                            value: g,
                            child: Text('$g/30'),
                          ),
                      ],
                      onChanged: (v) => setState(() {
                        _grade = v;
                        if (v != 30) _laude = false;
                      }),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                const Text('Lode'),
                Switch(
                  value: _laude,
                  onChanged: _grade == 30
                      ? (v) => setState(() => _laude = v)
                      : null,
                ),
              ],
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _valid
              ? () => Navigator.pop(context, (
                  grade: _grade,
                  laude: _grade == 30 && _laude,
                ))
              : null,
          child: const Text('Salva'),
        ),
      ],
    );
  }
}
