import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/error_log.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/safe_files.dart';
import 'package:university_notes/features/reader/parsers/html_blocks.dart';
import 'package:university_notes/features/reader/reader_document.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/fake_drive.dart';

/// Quarto giro della caccia ai crash, ricontrollo critico delle correzioni
/// dei tre giri precedenti: errori nuovi introdotti da quelle correzioni
/// (dati persi, comportamenti cambiati senza volerlo).

/// File temporaneo («.part») che non si lascia rinominare, come quando un
/// antivirus, l'indicizzazione o il client di OneDrive lo tiene aperto
/// subito dopo la scrittura.
class _StuckPart implements File {
  _StuckPart(this._real);
  final File _real;

  @override
  String get path => _real.path;
  @override
  File get absolute => _StuckPart(_real.absolute);
  @override
  Future<File> writeAsString(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) async {
    await _real.writeAsString(
      contents,
      mode: mode,
      encoding: encoding,
      flush: flush,
    );
    return this;
  }

  @override
  Future<bool> exists() => _real.exists();
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);
  @override
  Future<File> copy(String newPath) => _real.copy(newPath);
  @override
  Future<File> rename(String newPath) async =>
      throw FileSystemException('File in uso', path);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _StuckPartOverrides extends IOOverrides {
  @override
  File createFile(String path) {
    final real = super.createFile(path);
    return path.endsWith('.part') ? _StuckPart(real) : real;
  }
}

/// Appunti con la cartella scelta dall'utente che a un certo punto non
/// risponde (disco USB o di rete): si usa quella predefinita.
class _SwitchableNotes extends NotesStore {
  _SwitchableNotes(super.settings, this.chosen, this.fallback);
  final Directory chosen;
  final Directory fallback;
  bool unreachable = false;

  @override
  Future<(Directory, bool)> rootWithFallback() async =>
      unreachable ? (fallback, true) : (chosen, false);
}

/// Accesso finto: il rinnovo del token riesce sempre.
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
  Future<OAuthTokens> refresh(String refreshToken) => signIn();
}

void main() {
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('crash_r4_ric_');
  });
  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('scritture sicure', () {
    test('il file temporaneo non si rinomina: il file non sparisce', () async {
      final f = File(p.join(tmp.path, 'nota.md'))..writeAsStringSync('vecchio');
      await IOOverrides.runWithIOOverrides(() async {
        try {
          await writeStringAtomic(File(f.path), 'nuovo');
        } on FileSystemException {
          // un errore va bene, la perdita del file no
        }
      }, _StuckPartOverrides());
      // prima: l'originale si cancellava per riprovare la rinomina, la
      // seconda rinomina falliva e anche la copia nuova veniva cancellata
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), anyOf('vecchio', 'nuovo'));
    });
  });

  group('registro degli errori', () {
    tearDown(() {
      ErrorLog.directory = () async => Directory.systemTemp;
      ErrorLog.resetForTest();
    });

    test('un registro con byte non UTF-8 si legge lo stesso', () async {
      ErrorLog.resetForTest();
      ErrorLog.directory = () async => tmp;
      // voce troncata a metà di una lettera accentata (app chiusa mentre
      // scriveva), poi una voce intera
      File(p.join(tmp.path, ErrorLog.fileName)).writeAsBytesSync([
        ...utf8.encode('[1] Avvio\nerrore '),
        0xC3,
        ...utf8.encode('\n[2] Avvio\nseconda voce\n'),
      ]);
      final text = await ErrorLog.read();
      // prima: FormatException ignorata e registro mostrato vuoto
      expect(text, contains('seconda voce'));
    });
  });

  group('pagine HTML', () {
    test('una pagina salvata con script e paragrafi aperti resta una pagina', () {
      final b = StringBuffer('<html><head><script>');
      // codice minimizzato: «i<n» non è un tag
      for (var i = 0; i < 1500; i++) {
        b.write('for(i=0;i<n;i++){x+=a[i]}');
      }
      b.write('</script><style>a<b{color:red}</style></head><body>');
      // HTML vecchio: <p> e <li> senza chiusura (il parser li chiude)
      for (var i = 0; i < 1200; i++) {
        b.write('<p>Paragrafo $i');
      }
      b.write('<ul>');
      for (var i = 0; i < 1200; i++) {
        b.write('<li>Voce $i');
      }
      b.write('</ul><!-- <div><div><div> --></body></html>');
      final html = b.toString();
      expect(htmlNesting(html), lessThan(kHtmlMaxNesting));
      final blocks = HtmlBlocks.parse(html);
      final texts = [
        for (final x in blocks)
          if (x is RPara) x.text,
      ];
      // prima: tutta la pagina (codice compreso) in un solo paragrafo
      expect(texts, contains('Paragrafo 5'));
      expect(texts.any((t) => t.contains('x+=a[i]')), isFalse);
    });

    test('annidamento vero oltre il limite: ancora solo testo', () {
      final html = '${'<div>' * (kHtmlMaxNesting + 50)}fondo';
      expect(htmlNesting(html), greaterThan(kHtmlMaxNesting));
      final blocks = HtmlBlocks.parse(html);
      expect(blocks.whereType<RPara>().map((x) => x.text).join(), 'fondo');
    });
  });

  group('cartelle degli appunti', () {
    late AppDatabase db;
    late SettingsRepository settings;
    setUp(() async {
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
    });
    tearDown(() => db.close());

    test('cartella di un insegnamento con il nome di prima: si ritrova', () async {
      final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
      final notes = NotesStore(settings, root: () async => root);
      // il nome della cartella dei giri precedenti teneva il punto iniziale
      // (ora tolto, come i punti finali dopo il taglio a 90 caratteri)
      const c = Course(id: 1, name: '.NET e programmazione');
      File(p.join(root.path, '.NET e programmazione', 'Registrazioni', 'a.m4a'))
        ..createSync(recursive: true)
        ..writeAsBytesSync([1, 2, 3]);
      expect(NotesStore.folderName(c), 'NET e programmazione');
      // prima: registrazioni sparite dall'app dopo l'aggiornamento
      expect(await notes.count(c), 1);
      final list = await notes.list(c);
      expect(list[NoteFolder.recordings]!.single.name, 'a');
      expect(
        Directory(p.join(root.path, 'NET e programmazione')).existsSync(),
        isTrue,
      );
    });

    test(
      'nome lungo tagliato su un punto (database dei corsi): si ritrova',
      () async {
        final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
        final notes = NotesStore(settings, root: () async => root);
        const c = Course(
          id: 2,
          universityId: 'polito',
          name:
              'Sistemi di Programmazione e Controllo Nelle Organizzazioni '
              'Pubbliche e Private C.I. suddivisa in moduli',
        );
        const old =
            'PoliTo - Sistemi di Programmazione e Controllo Nelle '
            'Organizzazioni Pubbliche e Private C.';
        File(p.join(root.path, old, 'Appunti', 'x.md'))
          ..createSync(recursive: true)
          ..writeAsStringSync('appunti');
        expect(await notes.count(c), 1);
      },
      // su Windows il punto finale non esiste nei nomi: è la stessa cartella
      skip: Platform.isWindows,
    );

    test(
      'Windows: cartella scelta non raggiungibile → si sa che è la predefinita',
      () async {
        final docs = Directory(p.join(tmp.path, 'Documenti'))..createSync();
        TestWidgetsFlutterBinding.ensureInitialized();
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              const MethodChannel('plugins.flutter.io/path_provider'),
              (_) async => docs.path,
            );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding
              .instance
              .defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('plugins.flutter.io/path_provider'),
                null,
              ),
        );
        // un'unità che non c'è
        String? missing;
        for (var c = 'Z'.codeUnitAt(0); c > 'D'.codeUnitAt(0); c--) {
          final d = '${String.fromCharCode(c)}:\\';
          if (!Directory(d).existsSync()) {
            missing = d;
            break;
          }
        }
        if (missing == null) return;
        await settings.set(SettingKeys.appuntiRoot, '${missing}Appunti');
        final notes = NotesStore(settings);
        final (dir, fallback) = await notes.rootWithFallback();
        expect(fallback, isTrue);
        expect(p.isWithin(docs.path, dir.path), isTrue);
        await settings.set(SettingKeys.appuntiRoot, p.join(tmp.path, 'Mia'));
        final (dir2, fallback2) = await notes.rootWithFallback();
        expect(fallback2, isFalse);
        expect(dir2.path, p.join(tmp.path, 'Mia', 'Corsi'));
      },
      skip: !Platform.isWindows,
    );
  });

  group('sincronizzazione con la cartella degli appunti non raggiungibile', () {
    late AppDatabase db;
    late SettingsRepository settings;
    setUp(() async {
      db = await AppDatabase.openInMemory();
      settings = SettingsRepository(db);
      await settings.set('install_id', 't1');
    });
    tearDown(() => db.close());

    test('gli appunti su OneDrive non si eliminano', () async {
      Directory dir(String name) =>
          Directory(p.join(tmp.path, name))..createSync(recursive: true);
      final drive = FakeDrive();
      final notes = _SwitchableNotes(settings, dir('scelta'), dir('predef'));
      final od = OneDriveService(
        settings,
        notes,
        secrets: MemoryCloudSecrets(),
        transport: drive.call,
        oauthFactory: (_, _) => _FakeOAuth(),
        stateDir: () async => dir('stato'),
        builtInClientId: '11111111-2222-3333-4444-555555555555',
        deviceName: 'PC',
        sources: SyncSources(
          books: () async => dir('libri'),
          materials: () async => dir('materiali'),
          attachments: () async => dir('allegati'),
        ),
      );
      await od.signIn();
      await od.setScopes({SyncScope.notes});
      File(p.join(notes.chosen.path, 'Fisica', 'Appunti', 'a.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('uno');
      await od.sync();
      const remote = 'UniNotes/Corsi/Fisica/Appunti/a.md';
      expect(drive.files.containsKey(remote), isTrue);

      // il disco scelto non risponde: la radice è quella predefinita (vuota)
      notes.unreachable = true;
      final r = await od.sync();
      // prima: «eliminato su questo dispositivo» → nel cestino di OneDrive
      // (e poi tolto da tutti gli altri dispositivi)
      expect(drive.files.containsKey(remote), isTrue);
      expect(drive.trash, isEmpty);
      expect(r, isNotNull);
      expect(r!.errors.join(' '), contains('non è raggiungibile'));

      // tornato il disco: tutto come prima, niente da eliminare
      notes.unreachable = false;
      await od.sync();
      expect(drive.files.containsKey(remote), isTrue);
      expect(drive.trash, isEmpty);
    });
  });
}
