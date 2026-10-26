// Quarto giro della caccia alle falle (app, giro di conferma con prove di
// aggiramento vere): azioni delle notifiche mandate da altre app, filtri
// delle esclusioni dal costo alto, file per il lettore multimediale, file
// condivisi, percorsi e registri della sincronizzazione. Vedi «Giro 4 — App»
// in docs/sicurezza.md.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/reminders/notification_platform.dart';
import 'package:university_notes/core/reminders/notification_prefs.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/backup_service.dart';
import 'package:university_notes/core/services/media_guard.dart';
import 'package:university_notes/features/cloud/data_sync.dart';
import 'package:university_notes/features/cloud/incoming_files.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/safe_files.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/utils/exclusion_filter.dart';

import 'support/fake_reminders.dart';

String _read(String path) => File(path).readAsStringSync();

/// Notifiche finte con un tocco che ha «aperto l'app» (su Android: un
/// intent con l'azione di flutter_local_notifications mandato a
/// MainActivity, anche da un'altra app).
class _LaunchPlatform extends FakeNotificationPlatform {
  _LaunchPlatform(this.tap);
  final NotificationTap tap;

  @override
  Future<NotificationTap?> launchTap() async => tap;
}

const _code = '0123456789abcdef0123456789abcdef';

Future<AppServices> _services(NotificationPlatform platform) async {
  final db = await AppDatabase.openInMemory();
  addTearDown(db.close);
  final s = AppServices(
    db,
    reminders: (s) => RemindersService(
      s,
      platform: platform,
      calendarBackend: FakeCalendarBackend(),
      widgets: FakeHomeWidgets(),
      platformName: 'android',
      isRecording: () => false,
    ),
  );
  // (prima della chiusura del database: niente aggiornamenti in ritardo)
  addTearDown(s.reminders.dispose);
  return s;
}

/// Impostazioni che le azioni delle notifiche cambiano.
Future<Map<String, String?>> _state(AppServices s) async => {
  for (final k in [
    NotificationKeys.reviewState,
    NotificationKeys.reviewLater,
    NotificationKeys.donationOff,
    NotificationKeys.donationNext,
    NotificationKeys.outcomeDone,
  ])
    k: await s.settings.get(k),
};

/// Dispositivo per le prove della sincronizzazione dei dati.
class _Device {
  _Device(this.name, this.db, this.root, this.sync);
  final String name;
  final AppDatabase db;
  final Directory root;
  final DataSync sync;

  String get notes => p.join(root.path, 'appunti');

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
  File get ownFile => File(p.join(dati.path, own));

  Future<void> merge() =>
      sync.mergeFolder(dati, ownName: own, device: name, installId: name);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('1. azioni delle notifiche mandate da altre app', () {
    // Tutte le azioni e i payload che l'app accetta da un tocco:
    // - payload `recensione`: tocco o «Recensisci» (segna fatta e apre lo
    //   store), «Più tardi», «Non chiedere più»;
    // - payload `sostegno`: tocco o «Dona» (rimanda di 6 mesi e apre la
    //   pagina), «Più tardi», «Non chiedere più»;
    // - pulsante «Non ricordarmelo per questa prova» con `prova:<id>`;
    // - qualsiasi altro payload: apre solo una schermata (`prova:<id>`,
    //   `sezione:<nome>`, `registra`, `focus`, `anni_precedenti`;
    //   `registra:avvia` diventa `registra`, giro 3).
    final attacks = [
      const NotificationTap(AppRoutes.review),
      const NotificationTap(AppRoutes.review, NotificationActions.review),
      const NotificationTap(AppRoutes.review, NotificationActions.later),
      const NotificationTap(AppRoutes.review, NotificationActions.never),
      const NotificationTap(AppRoutes.donate),
      const NotificationTap(AppRoutes.donate, NotificationActions.donate),
      const NotificationTap(AppRoutes.donate, NotificationActions.later),
      const NotificationTap(AppRoutes.donate, NotificationActions.never),
      const NotificationTap('prova:1', NotificationActions.skipExam),
      // codice sbagliato, vuoto, troppo corto o ripetuto
      const NotificationTap(
        '${AppRoutes.review}#ffffffffffffffffffffffffffffffff',
        NotificationActions.never,
      ),
      const NotificationTap('${AppRoutes.donate}#', NotificationActions.never),
      const NotificationTap('prova:1#0123', NotificationActions.skipExam),
      const NotificationTap('prova:1#$_code#x', NotificationActions.skipExam),
    ];

    for (final tap in attacks) {
      test('senza il codice giusto non cambia nulla: '
          '«${tap.payload}» ${tap.action ?? 'tocco'}', () async {
        // prima della correzione ogni voce cambiava le impostazioni (le
        // richieste di recensione e sostegno spente, l'esito della prova
        // non più chiesto)
        final s = await _services(_LaunchPlatform(tap));
        await s.settings.set(NotificationKeys.code, _code);
        final before = await _state(s);
        await s.reminders.start();
        expect(await _state(s), before);
        // al massimo si apre una schermata
        final (route, _) = RemindersService.splitPayload(tap.payload);
        expect(s.openRoute.pending, RemindersService.notificationRoute(route));
      });
    }

    test('con il codice di questo dispositivo le azioni funzionano', () async {
      for (final (tap, key, value) in [
        (
          NotificationTap(
            RemindersService.signedPayload(AppRoutes.review, _code),
            NotificationActions.never,
          ),
          NotificationKeys.reviewState,
          'never',
        ),
        (
          NotificationTap(
            RemindersService.signedPayload(AppRoutes.donate, _code),
            NotificationActions.never,
          ),
          NotificationKeys.donationOff,
          '1',
        ),
        (
          NotificationTap(
            RemindersService.signedPayload('prova:7', _code),
            NotificationActions.skipExam,
          ),
          NotificationKeys.outcomeDone,
          '7',
        ),
      ]) {
        final s = await _services(_LaunchPlatform(tap));
        await s.settings.set(NotificationKeys.code, _code);
        await s.reminders.start();
        expect(await s.settings.get(key), value, reason: tap.payload);
      }
    });

    test('anche dalla coda dei pulsanti premuti ad app chiusa', () async {
      final platform = FakeNotificationPlatform()
        ..queue = [
          const NotificationTap(AppRoutes.review, NotificationActions.never),
          NotificationTap(
            RemindersService.signedPayload(AppRoutes.donate, _code),
            NotificationActions.never,
          ),
        ];
      final s = await _services(platform);
      await s.settings.set(NotificationKeys.code, _code);
      await s.reminders.start();
      expect(await s.settings.get(NotificationKeys.reviewState), isNull);
      expect(await s.settings.get(NotificationKeys.donationOff), '1');
    });

    test('le notifiche che cambiano dati partono con il codice (casuale, '
        'creato la prima volta), le altre come prima', () async {
      final platform = FakeNotificationPlatform();
      final s = await _services(platform);
      final c = await s.courses.insert(const Course(name: 'Analisi I'));
      final id = await s.exams.insert(
        Exam(courseId: c, date: DateTime(2027, 2, 10)),
      );
      final r = s.reminders;
      expect(await r.enableNotifications(), isTrue);
      final t = DateTime(2027, 1, 5, 10);
      final plan = await r.reschedule(
        await r.loadAgenda(t),
        await r.calendar.status(),
        now: t,
      );
      final code = await s.settings.get(NotificationKeys.code);
      expect(code, matches(RegExp(r'^[0-9a-f]{32}$')));
      final outcome = plan.singleWhere(
        (n) => n.type == NotificationType.outcome,
      );
      // nel piano la rotta, nella notifica vera la rotta con il codice
      expect(outcome.payload, 'prova:$id');
      expect(platform.scheduled[outcome.id]!.payload, 'prova:$id#$code');
      for (final n in plan.where(
        (n) => !RemindersService.changesData(n.type),
      )) {
        expect(platform.scheduled[n.id]!.payload, n.payload);
        expect(n.payload, isNot(contains('#')));
      }
      // tocco sul testo della notifica vera: apre la prova
      final (route, given) = RemindersService.splitPayload(
        platform.scheduled[outcome.id]!.payload,
      );
      expect((route, given), ('prova:$id', code));
      // ripianificando il codice resta lo stesso
      await r.reschedule(
        await r.loadAgenda(t),
        await r.calendar.status(),
        now: t,
      );
      expect(await s.settings.get(NotificationKeys.code), code);
    });

    test('il codice non va nei backup né agli altri dispositivi', () {
      expect(BackupService.protectedSettings, contains(NotificationKeys.code));
      final sync = _read('lib/core/database/sync_schema.dart');
      expect(sync, isNot(contains("'${NotificationKeys.code}'")));
    });

    test('Android: i pulsanti senza apertura dell\'app passano dal ricevitore '
        'non esportato; MainActivity (esportata) riceve il resto', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      expect(
        manifest,
        matches(
          RegExp(
            r'android:exported="false"\s+android:name="com\.dexterous\.'
            r'flutterlocalnotifications\.ActionBroadcastReceiver"',
          ),
        ),
      );
      expect(
        manifest,
        matches(
          RegExp(r'android:name="\.MainActivity"\s+android:exported="true"'),
        ),
      );
    });

    test('ricontrollo del giro 3: registra:avvia e codice dei widget', () {
      expect(
        RemindersService.notificationRoute(AppRoutes.recordStart),
        AppRoutes.record,
      );
      // anche con un codice nel payload
      final (route, _) = RemindersService.splitPayload(
        '${AppRoutes.recordStart}#$_code',
      );
      expect(RemindersService.notificationRoute(route), AppRoutes.record);
      final support = _read(
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes/'
        'widgets/WidgetSupport.kt',
      );
      expect(support, contains('MessageDigest.isEqual('));
      expect(support, contains('SecureRandom().nextBytes(it)'));
      expect(
        support,
        contains('if (!fresh || fromHistory) return ROUTE_RECORD'),
      );
    });
  });

  group('2. filtri delle esclusioni: espressioni dal costo alto', () {
    // casi noti di backtracking catastrofico e varianti
    final evil = [
      r'(a+)+$',
      r'(a|aa)+$',
      r'(.*a){10}',
      r'^(\w+\s?)*$',
      r'(x+x+)+y',
      r'(a|a)*b',
      r'(?:a|ab)*c',
      r'([a-z]*)*$',
      r'(?=(a+)+)b',
      r'(a|a)(a|a)(a|a)(a|a)(a|a)x',
      r'.*(a|a|a|a)(a|a|a|a).*x',
      r'.*(a|a|a).*x',
      r'(a|b|c|d|e|f|g|h|i|j|k|l|m|n|o|p).*.*z',
      r'\d*\d*\d*x',
      r'a{1,30000}a{1,30000}a{1,30000}b',
      r'(a{1,100}){1,100}b',
      r'(a)\1',
    ];
    // ammesse (costo limitato), anche quelle che su 10.000 caratteri senza
    // il taglio del testo costavano da 0,7 s a un minuto
    final costly = [
      r'.*.*x',
      r'.*a.*b',
      r'^.*.*.*x',
      r'[a-z]*[a-z]*!',
      r'a{1,30000}a{1,30000}b',
      r'a{0,10000}b',
      r'(?=.*x).*y',
      r'(?<=a+)a+b',
      r'(?!a*b)a*c',
      r'.*(a|a).*x',
      r'(a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a).*x',
      'a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|a|.*.*z',
      r'^lab(oratorio)?\s*\d*$',
    ];
    final texts = [
      'a' * 10000,
      ('ab ' * 3334).substring(0, 10000),
      '1' * 10000,
      '${' ' * 10000}!',
    ];

    test('i casi noti sono testo semplice', () {
      for (final e in evil) {
        expect(ExclusionFilter.isSafePattern(e), isFalse, reason: e);
      }
    });

    test('ogni espressione ammessa risponde in meno di 50 ms su un testo di '
        '10.000 caratteri', () {
      for (final c in costly) {
        expect(ExclusionFilter.isSafePattern(c), isTrue, reason: c);
      }
      // prima volta (compilazione) fuori dalla misura
      ExclusionFilter(costly).isExcluded(['riscaldamento']);
      for (final c in [...costly, ...evil]) {
        final f = ExclusionFilter([c]);
        for (final t in texts) {
          // il migliore di tre: la prima volta l'espressione si compila per
          // il testo e con la suite completa in parallelo il PC è carico
          // (una volta 62 ms per «.*(a|a).*x», poi pochi ms); il blocco che
          // si cerca qui dura secondi a ogni confronto
          var best = 1 << 30;
          for (var i = 0; i < 3; i++) {
            final sw = Stopwatch()..start();
            f.isExcluded([t]);
            best = best < sw.elapsedMilliseconds ? best : sw.elapsedMilliseconds;
          }
          expect(
            best,
            lessThan(50),
            reason: '$c su «${t.substring(0, 3)}…»',
          );
        }
      }
    });

    test('tanti filtri dal costo alto: solo i primi '
        '${ExclusionFilter.maxRegexPatterns} come espressioni', () {
      final f = ExclusionFilter([for (var i = 0; i < 100; i++) '.*.*x${i}y']);
      final sw = Stopwatch()..start();
      expect(f.isExcluded(['a' * 10000]), isFalse);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      // oltre il limite valgono come testo: «.*.*x50y» non è un'espressione
      expect(f.isExcluded(['.*.*x50y']), isTrue);
      expect(f.isExcluded(['aax50y']), isFalse);
      expect(f.isExcluded(['aax5y']), isTrue);
    });

    test('i filtri normali restano espressioni e funzionano', () {
      final f = ExclusionFilter([
        r'^lab(oratorio)?\s*\d*$',
        '(inglese|english)',
        r'(lab|laboratorio) (di|del)',
        r'tirocinio|\btesi\b',
        r'\bOFA\b',
      ]);
      expect(f.isExcluded(['Laboratorio 2']), isTrue);
      expect(f.isExcluded(['English B2']), isTrue);
      expect(f.isExcluded(['Lab di fisica']), isTrue);
      expect(f.isExcluded(['Prova finale (tesi)']), isTrue);
      expect(f.isExcluded(['OFA di matematica']), isTrue);
      expect(f.isExcluded(['Analisi']), isFalse);
    });
  });

  group('3. lettore multimediale: scalette travestite', () {
    late Directory tmp;
    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('sicurezza_g4_media_');
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {}
    });

    const list = '#EXTM3U\n#EXTINF:-1,x\nhttps://example.invalid/a.mp3\n';

    List<int> utf16(String s, {required bool little}) => [
      if (little) ...[0xFF, 0xFE] else ...[0xFE, 0xFF],
      for (final u in s.codeUnits)
        if (little) ...[u & 0xFF, u >> 8] else ...[u >> 8, u & 0xFF],
    ];

    List<int> utf32le(String s) => [
      0xFF, 0xFE, 0, 0, //
      for (final u in s.codeUnits) ...[u & 0xFF, u >> 8, 0, 0],
    ];

    Future<String?> reason(String name, List<int> bytes) async {
      final f = File(p.join(tmp.path, name));
      await f.writeAsBytes(bytes);
      return MediaGuard.unsafeReason(f.path);
    }

    test('scalette in UTF-16 e UTF-32 con il BOM non si aprono', () async {
      // prima della correzione passavano: i byte zero dei caratteri ASCII
      // sembravano un'intestazione binaria
      expect(await reason('a.m4a', utf16(list, little: true)), isNotNull);
      expect(await reason('b.m4a', utf16(list, little: false)), isNotNull);
      expect(await reason('c.mp3', utf32le(list)), isNotNull);
    });

    test('scalette con BOM UTF-8, spazi iniziali, .m3u8 rinominati', () async {
      for (final (name, text) in [
        ('d.m4a', '\u{FEFF}$list'),
        ('e.wav', '\n\n   \t$list'),
        ('lezione.mp4', list),
        ('f.mp3', '[playlist]\nFile1=https://example.invalid/x\n'),
        ('g.mkv', '# mpv EDL v0\nhttps://example.invalid/x.mkv\n'),
        ('h.webm', '<?xml version="1.0"?><MPD></MPD>'),
      ]) {
        expect(await reason(name, utf8.encode(text)), isNotNull, reason: name);
      }
    });

    test('i file veri dell\'app restano apribili', () async {
      // suoni WAV dell'app (file veri) e intestazioni reali di M4A, MP4,
      // MP3 con ID3, MP3 senza ID3, OGG, FLAC, WebM
      for (final f in Directory('assets/suoni').listSync().whereType<File>()) {
        expect(await MediaGuard.unsafeReason(f.path), isNull, reason: f.path);
      }
      final silence = List<int>.filled(900, 0);
      for (final (name, head) in [
        ('r.m4a', [0, 0, 0, 0x1C, ...'ftypM4A '.codeUnits, 0, 0, 2, 0]),
        ('v.mp4', [0, 0, 0, 0x20, ...'ftypisom'.codeUnits, 0, 0, 2, 0]),
        ('i.mp3', [...'ID3'.codeUnits, 4, 0, 0, 0, 0, 0, 0x23]),
        ('m.mp3', [0xFF, 0xFB, 0x90, 0x64]),
        ('l1.mp3', [0xFF, 0xFE, 0x90, 0x64]),
        ('o.ogg', [...'OggS'.codeUnits, 0, 2, 0, 0]),
        ('f.flac', [...'fLaC'.codeUnits, 0, 0, 0, 0x22]),
        ('w.webm', [0x1A, 0x45, 0xDF, 0xA3, 0x9F, 0x42, 0x86, 0x81]),
      ]) {
        expect(await reason(name, [...head, ...silence]), isNull, reason: name);
      }
    });

    test('intestazione finta seguita da una scaletta: passa il controllo '
        'iniziale, ma il lettore non segue riferimenti e apre solo file '
        'locali', () async {
      // mpv e FFmpeg riconoscono le scalette solo dall'inizio del file (dopo
      // BOM e spazi): con byte binari davanti il file si apre come audio o
      // video (o non si apre). Le opzioni del lettore sono la seconda difesa.
      for (final head in [
        [...'ID3'.codeUnits, 4, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0x18, ...'ftypM4A '.codeUnits],
        [...'OggS'.codeUnits, 0, 2],
        [...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVE'.codeUnits],
      ]) {
        expect(await reason('x.m4a', [...head, ...utf8.encode(list)]), isNull);
      }
      final set = <String, String>{};
      await MediaGuard.applyOptions((k, v) async => set[k] = v);
      expect(set, {'access-references': 'no', 'load-unsafe-playlists': 'no'});
      expect(MediaGuard.configuration.protocolWhitelist, ['file']);
    });

    test('registrazioni e lettore dei documenti usano il lettore protetto', () {
      for (final f in [
        'lib/features/notes/recording_player_screen.dart',
        'lib/features/reader/views/media_view.dart',
      ]) {
        final src = _read(f);
        expect(src, contains('await MediaGuard.newPlayer()'), reason: f);
        expect(src, contains('MediaGuard.unsafeReason('), reason: f);
        expect(src, isNot(contains('= Player(')), reason: f);
      }
      // nessun altro lettore apre file dell'utente (i suoni sono asset)
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        if (!src.contains('Media(')) continue;
        final ok =
            src.contains('MediaGuard.newPlayer()') ||
            src.contains("Media('asset:///");
        expect(ok, isTrue, reason: f.path);
      }
    });
  });

  group('4. file condivisi, percorsi della sincronizzazione, gzip', () {
    test('nomi dei file condivisi: niente uscita dalla cartella, niente '
        'caratteri di controllo né nomi riservati di Windows', () {
      final items = [
        for (final n in [
          '../../shared_prefs/x.xml',
          '..',
          '.',
          'a/../../b.pdf',
          r'..\..\x.pdf',
          r'C:\Windows\x.pdf',
          r'\\server\share\x.pdf',
          '%2e%2e%2fx.pdf',
          'nome\u0000.pdf',
          'riga\nnuova.pdf',
          '.nascosto',
        ])
          {'path': '/cache/condivisi/1_$n', 'name': n, 'temporary': true},
      ];
      final files = IncomingFiles.parse(items);
      expect(files, hasLength(items.length));
      for (final f in files) {
        expect(f.name, isNot(contains('/')), reason: f.name);
        expect(f.name, isNot(contains(r'\')), reason: f.name);
        expect(f.name, isNot(anyOf('.', '..', '')), reason: f.name);
        expect(f.name.startsWith('.'), isFalse, reason: f.name);
        expect(f.name.codeUnits.any((c) => c < 0x20), isFalse, reason: f.name);
        final dir = p.join(Directory.systemTemp.path, 'materiali');
        expect(p.isWithin(dir, p.join(dir, f.name)), isTrue, reason: f.name);
      }
      for (final n in ['CON', 'NUL.txt', 'com1.pdf', 'LPT9 .md', 'aux']) {
        final safe = NotesStore.safeName(n, windows: true);
        expect(isWindowsReservedName(safe), isFalse, reason: n);
      }
    });

    test('Android: il nome scelto dall\'altra app passa da cleanName (prova '
        'sulla JVM nel resoconto del giro)', () {
      final src = _read(
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes/'
        'IncomingShare.kt',
      );
      expect(src, contains('cleanName(name ?: uri.lastPathSegment, index)'));
      expect(src, contains(".substringAfterLast('/')"));
      expect(src, contains(r'\\u0000-\\u001f\\u007f'));
      expect(src, contains('n == "." || n == ".."'));
      expect(src, contains('substringAfterLast(\'@\')'));
      expect(src, contains('resolveContentProvider(authority, 0)'));
      expect(src, contains('if (uri.scheme != "content") continue'));
    });

    group('registri manipolati nella cartella cloud', () {
      late Directory tmp;
      setUp(() async {
        tmp = await Directory.systemTemp.createTemp('sicurezza_g4_sync_');
      });
      tearDown(() async {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {}
      });

      test('percorsi degli allegati: relativi con «..» e «\\», assoluti, '
          'UNC, file:, unità, codificati', () async {
        final a = await _Device.create('A', tmp);
        final c = await a.db.db.insert('courses', {'name': 'Laboratorio'});
        final m = await a.db.db.insert('modules', {
          'course_id': c,
          'name': 'Arduino',
        });
        await a.db.db.insert('attachments', {
          'module_id': m,
          'title': 'x.md',
          'path': p.join(a.notes, 'x.md'),
          'created_at': '2026-10-26T08:00:00',
        });
        await a.merge();
        final legit = SyncSnapshot.decode(await a.ownFile.readAsBytes())!;
        final row = legit.table('attachments').entries.single;
        expect(row.value.values['path'], '${DataSync.notesPrefix}x.md');
        final outside = p.join(tmp.path, 'fuori.md');
        final attacks = [
          '${DataSync.notesPrefix}../fuori.md',
          '${DataSync.notesPrefix}..\\..\\fuori.md',
          '${DataSync.notesPrefix}a\\..\\..\\..\\fuori.md',
          '${DataSync.notesPrefix}C:\\Windows\\win.ini',
          '${DataSync.notesPrefix}\\\\server\\share\\x.md',
          '${DataSync.notesPrefix}/etc/passwd',
          '${DataSync.notesPrefix}%2e%2e/%2e%2e/fuori.md',
          '${DataSync.notesPrefix}a//b.md',
          outside,
          p.join(tmp.path, 'B', 'appunti', '..', '..', 'fuori.md'),
          r'\\server\share\x.md',
          '//server/share/x.md',
          'file:///C:/Windows/win.ini',
          'C:fuori.md',
          '/etc/passwd',
        ];
        for (final (i, v) in attacks.indexed) {
          final b = await _Device.create('B$i', tmp);
          final s = SyncSnapshot.decode(await a.ownFile.readAsBytes())!;
          final e = s.table('attachments')[row.key]!;
          e.values['path'] = v;
          File(p.join(b.dati.path, a.own)).writeAsBytesSync(s.encode());
          await b.merge();
          final got = (await b.db.db.query('attachments')).single['path'];
          if (got != null) {
            final full = p.normalize(got as String);
            expect(p.isWithin(b.notes, full), isTrue, reason: '$v → $got');
          }
          await b.db.close();
        }
        await a.db.close();
      });

      test('gzip: bomba, membri concatenati, gzip dentro gzip, troncato', () {
        const limit = 1024 * 1024;
        final zeros = gzip.encode(List<int>.filled(8 * limit, 0x20));
        expect(
          () => SyncSnapshot.gunzipLimited(zeros, limit),
          throwsFormatException,
        );
        // due membri sotto il limite che insieme lo superano: o si ferma o
        // legge solo il primo, mai oltre il limite
        final half = gzip.encode(List<int>.filled(limit * 3 ~/ 4, 0x20));
        try {
          final out = SyncSnapshot.gunzipLimited([...half, ...half], limit);
          expect(out.length, lessThanOrEqualTo(limit));
        } on FormatException {
          // fermato
        }
        // gzip di una bomba: si decomprime una volta sola, poi non è JSON
        final nested = gzip.encode(zeros);
        expect(SyncSnapshot.decode(nested), isNull);
        // troncato o con il trailer rovinato: ignorato senza eccezioni
        final json = utf8.encode(
          '{"format":"${SyncSnapshot.format}","version":1,"tables":{}}',
        );
        final ok = gzip.encode(json);
        expect(SyncSnapshot.decode(ok), isNotNull);
        for (final cut in [3, 10]) {
          expect(SyncSnapshot.decode(ok.sublist(0, cut)), isNull);
        }
        // (senza il trailer zlib può dare lo stesso i dati, già completi)
        for (var cut = 11; cut < ok.length; cut++) {
          expect(
            () => SyncSnapshot.decode(ok.sublist(0, cut)),
            returnsNormally,
          );
        }
        expect(SyncSnapshot.decode([0x1f, 0x8b]), isNull);
      });
    });
  });
}
