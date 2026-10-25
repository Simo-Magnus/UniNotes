import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/temp_files.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_reminders.dart';

/// Caccia alle falle, giro 1 — dati sul dispositivo e privacy
/// (docs/sicurezza.md, «Giro 1 — Dati sul dispositivo e privacy»).
void main() {
  group('1. backup: cartella cloud e account del calendario', () {
    const keys = [
      'onedrive_folder',
      'gdrive_folder',
      'syscal_calendar_account',
      'syscal_writers',
    ];

    test('non si esportano', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = SettingsRepository(db);
      for (final k in keys) {
        await s.set(k, 'valore di $k');
      }
      await s.set('theme_mode', 'dark');
      final json = await BackupService(db).exportJson();
      for (final k in keys) {
        expect(json, isNot(contains(k)), reason: k);
      }
      expect(json, contains('theme_mode'));
    });

    test('un backup ricevuto da altri non li sovrascrive né li aggiunge', () async {
      // backup «di un altro» scritto a mano con le chiavi dentro
      final other = await AppDatabase.openInMemory();
      addTearDown(other.close);
      final map = await BackupService(other).exportMap();
      final tables = map['tables']! as Map<String, Object?>;
      tables['app_settings'] = [
        for (final k in keys) {'key': k, 'value': 'Documenti'},
        {'key': 'theme_mode', 'value': 'light'},
      ];
      final json = jsonEncode(map);

      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = SettingsRepository(db);
      await s.set('onedrive_folder', 'UniNotes');
      await BackupService(db).importJson(json);
      expect(await s.get('onedrive_folder'), 'UniNotes');
      expect(await s.get('gdrive_folder'), isNull);
      expect(await s.get('syscal_calendar_account'), isNull);
      expect(await s.get('syscal_writers'), isNull);
      // il resto del backup si ripristina come prima
      expect(await s.get('theme_mode'), 'light');
    });
  });

  group('2. «Elimina tutti i dati»: resti fuori dalle cartelle principali', () {
    late Directory tmp;
    late AppServices s;

    Directory dir(String rel) =>
        Directory(p.join(tmp.path, rel))..createSync(recursive: true);
    File file(String rel, [String text = 'x']) {
      final f = File(p.join(tmp.path, rel))..parent.createSync(recursive: true);
      f.writeAsStringSync(text);
      return f;
    }

    bool exists(String rel) =>
        FileSystemEntity.typeSync(p.join(tmp.path, rel)) !=
        FileSystemEntityType.notFound;

    DataEraser eraser() => DataEraser(
      s,
      supportDir: () async => dir('supporto'),
      cacheDirs: () async => [dir('cache')],
      wipeSecrets: () async {},
      clearPrefs: () async {},
      tempDir: () => dir('temp'),
      syncWait: Duration.zero,
    );

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sicurezza_g1_');
      final db = await AppDatabase.open(
        path: p.join(dir('supporto').path, AppDatabase.fileName),
      );
      final settings = SettingsRepository(db);
      final notes = NotesStore(settings, root: () async => dir('appunti'));
      s = AppServices(
        db,
        notes: notes,
        onedrive: OneDriveService(
          settings,
          notes,
          secrets: MemoryCloudSecrets(),
          stateDir: () async => dir('supporto'),
          deviceName: 'PC',
        ),
        googleDrive: GoogleDriveService(
          settings,
          notes,
          secrets: MemoryCloudSecrets(),
          stateDir: () async => dir('supporto'),
          deviceName: 'PC',
        ),
        reminders: (s) => RemindersService(
          s,
          platform: FakeNotificationPlatform(),
          calendarBackend: FakeCalendarBackend(),
          widgets: FakeHomeWidgets(),
          platformName: 'android',
          isRecording: () => false,
        ),
      );
    });

    tearDown(() async {
      try {
        await s.database.close();
      } catch (_) {}
      await tmp.delete(recursive: true);
    });

    test('registrazioni: via anche dai cestini e dalle cartelle di lavoro, '
        'gli appunti eliminati restano', () async {
      final root = dir('appunti');
      final bin = RecycleBin(() async => root);
      final rec = file('appunti/Analisi/Registrazioni/lezione.m4a', 'audio');
      final tr = file('appunti/Analisi/Trascrizioni/lezione.md', 'testo');
      final note = file('appunti/Analisi/Appunti/mio.md', 'appunto');
      await bin.trash([rec], title: 'lezione', course: 'Analisi');
      await bin.trash([tr], title: 'trascrizione', course: 'Analisi');
      await bin.trash([note], title: 'mio', course: 'Analisi');
      expect(await bin.list(), hasLength(3));
      // eliminati su un altro dispositivo (sincronizzazione)
      file('appunti/.cestino-onedrive/Analisi/Registrazioni/vecchia.m4a');
      file('appunti/.cestino-onedrive/Analisi/Appunti/vecchio.md');
      // cartelle di lavoro recenti e registrazione eliminata a metà
      file('temp/whisper_live_123/pezzo.wav', 'audio');
      file('temp/uninotes_cestino_456/lezione.wav', 'audio');
      file('temp/altro_programma/file.txt');

      final r = await eraser().run({EraseItem.recordings});
      expect(r.problems, isEmpty);

      final left = await bin.list();
      expect(left.map((e) => e.title), ['mio']);
      expect(
        exists('appunti/.cestino-onedrive/Analisi/Registrazioni/vecchia.m4a'),
        isFalse,
      );
      expect(
        exists('appunti/.cestino-onedrive/Analisi/Appunti/vecchio.md'),
        isTrue,
      );
      expect(exists('temp/whisper_live_123'), isFalse);
      expect(exists('temp/uninotes_cestino_456'), isFalse);
      expect(exists('temp/altro_programma/file.txt'), isTrue);
    });

    test('database: via le copie JSON della sincronizzazione e i file del '
        'calendario', () async {
      file('supporto/onedrive_backup/Backup PC a1b2c3.json', '{"voti":30}');
      file('supporto/gdrive_backup/Backup telefono 9f0e11.json', '{}');
      file('supporto/calendario/UniNotes - Prove.ics', 'BEGIN:VCALENDAR');
      file('supporto/libri/libro.pdf');
      await eraser().run({EraseItem.database});
      expect(exists('supporto/onedrive_backup'), isFalse);
      expect(exists('supporto/gdrive_backup'), isFalse);
      expect(exists('supporto/calendario'), isFalse);
      // le altre voci restano
      expect(exists('supporto/libri/libro.pdf'), isTrue);
    });

    test('senza registrazioni le cartelle di lavoro recenti restano', () async {
      file('temp/whisper_live_123/pezzo.wav', 'audio');
      file('temp/uninotes_cestino_456/lezione.wav', 'audio');
      await eraser().run({EraseItem.whisper});
      expect(exists('temp/whisper_live_123/pezzo.wav'), isTrue);
      expect(exists('temp/uninotes_cestino_456/lezione.wav'), isTrue);
    });
  });

  group('3. pulizia dei file temporanei', () {
    test('all\'avvio restano le cartelle recenti e il cestino; con allWork '
        'tutto ciò che è dell\'app', () async {
      final temp = await Directory.systemTemp.createTemp('sicurezza_g1_t_');
      addTearDown(() => temp.delete(recursive: true));
      Directory d(String n) =>
          Directory(p.join(temp.path, n))..createSync(recursive: true);
      for (final n in [
        'whisper_1',
        'parakeet_2',
        'uninotes_live_3',
        'uninotes_cestino_4',
        'UniNotes AI',
        'mio',
      ]) {
        d(n);
      }
      await clearTempFiles(temp: temp);
      bool has(String n) => Directory(p.join(temp.path, n)).existsSync();
      expect(has('UniNotes AI'), isFalse);
      expect(has('whisper_1'), isTrue);
      expect(has('uninotes_cestino_4'), isTrue);
      await clearTempFiles(temp: temp, allWork: true);
      expect(has('whisper_1'), isFalse);
      expect(has('parakeet_2'), isFalse);
      expect(has('uninotes_live_3'), isFalse);
      expect(has('uninotes_cestino_4'), isFalse);
      expect(has('mio'), isTrue);
    });
  });

  group('4. registri del sistema', () {
    test('il testo delle lezioni non va in debugPrint nelle build pubblicate', () {
      // debugPrint scrive anche in release (logcat, console di Apple): il
      // testo trascritto, i prompt e i token solo dentro `if (kDebugMode)`
      final risky = RegExp(
        r'debugPrint\([^;]*\$\{?(s|seg|segment|segments|transcript|prompt|'
        r'token|tokens|accessToken|refresh|refreshToken|text)\b',
      );
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final lines = e.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (!risky.hasMatch(line)) continue;
          final before = lines.sublist(i < 3 ? 0 : i - 3, i).join('\n');
          if (before.contains('kDebugMode')) continue;
          offenders.add('${e.path}:${i + 1}: ${line.trim()}');
        }
      }
      expect(offenders, isEmpty);
    });
  });

  test('servizi cloud: nessun token nel database delle impostazioni', () async {
    // i refresh token stanno nel portachiavi ([CloudSecrets]), mai fra le
    // impostazioni (che finiscono nei backup)
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final settings = SettingsRepository(db);
    final secrets = MemoryCloudSecrets();
    final notes = NotesStore(settings, root: () async => Directory.systemTemp);
    final od = OneDriveService(settings, notes, secrets: secrets);
    await od.storeTokens(
      OAuthTokens(
        accessToken: 'at-segreto',
        expiresAt: DateTime.now().add(const Duration(hours: 1)),
        refreshToken: 'rt-segreto',
      ),
    );
    await od.setAccount('studente@example.com');
    final json = await BackupService(db).exportJson();
    expect(json, isNot(contains('segreto')));
    expect(json, isNot(contains('studente@example.com')));
    expect(secrets.values[od.refreshKey], 'rt-segreto');
    expect(CloudDriveService.defaultFolder, 'UniNotes');
  });
}
