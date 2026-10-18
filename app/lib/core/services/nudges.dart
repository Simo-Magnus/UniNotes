import '../constants/build_flags.dart';
import '../constants/enums.dart';
import 'app_services.dart';

/// Inviti non invasivi mostrati nella Home (mai finestre a comparsa, mai
/// durante le sessioni d'esame, al massimo uno alla volta):
///
/// - **Recensione / stella su GitHub**: dopo almeno 14 giorni e 10 aperture
///   dell'app, e solo in un momento positivo (un esame superato negli
///   ultimi 7 giorni) oppure dopo 30 giorni di uso. «Più tardi» lo rimanda
///   di 60 giorni (al massimo due volte), «No, grazie» o il tocco sul link
///   lo chiudono per sempre.
/// - **Sostieni il progetto** (solo nelle build che possono mostrare il link:
///   GitHub e Microsoft Store, vedi SOSTIENI.md): dopo 30 giorni d'uso, al
///   massimo una volta ogni 120 giorni; «Non mostrare più» lo spegne.
///
/// Nessuno dei due compare se c'è una prova nei prossimi 7 giorni.
class Nudges {
  Nudges(this._s);
  final AppServices _s;

  static const _first = 'nudge_first_open';
  static const _opens = 'nudge_open_count';
  static const _reviewUntil = 'nudge_review_until';
  static const _reviewLater = 'nudge_review_later';
  static const _reviewDone = 'nudge_review_done';
  static const _donationLast = 'nudge_donation_last';
  static const _donationOff = 'nudge_donation_off';

  /// Giorni diversi in cui l'app è stata usata e ultimo giorno contato
  /// (richieste di recensione e sostegno nelle notifiche).
  static const useDaysKey = 'nudge_use_days';
  static const _lastUseDay = 'nudge_last_use_day';
  static const firstOpenKey = _first;
  static const reviewDoneKey = _reviewDone;
  static const donationOffKey = _donationOff;

  /// Da chiamare a ogni avvio dell'app.
  Future<void> registerOpen({DateTime? now}) async {
    final t = now ?? DateTime.now();
    if (await _s.settings.get(_first) == null) {
      await _s.settings.set(_first, t.toIso8601String());
    }
    final n = int.tryParse(await _s.settings.get(_opens) ?? '') ?? 0;
    await _s.settings.set(_opens, '${n + 1}');
    await registerUseDay(now: t);
  }

  /// Conta il giorno di uso effettivo (una volta al giorno: all'avvio e al
  /// ritorno nell'app).
  Future<void> registerUseDay({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final day =
        '${t.year}-${t.month.toString().padLeft(2, '0')}-'
        '${t.day.toString().padLeft(2, '0')}';
    if (await _s.settings.get(_lastUseDay) == day) return;
    final n = int.tryParse(await _s.settings.get(useDaysKey) ?? '') ?? 0;
    await _s.settings.set(useDaysKey, '${n + 1}');
    await _s.settings.set(_lastUseDay, day);
  }

  Future<DateTime?> _date(String k) async =>
      DateTime.tryParse(await _s.settings.get(k) ?? '');

  /// Una prova nei prossimi 7 giorni: niente inviti.
  Future<bool> _examSoon(DateTime t) async {
    final today = DateTime(t.year, t.month, t.day);
    for (final e in await _s.exams.all()) {
      final d = e.date;
      if (d == null || !e.status.isPending) continue;
      final diff = d.difference(today).inDays;
      if (diff >= 0 && diff <= 7) return true;
    }
    return false;
  }

  /// Quale invito mostrare ora (al massimo uno), o null.
  Future<NudgeKind?> current({DateTime? now}) async {
    final t = now ?? DateTime.now();
    final first = await _date(_first);
    if (first == null || await _examSoon(t)) return null;
    final days = t.difference(first).inDays;
    final opens = int.tryParse(await _s.settings.get(_opens) ?? '') ?? 0;

    // recensione
    if (await _s.settings.get(_reviewDone) == null && days >= 14 && opens >= 10) {
      final until = await _date(_reviewUntil);
      if (until == null || t.isAfter(until)) {
        final recentPass = (await _s.exams.byStatus([ExamStatus.passed])).any(
          (e) => e.date != null && t.difference(e.date!).inDays.abs() <= 7,
        );
        if (recentPass || days >= 30) return NudgeKind.review;
      }
    }
    // donazione
    if (kShowDonationLink &&
        await _s.settings.get(_donationOff) == null &&
        days >= 30) {
      final last = await _date(_donationLast);
      if (last == null || t.difference(last).inDays >= 120) {
        return NudgeKind.donation;
      }
    }
    return null;
  }

  /// L'invito è stato visto (la donazione si ripropone tra 120 giorni).
  Future<void> shown(NudgeKind k, {DateTime? now}) async {
    if (k == NudgeKind.donation) {
      await _s.settings.set(
        _donationLast,
        (now ?? DateTime.now()).toIso8601String(),
      );
    }
  }

  Future<void> later(NudgeKind k, {DateTime? now}) async {
    final t = now ?? DateTime.now();
    if (k == NudgeKind.review) {
      final n = int.tryParse(await _s.settings.get(_reviewLater) ?? '') ?? 0;
      if (n >= 2) return never(k);
      await _s.settings.set(_reviewLater, '${n + 1}');
      await _s.settings.set(
        _reviewUntil,
        t.add(const Duration(days: 60)).toIso8601String(),
      );
    } else {
      await shown(k, now: t);
    }
  }

  Future<void> never(NudgeKind k) => _s.settings.set(
    k == NudgeKind.review ? _reviewDone : _donationOff,
    '1',
  );

  /// Dove porta «Lascia una recensione» secondo il canale di distribuzione.
  static ({String label, String url}) reviewTarget() => switch (kStoreChannel) {
    'play' => (
      label: 'Lascia una recensione su Google Play',
      url:
          'https://play.google.com/store/apps/details?id=io.github.simomagnus.universitynotes',
    ),
    'appstore' when kAppStoreId.isNotEmpty => (
      label: 'Lascia una recensione sull\'App Store',
      url: 'https://apps.apple.com/app/id$kAppStoreId?action=write-review',
    ),
    'microsoft' when kMsStoreProductId.isNotEmpty => (
      label: 'Lascia una recensione sul Microsoft Store',
      url: 'ms-windows-store://review/?ProductId=$kMsStoreProductId',
    ),
    _ => (label: 'Metti una stella su GitHub', url: kGithubRepoUrl),
  };
}

enum NudgeKind { review, donation }
