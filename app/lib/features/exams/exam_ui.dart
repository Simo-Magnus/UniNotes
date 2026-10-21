import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/exam.dart';
import '../../utils/dates.dart';
import '../courses/course_ui.dart';

/// Tipi di prova ammessi dal data pack → etichetta.
const Map<String, String> kExamTypes = {
  'scritto': 'Scritto',
  'orale': 'Orale',
  'scritto+orale': 'Scritto e orale',
  'quiz': 'Quiz',
  'progetto': 'Progetto',
  'altro': 'Altro',
};

String examTypeLabel(String? t) =>
    t == null ? 'Tipo non indicato' : (kExamTypes[t] ?? t);

/// "lun 12/11/2026" (formattazione manuale: non dipende dai dati di locale).
String formatDate(DateTime d, {bool weekday = true}) =>
    weekday ? formatShortWeekdayDmy(d) : formatDmy(d);

/// "26/12/2026" da una stringa ISO; restituisce la stringa originale se non è una data.
String formatIsoDate(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso);
  return d == null ? iso : formatDate(d, weekday: false);
}

String examDateLabel(Exam e) {
  if (e.date == null) return 'Data da aggiungere';
  final t = e.time == null ? '' : ' · ore ${e.time}';
  return '${formatDate(e.date!)}$t';
}

/// Voto mostrato: "30 e lode", "28", oppure null.
String? gradeLabel(Exam e) {
  if (e.laude) return '30 e lode';
  if (e.grade == null) return null;
  return '${e.grade}';
}

String? shortGradeLabel(Exam e) {
  if (e.laude) return '30L';
  return e.grade?.toString();
}

/// Giorni mancanti alla data dell'esame (negativo se passata).
int? daysUntil(Exam e, {DateTime? now}) {
  if (e.date == null) return null;
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final d = DateTime(e.date!.year, e.date!.month, e.date!.day);
  return d.difference(today).inDays;
}

/// Regole di validazione del voto:
/// - il voto (18–30) si inserisce solo se lo stato è "Superato", ed è obbligatorio;
/// - la lode è ammessa solo con 30.
/// Restituisce il messaggio d'errore oppure null se valido.
/// Voto valido per lo stato. Le prove in itinere e gli esoneri danno spesso
/// punteggi bassi (3-6 punti) che si sommano all'esame: per loro nessun
/// vincolo 18-30 e niente lode ([midterm]).
String? validateExamGrade(
  ExamStatus status,
  int? grade,
  bool laude, {
  bool midterm = false,
}) {
  if (status != ExamStatus.passed) {
    if (grade != null || laude) {
      return 'Il voto si inserisce solo per le prove superate.';
    }
    return null;
  }
  if (midterm) {
    if (grade == null) return 'Inserisci il punteggio.';
    if (grade < 0 || grade > 100) return 'Punteggio non valido.';
    return null;
  }
  // superato senza voto = idoneità (non entra nella media)
  if (grade == null) return null;
  if (grade < 18 || grade > 30) {
    return 'Il voto deve essere compreso tra 18 e 30.';
  }
  if (laude && grade != 30) return 'La lode è ammessa solo con 30.';
  return null;
}

/// Esito di una prova: stato, voto e lode insieme (menù «Voto»).
typedef ExamOutcome = ({ExamStatus status, int? grade, bool laude});

/// Voci del menù «Voto» dell'esame finale oltre ai voti 18-30: nessun voto
/// (in attesa dell'esito, o ancora da sostenere), «Non superato» e
/// «Idoneità (senza voto)».
const int kOutcomeNone = -1;
const int kOutcomeFailed = -2;
const int kOutcomePass = 0;

/// Voce del menù «Voto» per stato e voto attuali.
int outcomeCode(ExamStatus status, int? grade, {bool laude = false}) {
  if (status == ExamStatus.failed) return kOutcomeFailed;
  if (status != ExamStatus.passed) return kOutcomeNone;
  if (laude) return 30;
  if (grade == null) return kOutcomePass;
  return (grade >= 18 && grade <= 30) ? grade : kOutcomePass;
}

/// Esito della voce [code] del menù «Voto». «Nessun voto» lascia una prova
/// ancora da sostenere com'è e mette le altre in attesa dell'esito.
ExamOutcome outcomeOf(
  int code, {
  required ExamStatus current,
  bool laude = false,
}) => switch (code) {
  kOutcomeFailed => (status: ExamStatus.failed, grade: null, laude: false),
  kOutcomePass => (status: ExamStatus.passed, grade: null, laude: false),
  kOutcomeNone => (
    status: current.isPending ? current : ExamStatus.taken,
    grade: null,
    laude: false,
  ),
  _ => (status: ExamStatus.passed, grade: code, laude: code == 30 && laude),
};

/// Etichetta della voce [code] del menù «Voto» ([current] = stato attuale).
String outcomeLabel(int code, ExamStatus current) => switch (code) {
  kOutcomeFailed => 'Non superato',
  kOutcomePass => 'Idoneità (senza voto)',
  kOutcomeNone =>
    current.isPending ? 'Nessun voto' : 'In attesa dell\'esito',
  _ => '$code/30',
};

/// Voci del menù «Voto» dell'esame finale, nell'ordine.
final List<int> kOutcomeCodes = [
  kOutcomeNone,
  kOutcomeFailed,
  kOutcomePass,
  for (var g = 18; g <= 30; g++) g,
];

Color examStatusColor(BuildContext context, ExamStatus s) {
  final scheme = Theme.of(context).colorScheme;
  return switch (s) {
    ExamStatus.planned => const Color(0xFF78909C),
    ExamStatus.booked => const Color(0xFF1E88E5),
    ExamStatus.taken => const Color(0xFF7E57C2),
    ExamStatus.passed => const Color(0xFF2E7D32),
    ExamStatus.failed => const Color(0xFFC62828),
    ExamStatus.cancelled => scheme.outline,
  };
}

/// Larghezza sotto la quale filtri e scelte a segmenti usano etichette brevi
/// (telefono).
const double kNarrowFilters = 520;

IconData examStatusIcon(ExamStatus s) => switch (s) {
  ExamStatus.planned => Icons.event_note_outlined,
  ExamStatus.booked => Icons.how_to_reg_outlined,
  ExamStatus.taken => Icons.hourglass_bottom,
  ExamStatus.passed => Icons.check_circle,
  ExamStatus.failed => Icons.cancel,
  ExamStatus.cancelled => Icons.block,
};

class ExamStatusChip extends StatelessWidget {
  const ExamStatusChip(this.status, {super.key});
  final ExamStatus status;

  @override
  Widget build(BuildContext context) => SmallBadge(
    label: status.label,
    color: examStatusColor(context, status),
    icon: examStatusIcon(status),
  );
}

class ExamKindChip extends StatelessWidget {
  const ExamKindChip(this.kind, {super.key});
  final ExamKind kind;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SmallBadge(
      label: kind.label,
      color: kind == ExamKind.midterm ? scheme.tertiary : scheme.secondary,
      icon: kind == ExamKind.midterm ? Icons.timelapse : Icons.flag_outlined,
    );
  }
}

/// Cerchio con il voto (verde se superato, rosso se non superato).
class GradeBadge extends StatelessWidget {
  const GradeBadge(this.exam, {super.key, this.size = 44, this.accent});

  /// Colore di risalto (università e tipo) per le verifiche ancora da fare.
  final Color? accent;
  final Exam exam;
  final double size;

  @override
  Widget build(BuildContext context) {
    final label = shortGradeLabel(exam);
    final color = (exam.status.isPending && accent != null)
        ? accent!
        : examStatusColor(context, exam.status);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withValues(alpha: 0.12),
        border: Border.all(color: color, width: 2),
      ),
      child: label != null
          ? Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: readableOn(color, Theme.of(context).brightness),
                fontSize: size * 0.32,
              ),
            )
          : Icon(
              examStatusIcon(exam.status),
              color: readableOn(color, Theme.of(context).brightness),
              size: size * 0.5,
            ),
    );
  }
}

/// Vero se la stringa sembra un percorso locale (Windows o Unix) anziché un titolo.
bool looksLikePath(String s) {
  final t = s.trim();
  return RegExp(r'^[A-Za-z]:[\\/]').hasMatch(t) ||
      t.startsWith(r'\\') ||
      t.startsWith('/') ||
      t.startsWith('file://');
}

/// Nome file finale di un percorso, per la visualizzazione.
String pathBaseName(String path) {
  final parts = path
      .split(RegExp(r'[\\/]'))
      .where((p) => p.isNotEmpty)
      .toList();
  return parts.isEmpty ? path : parts.last;
}
