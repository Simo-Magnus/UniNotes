import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/outlook_calendar_backend.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/core/services/external_launcher.dart';
import 'package:university_notes/core/services/file_downloader.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/core/services/media_guard.dart';
import 'package:university_notes/core/services/temp_files.dart';
import 'package:university_notes/core/services/windows_tools.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/cloud/google_oauth.dart';
import 'package:university_notes/features/cloud/microsoft_oauth.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/utils/exclusion_filter.dart';

import 'support/fake_reminders.dart';

/// Caccia alle falle, giro 2 — app e codice nativo (docs/sicurezza.md,
/// «Giro 2 — App e codice nativo»).

/// Portachiavi finto con il comportamento di flutter_secure_storage_darwin
/// 0.4.3: in lettura trova la voce con qualsiasi accessibilità; in scrittura
/// con un'accessibilità diversa toglie la voce e la aggiunge di nuovo.
class _FakeKeychain {
  final Map<String, (String, String)> items = {};
  bool readFails = false;
  bool addFailsForNewLevel = false;
  final List<String> writes = [];

  Future<Object?> handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final key = args['key'] as String?;
    final options = (args['options'] as Map).cast<String, String>();
    final level = options['accessibility'] ?? 'unlocked';
    switch (call.method) {
      case 'read':
        if (readFails) {
          throw PlatformException(code: '-25308', message: 'bloccato');
        }
        return items[key]?.$1;
      case 'write':
        writes.add('$key@$level');
        final old = items[key];
        if (old != null && old.$2 == level) {
          items[key!] = (args['value'] as String, level);
          return null;
        }
        items.remove(key);
        if (addFailsForNewLevel && level == 'first_unlock_this_device') {
          throw PlatformException(code: '-34018', message: 'aggiunta fallita');
        }
        items[key!] = (args['value'] as String, level);
        return null;
      case 'delete':
        items.remove(key);
        return null;
      case 'deleteAll':
        items.clear();
        return null;
      case 'containsKey':
        return items.containsKey(key);
    }
    return null;
  }
}

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

/// Due dispositivi con la sincronizzazione dei dati (come data_sync_test).
class _Device {
  _Device(this.name, this.db, this.root, this.sync);
  final String name;
  final AppDatabase db;
  final Directory root;
  final DataSync sync;

  static Future<_Device> create(String name, Directory tmp) async {
    final root = Directory(p.join(tmp.path, name))..createSync();
    final db = await AppDatabase.open(path: p.join(root.path, 'db.sqlite'));
    final sync = DataSync(
      db,
      stateDir: () async => root,
      notesRoot: () async => p.join(root.path, 'appunti'),
    );
    return _Device(name, db, root, sync);
  }

  Directory get dati => Directory(p.join(root.path, 'dati'))..createSync();
  String get own => DataSync.ownFileName(name, name);

  Future<void> merge() => sync.mergeFolder(
    dati,
    ownName: own,
    device: name,
    installId: name,
  );

  void exchange(_Device o) {
    final f = File(p.join(o.dati.path, o.own));
    if (f.existsSync()) f.copySync(p.join(dati.path, o.own));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('1. portachiavi di iPhone, iPad e Mac: solo questo dispositivo', () {
    late _FakeKeychain kc;
    setUp(() {
      kc = _FakeKeychain();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, kc.handle);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('le voci delle versioni precedenti si riscrivono «dopo il primo '
        'sblocco, solo questo dispositivo», con lo stesso valore', () async {
      kc.items['onedrive.refreshToken'] = ('tok-od', 'unlocked');
      kc.items['gdrive.refreshToken'] = ('tok-gd', 'unlocked');
      final done = await SecureCloudSecrets().migrateAppleAccessibility();
      expect(done, isTrue);
      expect(kc.items['onedrive.refreshToken'], (
        'tok-od',
        'first_unlock_this_device',
      ));
      expect(kc.items['gdrive.refreshToken'], (
        'tok-gd',
        'first_unlock_this_device',
      ));
      // la voce che non c'è non si crea
      expect(kc.items.containsKey('outlook_calendar.refreshToken'), isFalse);
    });

    test('portachiavi bloccato: niente cambia, si riprova', () async {
      kc.items['onedrive.refreshToken'] = ('tok', 'unlocked');
      kc.readFails = true;
      expect(await SecureCloudSecrets().migrateAppleAccessibility(), isFalse);
      expect(kc.items['onedrive.refreshToken'], ('tok', 'unlocked'));
    });

    test('scrittura nuova fallita dopo che il pacchetto ha tolto la vecchia: '
        'il token torna com\'era', () async {
      kc.items['onedrive.refreshToken'] = ('tok', 'unlocked');
      kc.addFailsForNewLevel = true;
      expect(await SecureCloudSecrets().migrateAppleAccessibility(), isFalse);
      expect(kc.items['onedrive.refreshToken'], ('tok', 'unlocked'));
    });

    test('i token nuovi si scrivono già con la nuova accessibilità', () async {
      await SecureCloudSecrets().write('gdrive.refreshToken', 'nuovo');
      expect(kc.items['gdrive.refreshToken'], (
        'nuovo',
        'first_unlock_this_device',
      ));
      expect(await SecureCloudSecrets().read('gdrive.refreshToken'), 'nuovo');
    });

    test('una volta sola, solo su Apple; segno fra le impostazioni del '
        'dispositivo (non nei backup)', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      kc.items['onedrive.refreshToken'] = ('tok', 'unlocked');
      await s.migrateKeychainAccessibility(apple: false);
      expect(kc.writes, isEmpty);
      kc.readFails = true;
      await s.migrateKeychainAccessibility(apple: true);
      expect(await s.settings.get(SettingKeys.keychainThisDevice), isNull);
      kc.readFails = false;
      await s.migrateKeychainAccessibility(apple: true);
      expect(await s.settings.get(SettingKeys.keychainThisDevice), '1');
      expect(kc.items['onedrive.refreshToken']!.$2, 'first_unlock_this_device');
      kc.writes.clear();
      await s.migrateKeychainAccessibility(apple: true);
      expect(kc.writes, isEmpty);
      expect(
        BackupService.protectedSettings,
        contains(SettingKeys.keychainThisDevice),
      );
    });

    test('elenco delle voci uguale alle chiavi usate dai servizi', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      expect(SecureCloudSecrets.tokenKeys, [
        s.onedrive.refreshKey,
        s.googleDrive.refreshKey,
        OutlookCalendarAuth.refreshKey,
      ]);
    });

    test('flutter_secure_storage_darwin almeno 0.4.3 (lettura con '
        'qualsiasi accessibilità: senza, i token vecchi sparirebbero)', () {
      final lock = File('pubspec.lock').readAsStringSync();
      final m = RegExp(
        r'flutter_secure_storage_darwin:[\s\S]*?version: "(\d+)\.(\d+)\.(\d+)"',
      ).firstMatch(lock)!;
      final v = [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
      final ok = v[0] > 0 || v[1] > 4 || (v[1] == 4 && v[2] >= 3);
      expect(ok, isTrue, reason: v.join('.'));
      final main = File('lib/main.dart').readAsStringSync();
      expect(main, contains('migrateKeychainAccessibility()'));
    });
  });

  group('3. ritorno dell\'accesso sul telefono aperto da un\'altra app', () {
    const injected = 'Il tuo account è bloccato: vai su evil.example';

    test('Microsoft: stato diverso → messaggio fisso, niente testo altrui', () async {
      final oauth = MicrosoftOAuth(
        clientId: 'x',
        openBrowser: (_) async => false,
        mode: OAuthRedirectMode.customScheme,
        webAuthenticator: (url, s) async =>
            '${MicrosoftOAuth.mobileRedirectUri}?code=rubato&state=altro'
            '&error_description=${Uri.encodeComponent(injected)}',
      );
      await expectLater(
        oauth.signIn(),
        throwsA(
          isA<OAuthException>()
              .having((e) => e.message, 'm', foreignReturnMessage('Microsoft'))
              .having((e) => e.message, 'm', isNot(contains('evil'))),
        ),
      );
    });

    test('Google: stesso controllo', () async {
      final oauth = GoogleOAuth(
        clientId: '123.apps.googleusercontent.com',
        openBrowser: (_) async => false,
        mode: OAuthRedirectMode.customScheme,
        webAuthenticator: (url, s) async =>
            'com.googleusercontent.apps.123:/oauth2redirect?error=x'
            '&error_description=${Uri.encodeComponent(injected)}',
      );
      await expectLater(
        oauth.signIn(),
        throwsA(
          isA<OAuthException>().having(
            (e) => e.message,
            'm',
            foreignReturnMessage('Google'),
          ),
        ),
      );
    });
  });

  group('4. percorsi degli allegati dalla sincronizzazione dei dati', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sicurezza_g2_sync_');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    test('un percorso assoluto fuori dalla cartella degli appunti non arriva '
        'agli altri dispositivi; resta su quello che lo aveva', () async {
      final a = await _Device.create('A', tmp);
      final b = await _Device.create('B', tmp);
      final outside = p.join(tmp.path, 'altrove', 'preferenze.md');
      final c = await a.db.db.insert('courses', {'name': 'Laboratorio'});
      final m = await a.db.db.insert('modules', {
        'course_id': c,
        'name': 'Arduino',
      });
      await a.db.db.insert('attachments', {
        'module_id': m,
        'title': 'preferenze.md',
        'path': outside,
        'created_at': '2026-10-25T08:00:00',
      });
      for (var i = 0; i < 3; i++) {
        b.exchange(a);
        await b.merge();
        a.exchange(b);
        await a.merge();
      }
      final onB = await b.db.db.query('attachments');
      expect(onB, hasLength(1));
      expect(onB.single['path'], isNull);
      final onA = await a.db.db.query('attachments');
      expect(onA.single['path'], outside);
      await a.db.close();
      await b.db.close();
    });
  });

  group('5. filtri delle esclusioni dalla sincronizzazione', () {
    test('espressioni dal costo alto: testo semplice, nessun blocco', () {
      final evil = [
        '((a+))+\$',
        '(a{1,})+\$',
        '(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)(a|a)b',
        '${'a?' * 30}${'a' * 30}',
        r'\d*\d*\d*\d*x',
        '.*.*.*.*.*x',
        r'(a)\1',
        'x' * 300,
      ];
      for (final e in evil) {
        expect(ExclusionFilter.isSafePattern(e), isFalse, reason: e);
      }
      final sw = Stopwatch()..start();
      final f = ExclusionFilter(evil);
      expect(f.isExcluded(['${'a' * 40}!', '1' * 60, 'Analisi matematica']), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(1000));
    });

    test('le caselle e i filtri normali restano espressioni', () {
      for (final g in kAllPresetPatterns) {
        expect(ExclusionFilter.isSafePattern(g), isTrue, reason: g);
      }
      final f = ExclusionFilter([
        r'^lab(oratorio)?\s*\d*$',
        '(inglese|english)',
        r'tirocinio|\btesi\b',
      ]);
      expect(f.isExcluded(['Laboratorio 2']), isTrue);
      expect(f.isExcluded(['English B2']), isTrue);
      expect(f.isExcluded(['Prova finale (tesi)']), isTrue);
      expect(f.isExcluded(['Analisi']), isFalse);
    });

    test('al massimo ${ExclusionFilter.maxPatterns} filtri', () {
      final f = ExclusionFilter([
        for (var i = 0; i < 500; i++) 'filtro$i',
        'analisi',
      ]);
      expect(f.isExcluded(['Analisi']), isFalse);
      expect(f.isExcluded(['filtro99']), isTrue);
    });
  });

  group('6. evidenziazioni dei PDF con «Libri e materiali»', () {
    test('la voce dei libri le toglie', () async {
      final tmp = await Directory.systemTemp.createTemp('sicurezza_g2_ev_');
      addTearDown(() => tmp.delete(recursive: true));
      final support = Directory(p.join(tmp.path, 'supporto'))..createSync();
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final appunti = Directory(p.join(tmp.path, 'appunti'))..createSync();
      final notes = NotesStore(settings, root: () async => appunti);
      final s = AppServices(
        db,
        notes: notes,
        onedrive: OneDriveService(
          settings,
          notes,
          secrets: MemoryCloudSecrets(),
          stateDir: () async => support,
          deviceName: 'PC',
        ),
        googleDrive: GoogleDriveService(
          settings,
          notes,
          secrets: MemoryCloudSecrets(),
          stateDir: () async => support,
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
      final hl = File(p.join(support.path, 'evidenziazioni', 'a1.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('[]');
      final other = File(p.join(support.path, 'whisper', 'modello.bin'))
        ..createSync(recursive: true);
      final eraser = DataEraser(
        s,
        supportDir: () async => support,
        cacheDirs: () async => const [],
        wipeSecrets: () async {},
        clearPrefs: () async {},
        tempDir: () => Directory(p.join(tmp.path, 'temp'))..createSync(),
        syncWait: Duration.zero,
      );
      await eraser.run({EraseItem.books});
      expect(hl.existsSync(), isFalse);
      expect(other.existsSync(), isTrue);
      expect(EraseItem.books.label, contains('evidenziazioni'));
    });
  });

  group('7. cartelle temporanee: solo quelle dell\'app', () {
    test('nomi nuovi con «uninotes_», vecchi solo con la parte casuale di '
        'Dart', () {
      for (final n in [
        'uninotes_whisper_1a2b3c4d',
        'uninotes_parakeet_x',
        'whisper_1a2b3c4d',
        'whisper_live_4603425',
        'whisper_chunks_Ab12Cd',
        'parakeet_9f',
      ]) {
        expect(isAppTempWorkDir(n), isTrue, reason: n);
      }
      for (final n in [
        'whisper_modelli',
        'whisper_choice_1a2b3c',
        'parakeet_cache_di_altri',
        'whisper_',
        'openai_whisper_1a2b',
      ]) {
        expect(isAppTempWorkDir(n), isFalse, reason: n);
      }
    });

    test('la pulizia lascia le cartelle di altri programmi', () async {
      final temp = await Directory.systemTemp.createTemp('sicurezza_g2_t_');
      addTearDown(() => temp.delete(recursive: true));
      Directory d(String n) =>
          Directory(p.join(temp.path, n))..createSync(recursive: true);
      final ours = d('whisper_1a2b3c4d');
      final newer = d('uninotes_whisper_live_77');
      final theirs = d('whisper_modelli_di_altri');
      await clearTempFiles(temp: temp, allWork: true);
      expect(ours.existsSync(), isFalse);
      expect(newer.existsSync(), isFalse);
      expect(theirs.existsSync(), isTrue);
    });

    test('ogni cartella di lavoro creata dall\'app ha il prefisso uninotes_',
        () {
      final bad = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final text = f.readAsStringSync();
        for (final m in RegExp(r"createTemp\(\s*'([^']*)'").allMatches(text)) {
          if (!m.group(1)!.startsWith('uninotes_')) {
            bad.add('${f.path}: ${m.group(1)}');
          }
        }
      }
      expect(bad, isEmpty);
    });
  });

  group('8. spazio libero su Windows', () {
    test('l\'unità passa come variabile d\'ambiente, non nel comando', () {
      expect(
        FileDownloader.freeSpaceScript,
        contains('\$env:${FileDownloader.freeSpaceVariable}'),
      );
      final src = File(
        'lib/core/services/file_downloader.dart',
      ).readAsStringSync();
      expect(src, isNot(contains("DriveInfo]::new('\$root')")));
      expect(src, contains('environment: {freeSpaceVariable: root}'));
    });

    test(
      'il comando risponde con un numero',
      () async {
        final n = await FileDownloader.defaultFreeSpace(Directory.systemTemp);
        expect(n, isNotNull);
        expect(n!, greaterThan(0));
      },
      skip: !Platform.isWindows,
    );
  });

  group('9. lettore multimediale: scalette al posto dell\'audio', () {
    test('scalette e testi riconosciuti, audio e video veri no', () {
      for (final t in [
        '#EXTM3U\n#EXTINF:1,x\nhttps://esempio.invalid/a.mp3\n',
        '[playlist]\nFile1=http://esempio.invalid/x\n',
        '# mpv EDL v0\nhttps://esempio.invalid/a.mp3\n',
        'FILE "http://esempio.invalid/a.wav" WAVE\n',
        '<?xml version="1.0"?><playlist/>',
        'https://esempio.invalid/stream\n',
        'ffconcat version 1.0\nfile http://esempio.invalid/a\n',
      ]) {
        expect(MediaGuard.looksLikeText(t.codeUnits), isTrue, reason: t);
      }
      for (final head in [
        [0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00, 0x57, 0x41],
        [0x49, 0x44, 0x33, 0x03, 0x00, 0x00, 0x00, 0x00, 0x0f, 0x76],
        [0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70, 0x4d, 0x34],
        [0x4f, 0x67, 0x67, 0x53, 0x00, 0x02],
        [0x1a, 0x45, 0xdf, 0xa3],
        <int>[],
      ]) {
        expect(MediaGuard.looksLikeText(head), isFalse, reason: '$head');
      }
    });

    test('il file si controlla prima di aprirlo', () async {
      final tmp = await Directory.systemTemp.createTemp('sicurezza_g2_m_');
      addTearDown(() => tmp.delete(recursive: true));
      final fake = File(p.join(tmp.path, 'lezione.m4a'))
        ..writeAsStringSync('#EXTM3U\nhttps://esempio.invalid/a.mp3\n');
      final real = File(p.join(tmp.path, 'vera.wav'))
        ..writeAsBytesSync([0x52, 0x49, 0x46, 0x46, 0x24, 0, 0, 0, 0x57]);
      expect(await MediaGuard.unsafeReason(fake.path), isNotNull);
      expect(await MediaGuard.unsafeReason(real.path), isNull);
      expect(await MediaGuard.unsafeReason(p.join(tmp.path, 'no.mp3')), isNull);
      for (final f in [
        'lib/features/reader/views/media_view.dart',
        'lib/features/notes/recording_player_screen.dart',
      ]) {
        final src = File(f).readAsStringSync();
        final guard = src.indexOf('MediaGuard.unsafeReason(');
        expect(guard, greaterThan(0), reason: f);
        // (lettore protetto dal giro 4, sicurezza_g4_app_test.dart)
        expect(
          guard,
          lessThan(src.indexOf('= await MediaGuard.newPlayer();')),
          reason: f,
        );
      }
    });
  });

  group('10. «Apri in OneNote»', () {
    test('solo onenote: seguito da https, e solo dalla sua funzione', () {
      for (final ok in [
        'onenote:https://d.docs.live.net/abc/Documenti/Corso/Sezione.one'
            '#Pagina&section-id={1A2B}&page-id={3C4D}&end',
        'ONENOTE:https://contoso-my.sharepoint.com/personal/x/Blocco',
      ]) {
        expect(ExternalLauncher.isOneNoteClientUrl(ok), isTrue, reason: ok);
      }
      for (final no in [
        'onenote:file:///C:/Windows/System32/calc.exe',
        r'onenote:\\server\share\x.one',
        'onenote:http://esempio.invalid/x',
        'onenote:https://',
        'onenote:https://a.b/x y',
        'https://www.onenote.com/x',
      ]) {
        expect(ExternalLauncher.isOneNoteClientUrl(no), isFalse, reason: no);
      }
      expect(ExternalLauncher.allowedSchemes, isNot(contains('onenote')));
      final screen = File(
        'lib/features/cloud/onenote_screen.dart',
      ).readAsStringSync();
      expect(screen, contains('ExternalLauncher.openOneNote('));
      final uses = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is File &&
            f.path.endsWith('.dart') &&
            f.readAsStringSync().contains('ExternalLauncher.openOneNote(')) {
          uses.add(p.basename(f.path));
        }
      }
      expect(uses, ['onenote_screen.dart']);
    });
  });

  group('11. pulizia della chiave di Gemini', () {
    test('portachiavi che non risponde: si riprova al prossimo avvio', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final s = AppServices(db);
      await s.removeLegacyGemini(secrets: _ThrowingSecrets());
      expect(await s.settings.get(SettingKeys.legacyGeminiRemoved), isNull);
      final ok = MemoryCloudSecrets()..values['gemini.apiKey'] = 'AIza-x';
      await s.removeLegacyGemini(secrets: ok);
      expect(ok.values, isEmpty);
      expect(await s.settings.get(SettingKeys.legacyGeminiRemoved), '1');
    });
  });

  group('12. script aperti con il programma predefinito', () {
    tearDown(
      () => ExternalLauncher.platform = () => defaultTargetPlatform,
    );

    test('sul PC e sul Mac «Apri» no, «Apri con…» sì; sul telefono sì', () {
      for (final t in [TargetPlatform.windows, TargetPlatform.macOS]) {
        ExternalLauncher.platform = () => t;
        for (final f in [
          r'C:\Corsi\Python\esercizio.py',
          '/Users/x/Corsi/esercizio.pyw',
          '/Users/x/Corsi/guida.chm',
          '/Users/x/Corsi/script.rb',
          '/Users/x/Corsi/esercizio.py. ',
        ]) {
          expect(ExternalLauncher.unsafePathReason(f), isNotNull, reason: f);
          expect(
            ExternalLauncher.unsafePathReason(f, explicitChoice: true),
            isNull,
            reason: f,
          );
        }
      }
      ExternalLauncher.platform = () => TargetPlatform.android;
      expect(
        ExternalLauncher.unsafePathReason('/data/x/esercizio.py'),
        isNull,
      );
      // i programmi veri restano bloccati anche con «Apri con…»
      for (final t in [TargetPlatform.windows, TargetPlatform.android]) {
        ExternalLauncher.platform = () => t;
        for (final f in [
          r'C:\x\avvio.wsb',
          '/Users/x/a.tool',
          '/Users/x/a.fileloc',
          '/home/x/a.AppImage',
          r'C:\x\setup.exe',
        ]) {
          expect(
            ExternalLauncher.unsafePathReason(f, explicitChoice: true),
            isNotNull,
            reason: f,
          );
        }
      }
    });
  });

  group('13. programmi di Windows', () {
    test('cartella di Windows solo come percorso completo locale', () {
      expect(WindowsTools.isLocalAbsolute(r'C:\Windows'), isTrue);
      expect(WindowsTools.isLocalAbsolute('D:/Windows'), isTrue);
      for (final v in ['.', r'Windows', r'\\server\Windows', r'C:Windows', '']) {
        expect(WindowsTools.isLocalAbsolute(v), isFalse, reason: v);
      }
    });
  });
}

class _ThrowingSecrets implements CloudSecrets {
  @override
  Future<String?> read(String key) async => throw StateError('bloccato');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('bloccato');
  @override
  Future<void> delete(String key) async => throw StateError('bloccato');
}
