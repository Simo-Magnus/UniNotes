import 'package:university_notes/core/reminders/agenda.dart';
import 'package:university_notes/core/reminders/home_widgets.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';

/// Notifiche del sistema finte: tengono in memoria quelle pianificate.
class FakeNotificationPlatform implements NotificationPlatform {
  final Map<int, PlannedNotification> scheduled = {};
  final List<PlannedNotification> shown = [];
  final List<int> cancelled = [];
  bool granted = true;
  bool askedPermission = false;
  List<NotificationTap> queue = [];

  @override
  Future<void> init(void Function(NotificationTap tap) onTap) async {}

  @override
  Future<NotificationTap?> launchTap() async => null;

  @override
  Future<List<NotificationTap>> takeQueuedTaps() async {
    final q = queue;
    queue = [];
    return q;
  }

  @override
  Future<bool> permissionGranted() async => granted && askedPermission;

  @override
  Future<bool> requestPermission() async {
    askedPermission = true;
    return granted;
  }

  @override
  Future<void> schedule(PlannedNotification n) async => scheduled[n.id] = n;

  @override
  Future<void> show(PlannedNotification n) async => shown.add(n);

  @override
  Future<void> cancel(int id) async {
    cancelled.add(id);
    scheduled.remove(id);
  }

  @override
  Future<void> openSystemSettings() async {}
}

/// Calendario di sistema finto in memoria (come un calendario «UniNotes»).
class FakeCalendarBackend implements CalendarBackend {
  bool access = true;
  bool grantOnRequest = true;
  bool failWrites = false;

  /// Accesso revocato: le chiamate lanciano [CalendarAccessException].
  bool revoked = false;
  final Map<String, ({String key, AgendaItem item, List<int> reminders})>
  events = {};
  int _next = 0;
  int writes = 0;
  String? calendarId;

  @override
  String get id => 'device';

  @override
  String get label => 'calendario finto';

  void _check() {
    if (revoked) {
      throw CalendarAccessException('Accesso revocato.', expired: true);
    }
  }

  @override
  Future<bool> hasAccess() async => access;

  @override
  Future<bool> requestAccess() async => access = grantOnRequest;

  @override
  Future<String> ensureCalendar(String? knownId) async {
    _check();
    return calendarId ??= 'cal-1';
  }

  @override
  Future<Map<String, List<String>>> existing(String calendarId) async {
    _check();
    final out = <String, List<String>>{};
    for (final e in events.entries) {
      (out[e.value.key] ??= []).add(e.key);
    }
    return out;
  }

  @override
  Future<String> write(
    String calendarId,
    AgendaItem item,
    List<int> reminderMinutes, {
    String? eventId,
  }) async {
    _check();
    if (failWrites) throw Exception('scrittura non riuscita');
    if (eventId != null && !events.containsKey(eventId)) {
      throw Exception('evento non trovato');
    }
    writes++;
    final id = eventId ?? 'ev${_next++}';
    events[id] = (key: item.key, item: item, reminders: reminderMinutes);
    return id;
  }

  @override
  Future<void> delete(String calendarId, String eventId) async {
    _check();
    events.remove(eventId);
  }
}

/// Widget finti: ricordano l'ultimo contenuto.
class FakeHomeWidgets extends HomeWidgetBridge {
  Map<String, Object?>? last;

  @override
  Future<void> update(Map<String, Object?> payload) async => last = payload;

  @override
  Future<String?> takeRoute() async => null;

  @override
  void listen(void Function(String route) onRoute) {}
}

/// Una prova dell'agenda per i test.
AgendaItem examItem(
  int id,
  DateTime date, {
  String? time,
  String subject = 'Analisi I',
}) => AgendaItem(
  key: examAgendaKey(id),
  kind: AgendaKind.exam,
  title: 'Esame · $subject',
  subject: subject,
  date: date,
  time: time,
  examId: id,
);

/// Stessa prova con un altro orario o luogo (per gli aggiornamenti).
AgendaItem withLocation(AgendaItem i, String location) => AgendaItem(
  key: i.key,
  kind: i.kind,
  title: i.title,
  subject: i.subject,
  date: i.date,
  time: i.time,
  location: location,
  examId: i.examId,
);

/// Ultime notifiche di un tipo.
List<PlannedNotification> ofType(
  Iterable<PlannedNotification> v,
  NotificationType t,
) => [
  for (final n in v)
    if (n.type == t) n,
];
