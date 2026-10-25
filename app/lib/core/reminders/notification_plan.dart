import '../academic/student_profile.dart' show previousYearsLabel;
import '../constants/build_flags.dart';
import 'agenda.dart';
import 'notification_prefs.dart';

/// Tipi di notifica: ognuno ha il suo canale Android (nome in italiano,
/// visibile nelle impostazioni di sistema) e un interruttore nell'app.
enum NotificationType {
  exam('prove', 'Prove in arrivo', 'Esami, prove in itinere ed esoneri'),
  session(
    'sessioni',
    'Inizio sessione d\'esame',
    'Il giorno prima dell\'inizio di ogni sessione',
  ),
  outcome(
    'esiti',
    'Esito delle prove',
    'Il giorno dopo una prova, per registrare voto o esito',
  ),
  link(
    'collegamenti',
    'Collegamenti interrotti',
    'OneDrive, Google Drive o calendario da ricollegare',
  ),
  recording(
    'registratore',
    'Registratore delle lezioni',
    'Avvisi sulla registrazione in corso (es. app ridotta nell\'area di '
        'notifica)',
  ),
  focus(
    'focus',
    'Sessione Focus in corso',
    'Tempo restante della sessione di concentrazione',
  ),
  focusAlert(
    'focus_avvisi',
    'Pause e fine della sessione Focus',
    'Avviso con suono quando inizia o finisce una pausa e a fine sessione',
  ),
  review(
    'recensione',
    'Richiesta di recensione',
    'Al massimo una richiesta, solo se l\'app ti è utile',
  ),
  donation(
    'sostegno',
    'Sostieni il progetto',
    'Invito facoltativo a sostenere UniNotes',
  ),
  previousYears(
    'anni_precedenti',
    'Esami degli anni precedenti',
    'Promemoria per indicare gli esami sostenuti prima di usare l\'app (al '
        'massimo due)',
  );

  const NotificationType(this.channelId, this.channelName, this.description);
  final String channelId;
  final String channelName;
  final String description;

  /// Recensione e sostegno: notifiche promozionali (consenso, disattivabili).
  bool get promotional => this == review || this == donation;

  /// Tipi che esistono in questa build: il sostegno (canale, pulsante
  /// «Dona», grafiche) solo dove le donazioni sono consentite
  /// (`--dart-define=DONATIONS=link`, vedi build_flags.dart).
  static List<NotificationType> available({
    bool donationsAllowed = kShowDonationLink,
  }) => [
    for (final t in values)
      if (t != donation || donationsAllowed) t,
  ];

  /// Sezione dell'app a cui appartiene la notifica: raggruppa le notifiche
  /// (gruppi di canali su Android, pile su iOS e macOS, intestazione nel
  /// Centro notifiche di Windows) e compare accanto al nome dell'app
  /// (Android) o come sottotitolo (iOS, macOS). Null per le promozionali.
  String? get section => switch (this) {
    exam || session || outcome || previousYears => 'Esami',
    focus || focusAlert => 'Studio',
    recording => 'Registra',
    link => 'Collegamenti',
    review || donation => null,
  };

  /// Gruppo dei canali Android (Impostazioni del sistema → Notifiche).
  String get groupId => section?.toLowerCase() ?? 'uninotes';

  /// Grafica del tipo (quadrato blu con il simbolo: logo dei toast di
  /// Windows, `assets/notifiche/<canale>.png`; per recensione e sostegno
  /// anche icona grande di Android, `res/drawable-nodpi/ic_notif_<canale>.png`,
  /// e miniatura allegata su iOS e macOS; vedi
  /// tool/genera_grafiche_notifiche.py).
  String get artwork => channelId;

  /// Icona grande a destra su Android (risorsa in `res/drawable-nodpi`):
  /// il logo dell'app (`ic_notif_uninotes`, come su iPhone e iPad) per tutti
  /// i tipi, tranne recensione e sostegno, che hanno la propria (stella e
  /// cuore). La registrazione in corso ha un layout proprio
  /// (RecordingNotification.kt).
  String get androidLargeIcon =>
      promotional ? 'ic_notif_$artwork' : 'ic_notif_uninotes';

  /// Immagine larga (`assets/notifiche/hero_<canale>.png`) per le notifiche
  /// rare: inizio della sessione d'esame, recensione, sostegno (in cima al
  /// toast di Windows).
  bool get hasHero => this == session || this == review || this == donation;

  /// File in `assets/notifiche` allegato alle notifiche di iOS e macOS
  /// (miniatura a destra): per l'inizio sessione l'immagine larga; per
  /// recensione e sostegno la sola stella o il solo cuore, quadrati, senza
  /// il logo dell'app (già a sinistra). Null per gli altri tipi.
  String? get darwinAttachment => switch (this) {
    session => 'hero_$artwork.png',
    review || donation => '$artwork.png',
    _ => null,
  };

  /// Avvisi che arrivano anche durante una sessione Focus: prove, sessioni
  /// d'esame, registratore e la sessione stessa. Gli altri («Com'è
  /// andata?», collegamenti, recensione, sostegno) aspettano la fine.
  bool get urgent =>
      this == exam ||
      this == session ||
      this == recording ||
      this == focus ||
      this == focusAlert;
}

/// Azioni delle notifiche (pulsanti).
class NotificationActions {
  static const review = 'recensisci';
  static const donate = 'dona';
  static const later = 'piu_tardi';
  static const never = 'mai_piu';
  static const recordOutcome = 'registra_esito';
  static const skipExam = 'non_per_questa_prova';
}

/// Gruppi dei canali Android (Impostazioni del sistema → Notifiche →
/// UniNotes): id ([NotificationType.groupId]) → (nome, descrizione).
const Map<String, (String, String)> kNotificationGroups = {
  'esami': (
    'Esami',
    'Prove in arrivo, sessioni d\'esame, esiti e anni precedenti',
  ),
  'studio': ('Studio', 'Sessione Focus e pause'),
  'registra': ('Registra', 'Registrazione delle lezioni'),
  'collegamenti': ('Collegamenti', 'OneDrive, Google Drive e calendario'),
  'uninotes': ('UniNotes', 'Recensione e sostegno al progetto, facoltativi'),
};

/// Una notifica da pianificare.
class PlannedNotification {
  const PlannedNotification({
    required this.id,
    required this.type,
    required this.at,
    required this.title,
    required this.body,
    required this.payload,
    this.actions = const [],
    this.ongoing = false,
    this.countdownTo,
    this.silent = false,
  });

  /// Notifica fissa (non si toglie con uno scorrimento): la sessione Focus
  /// in corso.
  final bool ongoing;

  /// Conto alla rovescia del sistema fino a questo istante (Android: il
  /// tempo restante si aggiorna da solo, anche ad app chiusa).
  final DateTime? countdownTo;

  /// Senza suono né vibrazione (aggiornamenti dello stato).
  final bool silent;

  /// Stessa notifica spostata a [when].
  PlannedNotification movedTo(DateTime when) => PlannedNotification(
    id: id,
    type: type,
    at: when,
    title: title,
    body: body,
    payload: payload,
    actions: actions,
    ongoing: ongoing,
    countdownTo: countdownTo,
    silent: silent,
  );

  /// ID numerico stabile (vedi [notificationId]).
  final int id;
  final NotificationType type;

  /// Istante locale.
  final DateTime at;
  final String title;
  final String body;

  /// Dove porta il tocco (vedi AppRoutes).
  final String payload;

  /// (id azione, testo del pulsante).
  final List<(String, String)> actions;

  @override
  String toString() => 'Notifica($id ${type.name} $at «$title»)';
}

/// ID stabile a 31 bit da tipo e chiave (FNV-1a): la stessa prova con lo
/// stesso anticipo ha sempre lo stesso numero, così ripianificando si
/// sostituisce invece di duplicare. Lontano dagli ID piccoli usati da altri
/// componenti (es. la notifica della registrazione in corso).
int notificationId(NotificationType type, String key) {
  var h = 0x811c9dc5;
  for (final c in '${type.name}:$key'.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  final id = h & 0x7FFFFFFF;
  return id < 100000 ? id + 100000 : id;
}

/// Prova ancora senza esito (stato «pianificato» o «prenotato») con una
/// data: il giorno dopo si chiede com'è andata. La notifica si pianifica in
/// anticipo; registrando l'esito prima, la ripianificazione la toglie.
class OutcomeCandidate {
  const OutcomeCandidate({
    required this.examId,
    required this.subject,
    required this.midterm,
    required this.date,
  });
  final int examId;
  final String subject;
  final bool midterm;
  final DateTime date;
}

/// Quando chiedere «Com'è andata?»: il giorno dopo la prova alle 18:00.
DateTime outcomeTime(DateTime examDate) =>
    DateTime(examDate.year, examDate.month, examDate.day + 1, 18);

/// iOS tiene al massimo 64 notifiche in attesa per app: si pianificano le
/// più vicine.
const int kMaxScheduled = 60;

/// Calcola le notifiche da pianificare. Funzione pura (test in
/// test/reminders_test.dart).
///
/// Regola calendario ↔ notifiche: se il collegamento al calendario di
/// sistema funziona ([calendarWorking]) e una prova o una sessione è stata
/// scritta nel calendario ([calendarWritten]), gli avvisi arrivano dal
/// calendario e l'app non pianifica i suoi; altrimenti li pianifica lei.
List<PlannedNotification> planNotifications({
  required DateTime now,
  required NotificationPrefs prefs,
  required List<AgendaItem> agenda,
  bool calendarWorking = false,
  Set<String> calendarWritten = const {},
  List<OutcomeCandidate> outcomes = const [],
  Set<int> outcomeDone = const {},
  PlannedNotification? review,
  PlannedNotification? donation,
  List<PlannedNotification> previousYears = const [],
  DateTime? quietUntil,
  bool donationsAllowed = kShowDonationLink,
}) {
  if (!prefs.consent) return const [];
  final out = <PlannedNotification>[];
  final ids = <int>{};
  void add(PlannedNotification n) {
    if (!n.at.isAfter(now) || !ids.add(n.id)) return;
    out.add(nightQuiet(quietAware(n, quietUntil)));
  }

  for (final item in agenda) {
    if (calendarWorking && calendarWritten.contains(item.key)) continue;
    if (item.kind == AgendaKind.session) {
      if (!prefs.sessions) continue;
      for (final r in reminderTimes(item, const [1])) {
        add(
          PlannedNotification(
            id: notificationId(NotificationType.session, item.key),
            type: NotificationType.session,
            at: r.at,
            title: 'Domani inizia la sessione d\'esame',
            body: [
              item.subject,
              if (item.sessionEnd != null)
                'fino al ${italianDate(item.sessionEnd!)}',
            ].join(', '),
            payload: AppRoutes.exams,
          ),
        );
      }
      continue;
    }
    if (!prefs.exams) continue;
    for (final r in reminderTimes(item, prefs.examOffsets, prefs.examHours)) {
      final what = item.kind == AgendaKind.midterm
          ? 'Prova in itinere'
          : 'Esame';
      final place = item.location?.trim() ?? '';
      if (r.hours > 0) {
        // «Tra 1 ora: Analisi I» · «Esame alle 9:00 · Aula 5»
        add(
          PlannedNotification(
            id: notificationId(NotificationType.exam, '${item.key}:h${r.hours}'),
            type: NotificationType.exam,
            at: r.at,
            title: r.hours == 1
                ? 'Tra 1 ora: ${item.subject}'
                : 'Tra ${r.hours} ore: ${item.subject}',
            body: [
              '$what alle ${item.time}',
              if (place.isNotEmpty) place,
            ].join(' · '),
            payload: AppRoutes.exam(item.examId!),
          ),
        );
        continue;
      }
      final when = r.days == 1 ? 'domani' : 'tra ${r.days} giorni';
      add(
        PlannedNotification(
          id: notificationId(NotificationType.exam, '${item.key}:${r.days}'),
          type: NotificationType.exam,
          at: r.at,
          title: '$what $when: ${item.subject}',
          body: [
            italianDate(item.date, weekday: true) +
                (item.time != null ? ' alle ${item.time}' : ''),
            if (place.isNotEmpty) place,
          ].join(' · '),
          payload: AppRoutes.exam(item.examId!),
        ),
      );
    }
  }

  if (prefs.outcome) {
    for (final e in outcomes) {
      if (outcomeDone.contains(e.examId)) continue;
      final what = e.midterm ? 'la prova di' : 'l\'esame di';
      add(
        PlannedNotification(
          id: notificationId(NotificationType.outcome, examAgendaKey(e.examId)),
          type: NotificationType.outcome,
          at: outcomeTime(e.date),
          title: 'Com\'è andata?',
          body:
              'Ieri avevi $what ${e.subject}. Registra l\'esito quando lo '
              'sai.',
          payload: AppRoutes.exam(e.examId),
          actions: const [
            (NotificationActions.recordOutcome, 'Registra l\'esito'),
            (NotificationActions.skipExam, 'Non ricordarmelo per questa prova'),
          ],
        ),
      );
    }
  }

  if (prefs.previousYears) previousYears.forEach(add);

  if (review != null && prefs.review) add(review);
  // l'invito a donare esiste solo nelle build che lo consentono
  // (`--dart-define=DONATIONS=link`), qualunque cosa dicano le preferenze
  if (donation != null && prefs.donation && donationsAllowed) add(donation);

  out.sort((a, b) => a.at.compareTo(b.at));
  return out.length > kMaxScheduled ? out.sublist(0, kMaxScheduled) : out;
}

/// Promemoria «Completa gli esami degli anni precedenti»: [count] esami
/// obbligatori degli anni prima dell'anno di partenza [startYear] sono
/// ancora «Da completare». Due sole notifiche, alle 18:00 di [days] giorni
/// dopo [since] (onboarding o cambio di corso): una dopo 3 giorni e l'unica
/// ripetizione dopo 14. Nessuna se non resta nulla da completare; quelle già
/// passate non si ripianificano.
List<PlannedNotification> previousYearsReminders({
  required DateTime since,
  required int count,
  required int startYear,
  List<int> days = const [3, 14],
}) {
  if (count <= 0 || startYear <= 1) return const [];
  final years = previousYearsLabel(startYear);
  return [
    for (final d in days)
      PlannedNotification(
        id: notificationId(NotificationType.previousYears, 'giorno-$d'),
        type: NotificationType.previousYears,
        at: DateTime(since.year, since.month, since.day + d, 18),
        title: 'Completa gli esami degli anni precedenti',
        body: count == 1
            ? 'Un esame $years è ancora da completare: indica se l\'hai '
                  'già sostenuto.'
            : '$count esami $years sono ancora da completare: indica quali '
                  'hai già sostenuto.',
        payload: AppRoutes.previousYears,
      ),
  ];
}

/// «Non disturbare» della sessione Focus: fino a [quietUntil] (fine della
/// sessione) gli avvisi non urgenti si spostano a un minuto dopo la fine;
/// quelli urgenti ([NotificationType.urgent]) restano dove sono.
PlannedNotification quietAware(PlannedNotification n, DateTime? quietUntil) {
  if (quietUntil == null || n.type.urgent || !n.at.isBefore(quietUntil)) {
    return n;
  }
  return n.movedTo(quietUntil.add(const Duration(minutes: 1)));
}

/// Di notte (22:00–7:00) le notifiche pianificate arrivano senza suono né
/// vibrazione: restano nella tendina per il mattino.
PlannedNotification nightQuiet(PlannedNotification n) {
  final h = n.at.hour;
  if (n.silent || (h >= 7 && h < 22)) return n;
  return PlannedNotification(
    id: n.id,
    type: n.type,
    at: n.at,
    title: n.title,
    body: n.body,
    payload: n.payload,
    actions: n.actions,
    ongoing: n.ongoing,
    countdownTo: n.countdownTo,
    silent: true,
  );
}

/// Payload delle notifiche e dei widget: dove aprire l'app.
class AppRoutes {
  static String exam(int id) => 'prova:$id';
  static const exams = 'sezione:Esami';
  static const links = 'sezione:Collegamenti';
  static const settings = 'sezione:Impostazioni';
  static const record = 'registra';
  static const focus = 'focus';
  static const review = 'recensione';
  static const donate = 'sostegno';

  /// Esami → Anni precedenti.
  static const previousYears = 'anni_precedenti';

  /// Id della prova di un payload `prova:<id>` (null se non lo è).
  static int? examId(String route) => route.startsWith('prova:')
      ? int.tryParse(route.substring('prova:'.length))
      : null;

  /// Sezione dell'app di un payload `sezione:<nome>`.
  static String? section(String route) =>
      route.startsWith('sezione:') ? route.substring('sezione:'.length) : null;
}

const _months = [
  'gennaio',
  'febbraio',
  'marzo',
  'aprile',
  'maggio',
  'giugno',
  'luglio',
  'agosto',
  'settembre',
  'ottobre',
  'novembre',
  'dicembre',
];
const _weekdays = [
  'lunedì',
  'martedì',
  'mercoledì',
  'giovedì',
  'venerdì',
  'sabato',
  'domenica',
];

/// «20 gennaio» o «martedì 20 gennaio» (senza dipendere da intl).
String italianDate(DateTime d, {bool weekday = false}) =>
    '${weekday ? '${_weekdays[d.weekday - 1]} ' : ''}${d.day} '
    '${_months[d.month - 1]}';
