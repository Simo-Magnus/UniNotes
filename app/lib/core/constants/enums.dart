/// Enumerazioni di dominio. Il valore `key` è quello salvato in SQLite,
/// `label` quello mostrato in UI.
library;

mixin KeyedEnum {
  String get key;
  String get label;
}

T enumFromKey<T extends KeyedEnum>(List<T> values, String? key, T fallback) {
  if (key == null) return fallback;
  for (final v in values) {
    if (v.key == key) return v;
  }
  return fallback;
}

/// Stato di un insegnamento. Tutti tranne «Archiviato» li calcola l'app
/// (core/academic/course_status_sync.dart) da anno e semestre del piano,
/// anno che frequenti e data di oggi, ed esami superati.
enum CourseStatus with KeyedEnum {
  active(
    'active',
    'In corso',
    'Lezioni in questo semestre dell\'anno che frequenti',
  ),
  toTake(
    'to_take',
    'Da sostenere',
    'Lezioni finite, esame non ancora superato',
  ),
  toComplete(
    'to_complete',
    'Da completare',
    'Anno prima che usassi l\'app: indica in Esami → Anni precedenti se '
        'l\'hai già sostenuto',
  ),
  upcoming(
    'upcoming',
    'Non ancora iniziato',
    'Lezioni in un semestre o anno successivo',
  ),
  completed('completed', 'Superato', 'Esame finale superato'),
  archived(
    'archived',
    'Archiviato',
    'Nascosto da elenchi e medie (scelto da te)',
  );

  const CourseStatus(this.key, this.label, this.description);
  @override
  final String key;
  @override
  final String label;

  /// Perché l'insegnamento ha questo stato.
  final String description;

  static CourseStatus fromKey(String? k) =>
      enumFromKey(values, k, CourseStatus.active);
}

enum EventType with KeyedEnum {
  lecture('lecture', 'Lezione'),
  examWindow('exam_window', 'Esame disponibile'),
  event('event', 'Evento universitario'),
  studyPlan('study_plan', 'Studio pianificato'),
  deadline('deadline', 'Scadenza');

  const EventType(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static EventType fromKey(String? k) =>
      enumFromKey(values, k, EventType.event);
}

enum ExamKind with KeyedEnum {
  finalExam('final', 'Esame finale'),
  midterm('midterm', 'Prova in itinere o esonero');

  const ExamKind(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static ExamKind fromKey(String? k) =>
      enumFromKey(values, k, ExamKind.finalExam);
}

enum ExamStatus with KeyedEnum {
  /// Segnata nell'app ma non ancora prenotata. Lo stato «Pianificato» non
  /// esiste più (un esame segnato è già pianificato): la chiave storica
  /// 'planned' resta nel database, l'etichetta è «Da prenotare».
  planned('planned', 'Da prenotare'),
  booked('booked', 'Prenotato'),
  taken('taken', 'Sostenuto'),
  passed('passed', 'Superato'),
  failed('failed', 'Non superato'),
  cancelled('cancelled', 'Annullato'),

  /// Esame di un anno prima dell'anno di partenza (l'anno di corso indicato
  /// quando lo studente ha iniziato a usare l'app) mai compilato: non è un
  /// arretrato, non è tra le prove da sostenere, non conta in medie, CFU e
  /// statistiche finché lo studente non dice se l'ha sostenuto (Esami →
  /// Anni precedenti).
  toComplete('to_complete', 'Da completare');

  const ExamStatus(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static ExamStatus fromKey(String? k) =>
      enumFromKey(values, k, ExamStatus.planned);

  bool get isPending => this == planned || this == booked;

  /// Esame degli anni precedenti ancora da compilare (vedi [toComplete]).
  bool get isToComplete => this == toComplete;
}

enum TopicStatus with KeyedEnum {
  notStarted('not_started', 'Non iniziato', 0),
  inProgress('in_progress', 'In corso', 0.4),
  partial('partial', 'Parzialmente completato', 0.7),
  completed('completed', 'Completato', 1),
  toReview('to_review', 'Da ripassare', 0.85);

  const TopicStatus(this.key, this.label, this.progressWeight);
  @override
  final String key;
  @override
  final String label;

  /// Contributo dell'argomento al progresso percentuale del corso.
  final double progressWeight;

  static TopicStatus fromKey(String? k) =>
      enumFromKey(values, k, TopicStatus.notStarted);
}

enum ActivityType with KeyedEnum {
  theory('theory', 'Teoria'),
  exercises('exercises', 'Esercizi'),
  review('review', 'Ripasso'),
  reading('reading', 'Lettura'),
  simulation('simulation', 'Simulazione'),
  other('other', 'Altro');

  const ActivityType(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static ActivityType fromKey(String? k) =>
      enumFromKey(values, k, ActivityType.other);
}

enum BookFormat with KeyedEnum {
  paper('paper', 'Cartaceo'),
  ebook('ebook', 'Ebook'),
  pdf('pdf', 'PDF'),
  other('other', 'Altro');

  const BookFormat(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static BookFormat fromKey(String? k) {
    switch (k) {
      case 'cartaceo':
        return paper;
    }
    return enumFromKey(values, k, BookFormat.other);
  }
}

enum BookOwnership with KeyedEnum {
  owned('owned', 'Posseduto'),
  borrowed('borrowed', 'Preso in prestito'),
  wanted('wanted', 'Da procurare'),
  sold('sold', 'Venduto'),
  unavailable('unavailable', 'Non disponibile');

  const BookOwnership(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static BookOwnership fromKey(String? k) =>
      enumFromKey(values, k, BookOwnership.wanted);
}

enum MaterialKind with KeyedEnum {
  lecture('lecture', 'Lezioni'),
  examText('exam_text', 'Testi d\'esame'),
  exercise('exercise', 'Esercitazioni'),
  notice('notice', 'Avvisi'),
  other('other', 'Altro');

  const MaterialKind(this.key, this.label);
  @override
  final String key;
  @override
  final String label;

  static MaterialKind fromKey(String? k) =>
      enumFromKey(values, k, MaterialKind.other);
}
