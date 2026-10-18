import '../constants/build_flags.dart';
import 'notification_plan.dart';

/// Dove porta «Recensisci» nella notifica di recensione.
class ReviewDestination {
  const ReviewDestination(this.url, {this.fallbackUrl, required this.github});

  /// Link principale (`market://`, `itms-apps://`, pagina GitHub…).
  final String url;

  /// Se il link principale non si apre (es. niente Play Store).
  final String? fallbackUrl;

  /// Build GitHub: invito a lasciare una stella o un commento.
  final bool github;
}

const _playId = 'io.github.simomagnus.universitynotes';

/// Destinazione della recensione secondo la piattaforma e la build:
/// - Android senza link alle donazioni (AAB per Google Play, o
///   `--dart-define=STORE=play`) → Play Store;
/// - iOS, e macOS dell'App Store → App Store, solo con
///   `--dart-define=APPSTORE_ID` (senza ID nessuna richiesta);
/// - Microsoft Store con `MSSTORE_ID` → pagina della recensione;
/// - build GitHub (APK, Windows, macOS con `DONATIONS=link`) → GitHub.
/// null = nessuna richiesta di recensione in questa build.
ReviewDestination? reviewDestination({
  required String platform,
  String store = kStoreChannel,
  bool donationLink = kShowDonationLink,
  String appStoreId = kAppStoreId,
  String msStoreId = kMsStoreProductId,
}) {
  const github = ReviewDestination(kGithubRepoUrl, github: true);
  ReviewDestination? apple() => appStoreId.isEmpty
      ? null
      : ReviewDestination(
          'itms-apps://itunes.apple.com/app/id$appStoreId?action=write-review',
          fallbackUrl:
              'https://apps.apple.com/app/id$appStoreId?action=write-review',
          github: false,
        );
  return switch (platform) {
    'android' when store == 'play' || !donationLink => const ReviewDestination(
      'market://details?id=$_playId',
      fallbackUrl: 'https://play.google.com/store/apps/details?id=$_playId',
      github: false,
    ),
    'android' => github,
    'ios' => apple(),
    'windows' when store == 'microsoft' && msStoreId.isNotEmpty =>
      ReviewDestination(
        'ms-windows-store://review/?ProductId=$msStoreId',
        github: false,
      ),
    _ => github,
  };
}

/// Stato delle richieste di recensione e sostegno (dalle impostazioni).
class PromoState {
  const PromoState({
    required this.firstOpen,
    required this.useDays,
    this.reviewClosed = false,
    this.reviewAt,
    this.reviewUntil,
    this.reviewShownAt,
    this.donationOff = false,
    this.donationAt,
    this.donationNext,
    this.donationShownAt,
  });

  /// Primo avvio dell'app (installazione).
  final DateTime firstOpen;

  /// Giorni diversi in cui l'app è stata aperta (uso effettivo).
  final int useDays;

  /// Recensione già chiesta, fatta o «Non chiedermelo più».
  final bool reviewClosed;

  /// Richiesta di recensione già pianificata (se nel futuro si tiene).
  final DateTime? reviewAt;

  /// «Più tardi»: non prima di questa data.
  final DateTime? reviewUntil;
  final DateTime? reviewShownAt;

  final bool donationOff;
  final DateTime? donationAt;

  /// Non prima di questa data (6 mesi dopo l'ultima, o 30 giorni dopo
  /// «Più tardi»).
  final DateTime? donationNext;
  final DateTime? donationShownAt;
}

/// Orario delle richieste: le 18:00 locali.
const int kPromoHour = 18;

/// Regole della richiesta di recensione: almeno 14 giorni dall'installazione
/// e 5 giorni d'uso effettivo, mai entro 2 giorni da una prova, mai durante
/// una registrazione. Restituisce l'istante da pianificare o null.
DateTime? reviewSlot({
  required DateTime now,
  required PromoState state,
  required List<DateTime> examDays,
  required bool recording,
  required bool available,
}) {
  if (!available || state.reviewClosed || recording) return null;
  if (state.useDays < 5) return null;
  final eligible = _max([
    plusDays(state.firstOpen, 14),
    if (state.reviewUntil != null) state.reviewUntil!,
  ]);
  return _slot(
    now: now,
    from: eligible,
    keep: state.reviewAt,
    ok: (d) => !_near(d, examDays, 2),
  );
}

/// Regole dell'invito a sostenere il progetto (solo build con il link alle
/// donazioni): dopo 30 giorni dall'installazione e 5 d'uso, poi al massimo
/// ogni 6 mesi, mai nello stesso mese della richiesta di recensione, mai
/// entro 7 giorni da una prova, mai durante una registrazione.
DateTime? donationSlot({
  required DateTime now,
  required PromoState state,
  required List<DateTime> examDays,
  required bool recording,
  required bool available,
  DateTime? reviewAt,
}) {
  if (!available || state.donationOff || recording) return null;
  if (state.useDays < 5) return null;
  final eligible = _max([
    plusDays(state.firstOpen, 30),
    if (state.donationNext != null) state.donationNext!,
    if (state.donationShownAt != null && state.donationNext == null)
      plusDays(state.donationShownAt!, 182),
  ]);
  final reviewMonths = {
    if (reviewAt != null) _month(reviewAt),
    if (state.reviewShownAt != null) _month(state.reviewShownAt!),
  };
  return _slot(
    now: now,
    from: eligible,
    keep: state.donationAt,
    ok: (d) => !_near(d, examDays, 7) && !reviewMonths.contains(_month(d)),
  );
}

int _month(DateTime d) => d.year * 12 + d.month;

/// [d] spostata di [days] giorni di calendario alla stessa ora (anche a
/// cavallo dell'ora legale).
DateTime plusDays(DateTime d, int days) =>
    DateTime(d.year, d.month, d.day + days, d.hour, d.minute);

DateTime _max(List<DateTime> v) => v.reduce((a, b) => a.isAfter(b) ? a : b);

bool _near(DateTime d, List<DateTime> days, int within) {
  final day = DateTime(d.year, d.month, d.day);
  for (final e in days) {
    final x = DateTime(e.year, e.month, e.day);
    if (day.difference(x).inDays.abs() <= within) return true;
  }
  return false;
}

/// Primo giorno valido alle 18:00, non prima di [from] e almeno un'ora dopo
/// [now]; una richiesta già pianificata ([keep]) resta dov'è se è ancora
/// valida (altrimenti chi apre l'app ogni giorno la vedrebbe slittare).
DateTime? _slot({
  required DateTime now,
  required DateTime from,
  required DateTime? keep,
  required bool Function(DateTime) ok,
}) {
  final earliest = _max([from, now.add(const Duration(hours: 1))]);
  if (keep != null && keep.isAfter(now) && !keep.isBefore(from) && ok(keep)) {
    return keep;
  }
  var d = DateTime(earliest.year, earliest.month, earliest.day, kPromoHour);
  if (d.isBefore(earliest)) {
    d = DateTime(d.year, d.month, d.day + 1, kPromoHour);
  }
  for (var i = 0; i < 120; i++) {
    if (ok(d)) return d;
    d = DateTime(d.year, d.month, d.day + 1, kPromoHour);
  }
  return null;
}

/// Notifica di recensione all'istante [at].
PlannedNotification reviewNotification(DateTime at, ReviewDestination dest) =>
    PlannedNotification(
      id: notificationId(NotificationType.review, 'recensione'),
      type: NotificationType.review,
      at: at,
      title: 'Ti trovi bene con UniNotes?',
      body: dest.github
          ? 'Se ti va, lascia una stella o un commento su GitHub: aiuta il '
                'progetto a farsi conoscere.'
          : 'Se ti va, lascia una recensione: aiuta altri studenti a '
                'trovare l\'app.',
      payload: AppRoutes.review,
      actions: const [
        (NotificationActions.review, 'Recensisci'),
        (NotificationActions.later, 'Più tardi'),
        (NotificationActions.never, 'Non chiedermelo più'),
      ],
    );

/// Notifica dell'invito a sostenere il progetto all'istante [at].
PlannedNotification donationNotification(DateTime at) => PlannedNotification(
  id: notificationId(NotificationType.donation, 'sostegno'),
  type: NotificationType.donation,
  at: at,
  title: 'Sostieni UniNotes, se vuoi',
  body:
      'UniNotes è gratuita e resta completa per tutti. Se ti è utile, una '
      'donazione aiuta a mantenerla. È del tutto facoltativo.',
  payload: AppRoutes.donate,
  actions: const [
    (NotificationActions.donate, 'Dona'),
    (NotificationActions.later, 'Più tardi'),
    (NotificationActions.never, 'Non chiedermelo più'),
  ],
);
