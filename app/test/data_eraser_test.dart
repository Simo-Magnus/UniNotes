import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/reminders/system_calendar.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_drive.dart';
import 'support/fake_google_drive.dart';
import 'support/fake_reminders.dart';

/// Accesso finto: riesce sempre.
class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth()
    : super(
        providerName: 'Prova',
        authEndpoint: Uri.parse('https://login.example/authorize'),
        tokenEndpoint: Uri.parse('https://login.example/token'),
        clientId: 'x',
        scope: 's',
        openBrowser: (_) async => true,
      );

  @override
  Future<OAuthTokens> signIn({
    String? loginHint,
    Duration timeout = const Duration(minutes: 5),
  }) async => OAuthTokens(
    accessToken: 'a',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: 'r',
  );

  @override
  Future<OAuthTokens> refresh(String refreshToken) => signIn();
}

/// Calendario finto che sa anche eliminare il calendario «UniNotes».
class _RemovableCalendar extends FakeCalendarBackend
    implements RemovableCalendar {
  bool calendarDeleted = false;

  @override
  Future<bool> deleteCalendarIfEmpty(String calendarId) async {
    if (events.isNotEmpty) return false;
    calendarDeleted = true;
    return true;
  }
}

void main() {
  late Directory tmp;
  late String dbPath;
  late AppServices s;
  late FakeDrive onedrive;
  late FakeGoogleDrive gdrive;
  late MemoryCloudSecrets secrets;
  late _RemovableCalendar calendar;
  var secretsWiped = false;
  var prefsCleared = false;

  Directory dir(String rel) =>
      Directory(p.join(tmp.path, rel))..createSync(recursive: true);
  File file(String rel, [String text = 'x']) {
    final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
    f.writeAsStringSync(text);
    return f;
  }

  Future<AppServices> services(AppDatabase db) async {
    final settings = SettingsRepository(db);
    final notes = NotesStore(settings, root: () async => dir('appunti/Corsi'));
    return AppServices(
      db,
      notes: notes,
      onedrive: OneDriveService(
        settings,
        notes,
        secrets: secrets,
        transport: onedrive.call,
        oauthFactory: (_, _) => _FakeOAuth(),
        stateDir: () async => dir('supporto'),
        builtInClientId: '1a2b3c4d-1111-2222-3333-444455556666',
        deviceName: 'PC',
      ),
      googleDrive: GoogleDriveService(
        settings,
        notes,
        secrets: secrets,
        transport: gdrive.call,
        oauthFactory: (_, _) => _FakeOAuth(),
        stateDir: () async => dir('supporto'),
        builtInClientId: 'client.apps.googleusercontent.com',
        builtInClientSecret: '',
        deviceName: 'PC',
      ),
      reminders: (s) => RemindersService(
        s,
        platform: FakeNotificationPlatform(),
        calendarBackend: calendar,
        widgets: FakeHomeWidgets(),
        platformName: 'android',
        isRecording: () => false,
      ),
    );
  }

  DataEraser eraser() => DataEraser(
    s,
    supportDir: () async => dir('supporto'),
    cacheDirs: () async => [dir('cache')],
    wipeSecrets: () async => secretsWiped = true,
    clearPrefs: () async => prefsCleared = true,
    syncWait: Duration.zero,
  );

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('eraser_');
    dbPath = p.join(dir('supporto').path, AppDatabase.fileName);
    onedrive = FakeDrive();
    gdrive = FakeGoogleDrive();
    secrets = MemoryCloudSecrets();
    calendar = _RemovableCalendar();
    secretsWiped = false;
    prefsCleared = false;
    s = await services(await AppDatabase.open(path: dbPath));

    // collegati a OneDrive e Google Drive, con la cartella dell'app e file
    // dell'utente accanto
    await secrets.write(s.onedrive.refreshKey, 'r');
    await secrets.write(s.googleDrive.refreshKey, 'r');
    onedrive.put('UniNotes/Corsi/Analisi/Appunti/a.md', 'a');
    onedrive.put('UniNotes/Backup/Backup PC.json', '{}');
    onedrive.put('Personale/tesi.docx', 'mia');
    final root = gdrive.add('root', 'UniNotes', 'application/vnd.google-apps.folder');
    final corsi = gdrive.add(root.id, 'Corsi', 'application/vnd.google-apps.folder');
    gdrive.add(corsi.id, 'a.md', 'text/markdown', [97]);
    gdrive.add('root', 'Mio.pdf', 'application/pdf', [1]);

    // calendario collegato con una prova
    final c = await s.courses.insert(const Course(name: 'Analisi I'));
    await s.exams.insert(Exam(courseId: c, date: DateTime(2027, 2, 10)));
    await s.settings.set(NotificationKeys.consent, '1');
    await s.reminders.enableCalendar();

    // file sul dispositivo
    file('appunti/Corsi/Analisi I/Registrazioni/lezione.flac', 'audio');
    file('appunti/Corsi/Analisi I/Trascrizioni/lezione.md');
    file('appunti/Corsi/Analisi I/Appunti/mio.md');
    file('appunti/Corsi/.eliminati/vecchio/x.md');
    file('supporto/whisper/modelli/ggml-base.bin', '0123456789');
    file('supporto/database_cache/ateneo.json');
    file('supporto/libri/libro.pdf');
    file('supporto/onedrive_sync_corsi.json', '{}');
    file('supporto/evidenziazioni/a.json');
    file('cache/x.tmp');
  });

  tearDown(() async {
    try {
      await s.database.close();
    } catch (_) {}
    await tmp.delete(recursive: true);
  });

  Future<bool> exists(String rel) async =>
      FileSystemEntity.type(p.join(tmp.path, rel)).then(
        (t) => t != FileSystemEntityType.notFound,
      );

  test('elenco: dimensioni, servizi collegati, OneNote spento', () async {
    expect(calendar.events, hasLength(1));
    final o = {for (final x in await eraser().options()) x.item: x};
    expect(o.keys, EraseItem.values);
    expect(o[EraseItem.whisper]!.bytes, 10);
    expect(o[EraseItem.recordings]!.bytes, greaterThan(0));
    expect(o[EraseItem.onedrive]!.available, isTrue);
    expect(o[EraseItem.onedrive]!.detail, contains('UniNotes'));
    expect(o[EraseItem.googleDrive]!.available, isTrue);
    expect(o[EraseItem.calendar]!.available, isTrue);
    expect(o[EraseItem.onenote]!.available, isFalse);
  });

  test('elimina tutto: solo ciò che l\'app ha creato, ovunque', () async {
    final all = {
      for (final o in await eraser().options())
        if (o.available) o.item,
    };
    final r = await eraser().run(all);
    expect(r.problems, isEmpty);

    // OneDrive: cartella dell'app nel cestino, i file dell'utente restano
    expect(onedrive.files.keys, ['Personale/tesi.docx']);
    expect(onedrive.folders.where((f) => f.startsWith('UniNotes')), isEmpty);
    // Google Drive: nel cestino solo la cartella UniNotes e il suo contenuto
    expect(gdrive.trash, containsAll(['UniNotes/Corsi', 'UniNotes']));
    expect(gdrive.trash, isNot(contains('Mio.pdf')));
    expect(gdrive.files, contains('Mio.pdf'));
    // calendario: eventi dell'app tolti, calendario vuoto eliminato
    expect(calendar.events, isEmpty);
    expect(calendar.calendarDeleted, isTrue);

    // dispositivo
    expect(await exists('supporto/${AppDatabase.fileName}'), isFalse);
    expect(await dir('supporto').list().isEmpty, isTrue);
    expect(await exists('appunti/Corsi'), isFalse);
    expect(await exists('cache/x.tmp'), isFalse);
    expect(secretsWiped, isTrue);
    expect(prefsCleared, isTrue);
  });

  test('scelta parziale: solo le voci spuntate', () async {
    final r = await eraser().run({EraseItem.recordings, EraseItem.whisper});
    expect(r.problems, isEmpty);
    expect(await exists('appunti/Corsi/Analisi I/Registrazioni'), isFalse);
    expect(await exists('appunti/Corsi/Analisi I/Trascrizioni'), isFalse);
    expect(await exists('appunti/Corsi/Analisi I/Appunti/mio.md'), isTrue);
    expect(await exists('appunti/Corsi/.eliminati/vecchio/x.md'), isTrue);
    expect(await exists('supporto/whisper'), isFalse);
    expect(await exists('supporto/libri/libro.pdf'), isTrue);
    // la sincronizzazione riparte da capo: niente eliminazioni propagate
    expect(await exists('supporto/onedrive_sync_corsi.json'), isFalse);
    // cloud, calendario, accessi e database restano
    expect(onedrive.files, contains('UniNotes/Corsi/Analisi/Appunti/a.md'));
    expect(calendar.events, hasLength(1));
    expect(secretsWiped, isFalse);
    expect(prefsCleared, isFalse);
    final db = await AppDatabase.open(path: dbPath);
    expect(await SettingsRepository(db).get(NotificationKeys.consent), '1');
    await db.close();
  });

  test('profilo e impostazioni senza database: i corsi restano', () async {
    await eraser().run({EraseItem.profile});
    final db = await AppDatabase.open(path: dbPath);
    final again = AppServices(db);
    expect(await again.settings.get(NotificationKeys.consent), isNull);
    expect(await again.courses.all(), hasLength(1));
    expect(prefsCleared, isTrue);
    await db.close();
  });

  test('database senza profilo: corsi ed esami via, impostazioni restano', () async {
    await eraser().run({EraseItem.database});
    final db = await AppDatabase.open(path: dbPath);
    final again = AppServices(db);
    expect(await again.courses.all(), isEmpty);
    expect(await again.settings.get(NotificationKeys.consent), '1');
    await db.close();
  });

  test('cartella cloud scelta a mano: si tolgono solo le sottocartelle dell\'app',
      () async {
    onedrive.put('Università/Corsi/x.md', 'x');
    onedrive.put('Università/mio.txt', 'mio');
    await s.onedrive.setFolder('Università');
    expect(await s.onedrive.deleteRemoteAppData(), 1);
    expect(onedrive.files, contains('Università/mio.txt'));
    expect(onedrive.files.containsKey('Università/Corsi/x.md'), isFalse);
    // vuota ma non è la cartella dell'app: resta
    onedrive.files.remove('Università/mio.txt');
    expect(await s.onedrive.deleteRemoteAppData(), 0);
    expect(onedrive.folders, contains('Università'));
  });

  test('voci per i dati rimasti da un\'installazione precedente', () {
    expect(
      DataEraser.deviceItems(sharedNotes: true),
      isNot(contains(EraseItem.notes)),
    );
    final mac = DataEraser.deviceItems(sharedNotes: false);
    expect(mac, containsAll([EraseItem.notes, EraseItem.recordings]));
    expect(mac, isNot(contains(EraseItem.onedrive)));
    expect(mac, isNot(contains(EraseItem.calendar)));
  });
}
