import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/database/schema.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/install_check.dart';
import 'package:university_notes/core/services/legacy_data.dart';
import 'package:university_notes/core/services/nudges.dart';
import 'package:university_notes/core/services/portable_path.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/cloud/onedrive_sync.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/features/notes/recorder/recording_save.dart';
import 'package:university_notes/features/notes/recorder/recording_session.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_drive.dart';
import 'support/fake_reminders.dart';

/// Quarto giro della caccia ai crash, aggiornamento dall'app: cosa le versioni
/// precedenti (dal 4 ottobre 2026 in poi) lasciavano sul dispositivo —
/// impostazioni con chiavi tolte o valori di altro tipo, cartelle e file di
/// formati vecchi, stato della sincronizzazione, backup esportati, cache del
/// catalogo, modelli, registrazioni rimaste a metà — e che la versione
/// attuale deve leggere senza errori e senza perdere dati.
///
/// Ricostruito dalla storia di git (sola lettura); l'elenco delle forme
/// vecchie è in docs/avvio_ed_errori.md («Aggiornamento dalle versioni
/// precedenti»).

/// Chiavi delle impostazioni scritte da versioni che oggi non le leggono più
/// (tolte, rinominate, o di funzioni eliminate: gruppi degli studenti,
/// chiave di Gemini e Antigravity, mappa offline, percorsi per ateneo…).
const _chiaviStoriche = [
  'agy_path',
  'gemini_model',
  'gemini_api_model',
  'legacy_gemini_removed',
  'claude_connected',
  'links_community_base_url',
  'links_community_course',
  'links_community_university',
  'links_community_user_links',
  'links_community_year',
  'links_gemini_mode',
  'gemini_transcript_speakers',
  'gemini_transcript_timestamps',
  'books_roots',
  'materials_root_polito',
  'materials_root_unito',
  'unito_calendar_link',
  'unito_channel_teachers',
  'map_pmtiles_path',
  'seed_imported_version',
  'last_sync_at',
  'last_sync_outcome',
  'last_timetable_sync',
  'last_uni_sync_import',
  'display_name',
  'surname_initial',
  'sha256_corsi',
  'onedrive_backup',
  'onedrive_folder',
  'onedrive_interval_minutes',
  'onedrive_last_sync_at',
  'onedrive_scopes',
  'exclusion_patterns',
  'whisper_model',
  'whisper_cli_path',
  'appunti_root',
  'update_url',
  'catalog_base_url',
  'theme_mode',
];

/// Forme di valore che una versione precedente poteva aver scritto: un
/// numero dove oggi c'è un elenco, JSON di un'altra struttura, testo dove si
/// aspetta una data, numeri enormi o infiniti, valori vuoti.
const _valori = <String>[
  '',
  ' ',
  '1',
  '0',
  '-1',
  'true',
  'false',
  'null',
  '1.5',
  '1e999',
  '99999999999999999999',
  'x',
  '[]',
  '{}',
  '[1,2,3]',
  '{"a":1}',
  '["a","b"]',
  '{"minuti":"x","pause":5,"ogni":null}',
  '2020-02-30',
  '0000-00-00',
  'nope,1,2,x',
  'recordings,notes,-data,boh',
];

/// Chiavi di impostazione (scritte tra apici nel codice) che compaiono nel
/// sorgente dell'app: ogni stringa in minuscolo con un trattino basso, un
/// punto o i due punti. Un insieme più grande di quello vero, ma innocuo.
Set<String> _chiaviDelCodice() {
  final out = <String>{};
  final re = RegExp(r"'([a-z][a-z0-9]*(?:[_.:][a-z0-9]+)+)(?:[_:]?)'");
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    for (final m in re.allMatches(e.readAsStringSync())) {
      final k = m.group(1)!;
      if (k.length >= 5 && k.length <= 60) out.add(k);
    }
  }
  return out;
}

class _BrokenSecrets implements CloudSecrets {
  @override
  Future<String?> read(String key) async =>
      throw StateError('portachiavi non disponibile');
  @override
  Future<void> write(String key, String value) async =>
      throw StateError('portachiavi non disponibile');
  @override
  Future<void> delete(String key) async =>
      throw StateError('portachiavi non disponibile');
}

class _FakeOAuth extends LoopbackOAuth {
  _FakeOAuth()
    : super(
        providerName: 'Microsoft',
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
  Future<OAuthTokens> refresh(String refreshToken) async => OAuthTokens(
    accessToken: 'a',
    expiresAt: DateTime.now().add(const Duration(hours: 1)),
    refreshToken: refreshToken,
  );
}

Future<AppServices> _services({
  FakeNotificationPlatform? platform,
  FakeCalendarBackend? backend,
}) async {
  final db = await AppDatabase.openInMemory();
  return AppServices(
    db,
    reminders: (s) => RemindersService(
      s,
      platform: platform ?? FakeNotificationPlatform(),
      calendarBackend: backend ?? FakeCalendarBackend(),
      widgets: FakeHomeWidgets(),
      platformName: 'android',
      isRecording: () => false,
    ),
  );
}

Future<void> _settle(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await tester.pump();
  }
}

Future<void> _pump(WidgetTester tester, AppServices s, Widget home) async {
  await tester.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('it', 'IT'),
        supportedLocales: const [Locale('it', 'IT')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: home,
      ),
    ),
  );
  await _settle(tester);
}

/// Gli overflow di layout sono un difetto d'aspetto, non un crash.
void Function(FlutterErrorDetails)? _previous;

void _collect() {
  final previous = _previous = FlutterError.onError;
  FlutterError.onError = (d) {
    if (d.toString().contains('overflowed by')) return;
    previous?.call(d);
  };
}

void _release() => FlutterError.onError = _previous;

void _noCrash(WidgetTester tester, String reason) {
  final e = tester.takeException();
  if (e != null) {
    fail('$reason: ${e is FlutterError ? e.toStringDeep() : e}');
  }
}

Future<void> _allSettings(AppServices s, String value, Set<String> keys) async {
  await s.database.db.delete('app_settings');
  final batch = s.database.db.batch();
  for (final k in keys) {
    batch.insert('app_settings', {'key': k, 'value': value});
  }
  await batch.commit(noResult: true);
}

const _steps = [
  kSchemaV1,
  kMigrationV2,
  kMigrationV3,
  kMigrationV4,
  kMigrationV5,
  kMigrationV6,
  kMigrationV7,
  kMigrationV8,
  kMigrationV9,
  kMigrationV10,
  kMigrationV11,
  kMigrationV12,
  kMigrationV13,
];

/// Database di una versione dello schema con una riga per tabella
/// personale (valori finti per le colonne obbligatorie).
Future<String> _oldDatabase(Directory tmp, int version) async {
  final path = p.join(tmp.path, 'v$version.db');
  final db = await databaseFactoryFfi.openDatabase(
    path,
    options: OpenDatabaseOptions(
      version: version,
      onCreate: (db, _) async {
        for (var i = 0; i < version; i++) {
          for (final stmt in _steps[i]) {
            await db.execute(stmt);
          }
        }
      },
    ),
  );
  for (final t in kPersonalTables) {
    final cols = await db.rawQuery('PRAGMA table_info($t)');
    if (cols.isEmpty) continue;
    final row = <String, Object?>{};
    for (final c in cols) {
      final name = '${c['name']}';
      final type = '${c['type']}'.toUpperCase();
      final needed = c['notnull'] == 1 && c['dflt_value'] == null;
      if (!needed && !name.endsWith('_id')) continue;
      if (name == 'id' && type.contains('INT')) continue;
      row[name] = name == 'key'
          ? 'chiave_$t'
          : type.contains('INT')
          ? 1
          : type.contains('REAL')
          ? 1.0
          : name.contains('date') || name.contains('start') || name == 'at'
          ? '2026-10-05'
          : 'x';
    }
    if (t == 'app_settings') row['value'] = '1';
    if (t == 'profile') row['id'] = 1;
    try {
      await db.insert(t, row);
    } on DatabaseException catch (e) {
      fail('riga di prova di $t (versione $version): $e');
    }
  }
  await db.close();
  return path;
}


void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('uninotes_r4_');
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('1. impostazioni di versioni precedenti (chiavi e valori di altro tipo)',
      () {
    test('ogni chiave del codice e ogni chiave storica, con ogni forma di '
        'valore: nessun lettore di impostazioni lancia', () async {
      final keys = {..._chiaviDelCodice(), ..._chiaviStoriche};
      expect(keys.length, greaterThan(100));
      final s = await _services();
      addTearDown(s.database.close);
      for (final v in _valori) {
        await _allSettings(s, v, keys);
        final reason = 'valore «$v»';
        // aspetto, suoni, tema
        s.display.value = DisplayPrefs.parse(
          contrast: await s.settings.get(DisplayKeys.contrast),
          textSize: await s.settings.get(DisplayKeys.textSize),
          reduceMotion: await s.settings.get(DisplayKeys.reduceMotion),
        );
        await s.feedback.load(s.settings);
        parseThemeMode(await s.settings.get(SettingKeys.themeMode));
        // esclusioni, notifiche, profilo, Focus, inviti
        await s.settings.exclusionPatterns();
        await NotificationPrefs.load(s.settings);
        await s.loadProfile();
        await s.focus.load();
        await Nudges(s).registerOpen();
        // sincronizzazione: caselle, intervallo, cartella, ultimo esito
        for (final c in s.clouds) {
          await c.scopes();
          await c.folder();
          await c.booksLocalOnly();
          await c.settings.get(c.intervalKey);
        }
        // catalogo e Whisper
        await s.catalog.baseUrl();
        await s.whisper.selectedModelId();
        await s.whisper.pickModel({'tiny', 'base'});
        expect(await s.settings.allSettings(), isNotEmpty, reason: reason);
      }
    });

    test('i promemoria partono con ogni forma di valore nelle impostazioni '
        'delle notifiche e del calendario', () async {
      final keys = {..._chiaviDelCodice(), ..._chiaviStoriche};
      for (final v in _valori) {
        final platform = FakeNotificationPlatform();
        final backend = FakeCalendarBackend();
        final s = await _services(platform: platform, backend: backend);
        final c = await s.courses.insert(const Course(name: 'Analisi I'));
        expect(c, isPositive);
        await _allSettings(s, v, keys);
        try {
          await s.reminders.start();
          await s.reminders.refresh();
        } finally {
          await s.database.close();
        }
      }
    });

    testWidgets('le schermate principali si aprono con impostazioni di forma '
        'vecchia o sbagliata', (tester) async {
      _collect();
      addTearDown(_release);
      final keys = {..._chiaviDelCodice(), ..._chiaviStoriche};
      for (final v in ['', '1', 'x', '{"a":1}', '[1,2,3]', '1e999']) {
        final s = await tester.runAsync(_services) as AppServices;
        await tester.runAsync(() async {
          await s.courses.insert(const Course(name: 'Analisi I'));
          await _allSettings(s, v, keys);
        });
        for (final d in kDestinations) {
          await _pump(tester, s, Builder(builder: d.builder));
          _noCrash(tester, '«${d.label}» con impostazioni «$v»');
        }
        await tester.pumpWidget(const SizedBox());
        await _settle(tester, 10);
        await tester.runAsync(s.database.close);
      }
    });
  });

  group('2. Windows: cartella dei dati con il nome vecchio (University Notes)',
      () {
    Future<(Directory, Directory)> dirs() async {
      final roaming = Directory(p.join(tmp.path, 'Roaming'));
      final now = Directory(p.join(roaming.path, 'UniNotes', 'UniNotes'));
      final old = Directory(
        p.join(roaming.path, 'University Notes', 'University Notes'),
      );
      await now.create(recursive: true);
      await old.create(recursive: true);
      return (now, old);
    }

    Future<void> oldInstall(Directory old) async {
      final db = await AppDatabase.open(
        path: p.join(old.path, AppDatabase.fileName),
      );
      await db.db.insert('courses', {'name': 'Analisi 1'});
      await db.close();
      for (final f in [
        'libri/dispensa.pdf',
        'whisper/models/ggml-small.bin',
        'evidenziazioni/abc.json',
        'dati_sync_base.json.gz',
        'onedrive_sync_state.json',
        'flutter_secure_storage.dat',
        'shared_preferences.json',
      ]) {
        final file = File(p.join(old.path, f));
        await file.parent.create(recursive: true);
        await file.writeAsString('dati $f');
      }
    }

    test('la cartella vecchia si ricava da quella attuale', () {
      final now = Directory(p.join('x', 'Roaming', 'UniNotes', 'UniNotes'));
      expect(
        LegacyData.legacyDirFor(now).path,
        p.join('x', 'Roaming', 'University Notes', 'University Notes'),
      );
    });

    test('database, libri, modelli e stato della sincronizzazione passano '
        'alla cartella nuova; le credenziali no', () async {
      final (now, old) = await dirs();
      await oldInstall(old);
      await File(p.join(now.path, 'error_log.txt')).writeAsString('log');
      final n = await LegacyData.migrateWindowsSupportDir(
        current: now,
        legacy: old,
        windows: true,
      );
      expect(n, 6);
      final db = await AppDatabase.open(
        path: p.join(now.path, AppDatabase.fileName),
      );
      expect((await db.db.query('courses')).single['name'], 'Analisi 1');
      await db.close();
      for (final f in [
        'libri/dispensa.pdf',
        'whisper/models/ggml-small.bin',
        'evidenziazioni/abc.json',
        'dati_sync_base.json.gz',
        'onedrive_sync_state.json',
        'error_log.txt',
      ]) {
        expect(File(p.join(now.path, f)).existsSync(), isTrue, reason: f);
      }
      expect(
        File(p.join(now.path, 'flutter_secure_storage.dat')).existsSync(),
        isFalse,
      );
      expect(File(p.join(now.path, 'shared_preferences.json')).existsSync(),
          isFalse);
      // di nuovo: niente da fare
      expect(
        await LegacyData.migrateWindowsSupportDir(
          current: now,
          legacy: old,
          windows: true,
        ),
        0,
      );
    });

    test('con un database già nella cartella nuova non si tocca nulla',
        () async {
      final (now, old) = await dirs();
      await oldInstall(old);
      final fresh = await AppDatabase.open(
        path: p.join(now.path, AppDatabase.fileName),
      );
      await fresh.db.insert('courses', {'name': 'Fisica'});
      await fresh.close();
      expect(
        await LegacyData.migrateWindowsSupportDir(
          current: now,
          legacy: old,
          windows: true,
        ),
        0,
      );
      expect(File(p.join(old.path, 'libri', 'dispensa.pdf')).existsSync(),
          isTrue);
      expect(Directory(p.join(now.path, 'libri')).existsSync(), isFalse);
    });

    test('senza cartella vecchia, con un file di database vuoto, non su '
        'Windows: niente e nessun errore', () async {
      final (now, old) = await dirs();
      expect(
        await LegacyData.migrateWindowsSupportDir(
          current: now,
          legacy: Directory(p.join(tmp.path, 'non_esiste')),
          windows: true,
        ),
        0,
      );
      await File(p.join(old.path, AppDatabase.fileName)).writeAsBytes([]);
      expect(
        await LegacyData.migrateWindowsSupportDir(
          current: now,
          legacy: old,
          windows: true,
        ),
        0,
      );
      await oldInstall(old);
      expect(
        await LegacyData.migrateWindowsSupportDir(
          current: now,
          legacy: old,
          windows: false,
        ),
        0,
      );
    });

    test('dopo il passaggio il controllo dell\'installazione non vede una '
        'nuova installazione (niente credenziali cancellate)', () async {
      final (now, old) = await dirs();
      await oldInstall(old);
      SharedPreferences.setMockInitialValues({});
      var wiped = 0;
      InstallCheck check() => InstallCheck(
        version: '2026.9.0',
        databaseExists: () async =>
            File(p.join(now.path, AppDatabase.fileName)).exists(),
        wipeSecrets: () async => wiped++,
        sharedNotes: () async => const [],
        identity: () async => null,
      );
      await LegacyData.migrateWindowsSupportDir(
        current: now,
        legacy: old,
        windows: true,
      );
      final st = await check().run();
      expect(st.fresh, isFalse);
      expect(st.needsAnswer, isFalse);
      expect(wiped, 0);
    });
  });

  group('3. appunti e registrazioni nel formato delle versioni precedenti', () {
    late AppServices s;
    late NotesStore store;
    late Directory root;
    const course = Course(name: 'Analisi I');

    setUp(() async {
      s = AppServices(await AppDatabase.openInMemory());
      root = Directory(p.join(tmp.path, 'Corsi'))..createSync(recursive: true);
      store = NotesStore(s.settings, root: () async => root);
    });
    tearDown(() => s.database.close());

    File put(String rel, [String text = 'x']) {
      final f = File(p.join(root.path, NotesStore.folderName(course), rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(text);
      return f;
    }

    test('la cartella «Claude» di prima diventa «AI» con tutti i file',
        () async {
      put('Claude/risposta.md', 'ciao');
      put('Registrazioni/2026-10-05 08-30 Lezione.flac');
      final files = await store.list(course);
      expect(files[NoteFolder.ai]!.map((f) => f.name), ['risposta']);
      expect(files[NoteFolder.recordings], hasLength(1));
      expect(
        Directory(
          p.join(root.path, NotesStore.folderName(course), 'Claude'),
        ).existsSync(),
        isFalse,
      );
    });

    test('«Claude» e «AI» insieme (sincronizzazione con un dispositivo '
        'rimasto alla versione vecchia): i file di «Claude» si vedono, '
        'nessuno si sovrascrive', () async {
      put('AI/risposta.md', 'nuova');
      put('Claude/risposta.md', 'vecchia');
      put('Claude/altra.md', 'altra');
      put('Claude/sotto/x.md', 'x');
      final files = await store.list(course);
      expect(
        files[NoteFolder.ai]!.map((f) => f.name).toList()..sort(),
        ['altra', 'risposta', 'risposta (2)'],
      );
      final base = p.join(root.path, NotesStore.folderName(course));
      expect(File(p.join(base, 'AI', 'risposta.md')).readAsStringSync(),
          'nuova');
      expect(File(p.join(base, 'AI', 'risposta (2).md')).readAsStringSync(),
          'vecchia');
      // la sottocartella si sposta intera: «Claude» è vuota e sparisce
      expect(File(p.join(base, 'AI', 'sotto', 'x.md')).existsSync(), isTrue);
      expect(Directory(p.join(base, 'Claude')).existsSync(), isFalse);
      // un secondo accesso non cambia nulla
      expect((await store.list(course))[NoteFolder.ai], hasLength(3));
      expect(await store.count(course), 3);
    });

    test('registrazioni di prima (.flac e .wav senza dati accanto), dati '
        'accanto con solo parte dei campi, residui «.part» e il vecchio '
        'manifesto: l\'elenco, il conteggio e i dati si leggono', () async {
      put('Registrazioni/2026-10-05 08-30 Lezione.flac');
      put('Registrazioni/2026-10-06 08-30 Lezione.wav');
      // dati accanto scritti dalla prima versione dei dati (solo la versione)
      put('Registrazioni/2026-10-06 08-30 Lezione.json', '{"versione":1}');
      put('Registrazioni/2026-10-07 08-30 Lezione.m4a');
      put(
        'Registrazioni/2026-10-07 08-30 Lezione.json',
        '{"versione":1,"durataMs":65000,"segnalibri":[{"ms":1000}],'
            '"segmenti":[{"s":0,"t":"Buongiorno"}]}',
      );
      put('Registrazioni/2026-10-08 08-30 Lezione.m4a.part');
      put('Registrazioni/2026-10-08 08-30 Lezione.json.part', '{"vers');
      put('.appunti.json', '{"corsi":[]}');
      put('Trascrizioni/2026-10-07 08-30 Lezione.md', '# Trascrizione');
      final files = await store.list(course);
      expect(files[NoteFolder.recordings]!.map((f) => f.name).toList(), [
        '2026-10-07 08-30 Lezione',
        '2026-10-06 08-30 Lezione',
        '2026-10-05 08-30 Lezione',
      ]);
      expect(await store.count(course), 4);
      final audio = files[NoteFolder.recordings]!.first;
      final meta = await RecordingMeta.load(audio.file.path);
      expect(meta.duration, const Duration(seconds: 65));
      expect(meta.bookmarks.single.at, const Duration(seconds: 1));
      expect(meta.segments.single.text, 'Buongiorno');
      expect((await RecordingMeta.load(
        files[NoteFolder.recordings]![1].file.path,
      ))
          .isEmpty, isTrue);
      expect(await store.companion(course, audio, NoteFolder.transcripts),
          isNotNull);
      // rinominare una lezione di prima porta con sé trascrizione e dati
      final done = await store.rename(course, audio, 'Analisi - limiti');
      expect(done.length, 3);
    });
  });

  group('4. «Eliminati di recente» e cestini della sincronizzazione di prima',
      () {
    test('voci scritte dalle prime versioni (senza corso, senza file, '
        'illeggibili): si elencano, si ripristinano, scadono senza errori',
        () async {
      final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
      final bin = Directory(p.join(root.path, '.eliminati'))..createSync();
      final now = DateTime(2026, 11, 20, 12);
      Directory entry(String id, [Object? info]) {
        final d = Directory(p.join(bin.path, id))..createSync();
        if (info != null) {
          File(p.join(d.path, 'info.json')).writeAsStringSync(
            info is String ? info : jsonEncode(info),
          );
        }
        return d;
      }

      final origin = p.join(root.path, 'Analisi', 'Registrazioni', 'a.m4a');
      final one = entry('1', {
        'titolo': 'Lezione',
        'eliminato': DateTime(2026, 11, 10).toIso8601String(),
        'file': [
          {'nome': 'a.m4a', 'origine': origin},
        ],
      });
      File(p.join(one.path, 'a.m4a')).writeAsStringSync('audio');
      // senza elenco dei file e con una voce rovinata
      entry('2', {
        'titolo': 'Nota',
        'eliminato': DateTime(2026, 11, 11).toIso8601String(),
      });
      entry('3', {
        'titolo': 'Rotta',
        'eliminato': DateTime(2026, 11, 11).toIso8601String(),
        'file': ['x', 5, {'nome': 3}],
      });
      entry('4', '{non json');
      entry('5', '[]');
      entry('6'); // cartella senza dati
      // vecchia e già scaduta
      final old = entry('7', {
        'titolo': 'Vecchia',
        'eliminato': DateTime(2026, 9, 1).toIso8601String(),
      });
      File(p.join(old.path, 'v.md')).writeAsStringSync('v');
      // cestini di OneDrive e Google Drive dentro la cartella degli appunti
      Directory(p.join(root.path, '.cestino-onedrive', 'Analisi'))
          .createSync(recursive: true);
      Directory(p.join(root.path, '.cestino-googledrive')).createSync();

      final trash = RecycleBin(() async => root, now: () => now);
      final list = await trash.list();
      expect(list.map((e) => e.id).toSet(), {'1', '2', '3', '7'});
      final e1 = list.firstWhere((e) => e.id == '1');
      expect(e1.isAudio, isTrue);
      final back = await trash.restore(e1);
      expect(File(origin).readAsStringSync(), 'audio');
      expect(back.single.path, origin);
      // la pulizia annota ma non cancella subito (3 giorni di margine)
      await trash.purge();
      expect(old.existsSync(), isTrue);
      final later = RecycleBin(
        () async => root,
        now: () => now.add(const Duration(days: 4)),
      );
      expect(await later.purge(), 1);
      expect(old.existsSync(), isFalse);
    });
  });

  group('5. registrazioni in corso lasciate da versioni precedenti', () {
    late AppServices s;
    late Directory root, work;

    setUp(() async {
      final db = await AppDatabase.openInMemory();
      root = Directory(p.join(tmp.path, 'Documenti', 'UniNotes', 'Corsi'))
        ..createSync(recursive: true);
      work = Directory(p.join(tmp.path, 'registrazioni_in_corso'))
        ..createSync();
      s = AppServices(
        db,
        notes: NotesStore(SettingsRepository(db), root: () async => root),
      );
    });
    tearDown(() => s.database.close());

    /// Dati di lavoro scritti da una versione precedente: percorso assoluto
    /// della cartella di destinazione di allora.
    Future<File> legacy(String id, String targetDir, {Object? courseId}) async {
      final wav = File(p.join(work.path, '$id.wav'));
      await wav.writeAsBytes([
        ...wavHeader(sampleRate: 16000, channels: 1, dataLength: 0),
        ...Uint8List(32000),
      ]);
      await File(p.join(work.path, '$id.json')).writeAsString(
        jsonEncode({
          'cartella': targetDir,
          'nome': '2026-10-12 08-30 Lezione',
          'corso': 'Analisi I',
          'corsoId': ?courseId,
          'inizio': DateTime(2026, 10, 12, 8, 30).toIso8601String(),
          'frequenza': 16000,
          'canali': 1,
          'segnalibri': [
            {'ms': 1000, 'nota': 'definizione'},
          ],
          'segmenti': [
            {'s': 0, 'e': 900, 't': 'Buongiorno'},
          ],
        }),
      );
      return wav;
    }

    Future<List<File>> saved(Directory dir) async => [
      await for (final e in dir.list(recursive: true))
        if (e is File && NotesStore.audioExtensions.contains(p.extension(e.path))) e,
    ];

    test('cartella di destinazione di una cartella degli appunti precedente '
        '(esiste ancora, ma l\'app non la guarda): la registrazione va in '
        'quella attuale', () async {
      final id = await s.courses.insert(const Course(name: 'Analisi I'));
      final oldRoot = p.join(tmp.path, 'Appunti', 'Corsi', 'Analisi I',
          'Registrazioni');
      Directory(oldRoot).createSync(recursive: true);
      await legacy('registrazione_1', oldRoot, courseId: id);
      final found = await RecordingSession.orphans(work);
      expect(found, hasLength(1));
      final out = await recoverSession(s, found.single);
      expect(out, isNotNull);
      expect(p.isWithin(root.path, out!.path), isTrue, reason: out.path);
      expect(p.basename(p.dirname(out.path)), 'Registrazioni');
      expect(await saved(Directory(p.dirname(oldRoot))), isEmpty);
      // i segnalibri e il testo dal vivo arrivano insieme all'audio
      final meta = await RecordingMeta.load(out.path);
      expect(meta.bookmarks.single.note, 'definizione');
      expect(meta.segments.single.text, 'Buongiorno');
      // lavoro ripulito: nulla da recuperare al prossimo avvio
      expect(await RecordingSession.orphans(work), isEmpty);
    });

    test('percorso di destinazione che non si può creare (unità che non '
        'c\'è più): niente «Recupero non riuscito» a ogni avvio', () async {
      await s.courses.insert(const Course(name: 'Analisi I'));
      final blocco = File(p.join(tmp.path, 'blocco'))..writeAsStringSync('x');
      // (senza id del corso: lo si ritrova dal nome)
      await legacy(
        'registrazione_2',
        p.join(blocco.path, 'Appunti', 'Registrazioni'),
      );
      final found = await RecordingSession.orphans(work);
      final out = await recoverSession(s, found.single);
      expect(out, isNotNull);
      expect(p.isWithin(root.path, out!.path), isTrue);
      expect(await out.exists(), isTrue);
    });

    test('corso che non c\'è più: cartella col nome del corso nella '
        'cartella attuale, l\'audio non si perde', () async {
      await legacy(
        'registrazione_3',
        p.join(tmp.path, 'Z', 'Registrazioni'),
        courseId: 999,
      );
      final out = await recoverSession(
        s,
        (await RecordingSession.orphans(work)).single,
      );
      expect(p.isWithin(root.path, out!.path), isTrue);
      expect(out.path, contains('Analisi I'));
    });

    test('destinazione già nella cartella attuale: non cambia', () async {
      final id = await s.courses.insert(const Course(name: 'Analisi I'));
      final dir = p.join(root.path, 'Analisi I', 'Registrazioni');
      await legacy('registrazione_4', dir, courseId: id);
      final out = await recoverSession(
        s,
        (await RecordingSession.orphans(work)).single,
      );
      expect(p.dirname(out!.path), dir);
    });

    test('«Elimina» di una registrazione rimasta: la voce del cestino '
        'ripristina nella cartella attuale', () async {
      final id = await s.courses.insert(const Course(name: 'Analisi I'));
      await legacy(
        'registrazione_5',
        p.join(tmp.path, 'Appunti', 'Corsi', 'Analisi I', 'Registrazioni'),
        courseId: id,
      );
      final session = (await RecordingSession.orphans(work)).single;
      final entry = await trashSession(s, session);
      expect(entry, isNotNull);
      final back = await s.trash.restore(entry!);
      expect(back.any((f) => p.isWithin(root.path, f.path)), isTrue);
    });

    test('dati di lavoro illeggibili, di un\'altra forma o file estranei: '
        'si saltano e le altre registrazioni si recuperano', () async {
      await File(p.join(work.path, 'a.json')).writeAsString('{non json');
      await File(p.join(work.path, 'b.json')).writeAsString('[1,2]');
      await File(p.join(work.path, 'c.json')).writeAsString('{"cartella":5}');
      await File(p.join(work.path, 'd.json.part')).writeAsString('{"cart');
      await File(p.join(work.path, 'e.wav')).writeAsBytes([1, 2, 3]);
      await legacy('registrazione_6', p.join(root.path, 'X', 'Registrazioni'));
      final found = await RecordingSession.orphans(work);
      expect(found.map((e) => p.basename(e.wav.path)), [
        'registrazione_6.wav',
      ]);
    });
  });

  group('6. sincronizzazione: stato e cartella delle versioni precedenti', () {
    late AppDatabase db;
    late SettingsRepository settings;
    late FakeDrive drive;
    late MemoryCloudSecrets secrets;
    late Directory appunti, stato;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
      await settings.set('install_id', 't1');
      drive = FakeDrive();
      secrets = MemoryCloudSecrets();
      await secrets.write('onedrive.refreshToken', 'r');
      appunti = Directory(p.join(tmp.path, 'appunti'))..createSync();
      stato = Directory(p.join(tmp.path, 'stato'))..createSync();
    });
    tearDown(() => db.close());

    OneDriveService service() => OneDriveService(
      settings,
      NotesStore(settings, root: () async => appunti),
      secrets: secrets,
      transport: drive.call,
      oauthFactory: (_, _) => _FakeOAuth(),
      stateDir: () async => stato,
      builtInClientId: '1a2b3c4d-1111-2222-3333-444455556666',
      deviceName: 'PC',
    );

    test('cartella «University Notes» di prima, con un file di stato '
        'rovinato accanto: si continua con la stessa cartella, niente '
        'doppioni né conflitti', () async {
      final note = File(p.join(appunti.path, 'Analisi', 'a.md'))
        ..createSync(recursive: true);
      note.writeAsStringSync('limiti');
      // la versione di prima sincronizzava con la cartella predefinita
      // di allora e non salvava la scelta nelle impostazioni
      await settings.set('onedrive_folder', 'University Notes');
      var od = service();
      expect((await od.sync())!.uploaded, 1);
      final remote = drive.files.keys.toList();
      expect(remote.single, startsWith('University Notes/'));
      await settings.set('onedrive_folder', null);
      // file di stato di altre versioni o scritti a metà
      File(p.join(stato.path, 'onedrive_sync_000.json')).writeAsStringSync(
        '{"remoteFo',
      );
      File(p.join(stato.path, 'onedrive_sync_lista.json')).writeAsStringSync(
        '[1,2]',
      );
      File(p.join(stato.path, 'onedrive_sync_binario.json'))
          .writeAsBytesSync([0xff, 0xfe, 0x00, 0x80]);
      od = service();
      expect(await od.folder(), 'University Notes');
      final r = (await od.sync())!;
      expect(r.errors, isEmpty);
      expect(r.uploaded + r.downloaded + r.conflicts, 0);
      expect(drive.files.keys.toList(), remote);
      expect(note.readAsStringSync(), 'limiti');
    });

    test('rinominare la cartella con un file di stato rovinato: gli altri '
        'stati seguono la cartella (niente conflitti a ogni file)', () async {
      await settings.set('onedrive_folder', 'University Notes');
      File(p.join(appunti.path, 'Analisi', 'a.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('x');
      final od = service();
      await od.sync();
      File(p.join(stato.path, 'onedrive_sync_000.json')).writeAsStringSync(
        '{"remoteFo',
      );
      await od.moveSyncStates('University Notes', 'UniNotes');
      final moved = (await od.syncStates())
          .map((m) => m['remoteFolder'])
          .toSet();
      expect(moved, {'UniNotes/Corsi'});
    });

    test('file «onedrive_sync_state.json» della prima versione (una sola '
        'cartella, solo remoteFolder e files): lo stato vale ancora', () async {
      File(p.join(appunti.path, 'a.md')).writeAsStringSync('x');
      final graph = GraphClient(() async => 'token', transport: drive.call);
      OneDriveSync engine(File state) => OneDriveSync(
        graph: graph,
        localRoot: appunti,
        remoteFolder: 'University Notes',
        stateFile: state,
        deviceName: 'PC',
      );
      final current = File(p.join(stato.path, 'onedrive_sync_corsi.json'));
      expect((await engine(current).run()).uploaded, 1);
      final saved = jsonDecode(current.readAsStringSync()) as Map;
      final first = File(p.join(stato.path, 'onedrive_sync_state.json'))
        ..writeAsStringSync(
          jsonEncode({
            'remoteFolder': saved['remoteFolder'],
            'files': saved['files'],
          }),
        );
      final r = await engine(first).run();
      expect(r.changed, isFalse);
    });
  });

  group('7. backup .json esportati da versioni precedenti', () {
    for (var v = 1; v <= 13; v++) {
      test('copia del database della versione $v dello schema: il backup '
          'si legge e si ripristina nella versione attuale', () async {
        final json = await BackupService.jsonFromDatabaseFile(
          await _oldDatabase(tmp, v),
        );
        final map = jsonDecode(json) as Map<String, Object?>;
        map['schemaVersion'] = v;
        final db = await AppDatabase.openInMemory();
        addTearDown(db.close);
        final svc = BackupService(db);
        final text = jsonEncode(map);
        expect(svc.inspect(text).schemaVersion, v);
        final restored = await svc.importJson(text);
        expect(restored['courses'], 1);
        expect((await db.db.query('courses')), hasLength(1));
        // ancora esportabile e di nuovo ripristinabile
        final again = await BackupService(db).exportJson();
        expect((await svc.importJson(again))['courses'], 1);
      });
    }

    test('backup delle prime versioni (senza profilo e anni del piano): il '
        'percorso scelto ora non si cancella', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      await db.db.insert('profile', {
        'id': 1,
        'university_id': 'polito',
        'university_name': 'Politecnico',
        'degree_id': 'x',
        'degree_name': 'Informatica',
        'degree_type': 'L',
        'duration_years': 3,
        'current_year': 2,
        'reference_aa': '2026/2027',
      });
      await db.db.insert('plan_years', {
        'year': 2025,
        'academic_year': '2025/2026',
        'status': 'done',
      });
      final json = jsonEncode({
        'format': 'university-manager-backup',
        'version': 1,
        'schemaVersion': 5,
        'createdAt': '2026-10-04T12:00:00',
        'tables': {
          'courses': [
            {'id': 1, 'name': 'Analisi 1'},
          ],
          'app_settings': <Object?>[],
        },
      });
      final restored = await BackupService(db).importJson(json);
      expect(restored['courses'], 1);
      expect(await db.db.query('profile'), hasLength(1));
      expect(await db.db.query('plan_years'), hasLength(1));
    });

    test('impostazioni di versioni precedenti nel backup: quelle del '
        'dispositivo non si sovrascrivono, le altre tornano', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.set('appunti_root', 'C:/mia/cartella');
      await settings.set('onedrive_client_id', 'mio');
      final json = jsonEncode({
        'format': 'university-manager-backup',
        'version': 1,
        'schemaVersion': 5,
        'tables': {
          'app_settings': [
            {'key': 'appunti_root', 'value': 'D:/Appunti'},
            {'key': 'onedrive_client_id', 'value': 'altro'},
            {'key': 'agy_path', 'value': 'C:/agy.exe'},
            {'key': 'exclusion_patterns', 'value': '["inglese"]'},
            {'key': 'whisper_model', 'value': 'base.en'},
            {'key': 'theme_mode', 'value': 5},
          ],
        },
      });
      await BackupService(db).importJson(json);
      expect(await settings.get('appunti_root'), 'C:/mia/cartella');
      expect(await settings.get('onedrive_client_id'), 'mio');
      expect(await settings.get('agy_path'), isNull);
      expect(await settings.get('exclusion_patterns'), '["inglese"]');
      expect(await settings.get('theme_mode'), '5');
      expect(await settings.get('whisper_model'), 'base.en');
    });
  });

  group('8. cache del catalogo e data pack di formati precedenti', () {
    late AppDatabase db;
    late Directory cache;

    setUp(() async {
      db = await AppDatabase.openInMemory();
      cache = Directory(p.join(tmp.path, 'database_cache'))..createSync();
    });
    tearDown(() => db.close());

    File put(String rel, String text) {
      final f = File(p.join(cache.path, rel));
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(text);
      return f;
    }

    test('file comuni e registro di versioni precedenti (campi in più, in '
        'meno o di altro tipo): si leggono o si ignorano, mai un errore',
        () async {
      put(
        'meta.json',
        jsonEncode({
          'versione': 20261004,
          'community': 3,
          'atenei': {
            'polito': {'corsi': '12', 'community': 4, 'file': 5},
            'rotto': 7,
          },
        }),
      );
      put(
        'universita.json',
        jsonEncode({
          'universita': [
            {'id': 'polito', 'nome': 'Politecnico di Torino'},
            {'id': 5},
            'x',
          ],
          'conteggi': {'polito': 'molti'},
        }),
      );
      put('indice_corsi.json', jsonEncode({'corsi': [[1, 2], 'x', null]}));
      put('corsi_sostituiti.json', jsonEncode({'corsi': {'a': 5, 'b': {}}}));
      // registri scritti dalle versioni del 14 e del 19 ottobre
      for (final registro in [
        {'ateneo': 'polito', 'versione': 3, 'scaricato_il': 5},
        {'ateneo': 'polito', 'corso': 7, 'assenti': 'x'},
        {'sha256_corsi': 'abc'},
        [1, 2],
      ]) {
        put('ateneo.json', jsonEncode(registro));
        final catalog = CatalogService(
          SettingsRepository(db),
          fetcher: (u, {onProgress}) async =>
              throw const SocketException('offline'),
          assetLoader: (path) async => throw StateError('manca $path'),
          assetBytesLoader: (path) async => throw StateError('manca $path'),
          cacheDir: () async => cache,
        );
        await catalog.universita();
        await catalog.indiceCorsi();
        await catalog.corsiSostituiti();
        await catalog.localMeta();
        final d = await catalog.datiCorso('polito', 'c1');
        expect(d.corsi, isFalse);
        final r = await catalog.scaricaCorso('polito', 'c1');
        expect(r, isNotNull);
        await catalog.eliminaAltri('polito', 'c1');
      }
    });

    test('indirizzo del database salvato dalle versioni precedenti (il '
        'repository di sviluppo di allora): vale come predefinito', () async {
      final settings = SettingsRepository(db);
      final catalog = CatalogService(
        settings,
        fetcher: (u, {onProgress}) async =>
            throw const SocketException('offline'),
        cacheDir: () async => cache,
      );
      for (final old in [
        'https://raw.githubusercontent.com/Simo-Magnus/University_Notes/main/database',
        'https://raw.githubusercontent.com/simo-magnus/university_notes/main/database/',
        '  https://raw.githubusercontent.com/Simo-Magnus/University_Notes/main/database//  ',
      ]) {
        await settings.set('catalog_base_url', old);
        expect(await catalog.baseUrl(), kDefaultCatalogBaseUrl, reason: old);
      }
      await settings.set('catalog_base_url', 'https://esempio.it/db');
      expect(await catalog.baseUrl(), 'https://esempio.it/db');
      // salvare l'indirizzo predefinito non lo scrive nelle impostazioni
      await catalog.setBaseUrl(kDefaultCatalogBaseUrl);
      expect(await settings.get('catalog_base_url'), isNull);
    });

    test('cartelle di prima (corsi, moduli, gruppi degli studenti, altri '
        'corsi e atenei in per_corso): si tolgono scegliendo un corso, il '
        'corso scelto resta', () async {
      put('corsi/polito.json', '{}');
      put('moduli/polito.json', '{}');
      put('community/polito.json', '{}');
      put('per_corso/polito/c1.json', '{}');
      put('per_corso/polito/c2.json', '{}');
      put('per_corso/polito/indice.json', '{}');
      put('per_corso/unito/c9.json', '{}');
      put('sessioni/polito.json', '{}');
      put('sessioni/unito.json', '{}');
      put('ateneo.json', jsonEncode({'ateneo': 'unito', 'corso': 'c9'}));
      final catalog = CatalogService(
        SettingsRepository(db),
        fetcher: (u, {onProgress}) async =>
            throw const SocketException('offline'),
        assetLoader: (path) async => throw StateError('manca $path'),
        cacheDir: () async => cache,
      );
      await catalog.eliminaAltri('polito', 'c1');
      bool has(String rel) => File(p.join(cache.path, rel)).existsSync();
      expect(has('per_corso/polito/c1.json'), isTrue);
      expect(has('per_corso/polito/indice.json'), isFalse);
      expect(has('per_corso/polito/c2.json'), isFalse);
      expect(has('per_corso/unito/c9.json'), isFalse);
      expect(has('sessioni/polito.json'), isTrue);
      expect(has('sessioni/unito.json'), isFalse);
      expect(has('ateneo.json'), isFalse);
      for (final old in ['corsi', 'moduli', 'community']) {
        expect(Directory(p.join(cache.path, old)).existsSync(), isFalse);
      }
    });
  });

  group('9. modelli e programmi di trascrizione scaricati da versioni '
      'precedenti', () {
    test('modelli con nomi o cartelle vecchi, download a metà, archivi e '
        'cartelle di lavoro rimasti: stato e scelta del modello senza '
        'errori', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      void put(String rel, [List<int> bytes = const [1, 2, 3]]) {
        final f = File(p.join(tmp.path, 'whisper', rel));
        f.parent.createSync(recursive: true);
        f.writeAsBytesSync(bytes);
      }

      // modelli solo inglese e il modello integrato dell'installatore di
      // Windows, tolti dall'elenco; uno attuale e uno interrotto
      put('models/ggml-base.en.bin');
      put('models/ggml-distil-large-v3.bin');
      put('models/ggml-base-q5_1.bin');
      put('models/ggml-small.bin');
      put('models/ggml-medium.bin.part', List.filled(500, 7));
      put('models/ggml-base-q5_1.bin.copia');
      // programma a metà estrazione e archivi non cancellati
      put('bin.part/whisper-cli.exe.part');
      put('bin/LEGGIMI.txt');
      put('whisper.zip');
      put('ffmpeg/ffmpeg.zip');
      put('ffmpeg/ffmpeg.exe.part');
      for (final host in [
        WhisperHost.windows,
        WhisperHost.android,
        WhisperHost.macos,
      ]) {
        for (final saved in ['base.en', 'distil-large-v3', '', 'base-q5_1']) {
          await settings.set('whisper_model', saved);
          final w = WhisperService(
            settings: settings,
            baseDir: () async => tmp,
            host: host,
            freeSpace: (_) async => null,
            builtInAsset: false,
            deviceProbe: () async => const DeviceProfile(
              platform: WhisperPlatform.pc,
              ramBytes: 16000000000,
            ),
          );
          final st = await w.status();
          expect(st.models, contains('small'));
          expect(st.models, isNot(contains('medium')));
          expect(await w.partialBytes(whisperModelById('medium')!), 500);
          final picked = await w.pickModel({...st.models});
          expect(picked?.id, 'small');
          await w.availableModels();
          await w.resolveModel();
          await w.findCli();
          await w.ffmpeg();
        }
      }
    });
  });

  group('10. lettore: posizione, segnalibri e recenti delle versioni '
      'precedenti', () {
    test('stato salvato con la chiave del percorso assoluto (versioni '
        'precedenti): si legge, e salvando passa alla chiave nuova senza '
        'perdere i segnalibri', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final support = Directory(p.join(tmp.path, 'support'))..createSync();
      final old = portableBase;
      addTearDown(() => portableBase = old);
      portableBase = p.normalize(support.path);
      final file = File(p.join(support.path, 'libri', 'dispensa.pdf'))
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(100, 1));
      await settings.set(
        ReaderStore.keyFor(file.path, 100),
        jsonEncode({
          'pos': 7,
          'bm': [
            {'p': 3, 'l': 'definizione', 'c': '2026-10-05T10:00:00'},
            {'p': 9.0, 'l': 'x'},
            {'l': 'senza posizione'},
          ],
        }),
      );
      final store = ReaderStore(settings);
      var st = await store.load(file.path);
      expect(st.position, 7);
      expect(st.bookmarks.map((b) => b.position), [3, 9]);
      await store.savePosition(file.path, 8);
      st = await store.load(file.path);
      expect(st.position, 8);
      expect(st.bookmarks, hasLength(2));
      // la chiave nuova è quella del percorso relativo
      expect(
        await settings.get(await ReaderStore.keyOf(file.path)),
        isNotNull,
      );
    });

    test('file recenti scritti in altre forme: le voci buone restano',
        () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.set(
        ReaderStore.recentKey,
        jsonEncode([
          {'path': 'C:/a.pdf', 'title': 'A', 'at': '2026-10-05T10:00:00'},
          {'path': 5},
          {'path': ''},
          'x',
          {'path': 'C:/b.pdf'},
        ]),
      );
      final recent = await ReaderStore(settings).recent();
      expect(recent.map((r) => r.path), ['C:/a.pdf', 'C:/b.pdf']);
    });
  });

  group('11. account e credenziali di versioni precedenti', () {
    test('chiave di Gemini e impostazioni di Antigravity: tolte una volta, '
        'anche con il portachiavi che lancia, senza toccare il resto',
        () async {
      for (final broken in [false, true]) {
        final s = AppServices(await AppDatabase.openInMemory());
        await s.settings.set('agy_path', 'C:/agy.exe');
        await s.settings.set('gemini_model', 'gemini-2.5-flash');
        await s.settings.set('gemini_api_model', 'gemini-3.1-pro-preview');
        await s.settings.set('links_reference_ai', 'gemini');
        final secrets = broken ? _BrokenSecrets() : MemoryCloudSecrets();
        if (secrets is MemoryCloudSecrets) {
          secrets.values['gemini.apiKey'] = 'AIza-finta';
          secrets.values['onedrive.refreshToken'] = 'r';
        }
        await s.removeLegacyGemini(secrets: secrets);
        expect(await s.settings.get('agy_path'), isNull);
        expect(await s.settings.get('gemini_model'), isNull);
        expect(await s.settings.get('links_reference_ai'), 'gemini');
        // portachiavi che lancia: la chiave può essere ancora lì, la pulizia
        // non si segna come fatta e si riprova al prossimo avvio (sicurezza,
        // giro 2: prima si segnava fatta e la chiave restava per sempre)
        expect(
          await s.settings.get('legacy_gemini_removed'),
          broken ? isNull : '1',
        );
        if (secrets is MemoryCloudSecrets) {
          expect(secrets.values.keys, ['onedrive.refreshToken']);
        }
        // una seconda volta non fa niente (o riprova senza errori)
        await s.removeLegacyGemini(secrets: secrets);
        if (broken) {
          // portachiavi tornato disponibile: si toglie e si segna
          final ok = MemoryCloudSecrets()..values['gemini.apiKey'] = 'AIza-x';
          await s.removeLegacyGemini(secrets: ok);
          expect(ok.values, isEmpty);
          expect(await s.settings.get('legacy_gemini_removed'), '1');
        }
        await s.database.close();
      }
    });

    test('caselle della sincronizzazione scritte dalle versioni '
        'precedenti: nomi sconosciuti ignorati, «Dati» accesa di serie', () {
      expect(SyncScope.parse(null), SyncScope.values.toSet());
      expect(SyncScope.parse('recordings,notes'), {
        SyncScope.recordings,
        SyncScope.notes,
        SyncScope.data,
      });
      expect(SyncScope.parse('recordings,notes,books,attachments,backup'),
          contains(SyncScope.data));
      expect(SyncScope.parse('mail,calendar,boh,,'), {SyncScope.data});
      expect(SyncScope.parse('-data'), isEmpty);
      expect(SyncScope.parse(''), {SyncScope.data});
    });

    test('accesso con un portachiavi che non risponde: collegato = no, '
        'nessuna eccezione', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      await settings.set('onedrive_account', 'io@ateneo.it');
      final od = OneDriveService(
        settings,
        NotesStore(settings, root: () async => tmp),
        secrets: _BrokenSecrets(),
        stateDir: () async => tmp,
        builtInClientId: '1a2b3c4d-1111-2222-3333-444455556666',
        deviceName: 'PC',
      );
      expect(await od.connected(), isFalse);
      expect(await od.account(), 'io@ateneo.it');
      expect(await od.signOut(), isTrue);
      expect(await od.account(), isNull);
    });
  });

  group('2b. controllo dell\'installazione dopo un aggiornamento', () {
    InstallCheck check({
      required bool database,
      List<Directory> notes = const [],
      String? identity,
      void Function()? onWipe,
      String version = '2026.9.0',
    }) => InstallCheck(
      version: version,
      databaseExists: () async => database,
      wipeSecrets: () async => onWipe?.call(),
      sharedNotes: () async => notes,
      identity: () async => identity,
    );

    test('aggiornamento da una versione che non salvava la versione '
        '(database e appunti già presenti): nessuna domanda, credenziali '
        'intatte', () async {
      SharedPreferences.setMockInitialValues({});
      var wiped = 0;
      final st = await check(
        database: true,
        notes: [tmp],
        identity: 'win:1',
        onWipe: () => wiped++,
      ).run();
      expect(st.fresh, isFalse);
      expect(st.needsAnswer, isFalse);
      expect(wiped, 0);
    });

    test('preferenze con tipi di altre versioni (numero al posto del '
        'testo, testo al posto del booleano): nessuna eccezione, si '
        'riparte dal controllo', () async {
      SharedPreferences.setMockInitialValues({
        InstallCheck.versionKey: 5,
        InstallCheck.identityKey: true,
        InstallCheck.pendingLeftoverKey: 'si',
        InstallCheck.pendingSharedKey: 1,
      });
      final st = await check(database: true, identity: 'win:1').run();
      expect(st.needsAnswer, isFalse);
    });

    test('nuova installazione (nessun database) con appunti rimasti in '
        'Documenti: la domanda compare e le credenziali rimaste si '
        'cancellano', () async {
      SharedPreferences.setMockInitialValues({});
      var wiped = 0;
      final st = await check(
        database: false,
        notes: [tmp],
        onWipe: () => wiped++,
      ).run();
      expect(st.fresh, isTrue);
      expect(st.sharedNotes, [tmp]);
      expect(wiped, 1);
    });
  });

  group('12. database di ogni versione dello schema: sincronizzazione e '
      'schermate', () {
    for (var v = 1; v <= 13; v++) {
      test('dati della versione $v: l\'unione con un altro dispositivo li '
          'porta di là senza errori e senza perdere nulla qui', () async {
        final a = await AppDatabase.open(path: await _oldDatabase(tmp, v));
        final b = await AppDatabase.open(path: p.join(tmp.path, 'b$v.db'));
        addTearDown(a.close);
        addTearDown(b.close);
        final da = Directory(p.join(tmp.path, 'dati_a$v'))..createSync();
        final db = Directory(p.join(tmp.path, 'dati_b$v'))..createSync();
        final sa = DataSync(a, stateDir: () async => da);
        final sb = DataSync(b, stateDir: () async => db);
        Future<void> merge(DataSync d, AppDatabase _, String name) async {
          final folder = Directory(p.join(tmp.path, 'cloud_$v'))
            ..createSync();
          await d.mergeFolder(
            folder,
            ownName: DataSync.ownFileName(name, name),
            device: name,
            installId: name,
          );
        }

        final before = (await a.db.query('courses')).length;
        await merge(sa, a, 'A');
        await merge(sb, b, 'B');
        await merge(sa, a, 'A');
        await merge(sb, b, 'B');
        expect((await a.db.query('courses')).length, before);
        expect((await b.db.query('courses')).length, before);
      });
    }

    for (final v in [1, 5, 9, 13]) {
      testWidgets('dati della versione $v: tutte le sezioni si aprono',
          (tester) async {
        _collect();
        addTearDown(_release);
        final path = await tester.runAsync(() => _oldDatabase(tmp, v));
        final db = await tester.runAsync(() => AppDatabase.open(path: path!));
        final s = AppServices(db!);
        for (final d in kDestinations) {
          await _pump(tester, s, Builder(builder: d.builder));
          _noCrash(tester, '«${d.label}» con i dati della versione $v');
        }
        await tester.pumpWidget(const SizedBox());
        // le richieste ancora in corso finiscono prima di chiudere il file
        await _settle(tester, 10);
        await tester.runAsync(db.close);
      });
    }
  });
}
