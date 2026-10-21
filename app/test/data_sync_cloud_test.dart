import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_google_drive.dart';

class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth()
    : super(
        providerName: 'Google',
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

/// Un dispositivo collegato allo stesso Google Drive (finto).
class _Phone {
  _Phone(this.db, this.drive, this.applied);
  final AppDatabase db;
  final GoogleDriveService drive;
  final List<int> applied;

  static Future<_Phone> create(
    Directory tmp,
    String name,
    FakeGoogleDrive cloud,
  ) async {
    final root = Directory(p.join(tmp.path, name))..createSync();
    Directory dir(String n) =>
        Directory(p.join(root.path, n))..createSync(recursive: true);
    final db = await AppDatabase.open(path: p.join(root.path, 'db.sqlite'));
    final settings = SettingsRepository(db);
    await settings.set('install_id', name);
    final applied = <int>[];
    final data = DataSync(
      db,
      stateDir: () async => dir('stato'),
      onApplied: () => applied.add(1),
    );
    final gd = GoogleDriveService(
      settings,
      NotesStore(settings, root: () async => dir('appunti')),
      secrets: MemoryCloudSecrets(),
      transport: cloud.call,
      oauthFactory: (_, _) => _FakeOAuth(),
      stateDir: () async => dir('stato'),
      builtInClientId: 'client.apps.googleusercontent.com',
      builtInClientSecret: '',
      deviceName: name,
      sources: SyncSources(data: data),
    );
    return _Phone(db, gd, applied);
  }

  Future<int> minutes() async =>
      ((await db.db.rawQuery(
            'SELECT SUM(duration_minutes) AS m FROM study_sessions',
          )).first['m']
          as int?) ??
      0;
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('data_sync_cloud_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('stesso Google Drive: sessioni sommate, voto e argomenti ovunque; '
      'senza novità nessun caricamento', () async {
    final cloud = FakeGoogleDrive();
    final pc = await _Phone.create(tmp, 'PC', cloud);
    final tel = await _Phone.create(tmp, 'telefono', cloud);
    for (final d in [pc, tel]) {
      final c = await d.db.db.insert('courses', {
        'external_id': 'polito:course:01ABC',
        'name': 'Analisi I',
      });
      final m = await d.db.db.insert('modules', {
        'course_id': c,
        'name': 'Limiti',
      });
      await d.db.db.insert('topics', {'module_id': m, 'name': 'Asintoti'});
      await d.drive.signIn();
    }
    await pc.db.db.insert('study_sessions', {
      'start_at': '2026-10-21T09:00:00',
      'duration_minutes': 50,
    });
    await pc.db.db.update('topics', {'status': 'done'});
    await tel.db.db.insert('study_sessions', {
      'start_at': '2026-10-21T18:00:00',
      'duration_minutes': 25,
    });
    await pc.drive.sync();
    final r = await tel.drive.sync();
    expect(r, isNotNull);
    expect(r!.dataChanges, greaterThan(0));
    expect(r.toString(), contains('dati aggiornati dagli altri dispositivi'));
    await pc.drive.sync();
    expect(
      cloud.files.keys.where((k) => k.startsWith('UniNotes/Dati/')).toSet(),
      {
        'UniNotes/Dati/PC PC.json.gz',
        'UniNotes/Dati/telefono telefono.json.gz',
      },
    );
    for (final d in [pc, tel]) {
      expect(await d.minutes(), 75);
      expect(
        (await d.db.db.rawQuery('SELECT status FROM topics')).single['status'],
        'done',
      );
    }
    expect(tel.applied, isNotEmpty);
    // nulla di nuovo: controllo leggero, nessun file caricato
    final quiet = await pc.drive.sync(force: false);
    expect(quiet!.uploaded, 0);
    expect(quiet.dataChanges, 0);
    // la casella «Dati» si può spegnere
    await tel.drive.setScopes({SyncScope.notes});
    expect(await tel.drive.scopes(), {SyncScope.notes});
    await pc.db.close();
    await tel.db.close();
  });

  test('caselle: «Dati» accesa anche per chi aveva già scelto le altre', () {
    expect(SyncScope.parse('notes,books'), {
      SyncScope.data,
      SyncScope.notes,
      SyncScope.books,
    });
    expect(SyncScope.parse(SyncScope.encode({SyncScope.notes})), {
      SyncScope.notes,
    });
    expect(SyncScope.parse(null), SyncScope.values.toSet());
  });
}
