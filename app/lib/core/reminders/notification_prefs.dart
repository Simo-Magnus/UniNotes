import '../../repositories/settings_repository.dart';
import '../constants/build_flags.dart';

/// Chiavi delle impostazioni delle notifiche (Impostazioni → Notifiche) e
/// dello stato delle richieste di recensione e sostegno.
class NotificationKeys {
  /// Consenso alle notifiche dato nell'app: '1' sì, '0' no, null mai
  /// chiesto. Senza consenso l'app non pianifica nulla.
  static const consent = 'notif_consent';

  /// Il consenso è già stato chiesto in modo contestuale (prima prova con
  /// una data): non si richiede più, resta l'interruttore nelle impostazioni.
  static const asked = 'notif_asked';

  static const exams = 'notif_exams';
  static const examOffsets = 'notif_exam_offsets';
  static const sessions = 'notif_sessions';
  static const outcome = 'notif_outcome';
  static const links = 'notif_links';
  static const review = 'notif_review';
  static const donation = 'notif_donation';

  /// Prove per cui non chiedere «Com'è andata?» (id separati da virgola):
  /// già chiesto una volta o «Non ricordarmelo per questa prova».
  static const outcomeDone = 'notif_outcome_done';

  /// Notifiche «Com'è andata?» pianificate: JSON {id prova: istante}.
  static const outcomeScheduled = 'notif_outcome_scheduled';

  /// Notifiche pianificate dall'app: JSON {id notifica: istante}.
  static const scheduled = 'notif_scheduled';

  // Recensione: una sola richiesta («Più tardi» la ripropone dopo 30
  // giorni, al massimo due volte).
  static const reviewState = 'notif_review_state'; // done | never
  static const reviewAt = 'notif_review_at';
  static const reviewUntil = 'notif_review_until';
  static const reviewLater = 'notif_review_later';
  static const reviewShownAt = 'notif_review_shown_at';

  // Sostegno: al massimo ogni 6 mesi.
  static const donationOff = 'notif_donation_off';
  static const donationAt = 'notif_donation_at';
  static const donationNext = 'notif_donation_next';
  static const donationShownAt = 'notif_donation_shown_at';

  /// Ultimo avviso «Collegamento interrotto» per servizio (prefisso).
  static const linkWarnedPrefix = 'notif_link_warned_';
}

/// Anticipi predefiniti degli avvisi delle prove (giorni prima).
const List<int> kDefaultExamOffsets = [7, 1];

/// Anticipi proposti nelle impostazioni.
const List<int> kExamOffsetChoices = [1, 2, 3, 7, 14];

/// Preferenze delle notifiche lette dalle impostazioni.
class NotificationPrefs {
  const NotificationPrefs({
    this.consent = false,
    this.exams = true,
    this.examOffsets = kDefaultExamOffsets,
    this.sessions = true,
    this.outcome = true,
    this.links = true,
    this.review = true,
    this.donation = kShowDonationLink,
  });

  /// L'utente ha attivato le notifiche nell'app.
  final bool consent;
  final bool exams;
  final List<int> examOffsets;
  final bool sessions;
  final bool outcome;
  final bool links;
  final bool review;

  /// Attiva di default solo nelle build con il link alle donazioni.
  final bool donation;

  static Future<NotificationPrefs> load(SettingsRepository s) async {
    Future<bool> flag(String k, bool def) async {
      final v = await s.get(k);
      return v == null ? def : v == '1';
    }

    return NotificationPrefs(
      consent: await s.get(NotificationKeys.consent) == '1',
      exams: await flag(NotificationKeys.exams, true),
      examOffsets: parseOffsets(await s.get(NotificationKeys.examOffsets)),
      sessions: await flag(NotificationKeys.sessions, true),
      outcome: await flag(NotificationKeys.outcome, true),
      links: await flag(NotificationKeys.links, true),
      review: await flag(NotificationKeys.review, true),
      donation:
          kShowDonationLink && await flag(NotificationKeys.donation, true),
    );
  }

  /// "7,1" → [7, 1]; vuoto o non valido → anticipi predefiniti.
  static List<int> parseOffsets(String? v) {
    if (v == null) return kDefaultExamOffsets;
    final out = <int>{
      for (final x in v.split(','))
        if (int.tryParse(x.trim()) case final n? when n > 0 && n <= 60) n,
    }.toList()..sort((a, b) => b - a);
    return out;
  }

  static String formatOffsets(Iterable<int> v) =>
      ({...v}.toList()..sort((a, b) => b - a)).join(',');
}
