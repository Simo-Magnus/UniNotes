import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/academic/electives.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/external_launcher.dart';
import 'package:university_notes/features/cloud/data_sync_snapshot.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/wav.dart';
import 'package:university_notes/features/notes/recycle_bin.dart';
import 'package:university_notes/features/reader/parsers/html_blocks.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Quinto giro della caccia ai crash: i problemi rimasti aperti dai giri
/// precedenti (insegnamenti a scelta, cartelle degli appunti in uso, lente o
/// di ripiego, cestino, «Elimina tutti i dati» su Android, widget, percorsi
/// relativi, caricamenti lenti, testo delle pagine HTML, WAV dopo un errore).

Future<AppServices> _empty() async {
  final db = await AppDatabase.openInMemory();
  for (final t in ['courses', 'exams', 'modules', 'topics', 'events']) {
    await db.db.delete(t);
  }
  return AppServices(db);
}

// ------------------------------------------------- file system finto

/// Cartella vera con alcune operazioni cambiate (cartella in uso, unità
/// lenta o assente).
class _HookDir implements Directory {
  _HookDir(this._real, this._fs);
  final Directory _real;
  final _Fs _fs;

  @override
  String get path => _real.path;
  @override
  Uri get uri => _real.uri;
  @override
  Directory get absolute => _HookDir(_real.absolute, _fs);
  @override
  Directory get parent => _HookDir(_real.parent, _fs);
  @override
  bool get isAbsolute => _real.isAbsolute;
  @override
  Future<bool> exists() async {
    final hook = _fs.exists;
    if (hook != null) {
      final r = await hook(path);
      if (r != null) return r;
    }
    return _real.exists();
  }

  @override
  bool existsSync() => _real.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) async {
    await _real.create(recursive: recursive);
    return this;
  }

  @override
  void createSync({bool recursive = false}) =>
      _real.createSync(recursive: recursive);
  @override
  Future<Directory> rename(String newPath) async {
    if (_fs.stuck.any((s) => p.equals(s, path))) {
      throw FileSystemException('Cartella in uso', path);
    }
    return _real.rename(newPath);
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => _real.list(recursive: recursive, followLinks: followLinks);
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => _real.listSync(recursive: recursive, followLinks: followLinks);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _real.delete(recursive: recursive);
  @override
  void deleteSync({bool recursive = false}) =>
      _real.deleteSync(recursive: recursive);
  @override
  Future<FileStat> stat() => _real.stat();
  @override
  FileStat statSync() => _real.statSync();
  @override
  Future<String> resolveSymbolicLinks() => _real.resolveSymbolicLinks();
  @override
  Future<Directory> createTemp([String? prefix]) => _real.createTemp(prefix);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// File vero che non si lascia spostare (in uso).
class _HookFile implements File {
  _HookFile(this._real, this._fs);
  final File _real;
  final _Fs _fs;

  @override
  String get path => _real.path;
  @override
  Uri get uri => _real.uri;
  @override
  File get absolute => _HookFile(_real.absolute, _fs);
  @override
  Directory get parent => _real.parent;
  @override
  bool get isAbsolute => _real.isAbsolute;
  @override
  Future<bool> exists() => _real.exists();
  @override
  bool existsSync() => _real.existsSync();
  @override
  Future<File> create({bool recursive = false, bool exclusive = false}) =>
      _real.create(recursive: recursive, exclusive: exclusive);
  @override
  void createSync({bool recursive = false, bool exclusive = false}) =>
      _real.createSync(recursive: recursive, exclusive: exclusive);
  @override
  void writeAsStringSync(
    String contents, {
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
    bool flush = false,
  }) => _real.writeAsStringSync(
    contents,
    mode: mode,
    encoding: encoding,
    flush: flush,
  );
  @override
  String readAsStringSync({Encoding encoding = utf8}) =>
      _real.readAsStringSync(encoding: encoding);
  @override
  void setLastModifiedSync(DateTime time) => _real.setLastModifiedSync(time);
  @override
  Future<File> rename(String newPath) async {
    if (_fs.stuck.any((s) => p.equals(s, path))) {
      throw FileSystemException('File in uso', path);
    }
    return _real.rename(newPath);
  }

  @override
  Future<File> copy(String newPath) => _real.copy(newPath);
  @override
  Future<FileSystemEntity> delete({bool recursive = false}) async {
    if (_fs.stuck.any((s) => p.equals(s, path))) {
      throw FileSystemException('File in uso', path);
    }
    return _real.delete(recursive: recursive);
  }

  @override
  Future<FileStat> stat() => _real.stat();
  @override
  FileStat statSync() => _real.statSync();
  @override
  Future<DateTime> lastModified() => _real.lastModified();
  @override
  Future<int> length() => _real.length();
  @override
  Future<String> readAsString({Encoding encoding = utf8}) =>
      _real.readAsString(encoding: encoding);
  @override
  Future<Uint8List> readAsBytes() => _real.readAsBytes();
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
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    await _real.writeAsBytes(bytes, mode: mode, flush: flush);
    return this;
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _real.open(mode: mode);
  @override
  IOSink openWrite({
    FileMode mode = FileMode.write,
    Encoding encoding = utf8,
  }) => _real.openWrite(mode: mode, encoding: encoding);
  @override
  Stream<List<int>> openRead([int? start, int? end]) =>
      _real.openRead(start, end);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Regole del file system finto.
class _Fs {
  /// Percorsi (cartelle o file) che non si lasciano rinominare.
  final Set<String> stuck = {};

  /// `exists()` di una cartella: null = risposta vera.
  Future<bool?> Function(String path)? exists;
}

final class _Overrides extends IOOverrides {
  _Overrides(this.fs);
  final _Fs fs;

  @override
  Directory createDirectory(String path) =>
      _HookDir(super.createDirectory(path), fs);

  @override
  File createFile(String path) => _HookFile(super.createFile(path), fs);
}

Future<T> _withFs<T>(_Fs fs, Future<T> Function() body) =>
    IOOverrides.runWithIOOverrides(body, _Overrides(fs));

// ------------------------------------------------------ rete finta

/// Richiesta HTTP finta: ogni pezzo da [chunkRate] byte impiega [per] a
/// partire (rete lenta ma che avanza).
class _SlowRequest implements HttpClientRequest {
  _SlowRequest(this.per, this.chunkRate);
  final Duration per;
  final int chunkRate;
  final List<int> received = [];
  final _pending = <int>[];
  @override
  final HttpHeaders headers = _Headers();
  @override
  int contentLength = -1;

  @override
  void add(List<int> data) => _pending.addAll(data);

  Future<void> _send() async {
    while (_pending.isNotEmpty) {
      final n = _pending.length < chunkRate ? _pending.length : chunkRate;
      await Future<void>.delayed(per);
      received.addAll(_pending.sublist(0, n));
      _pending.removeRange(0, n);
    }
  }

  @override
  Future<void> flush() => _send();

  @override
  Future<HttpClientResponse> close() async {
    await _send();
    return _Response(200, utf8.encode('{"ok":true}'));
  }

  @override
  Future<HttpClientResponse> get done => close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  final map = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      map[name] = '$value';
  @override
  void forEach(void Function(String name, List<String> values) action) =>
      map.forEach((k, v) => action(k, [v]));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  _Response(this.statusCode, this.body);
  @override
  final int statusCode;
  final List<int> body;
  @override
  final HttpHeaders headers = _Headers();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.fromIterable([body]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _SlowClient implements HttpClient {
  _SlowClient(this.request);
  final _SlowRequest request;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async => request;
  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _HttpOverrides extends HttpOverrides {
  _HttpOverrides(this.client);
  final HttpClient client;
  @override
  HttpClient createHttpClient(SecurityContext? context) => client;
}

// ------------------------------------------------- WAV con disco pieno

class _FailingRaf implements RandomAccessFile {
  _FailingRaf(this._real);
  final RandomAccessFile _real;
  int writes = 0;

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    // l'intestazione si scrive, poi il disco è pieno
    if (writes++ > 0) {
      throw const FileSystemException('Spazio esaurito sul disco');
    }
    await _real.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<int> position() => _real.position();
  @override
  Future<RandomAccessFile> setPosition(int position) async {
    await _real.setPosition(position);
    return this;
  }

  @override
  Future<RandomAccessFile> flush() async {
    await _real.flush();
    return this;
  }

  @override
  Future<void> close() => _real.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FullDiskFile implements File {
  _FullDiskFile(this._real);
  final File _real;
  @override
  String get path => _real.path;
  @override
  Directory get parent => _real.parent;
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async =>
      _FailingRaf(await _real.open(mode: mode));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// OneDrive che conta i tentativi di sincronizzazione.
class _CountingDrive extends OneDriveService {
  _CountingDrive(super.settings, super.notes);
  int checks = 0;
  @override
  Future<bool> connected() async {
    checks++;
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('crash_r5_');
    NotesStore.forgetReachability();
  });
  tearDown(() async {
    networkIdleTimeout = const Duration(seconds: 60);
    CloudDriveService.busyElsewhere = null;
    CloudDriveService.hold = false;
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// Documenti dell'app (cartella di ripiego degli appunti) in [docs].
  void mockDocs(Directory docs) {
    const ch = MethodChannel('plugins.flutter.io/path_provider');
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(ch, (_) async => docs.path);
    addTearDown(() => m.setMockMethodCallHandler(ch, null));
  }

  group('1. insegnamento a scelta: si archivia solo senza nessuna prova', () {
    test('restano altre prove in itinere: niente archiviazione', () async {
      final s = await _empty();
      addTearDown(s.database.close);
      final c = await s.courses.insert(
        const Course(name: 'Robotica', mandatory: false),
      );
      final a = (await s.exams.byId(
        await s.exams.save(Exam(courseId: c, kind: ExamKind.midterm)),
      ))!;
      final b = (await s.exams.byId(
        await s.exams.save(Exam(courseId: c, kind: ExamKind.midterm)),
      ))!;
      // eliminando una delle due prove in itinere resta l'altra
      expect(await wouldDropElective(s, a), isFalse);
      await s.exams.delete(a.id!);
      expect(await dropElectiveWithoutExam(s, c), isFalse);
      expect((await s.courses.byId(c))!.status, isNot(CourseStatus.archived));
      // l'ultima: sì
      expect(await wouldDropElective(s, b), isTrue);
      await s.exams.delete(b.id!);
      expect(await dropElectiveWithoutExam(s, c), isTrue);
      expect((await s.courses.byId(c))!.status, CourseStatus.archived);
    });

    test('eliminato l\'esame finale con una prova in itinere: resta', () async {
      final s = await _empty();
      addTearDown(s.database.close);
      final c = await s.courses.insert(
        const Course(name: 'Robotica', mandatory: false),
      );
      await s.exams.save(Exam(courseId: c, kind: ExamKind.midterm));
      final fin = (await s.exams.byId(await s.exams.save(Exam(courseId: c))))!;
      expect(await wouldDropElective(s, fin), isFalse);
      await s.exams.delete(fin.id!);
      expect(await dropElectiveWithoutExam(s, c), isFalse);
      expect((await s.courses.byId(c))!.status, isNot(CourseStatus.archived));
    });
  });

  group('2. cartella dell\'insegnamento in uso durante la rinomina', () {
    const a = Course(name: 'Analisi', universityId: 'polito');
    const b = Course(name: 'Analisi 1', universityId: 'polito');

    test('gli appunti si vedono ancora e la rinomina si riprova', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
      final rec = File(
        p.join(root.path, NotesStore.folderName(a), 'Registrazioni', 'l.wav'),
      )..createSync(recursive: true);
      final fs = _Fs()..stuck.add(rec.parent.parent.path);
      await _withFs(fs, () async {
        final store = NotesStore(settings, root: () async => root);
        // non riuscita: chi chiama lo dice (NotesStore.renamePendingNote)
        expect(await store.renameCourse(a, b), isFalse);
        expect(store.hasPendingRename(b), isTrue);
        // la cartella è ancora quella di prima, ma l'app la trova
        final files = (await store.list(b))[NoteFolder.recordings]!;
        expect(files.map((f) => p.basename(f.file.path)), ['l.wav']);
        expect(await store.count(b), 1);
        // le registrazioni nuove vanno nella stessa cartella
        final dir = await store.courseDir(b, NoteFolder.recordings);
        expect(p.equals(dir.path, rec.parent.path), isTrue);
        // riaprendo l'app (altra istanza) la si trova ancora
        final again = NotesStore(settings, root: () async => root);
        expect((await again.list(b))[NoteFolder.recordings], hasLength(1));
        // cartella libera: al prossimo accesso prende il nome nuovo
        fs.stuck.clear();
        expect((await again.list(b))[NoteFolder.recordings], hasLength(1));
        expect(again.hasPendingRename(b), isFalse);
        expect(await settings.get(NotesStore.pendingRenamesKey), isNull);
      });
      expect(
        Directory(p.join(root.path, NotesStore.folderName(a))).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(root.path, NotesStore.folderName(b), 'Registrazioni', 'l.wav'),
        ).existsSync(),
        isTrue,
      );
    });

    test('unione con una cartella già presente e un file in uso', () async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final settings = SettingsRepository(db);
      final root = Directory(p.join(tmp.path, 'Corsi'))..createSync();
      final oldDir = p.join(root.path, NotesStore.folderName(a), 'Appunti');
      final newDir = p.join(root.path, NotesStore.folderName(b), 'Appunti');
      final busy = File(p.join(oldDir, 'aperto.md'))
        ..createSync(recursive: true);
      File(p.join(oldDir, 'libero.md')).createSync();
      File(p.join(newDir, 'nuovo.md')).createSync(recursive: true);
      final fs = _Fs()..stuck.add(busy.path);
      await _withFs(fs, () async {
        final store = NotesStore(settings, root: () async => root);
        await store.renameCourse(a, b);
        final names = {
          for (final f in (await store.list(b))[NoteFolder.notes]!)
            p.basename(f.file.path),
        };
        // anche il file rimasto nella cartella col nome di prima
        expect(names, {'aperto.md', 'libero.md', 'nuovo.md'});
        expect(await store.count(b), 3);
        fs.stuck.clear();
        await store.list(b);
      });
      expect(File(p.join(newDir, 'aperto.md')).existsSync(), isTrue);
      expect(
        Directory(p.join(root.path, NotesStore.folderName(a))).existsSync(),
        isFalse,
      );
    });
  });

  group('3. cartella scelta lenta o tornata dopo il ripiego', () {
    test(
      'un disco che si sveglia in 6 secondi non manda nel ripiego',
      () async {
        final db = await AppDatabase.openInMemory();
        addTearDown(db.close);
        final settings = SettingsRepository(db);
        final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
        mockDocs(docs);
        final chosen = p.join(tmp.path, 'Mia');
        await settings.set(SettingKeys.appuntiRoot, chosen);
        final prefix = p.rootPrefix(chosen);
        var calls = 0;
        final fs = _Fs()
          ..exists = (path) async {
            if (!p.equals(path, prefix)) return null;
            calls++;
            await Future<void>.delayed(const Duration(seconds: 6));
            return true;
          };
        await _withFs(fs, () async {
          final store = NotesStore(settings);
          final (dir, fellBack) = await store.rootWithFallback();
          expect(fellBack, isFalse);
          expect(dir.path, p.join(chosen, 'Corsi'));
          // l'esito si ricorda: la lettura dopo non aspetta di nuovo
          final t = Stopwatch()..start();
          final (dir2, _) = await store.rootWithFallback();
          expect(dir2.path, p.join(chosen, 'Corsi'));
          expect(t.elapsed, lessThan(const Duration(seconds: 3)));
          expect(calls, 1);
        });
      },
      skip: !Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'cartella scelta tornata: le registrazioni fatte nel frattempo la '
      'raggiungono',
      () async {
        final db = await AppDatabase.openInMemory();
        addTearDown(db.close);
        final settings = SettingsRepository(db);
        final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
        mockDocs(docs);
        final chosen = p.join(tmp.path, 'Mia');
        await settings.set(SettingKeys.appuntiRoot, chosen);
        // appunti già nella cartella scelta
        final kept = File(p.join(chosen, 'Corsi', 'Analisi', 'Appunti', 'a.md'))
          ..createSync(recursive: true);
        // appunti vecchi nella predefinita, di prima della scelta
        final legacy = File(
          p.join(docs.path, 'UniNotes', 'Corsi', 'Vecchio', 'Appunti', 'v.md'),
        )..createSync(recursive: true);
        legacy.setLastModifiedSync(DateTime(2025, 1, 1));
        final prefix = p.rootPrefix(chosen);
        var unreachable = true;
        final fs = _Fs()
          ..exists = (path) async =>
              p.equals(path, prefix) && unreachable ? false : null;
        await _withFs(fs, () async {
          final store = NotesStore(settings);
          final (fb, fellBack) = await store.rootWithFallback();
          expect(fellBack, isTrue);
          final rec = File(
            p.join(fb.path, 'Analisi', 'Registrazioni', 'lezione.wav'),
          )..createSync(recursive: true);
          rec.writeAsStringSync('audio');
          unreachable = false;
          // la cartella scelta torna: le registrazioni nuove la
          // raggiungono, quelle vecchie restano dov'erano
          final moved = File(
            p.join(chosen, 'Corsi', 'Analisi', 'Registrazioni', 'lezione.wav'),
          );
          final until = DateTime.now().add(const Duration(seconds: 20));
          while (!moved.existsSync() && DateTime.now().isBefore(until)) {
            // (l'esito «non raggiungibile» si ricorda per qualche secondo)
            NotesStore.forgetReachability();
            await NotesStore(settings).rootWithFallback();
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          expect(moved.existsSync(), isTrue);
          expect(moved.readAsStringSync(), 'audio');
          expect(rec.existsSync(), isFalse);
        });
        expect(kept.existsSync(), isTrue);
        expect(legacy.existsSync(), isTrue);
      },
      skip: !Platform.isWindows,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  });

  group('4. sincronizzazione dei dati con la cartella di ripiego', () {
    test(
      'i percorsi degli allegati restano relativi alla cartella scelta',
      () async {
        final db = await AppDatabase.openInMemory();
        addTearDown(db.close);
        final settings = SettingsRepository(db);
        final docs = Directory(p.join(tmp.path, 'docs'))..createSync();
        mockDocs(docs);
        final chosen = p.join(tmp.path, 'Mia');
        await settings.set(SettingKeys.appuntiRoot, chosen);
        final prefix = p.rootPrefix(chosen);
        final fs = _Fs()
          ..exists = (path) async => p.equals(path, prefix) ? false : null;
        final s = AppServices(db, notes: NotesStore(settings));
        final course = await s.courses.insert(const Course(name: 'Lab'));
        final m = await db.db.insert('modules', {
          'course_id': course,
          'name': 'Arduino',
        });
        final attached = p.join(chosen, 'Corsi', 'Lab', 'Riassunti', 'l.md');
        await db.db.insert('attachments', {
          'module_id': m,
          'title': 'l.md',
          'path': attached,
          'created_at': '2026-10-21T08:00:00',
        });
        // riassunto salvato nella cartella di ripiego: andrà nello stesso
        // posto della cartella scelta quando torna
        await db.db.insert('attachments', {
          'module_id': m,
          'title': 'r.md',
          'path': p.join(
            docs.path,
            'UniNotes',
            'Corsi',
            'Lab',
            'Riassunti',
            'r.md',
          ),
          'created_at': '2026-10-21T09:00:00',
        });
        final dati = Directory(p.join(tmp.path, 'Dati'))..createSync();
        await _withFs(fs, () async {
          expect((await s.notes.rootWithFallback()).$2, isTrue);
          await s.dataSync.mergeFolder(dati, ownName: 'me.json.gz');
        });
        final own = SyncSnapshot.decode(
          File(p.join(dati.path, 'me.json.gz')).readAsBytesSync(),
        )!;
        final paths = [
          for (final e in own.table('attachments').values) e.values['path'],
        ];
        expect(paths.toSet(), {
          'appunti:Lab/Riassunti/l.md',
          'appunti:Lab/Riassunti/r.md',
        });
        // nel database resta il percorso di prima
        expect(
          (await db.db.query('attachments', orderBy: 'id')).first['path'],
          attached,
        );
      },
      skip: !Platform.isWindows,
    );
  });

  group('5. «Eliminati di recente» dopo il cambio della cartella', () {
    test('il ripristino usa la cartella degli appunti attuale', () async {
      final now = Directory(p.join(tmp.path, 'Nuova', 'Corsi'))
        ..createSync(recursive: true);
      final old = p.join(tmp.path, 'Vecchia', 'Corsi');
      final bin = RecycleBin(() async => now);
      final entryDir = Directory(
        p.join(now.path, RecycleBin.dirName, '1700000000000'),
      )..createSync(recursive: true);
      File(p.join(entryDir.path, 'l.wav')).writeAsStringSync('audio');
      File(p.join(entryDir.path, 'l.json')).writeAsStringSync('{}');
      File(p.join(entryDir.path, 'fuori.txt')).writeAsStringSync('x');
      final outside = p.join(tmp.path, 'Altrove', 'fuori.txt');
      File(p.join(entryDir.path, 'info.json')).writeAsStringSync(
        jsonEncode({
          'titolo': 'Lezione',
          'eliminato': DateTime.now().toIso8601String(),
          'file': [
            {
              'nome': 'l.wav',
              'origine': p.join(old, 'Analisi', 'Registrazioni', 'l.wav'),
            },
            {
              'nome': 'l.json',
              'origine': p.join(old, 'Analisi', 'Registrazioni', 'l.json'),
            },
            // percorso che non è degli appunti: resta quello
            {'nome': 'fuori.txt', 'origine': outside},
          ],
        }),
      );
      final entry = (await bin.list()).single;
      final files = await bin.restore(entry);
      expect(files, hasLength(3));
      expect(
        File(p.join(now.path, 'Analisi', 'Registrazioni', 'l.wav'))
            .existsSync(),
        isTrue,
      );
      expect(
        File(p.join(now.path, 'Analisi', 'Registrazioni', 'l.json'))
            .existsSync(),
        isTrue,
      );
      expect(File(outside).existsSync(), isTrue);
      expect(Directory(old).existsSync(), isFalse);
    });
  });

  group('6. «Elimina tutti i dati» e la sincronizzazione in background', () {
    test('aspetta il motore in background e non ne fa partire altre', () async {
      final db = await AppDatabase.openInMemory();
      final settings = SettingsRepository(db);
      Directory dir(String rel) =>
          Directory(p.join(tmp.path, rel))..createSync(recursive: true);
      final notes = NotesStore(settings, root: () async => dir('appunti'));
      final drive = _CountingDrive(settings, notes);
      final s = AppServices(db, notes: notes, onedrive: drive);
      final until = DateTime.now().add(const Duration(milliseconds: 800));
      CloudDriveService.busyElsewhere = () async =>
          DateTime.now().isBefore(until);
      final eraser = DataEraser(
        s,
        supportDir: () async => dir('supporto'),
        cacheDirs: () async => [dir('cache')],
        wipeSecrets: () async {},
        clearPrefs: () async {},
        syncWait: const Duration(seconds: 10),
      );
      final t = Stopwatch()..start();
      final run = eraser.run(const {});
      await Future<void>.delayed(const Duration(milliseconds: 200));
      // a metà eliminazione nessuna sincronizzazione parte
      drive.checks = 0;
      expect(await drive.sync(), isNull);
      expect(drive.checks, 0);
      await run;
      expect(
        t.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 700)),
      );
    });
  });

  group('7. tocco su un widget Android durante l\'avvio', () {
    test('la schermata chiesta resta in attesa se Dart non ascolta ancora', () {
      final src = File(
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes/'
        'MainActivity.kt',
      ).readAsStringSync();
      final i = src.indexOf('fun onNewIntent');
      expect(i, greaterThan(0));
      final body = src.substring(
        i,
        src.indexOf('override fun cleanUpFlutterEngine', i),
      );
      // l'invio verso Dart ha una risposta: senza chi la riceve
      // (notImplemented, errore) la schermata va in pendingRoute
      expect(body, contains('invokeMethod("route", route, object'));
      expect(
        RegExp(
          r'notImplemented\(\)[^}]*pendingRoute = route',
          dotAll: true,
        ).hasMatch(body),
        isTrue,
      );
    });
  });

  group('8. percorsi relativi', () {
    test('«Apri cartella» di un libro con un percorso relativo', () async {
      for (final rel in ['.', 'libro.pdf', 'Libri/libro.pdf', '']) {
        expect(ExternalLauncher.unsafePathReason(rel), isNotNull, reason: rel);
      }
      // (prima `openPath('.')` apriva la cartella di lavoro del programma)
      final r = await ExternalLauncher.openPath('.');
      expect(r.ok, isFalse);
      expect(r.message, contains('Percorso incompleto'));
      expect(
        ExternalLauncher.unsafePathReason(p.join(tmp.path, 'libro.pdf')),
        isNull,
      );
    });
  });

  group('9. caricamenti su una rete molto lenta', () {
    test('un blocco che avanza piano non scade', () async {
      networkIdleTimeout = const Duration(milliseconds: 1500);
      // 160 KB a 20 KB/s: 8 secondi, oltre i «32 KB/s» di prima, ma ogni
      // pezzo arriva entro l'attesa senza dati
      final req = _SlowRequest(const Duration(milliseconds: 800), 16 * 1024);
      final body = List<int>.generate(160 * 1024, (i) => i & 0xFF);
      final r = await HttpOverrides.runWithHttpOverrides(
        () => ioTransport(
          'PUT',
          Uri.parse('https://graph.example/upload'),
          body: body,
        ),
        _HttpOverrides(_SlowClient(req)),
      );
      expect(r.status, 200);
      expect(req.received.length, body.length);
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('una rete ferma scade comunque', () async {
      networkIdleTimeout = const Duration(milliseconds: 300);
      final req = _SlowRequest(const Duration(seconds: 5), 16 * 1024);
      await expectLater(
        HttpOverrides.runWithHttpOverrides(
          () => ioTransport(
            'PUT',
            Uri.parse('https://graph.example/upload'),
            body: List<int>.filled(64 * 1024, 1),
          ),
          _HttpOverrides(_SlowClient(req)),
        ),
        throwsA(isA<TimeoutException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  });

  group('10. minori', () {
    test('pagina troppo annidata mostrata come testo: «&» giusto', () {
      final src =
          '${'<div>' * (kHtmlMaxNesting + 5)}Tom &amp; Jerry &lt;3 &egrave;'
          '${'</div>' * (kHtmlMaxNesting + 5)}';
      final text = parseHtmlSafe(src).body!.text;
      expect(text, contains('Tom & Jerry <3 è'));
      expect(text, isNot(contains('&amp;')));
    });

    test('WAV: la durata conta solo i dati scritti', () async {
      final f = _FullDiskFile(File(p.join(tmp.path, 'r.wav')));
      final w = await WavWriter.create(f, sampleRate: 16000, channels: 1);
      w.add(Uint8List(32000)); // 1 secondo
      await w.drain();
      expect(w.error, isNotNull);
      w.add(Uint8List(32000));
      await w.drain();
      expect(w.duration, Duration.zero);
      await w.close();
    });
  });
}
