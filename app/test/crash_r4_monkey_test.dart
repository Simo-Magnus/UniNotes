// Quarto giro della caccia ai crash (sigla R4-A): prova a caso automatica
// («monkey test») di tutta l'interfaccia. Si apre l'app vera
// (UniversityNotesApp → onboarding o AppShell) con servizi di prova e
// database preparati, poi un generatore a seme fisso esegue azioni casuali:
// tocchi e pressioni lunghe sugli elementi toccabili, tocchi in punti a caso,
// scorrimenti, testo casuale nei campi (emoji, testo lunghissimo, numeri
// strani), «Indietro», Esc, Tab e frecce, ridimensionamenti della finestra
// (da 320×568 a 1920×1080), caratteri ×1/×1,3/×2, tema chiaro/scuro e attese.
// Dopo ogni azione si raccolgono gli errori di Flutter e le eccezioni non
// gestite; al primo errore la prova si ferma con seme, passo e ultime azioni.
//
// Niente risorse vere: selettore dei file, link, «Condividi», «Apri con»,
// microfono, percorsi di sistema, notifiche e calendario sono finti; i
// pulsanti che uscirebbero dall'app o toccherebbero dati veri (accesso a
// OneDrive/Google/Outlook, «Elimina tutti i dati», Esplora file) si saltano
// (vedi [_denied]).
//
// Suite normale: pochi semi, qualche centinaio di azioni. Giro lungo:
//   CRASH_R4_MONKEY=1 flutter test test/crash_r4_monkey_test.dart
// con CRASH_R4_SEEDS (semi per scenario, predefinito 12), CRASH_R4_ACTIONS
// (azioni per seme, predefinito 1200) e CRASH_R4_SEED (un solo seme, per
// riprodurre un errore riportato).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';
import 'package:provider/provider.dart';
import 'package:university_notes/core/theme/display_prefs.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/notes/recording_player_screen.dart';
import 'package:university_notes/features/study/topics_tab.dart';
import 'package:university_notes/features/exams/averages_tab.dart';
import 'package:university_notes/features/exams/exam_stats.dart';
import 'package:university_notes/features/courses/course_form.dart';
import 'package:university_notes/features/courses/course_rename.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/features/books/book_tile.dart';
import 'package:university_notes/features/settings/sections/calendar_section.dart';
import 'package:university_notes/features/settings/sections/notifications_section.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'support/catalog_fixtures.dart';
import 'support/fake_parakeet.dart';
import 'support/fake_reminders.dart';

// ---------------------------------------------------------------- finti

/// Microfono finto: silenzio a richiesta, nessun dispositivo vero.
class _FakeRecorder implements AudioRecorder {
  final pcm = StreamController<Uint8List>.broadcast();

  @override
  Future<bool> hasPermission({bool request = true}) async => true;
  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig c)? cb) async {}
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async =>
      pcm.stream;
  @override
  Stream<RecordState> onStateChanged() => const Stream.empty();
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<String?> stop() async => null;
  @override
  Future<void> dispose() async {}
  @override
  Future<bool> isRecording() async => false;
  @override
  Future<bool> isPaused() async => false;
  @override
  Future<void> cancel() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// File scelto nel selettore finto.
final class _PickedFile extends PlatformFile {
  _PickedFile(this.file);
  final File file;

  @override
  String get name => p.basename(file.path);
  @override
  Uri get uri => Uri.file(file.path);
  @override
  get xFile => throw UnsupportedError('XFile non usato dalla prova');
  @override
  int? lengthSync() => file.existsSync() ? file.lengthSync() : null;
  @override
  Future<int?> length() async => lengthSync();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() =>
      file.openRead().map(Uint8List.fromList);
}

/// Selettore dei file finto: a volte «Annulla», a volte uno o più file della
/// cartella dei campioni (anche rovinati), mai una finestra vera.
class _FakePicker extends FilePickerPlatform {
  _FakePicker(this.samples, this.saved, this.rnd, this.log);
  final Directory samples;
  final Directory saved;
  final Random rnd;
  final void Function(String) log;

  List<File> get _files =>
      samples.listSync().whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (rnd.nextInt(3) == 0) {
      log('selettore: annullato');
      return null;
    }
    final f = _files[rnd.nextInt(_files.length)];
    log('selettore: ${p.basename(f.path)}');
    return _PickedFile(f);
  }

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (rnd.nextInt(3) == 0) {
      log('selettore: annullato');
      return const [];
    }
    final all = _files..shuffle(rnd);
    final n = 1 + rnd.nextInt(min(3, all.length));
    log('selettore: ${all.take(n).map((f) => p.basename(f.path)).join(', ')}');
    return [for (final f in all.take(n)) _PickedFile(f)];
  }

  @override
  Future<List<String>> pickFileAndDirectoryPaths({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
  }) async => const [];

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    AndroidOptions androidOptions = const AndroidOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (rnd.nextBool()) {
      log('cartella: annullata');
      return null;
    }
    final d = Directory(p.join(saved.path, 'cartella ${rnd.nextInt(3)}'))
      ..createSync(recursive: true);
    log('cartella: ${d.path}');
    return d.path;
  }

  @override
  Future<Uri?> saveFile({
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    String? dialogTitle,
    String? initialDirectory,
    Function(FilePickerStatus)? onFileSaving,
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    if (rnd.nextBool()) {
      log('salva: annullato');
      return null;
    }
    final f = File(p.join(saved.path, 'salvato_${rnd.nextInt(1000)}'));
    f.writeAsBytesSync(bytes);
    log('salva: ${bytes.length} byte');
    return Uri.file(f.path);
  }
}

/// Canali nativi: ognuno risponde come una piattaforma «senza plugin»
/// (MissingPluginException, come negli altri test), tranne quelli che
/// porterebbero fuori dall'app o su dati veri, che hanno una risposta finta.
class _Channels {
  _Channels(this.tmp);
  final Directory tmp;
  final Set<String> seen = {};
  final List<String> external = [];
  static const _codec = StandardMethodCodec();

  ByteData _ok(Object? v) => _codec.encodeSuccessEnvelope(v);

  Future<ByteData?>? handle(
    String channel,
    MessageHandler? handler,
    ByteData? message,
  ) {
    if (handler != null) return handler(message);
    MethodCall? call;
    try {
      if (message != null) call = _codec.decodeMethodCall(message);
    } catch (_) {}
    final m = call?.method ?? '?';
    switch (channel) {
      case 'flutter/platform':
        if (m == 'SystemNavigator.pop') {
          external.add('uscita dall\'app (SystemNavigator.pop)');
          return Future.value(_ok(null));
        }
        if (m == 'Clipboard.setData' || m == 'Clipboard.getData') {
          return Future.value(_ok(null));
        }
        break;
      case 'plugins.flutter.io/path_provider':
        final d = Directory(p.join(tmp.path, 'sistema', m))
          ..createSync(recursive: true);
        return Future.value(_ok(d.path));
      case 'plugins.flutter.io/url_launcher':
        external.add(
          'link: ${call?.arguments is Map ? (call!.arguments as Map)['url'] : m}',
        );
        return Future.value(_ok(m == 'closeWebView' ? null : true));
      case 'dev.fluttercommunity.plus/share':
        external.add('condividi');
        return Future.value(_ok('dev.fluttercommunity.plus/share/unavailable'));
      case 'io.github.simomagnus.universitynotes/apri_con':
        external.add('apri con');
        return Future.value(_ok('annullato'));
      case 'open_file':
        external.add('apri file');
        return Future.value(_ok('{"type":0,"message":"done"}'));
    }
    if (channel.startsWith('flutter/')) {
      return TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .delegate
          .send(channel, message);
    }
    seen.add('$channel#$m');
    return null;
  }
}

// ---------------------------------------------------------------- dati

/// Testi ostili per i nomi (come in crash_r3_testo_test.dart).
const _emoji = '\u{1F600}';
final _hostile = <String>[
  'Fisica $_emoji',
  '\u202Eelacitamatam\u202C Analisi',
  'Riga1\r\nRiga2\rRiga3',
  'e${'\u0301' * 60}',
  '\u0645\u0631\u062D\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 8,
  '\u200B\u200B',
  ' \u00A0\u2003\u3000 ',
  'Parola' * 400,
  _emoji * 120,
  r'C:\Windows\..\..\x',
  '../../etc/passwd',
  '<b>html</b> & "virgolette"',
  r'$\frac{1}{0}$ $$\sqrt{-1}$$',
];

/// Testo scritto nei campi.
final _typed = <String>[
  '',
  ' ',
  'a',
  'Analisi matematica',
  _emoji,
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 20,
  'x' * 5000,
  'lunghissimo ' * 2000,
  '0',
  '-1',
  '18',
  '30',
  '31',
  '110',
  '99999999999999999999999',
  '1e309',
  'NaN',
  'Infinity',
  '3,5',
  '6.0',
  '6,',
  '.',
  '30L',
  '30 e lode',
  '2026-02-31',
  '31/02/2026',
  '29/02/2027',
  '00:00',
  '25:61',
  '\n\n\n',
  'a\nb\nc',
  '\t',
  '<script>alert(1)</script>',
  r'$\frac{1}{0}$',
  r'$$',
  r'\[',
  '[link](javascript:alert(1))',
  'https://example.com/${'a' * 300}',
  r'C:\Windows\System32',
  '../../x',
  'ÀÈÌÒÙ àèìòù',
  '\u0645\u0631\u062D\u0628\u0627',
  '\u202Etesto',
  'e${'\u0301' * 50}',
  'null',
  '%s%n%x',
  "'; DROP TABLE courses; --",
  '*' * 1000,
  '((((((((((((((((((((a))))))))))))))))))))',
  '#' * 50,
];

String _randomText(Random r) {
  if (r.nextInt(3) > 0) return _typed[r.nextInt(_typed.length)];
  const pool = [
    'a',
    'b',
    'Z',
    '0',
    '9',
    ' ',
    '\n',
    '.',
    ',',
    '-',
    '/',
    ':',
    r'$',
    '\\',
    '#',
    '*',
    '_',
    '[',
    ']',
    '(',
    ')',
    '{',
    '}',
    'è',
    'ß',
    _emoji,
    '\u0301',
    '\u202E',
    '\u200D',
    '\u{1F468}',
    '\u4E2D',
    '\u0645',
  ];
  final n = r.nextInt(r.nextBool() ? 20 : 400);
  return List.generate(n, (_) => pool[r.nextInt(pool.length)]).join();
}

/// Un WAV di [seconds] secondi di silenzio (16 kHz, mono).
Uint8List _wav(int seconds) {
  final data = 16000 * 2 * seconds;
  final b = BytesBuilder();
  void s(String t) => b.add(ascii.encode(t));
  void u32(int v) => b.add([v & 255, v >> 8 & 255, v >> 16 & 255, v >> 24]);
  void u16(int v) => b.add([v & 255, v >> 8 & 255]);
  s('RIFF');
  u32(36 + data);
  s('WAVEfmt ');
  u32(16);
  u16(1);
  u16(1);
  u32(16000);
  u32(32000);
  u16(2);
  u16(16);
  s('data');
  u32(data);
  b.add(Uint8List(data));
  return b.toBytes();
}

/// File per il selettore finto: buoni, vuoti, troncati, con il nome strano.
void _writeSamples(Directory d, Random r) {
  d.createSync(recursive: true);
  void w(String name, List<int> bytes) =>
      File(p.join(d.path, name)).writeAsBytesSync(bytes);
  w(
    'appunti.md',
    utf8.encode('# Titolo\n\n- punto\n\n\$x^2\$ e testo $_emoji'),
  );
  w('testo.txt', utf8.encode('Riga uno\nRiga due\n${'parola ' * 3000}'));
  w('vuoto.txt', const []);
  w('pagina.html', utf8.encode('<html><body><h1>T</h1><p>p<b>b</p>'));
  w('tabella.csv', utf8.encode('a;b;c\n1;2;3\n"x;y";4\n'));
  w('backup.json', utf8.encode('{"version": 99, "courses": [{"name": 1}]'));
  w('dati.json', utf8.encode(jsonEncode({'courses': [], 'exams': null})));
  w('rovinato.docx', List.generate(3000, (_) => r.nextInt(256)));
  w('rovinato.epub', utf8.encode('PK\u0003\u0004 non è uno zip'));
  w('lezione.wav', _wav(1));
  w('troncato.wav', _wav(1).sublist(0, 60));
  w('casuale.bin', List.generate(5000, (_) => r.nextInt(256)));
  w('nome $_emoji con spazi.txt', utf8.encode('ciao'));
  w('immagine.png', [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
  w('dispense.zip', utf8.encode('PK'));
  w(
    'formule.tex',
    utf8.encode(r'\documentclass{article}\begin{document}$\int$'),
  );
}

enum _Scenario { vuoto, piano, limiti }

class _Setup {
  _Setup(this.services, this.tmp, this.channels);
  final AppServices services;
  final Directory tmp;
  final _Channels channels;
}

Future<AppServices> _services(AppDatabase db, Directory tmp) async {
  final settings = SettingsRepository(db);
  final notes = NotesStore(
    settings,
    root: () async => Directory(p.join(tmp.path, 'Appunti', 'Corsi')),
  );
  Future<Directory> support() async =>
      Directory(p.join(tmp.path, 'supporto'))..createSync(recursive: true);
  final secrets = MemoryCloudSecrets();
  return AppServices(
    db,
    library: BookLibrary(baseDir: support),
    materialsLibrary: BookLibrary(
      baseDir: support,
      folderName: BookLibrary.materialsFolder,
    ),
    attachmentsLibrary: BookLibrary(
      baseDir: support,
      folderName: BookLibrary.attachmentsFolder,
    ),
    notes: notes,
    catalog: fakeCatalog(
      settings,
      remote: {'corsi/polito.json': jsonEncode(corsiPolitoFixture())},
      cacheDir: Directory(p.join(tmp.path, 'catalogo'))
        ..createSync(recursive: true),
    ),
    whisper: WhisperService(
      settings: settings,
      baseDir: () async =>
          Directory(p.join(tmp.path, 'whisper'))..createSync(recursive: true),
      host: WhisperHost.windows,
      processRunner: (exe, _) async => throw ProcessException(exe, const []),
      processStarter: (exe, _) async => throw ProcessException(exe, const []),
      freeSpace: (_) async => 200 * 1000 * 1000 * 1000,
      deviceProbe: () async => const DeviceProfile(
        platform: WhisperPlatform.pc,
        ramBytes: 16 * 1000 * 1000 * 1000,
        cores: 8,
      ),
      parakeet: FakeParakeet(
        Directory(p.join(tmp.path, 'parakeet'))..createSync(recursive: true),
        isInstalled: false,
      ),
    ),
    onedrive: OneDriveService(
      settings,
      notes,
      secrets: secrets,
      stateDir: () async => tmp,
    ),
    googleDrive: GoogleDriveService(
      settings,
      notes,
      secrets: secrets,
      stateDir: () async => tmp,
      builtInClientId: 'client.apps.googleusercontent.com',
      builtInClientSecret: '',
    ),
    reminders: (s) => RemindersService(
      s,
      platform: FakeNotificationPlatform(),
      calendarBackend: FakeCalendarBackend(),
      widgets: FakeHomeWidgets(),
      platformName: 'windows',
      isRecording: () => false,
      focusQuietUntil: () => null,
    ),
    recorder: LectureRecorder(
      recorder: _FakeRecorder.new,
      workDir: () async =>
          Directory(p.join(tmp.path, 'lavoro'))..createSync(recursive: true),
      controls: () => const NoBackgroundControls(),
    ),
  );
}

/// Piano reale (PoliTO, fixture) al 2° anno nel 2026/27 con prove, studio,
/// libri, appunti e registrazioni.
Future<void> _fillPlan(AppServices s, {required bool hostile}) async {
  await PathSetupService(s).apply(
    PathSelection(
      ateneo: UniversitaCatalog.fromJson(kUniversitaFixture).byId('polito')!,
      tipo: TipoCorso.l,
      corso: IndiceCorsi.fromJson(kIndiceFixture).corsi.first,
      year: 2,
    ),
    now: DateTime(2026, 10, 4),
  );
  await s.loadProfile();
  var courses = await s.courses.all();
  final first = courses.first;
  if (hostile) {
    // nomi ostili, CFU strani, anni fuori piano, molti insegnamenti
    for (var i = 0; i < 60; i++) {
      await s.courses.insert(
        Course(
          name: _hostile[i % _hostile.length],
          universityId: first.universityId,
          degreeId: first.degreeId,
          year: 1 + i % 4,
          semester: '${1 + i % 3}',
          cfu: const [0.0, 0.5, 6.0, 12.0, 180.0, 1e9][i % 6],
          teacher: _hostile[(i + 3) % _hostile.length],
          description: _hostile[(i + 5) % _hostile.length],
        ),
      );
    }
    courses = await s.courses.all();
  }
  final now = DateTime.now();
  final day = DateTime(now.year, now.month, now.day);
  var k = 0;
  for (final c in courses.take(hostile ? 70 : 14)) {
    final id = c.id!;
    final n = k++;
    // esame finale (superato, prenotato, non superato, da completare…)
    final status = ExamStatus.values[n % ExamStatus.values.length];
    await s.exams.save(
      Exam(
        courseId: id,
        date: hostile && n % 5 == 0
            ? DateTime(1970 + n % 3, 1, 1)
            : day.add(Duration(days: (n % 9) * 11 - 40)),
        time: n.isEven ? '0${n % 10}:30' : null,
        status: status,
        grade: status == ExamStatus.passed ? 18 + n % 13 : null,
        laude: status == ExamStatus.passed && n % 13 == 12,
        title: hostile ? _hostile[n % _hostile.length] : null,
        location: hostile ? _hostile[(n + 2) % _hostile.length] : 'Aula 1',
        notes: hostile ? _hostile[(n + 4) % _hostile.length] : null,
        studyMaterials: n % 3 == 0 ? const ['Dispense', 'Esercizi'] : const [],
      ),
    );
    // prove in itinere ed esoneri
    if (n % 2 == 0) {
      await s.exams.save(
        Exam(
          courseId: id,
          kind: ExamKind.midterm,
          title: 'Prova in itinere ${n % 3 + 1}',
          date: day.add(Duration(days: n % 7 - 3)),
          status: n % 4 == 0 ? ExamStatus.passed : ExamStatus.booked,
          grade: n % 4 == 0 ? 20 + n % 10 : null,
        ),
      );
    }
    // Studio: moduli, argomenti, sessioni
    final m = await s.study.insertModule(
      StudyModule(courseId: id, name: hostile ? _hostile[n % 14] : 'Modulo 1'),
    );
    for (var t = 0; t < (hostile ? 12 : 3); t++) {
      await s.study.insertTopic(
        Topic(
          moduleId: m,
          name: hostile ? _hostile[(n + t) % 14] : 'Argomento ${t + 1}',
          status: TopicStatus.values[(n + t) % TopicStatus.values.length],
          sort: t,
        ),
      );
    }
    for (var d = 0; d < 3; d++) {
      final start = day.subtract(Duration(days: d * 2 + n % 3, hours: 3));
      final minutes = hostile && d == 0 ? 60 * 24 * 3 : 25 + 10 * d;
      await s.study.insertSession(
        StudySession(
          courseId: id,
          start: start,
          end: start.add(Duration(minutes: minutes)),
          durationMinutes: minutes,
          activityType: ActivityType.values[d % ActivityType.values.length],
          focus: d == 1,
        ),
      );
    }
  }
  // Libri con file nell'app
  final lib = await s.library.directory();
  for (var b = 0; b < (hostile ? 30 : 4); b++) {
    final name = 'libro_$b.${const ['txt', 'md', 'html', 'csv'][b % 4]}';
    File(p.join(lib.path, name)).writeAsStringSync(
      '# Libro $b\n\n${hostile ? _hostile[b % 14] : 'Capitolo uno.'}\n' * 30,
    );
    await s.books.insert(
      Book(
        courseId: courses[b % courses.length].id,
        title: hostile ? _hostile[b % 14] : 'Libro $b',
        author: 'Autore $b',
        format: BookFormat.values[b % BookFormat.values.length],
        ownership: BookOwnership.values[b % BookOwnership.values.length],
        storedFile: b % 3 == 2 ? 'mancante_$b.txt' : name,
        lastPage: b,
        pageCount: b % 2 == 0 ? 0 : 100,
      ),
    );
  }
  final mat = await s.materialsLibrary.directory();
  File(p.join(mat.path, 'dispense.md')).writeAsStringSync('# Dispense\n');
  await s.books.insertMaterial(
    StudyMaterial(
      courseId: first.id,
      title: 'Dispense',
      storedFile: 'dispense.md',
      kind: MaterialKind.lecture,
    ),
  );
  // Appunti, trascrizioni, riassunti e registrazioni finte
  for (final c in courses.take(hostile ? 8 : 3)) {
    await s.notes.writeText(
      c,
      NoteFolder.notes,
      'Appunti',
      '# Appunti\n\nTesto con formula \$e^{i\\pi}+1=0\$ e $_emoji.\n'
          '${hostile ? 'riga lunghissima ' * 3000 : ''}',
    );
    final rec = await s.notes.newRecordingPath(
      c,
      DateTime(2026, 10, 12, 8, 30),
      '.wav',
    );
    File(rec).writeAsBytesSync(_wav(2));
    final base = p.basenameWithoutExtension(rec);
    await s.notes.writeText(
      c,
      NoteFolder.transcripts,
      base,
      'Trascrizione della lezione. ${hostile ? _hostile.join(' ') : ''}',
    );
    await s.notes.writeText(c, NoteFolder.summaries, base, '## Riassunto\n');
    if (hostile) {
      // registrazione vuota e dati della registrazione rovinati
      final bad = await s.notes.newRecordingPath(
        c,
        DateTime(2026, 10, 13, 10),
        '.wav',
      );
      File(bad).writeAsBytesSync(const []);
      File(p.setExtension(bad, '.json')).writeAsStringSync('{"marks": [1,');
    }
  }
}

Future<_Setup> _prepare(_Scenario sc, Random r) async {
  final tmp = await Directory.systemTemp.createTemp('r4_monkey_');
  _writeSamples(Directory(p.join(tmp.path, 'campioni')), r);
  final db = await AppDatabase.openInMemory();
  final s = await _services(db, tmp);
  switch (sc) {
    case _Scenario.vuoto:
      // primo avvio: nessun profilo → onboarding
      break;
    case _Scenario.piano:
      await _fillPlan(s, hostile: false);
    case _Scenario.limiti:
      await _fillPlan(s, hostile: true);
  }
  return _Setup(s, tmp, _Channels(tmp));
}

// ---------------------------------------------------------------- scimmia

/// Pulsanti che non si toccano: uscirebbero dall'app o userebbero dati e
/// account veri (accesso a OneDrive/Google/Outlook, pulizia completa con
/// chiusura dell'app, Esplora file, appunti di sistema di Windows).
const _denied = <String>[
  'accedi',
  'elimina tutti i dati',
  'apri cartella',
  'apri la cartella',
  'mostra nella cartella',
  'mostra nella sua cartella',
  'copia i file',
];

/// «Collega» da solo (OneDrive, Google Drive, calendario di Outlook).
bool _isDenied(String label) {
  final l = label.toLowerCase();
  if (_denied.any(l.contains)) return true;
  return RegExp(r'(^|\|\s*)collega(\s*\||$)').hasMatch(l) ||
      l.contains('collega il calendario') ||
      l.contains('collega onedrive') ||
      l.contains('collega google');
}

class _Target {
  _Target(this.element, this.box, this.kind);
  final Element element;
  final RenderBox box;
  final String kind;
}

bool _privateUse(String s) => s.runes.any((c) => c >= 0xE000 && c <= 0xF8FF);

String _label(Element e) {
  final parts = <String>[];
  var budget = 400;
  void visit(Element el) {
    if (budget <= 0) return;
    final w = el.widget;
    if (w is RichText) {
      final t = w.text.toPlainText();
      if (!_privateUse(t)) {
        parts.add(t);
        budget -= t.length + 1;
      }
    } else if (w is Tooltip && w.message != null) {
      parts.add(w.message!);
    }
    el.visitChildren(visit);
  }

  visit(e);
  var n = 0;
  e.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Tooltip && w.message != null) parts.add(w.message!);
    if (w is Semantics && w.properties.label != null) {
      parts.add(w.properties.label!);
    }
    return ++n < 8;
  });
  return parts.where((s) => s.trim().isNotEmpty).join(' | ');
}

String _short(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ');
  final runes = one.runes.toList();
  return runes.length <= 60 ? one : '${String.fromCharCodes(runes.take(60))}…';
}

class _Monkey {
  _Monkey(this.t, this.seed, this.setup)
    : rnd = Random(seed),
      pickRnd = Random(seed * 31 + 7);
  final WidgetTester t;
  final int seed;
  final _Setup setup;
  final Random rnd;
  final Random pickRnd;
  final List<String> actions = [];
  final List<String> errors = [];
  final Map<String, int> overflows = {};

  /// Errori noti di Flutter, non dell'app (vedi il filtro in [_run]).
  final Map<String, int> known = {};

  /// Azioni che hanno impiegato più di 10 s veri.
  final List<String> slow = [];
  int done = 0;
  int empty = 0;
  int maxEmpty = 0;

  void log(String s) {
    actions.add('${done + 1}: $s');
    if (actions.length > 40) actions.removeAt(0);
    // CRASH_R4_TRACE=1: ogni azione subito sullo schermo (per gli stalli,
    // quando la prova finisce per il tempo scaduto senza resoconto)
    // ignore: avoid_print
    if (_trace) print('[$seed] ${actions.last}');
  }

  static const _sizes = [
    Size(320, 568),
    Size(360, 640),
    Size(375, 812),
    Size(412, 915),
    Size(568, 320),
    Size(600, 960),
    Size(768, 1024),
    Size(1024, 768),
    Size(1280, 800),
    Size(1366, 768),
    Size(1920, 1080),
  ];

  Size get _screen => t.view.physicalSize / t.view.devicePixelRatio;

  bool _onScreen(Offset o) {
    final s = _screen;
    return o.dx >= 0 && o.dy >= 0 && o.dx < s.width && o.dy < s.height;
  }

  /// [o] colpisce davvero [box] (niente dialoghi, barriere o altro sopra).
  bool _hits(RenderBox box, Offset o) {
    if (!_onScreen(o)) return false;
    final result = HitTestResult();
    t.binding.hitTestInView(result, o, t.view.viewId);
    return result.path.any((e) => identical(e.target, box));
  }

  List<_Target> _collect() {
    final out = <_Target>[];
    void visit(Element el) {
      final w = el.widget;
      String? kind;
      if (w is GestureDetector &&
          (w.onTap != null ||
              w.onTapDown != null ||
              w.onTapUp != null ||
              w.onLongPress != null ||
              w.onDoubleTap != null ||
              w.onSecondaryTap != null)) {
        kind = 'tocco';
      } else if (w is Checkbox ||
          w is Switch ||
          w is Radio ||
          w is Slider ||
          w is RangeSlider) {
        kind = w.runtimeType.toString();
      } else if (w is EditableText) {
        kind = 'campo';
      } else if (w is Scrollable) {
        kind = 'scorrimento';
      }
      if (kind != null) {
        final ro = el.renderObject;
        if (ro is RenderBox && ro.attached && ro.hasSize) {
          out.add(_Target(el, ro, kind));
        }
      }
      el.visitChildren(visit);
    }

    t.binding.rootElement?.visitChildren(visit);
    return out;
  }

  /// Punto del bersaglio raggiungibile da un tocco (centro o punto a caso).
  Offset? _point(_Target x) {
    final b = x.box;
    final c = b.localToGlobal(b.size.center(Offset.zero));
    if (_hits(b, c)) return c;
    for (var i = 0; i < 3; i++) {
      final o = b.localToGlobal(
        Offset(
          rnd.nextDouble() * b.size.width,
          rnd.nextDouble() * b.size.height,
        ),
      );
      if (_hits(b, o)) return o;
    }
    return null;
  }

  /// Un bersaglio di [kinds] toccabile adesso, con l'etichetta; null se non
  /// ce ne sono (o sono tutti fra quelli da saltare).
  (_Target, Offset, String)? _pick(List<_Target> all, Set<String> kinds) {
    final c = all.where((x) => kinds.contains(x.kind)).toList()..shuffle(rnd);
    for (final x in c.take(40)) {
      final o = _point(x);
      if (o == null) continue;
      final label = _label(x.element);
      if (_isDenied(label)) continue;
      return (x, o, label);
    }
    return null;
  }

  /// Un tocco in [o] non deve finire su un pulsante da saltare.
  bool _safeAt(List<_Target> all, Offset o) {
    if (!_onScreen(o)) return false;
    final result = HitTestResult();
    t.binding.hitTestInView(result, o, t.view.viewId);
    final hit = {for (final e in result.path) e.target};
    for (final x in all) {
      if (x.kind != 'tocco') continue;
      if (hit.contains(x.box) && _isDenied(_label(x.element))) return false;
    }
    return true;
  }

  Future<void> settle() async {
    await t.pump(const Duration(milliseconds: 16));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    await t.pump(Duration(milliseconds: 20 + rnd.nextInt(250)));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 3)),
    );
    await t.pump(const Duration(milliseconds: 16));
  }

  Future<void> step() async {
    final all = _collect();
    final taps = {'tocco', 'Checkbox', 'Switch', 'Radio', 'Slider'};
    if (!all.any((x) => x.kind != 'scorrimento')) {
      empty++;
      maxEmpty = max(maxEmpty, empty);
    } else {
      empty = 0;
    }
    final roll = rnd.nextInt(1000);
    if (roll < 520) {
      final hit = _pick(all, taps);
      if (hit == null) return _back();
      final (x, o, label) = hit;
      log(
        'tocco «${_short(label)}» (${x.element.widget.runtimeType}) '
        '@${o.dx.round()},${o.dy.round()}',
      );
      await t.tapAt(o);
    } else if (roll < 560) {
      final hit = _pick(all, taps);
      if (hit == null) return;
      final (x, o, label) = hit;
      log(
        'pressione lunga «${_short(label)}» @${o.dx.round()},${o.dy.round()}',
      );
      await t.longPressAt(o);
    } else if (roll < 590) {
      final s = _screen;
      final o = Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height);
      if (!_safeAt(all, o)) return;
      log('tocco a caso @${o.dx.round()},${o.dy.round()}');
      await t.tapAt(o);
    } else if (roll < 700) {
      final hit = _pick(all, {'campo'});
      if (hit == null) return;
      final (x, o, label) = hit;
      final text = _randomText(rnd);
      log(
        'testo in «${_short(label)}»: ${text.length} caratteri '
        '«${_short(text)}»',
      );
      await t.tapAt(o);
      await t.pump();
      await t.enterText(find.byWidget(x.element.widget), text);
      if (rnd.nextInt(3) == 0) {
        await t.pump();
        log('invio nel campo');
        await t.testTextInput.receiveAction(TextInputAction.done);
      }
    } else if (roll < 820) {
      final hit = _pick(all, {'scorrimento'});
      if (hit == null) return;
      final (x, o, _) = hit;
      final s = x.element.widget as Scrollable;
      final along = axisDirectionToAxis(s.axisDirection) == Axis.vertical;
      final d = (rnd.nextDouble() * 900 - 450).roundToDouble();
      // un lancio di 0 px non è un gesto (asserzione di flutter_test)
      if (d.abs() < 20) return;
      final off = along ? Offset(0, d) : Offset(d, 0);
      if (rnd.nextInt(4) == 0) {
        log('lancio @${o.dx.round()},${o.dy.round()} di $d');
        await t.flingFrom(o, off, 1500 + rnd.nextDouble() * 3000);
      } else {
        log('scorrimento @${o.dx.round()},${o.dy.round()} di $d');
        await t.dragFrom(o, off);
      }
    } else if (roll < 880) {
      await _back();
    } else if (roll < 900) {
      log('Esc');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
    } else if (roll < 915) {
      final k = [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowDown,
        LogicalKeyboardKey.arrowUp,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.pageDown,
      ][rnd.nextInt(6)];
      log('tasto ${k.keyLabel}');
      await t.sendKeyEvent(k);
    } else if (roll < 935) {
      final s = _sizes[rnd.nextInt(_sizes.length)];
      log('finestra ${s.width.toInt()}×${s.height.toInt()}');
      t.view.physicalSize = s;
      t.view.devicePixelRatio = 1;
    } else if (roll < 950) {
      final f = const [1.0, 1.3, 2.0][rnd.nextInt(3)];
      log('caratteri ×$f');
      t.platformDispatcher.textScaleFactorTestValue = f;
    } else if (roll < 960) {
      final s = setup.services;
      final m = s.themeMode.value == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark;
      log('tema ${m.name}');
      s.themeMode.value = m;
    } else {
      final ms = 200 + rnd.nextInt(2800);
      log('attesa $ms ms');
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await t.pump(Duration(milliseconds: ms));
    }
  }

  Future<void> _back() async {
    log('Indietro');
    // non si aspetta: un «Indietro» che apre una domanda («Salvare?») si
    // completa solo dopo la risposta, che arriva con le azioni seguenti
    unawaited(t.binding.handlePopRoute());
    await t.pump();
  }

  String report(String scenario) {
    final b = StringBuffer()
      ..writeln('scenario $scenario, seme $seed, passo ${done + 1}')
      ..writeln('ultime azioni:')
      ..writeAll(actions.map((a) => '  $a\n'))
      ..writeln('errori:');
    for (final e in errors.take(3)) {
      b.writeln(e);
    }
    return b.toString();
  }
}

bool get _long => Platform.environment['CRASH_R4_MONKEY'] == '1';

bool get _trace => Platform.environment['CRASH_R4_TRACE'] == '1';

/// Porta a termine [op] facendo avanzare il tempo finto e quello vero; se
/// non finisce in ~40 s finti / 3 s veri è uno stallo, registrato come
/// errore di [m].
Future<void> _drive(
  WidgetTester t,
  Future<void> Function() op,
  String what,
  _Monkey m,
) async {
  var finished = false;
  unawaited(
    op().then(
      (_) => finished = true,
      onError: (Object e) {
        finished = true;
        m.errors.add('$what non riuscita: $e');
      },
    ),
  );
  for (var i = 0; i < 400 && !finished; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
  if (!finished) m.errors.add('stallo: $what non è mai finita');
}

int _env(String k, int d) => int.tryParse(Platform.environment[k] ?? '') ?? d;

/// Esegue la scimmia: true se nessun errore. Riempie [stats].
Future<void> _run(
  WidgetTester t,
  _Scenario sc,
  int seed,
  int steps, {
  bool semantics = false,
  Map<String, int>? total,
}) async {
  t.view.physicalSize = _Monkey._sizes[seed % _Monkey._sizes.length];
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final setup = (await t.runAsync(() => _prepare(sc, Random(seed))))!;
  final s = setup.services;
  final monkey = _Monkey(t, seed, setup);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.allMessagesHandler = setup.channels.handle;
  final previousPicker = FilePickerPlatform.instance;
  FilePickerPlatform.instance = _FakePicker(
    Directory(p.join(setup.tmp.path, 'campioni')),
    Directory(p.join(setup.tmp.path, 'salvati'))..createSync(recursive: true),
    monkey.pickRnd,
    monkey.log,
  );
  SemanticsHandle? handle;
  if (semantics) handle = t.ensureSemantics();

  final previous = FlutterError.onError;
  FlutterError.onError = (d) {
    final text = d.exceptionAsString();
    if (text.contains('overflowed by')) {
      final key = text.split('\n').first;
      monkey.overflows[key] = (monkey.overflows[key] ?? 0) + 1;
      return;
    }
    // Asserzione nota di Flutter (solo debug, in release il volo prosegue
    // verso la posizione vecchia): uno SnackBar visibile vola fra due pagine
    // e, durante l'apertura, un tocco arrivato alla pagina sotto ne
    // sostituisce lo Scaffold; tornando indietro il volo invertito non trova
    // più il suo Hero. Si riproduce anche con un'app Flutter minima.
    // Altre asserzioni solo di debug nate dentro Flutter (pila senza codice
    // dell'app), vedi docs/avvio_ed_errori.md («Prova a caso»):
    // - riconoscitore del doppio tocco eliminato durante una ricostruzione
    //   che chiude la gara dei tocchi (selettore dell'ora di Material);
    // - TabBarView che cambia scheda mentre si ricostruisce durante uno
    //   scorrimento lanciato;
    // - DropdownButton che chiude il suo menu mentre si ricostruisce;
    // - frecce su/giù in un campo con un'impaginazione del testo non più
    //   valida (VerticalCaretMovementRun);
    // - campo di testo che chiede la posizione del cursore mentre la pagina
    //   entra con l'animazione (_handleContextMenuOnScroll);
    // - menu di un DropdownButton più alto dello spazio disponibile.
    final stack = (d.stack ?? StackTrace.empty).toString();
    final String? flutterOnly =
        text.contains('heroes.dart') && stack.contains('_HeroFlight.divert')
        ? 'volo di un Hero deviato'
        : text.contains('called during build') &&
              stack.contains('RawGestureDetectorState._syncAll')
        ? 'riconoscitore di tocchi chiuso durante la ricostruzione'
        : text.contains('called during build') &&
              stack.contains('_TabBarViewState.didChangeDependencies')
        ? 'TabBarView: cambio di scheda durante la ricostruzione'
        : text.contains('called during build') &&
              stack.contains('_DropdownButtonState._removeDropdownRoute')
        ? 'DropdownButton: menu chiuso durante la ricostruzione'
        : text.contains("'isValid'") &&
              stack.contains('VerticalCaretMovementRun')
        ? 'campo di testo: frecce con impaginazione scaduta'
        : stack.contains('EditableTextState._handleContextMenuOnScroll')
        ? 'campo di testo: posizione del cursore durante un\'animazione'
        : stack.contains('_DropdownMenuRouteLayout')
        ? 'DropdownButton: menu più alto della finestra'
        : null;
    if (flutterOnly != null) {
      monkey.known[flutterOnly] = (monkey.known[flutterOnly] ?? 0) + 1;
      return;
    }
    // con il widget che ha causato l'errore («The relevant error-causing
    // widget was …», file e riga) e l'inizio della pila
    final where = d
        .toString()
        .split('\n')
        .where(
          (l) =>
              l.contains('error-causing widget') ||
              l.contains('package:university_notes') ||
              l.contains('file:///'),
        )
        .take(12)
        .join('\n');
    monkey.errors.add(
      '${d.exceptionAsString()}\n$where\n'
      '${(d.stack ?? StackTrace.empty).toString().split('\n').take(30).join('\n')}',
    );
  };

  final done = Completer<void>();
  Zone.current
      .fork(
        specification: ZoneSpecification(
          handleUncaughtError: (self, parent, zone, e, st) {
            monkey.errors.add(
              'eccezione non gestita: $e\n'
              '${st.toString().split('\n').take(25).join('\n')}',
            );
          },
        ),
      )
      .run(() async {
        try {
          await t.pumpWidget(UniversityNotesApp(services: s));
          for (var i = 0; i < 6; i++) {
            await monkey.settle();
          }
          for (; monkey.done < steps; monkey.done++) {
            if (monkey.errors.isNotEmpty) break;
            if (_long && monkey.done % 100 == 0) {
              // ignore: avoid_print
              print('  ${sc.name} $seed: passo ${monkey.done}');
            }
            final watch = Stopwatch()..start();
            await monkey.step();
            await monkey.settle();
            if (watch.elapsed > const Duration(seconds: 10)) {
              monkey.slow.add(
                '${monkey.actions.last} (${watch.elapsed.inSeconds} s)',
              );
            }
            if (monkey.errors.isNotEmpty) break;
          }
          done.complete();
        } catch (e, st) {
          monkey.errors.add(
            'errore dell\'impianto di prova: $e\n'
            '${st.toString().split('\n').take(25).join('\n')}',
          );
          done.complete();
        }
      });
  await done.future;
  // ignore: avoid_print
  if (_long) print('  ${sc.name} $seed: azioni finite, chiusura');

  // chiusura: niente timer o registrazioni lasciati a metà
  // (le operazioni dell'app possono aspettare sia il tempo finto sia quello
  // vero: si fanno avanzare entrambi, mai solo dentro runAsync)
  if (s.recorder.active) {
    await _drive(t, s.recorder.stop, 'fine della registrazione', monkey);
  }
  // cronometro dello Studio (unico per l'app, vive oltre le schermate)
  StudyTimer.instance.reset();
  await t.pumpWidget(const SizedBox());
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(minutes: 1));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
  }
  await _drive(t, s.database.close, 'chiusura del database', monkey);
  FlutterError.onError = previous;
  handle?.dispose();
  messenger.allMessagesHandler = null;
  FilePickerPlatform.instance = previousPicker;
  await t.runAsync(() async {
    try {
      await setup.tmp.delete(recursive: true);
    } catch (_) {}
  });

  final name = sc.name;
  // ignore: avoid_print
  print(
    'scimmia $name seme $seed: ${monkey.done} azioni, '
    '${monkey.errors.isEmpty ? 'nessun errore' : 'ERRORE'}; '
    'testi fuori spazio ${monkey.overflows.values.fold(0, (a, b) => a + b)}'
    '${monkey.overflows.isEmpty ? '' : ' (${monkey.overflows.keys.take(3).join('; ')})'}; '
    'schermate senza elementi toccabili per al massimo ${monkey.maxEmpty} passi; '
    'azioni lente: ${monkey.slow.isEmpty ? 'nessuna' : monkey.slow.join(', ')}; '
    'errori noti di Flutter: ${monkey.known.isEmpty ? 'nessuno' : monkey.known}; '
    'uscite finte: ${setup.channels.external.toSet().take(8).join(', ')}; '
    'canali senza plugin: ${setup.channels.seen.take(12).join(', ')}',
  );
  if (total != null && monkey.errors.isEmpty) {
    total['azioni'] = (total['azioni'] ?? 0) + monkey.done;
  }
  expect(monkey.errors, isEmpty, reason: monkey.report(name));
}

/// Prove mirate dei casi trovati dalla scimmia (rosse sul codice del commit
/// 4672237b, verdi dopo la correzione).
void _foundCases() {
  group('casi trovati dalla scimmia', () {
    // 1. Impostazioni → Calendario/Notifiche: un dato cambiato altrove
    // (es. Esclusioni) ricaricava la sezione con `setState(() => _future =
    // _load())`, una freccia che restituisce il Future a setState: errore
    // «setState() callback argument returned a Future» e sezione non
    // ridisegnata.
    for (final (name, section) in [
      ('Calendario', const CalendarSection()),
      ('Notifiche', const NotificationsSection()),
    ]) {
      testWidgets('$name: ricarica dopo una modifica dei dati', (t) async {
        final tmp = (await t.runAsync(
          () => Directory.systemTemp.createTemp('r4_sezione_'),
        ))!;
        final db = (await t.runAsync(AppDatabase.openInMemory))!;
        final s = (await t.runAsync(() => _services(db, tmp)))!;
        await t.pumpWidget(
          Provider<AppServices>.value(
            value: s,
            child: MaterialApp(
              home: Scaffold(body: SingleChildScrollView(child: section)),
            ),
          ),
        );
        for (var i = 0; i < 3; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        // la sezione Calendario rilegge dopo una modifica dei dati, quella
        // delle Notifiche quando cambiano i promemoria
        s.revision.bump();
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        s.reminders.notifyListeners();
        await t.pump();
        expect(t.takeException(), isNull);
        for (var i = 0; i < 3; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await t.pump();
        }
        await t.pumpWidget(const SizedBox());
        await t.runAsync(() async {
          await db.close();
          await tmp.delete(recursive: true);
        });
      });
    }

    // 2. Grandezza del testo del sistema cambiata con l'app aperta: la scala
    // dell'app (AppTextScaler) dava a Flutter un textScaleFactor che seguiva
    // subito il sistema, il MediaQuery vecchio e il nuovo risultavano
    // uguali e i testi restavano impaginati con la grandezza di prima; al
    // primo cambio di colore (tema, pulsante premuto) «debugSize == size».
    testWidgets('grandezza del testo del sistema cambiata: testi '
        'reimpaginati', (t) async {
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final color = ValueNotifier<Color>(Colors.red);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) {
            final m = MediaQuery.of(context);
            return MediaQuery(
              data: m.copyWith(textScaler: AppTextScaler(m.textScaler, 1)),
              child: child!,
            );
          },
          home: Scaffold(
            body: ValueListenableBuilder(
              valueListenable: color,
              builder: (_, c, _) =>
                  Text('Testo', style: TextStyle(color: c, fontSize: 14)),
            ),
          ),
        ),
      );
      final before = t.getSize(find.text('Testo')).height;
      for (final v in [2.0, 1.0, 1.5]) {
        t.platformDispatcher.textScaleFactorTestValue = v;
        await t.pump();
        await t.pump();
        color.value = color.value == Colors.red ? Colors.blue : Colors.red;
        await t.pump();
        expect(t.takeException(), isNull);
        expect(
          t.getSize(find.text('Testo')).height,
          moreOrLessEquals(before * v, epsilon: 2),
        );
      }
    });

    // 3. Tastiera collegata al telefono o al tablet: Pagina giù con il fuoco
    // fuori dalle liste e due liste verticali nella pagina (si agganciano da
    // sole al PrimaryScrollController) → «more than one ScrollPosition is
    // attached» (in release «Too many elements») a ogni tasto.
    testWidgets('Pagina giù con due liste nella pagina', (t) async {
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_pagina_'),
      ))!;
      final s = (await t.runAsync(() => _services(db, tmp)))!;
      await t.pumpWidget(UniversityNotesApp(services: s));
      await t.pump();
      appNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Column(
              children: [
                for (var l = 0; l < 2; l++)
                  Expanded(
                    child: ListView(
                      children: [
                        for (var i = 0; i < 50; i++) Text('riga $l.$i'),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      for (var i = 0; i < 10; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      for (final k in [
        LogicalKeyboardKey.pageDown,
        LogicalKeyboardKey.pageUp,
        LogicalKeyboardKey.arrowDown,
      ]) {
        await t.sendKeyEvent(k);
        await t.pump();
        expect(t.takeException(), isNull, reason: k.keyLabel);
      }
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 5; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(seconds: 1));
      }
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 4. Lettore di schermo attivo nella pagina di una registrazione: la
    // barra della posizione aveva «value» senza «increasedValue» e
    // «decreasedValue» (asserzione dell'albero semantico a ogni disegno).
    testWidgets('registrazione con il lettore di schermo attivo', (t) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final handle = t.ensureSemantics();
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_lettore_'),
      ))!;
      final (s, course, file) = (await t.runAsync(() async {
        final s = await _services(db, tmp);
        const c = Course(id: 1, name: 'Analisi');
        final path = await s.notes.newRecordingPath(
          c,
          DateTime(2026, 10, 12, 8, 30),
          '.wav',
        );
        File(path).writeAsBytesSync(_wav(2));
        return (s, c, File(path));
      }))!;
      await t.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(
            home: RecordingPlayerScreen(course: course, file: file),
          ),
        ),
      );
      for (var i = 0; i < 5; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(t.takeException(), isNull);
      expect(
        find.bySemanticsLabel('Posizione nella registrazione'),
        findsOneWidget,
      );
      handle.dispose();
      await t.pumpWidget(const SizedBox());
      for (var i = 0; i < 3; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(seconds: 1));
      }
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 5. Studio → «Cambia insegnamento» aperto, poi la finestra passa da
    // stretta a larga (o il tablet ruota): la shell cambia disposizione e
    // ricrea Studio; scegliendo un insegnamento nel foglio rimasto aperto
    // si chiamava setState sullo Studio di prima, già eliminato.
    testWidgets('scelta dell\'insegnamento dopo il cambio di disposizione', (
      t,
    ) async {
      t.view.physicalSize = const Size(412, 915);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_studio_'),
      ))!;
      final s = (await t.runAsync(() async {
        final s = await _services(db, tmp);
        await _fillPlan(s, hostile: false);
        // altri insegnamenti dell'anno frequentato, da scegliere nel foglio
        final first = (await s.courses.all()).first;
        for (final name in ['Fisica tecnica', 'Geometria']) {
          await s.courses.insert(
            Course(
              name: name,
              universityId: first.universityId,
              degreeId: first.degreeId,
              year: s.profile.value?.currentYear ?? 2,
              semester: '1',
              cfu: 6,
            ),
          );
        }
        return s;
      }))!;
      Future<void> settle([int n = 8]) async {
        for (var i = 0; i < n; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await t.pumpWidget(UniversityNotesApp(services: s));
      await settle(20);
      await t.tap(find.text('Studio').last);
      await settle();
      await t.tap(find.byKey(const Key('course-name')));
      await settle();
      expect(
        find.descendant(
          of: find.byType(CoursePickerList),
          matching: find.text('Geometria'),
        ),
        findsOneWidget,
      );
      // finestra larga: colonna di navigazione al posto della barra
      t.view.physicalSize = const Size(1366, 915);
      await settle();
      await t.tap(
        find.descendant(
          of: find.byType(CoursePickerList),
          matching: find.text('Geometria'),
        ),
        warnIfMissed: false,
      );
      await settle();
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle(3);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 6. Esami → Medie in una colonna stretta (finestra larga: due colonne,
    // lista accanto al dettaglio) con i caratteri ×2: «30 e lode» a destra
    // della riga occupava tutta la riga («Trailing widget consumes the
    // entire tile width»), il nome restava senza spazio.
    testWidgets('Medie in una colonna stretta con i caratteri grandi', (
      t,
    ) async {
      t.view.physicalSize = const Size(1000, 900);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_medie_'),
      ))!;
      final data = (await t.runAsync(() async {
        final s = await _services(db, tmp);
        await _fillPlan(s, hostile: false);
        for (final c in await s.courses.all()) {
          await s.exams.save(
            Exam(
              courseId: c.id!,
              date: DateTime(2026, 2, 10),
              status: ExamStatus.passed,
              grade: 30,
              laude: true,
            ),
          );
        }
        return loadExamsData(s);
      }))!;
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('consumes the entire tile width')) errors.add(text);
      };
      // la colonna più stretta possibile: finestra a 840 px (dove parte la
      // disposizione larga) meno la colonna di navigazione, 3/5 accanto al
      // dettaglio
      for (final width in [453.0, 520.0, 640.0]) {
        final before = errors.length;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: AveragesTab(data: data, onSelect: (_) {}),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        if (errors.length > before) {
          errors.add('colonna di ${width.toInt()} px');
        }
      }
      FlutterError.onError = previous;
      expect(errors, isEmpty);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 7. Modulo dell'insegnamento: nome cancellato, modulo scorso in basso
    // (il campo del nome esce dalla lista e validate() non lo controlla),
    // «Salva» → «Null check operator used on a null value» in _save.
    testWidgets('insegnamento salvato con il nome vuoto fuori schermo', (
      t,
    ) async {
      t.view.physicalSize = const Size(400, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      final db = (await t.runAsync(AppDatabase.openInMemory))!;
      final tmp = (await t.runAsync(
        () => Directory.systemTemp.createTemp('r4_modulo_'),
      ))!;
      final (s, course) = (await t.runAsync(() async {
        final s = await _services(db, tmp);
        await _fillPlan(s, hostile: false);
        return (s, (await s.courses.all()).first);
      }))!;
      Future<void> settle([int n = 6]) async {
        for (var i = 0; i < n; i++) {
          await t.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          await t.pump(const Duration(milliseconds: 100));
        }
      }

      await t.pumpWidget(
        Provider<AppServices>.value(
          value: s,
          child: MaterialApp(home: CourseFormPage(course: course)),
        ),
      );
      await settle();
      for (
        var i = 0;
        i < 100 && find.byType(CourseNameField).evaluate().isEmpty;
        i++
      ) {
        await settle(1);
      }
      expect(find.byType(CourseNameField), findsOneWidget);
      await t.enterText(
        find.descendant(
          of: find.byType(CourseNameField),
          matching: find.byType(EditableText),
        ),
        '   ',
      );
      await t.pump();
      // fuoco altrove: un campo con il fuoco resterebbe vivo fuori schermo
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      // in fondo al modulo: il campo del nome non è più nella lista
      for (var i = 0; i < 12; i++) {
        await t.drag(find.byType(ListView).first, const Offset(0, -600));
        await t.pump();
      }
      await settle(2);
      expect(find.byType(CourseNameField), findsNothing);
      // «Salva» nella barra in alto
      await t.tap(find.text('Salva').last);
      await settle();
      expect(t.takeException(), isNull);
      expect(
        find.text('Inserisci il nome dell\'insegnamento.'),
        findsOneWidget,
      );
      await t.pumpWidget(const SizedBox());
      await settle(3);
      await t.runAsync(() async {
        await db.close();
        await tmp.delete(recursive: true);
      });
    });

    // 8. Libri: scheda di un libro senza file in uno spazio stretto con la
    // finestra larga e i caratteri ×2: «Aggiungi» e il menu a destra
    // occupavano tutta la riga («Trailing widget consumes the entire tile
    // width»).
    testWidgets('scheda di un libro stretta con i caratteri grandi', (t) async {
      t.view.physicalSize = const Size(1920, 1080);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      t.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      final errors = <String>[];
      final previous = FlutterError.onError;
      FlutterError.onError = (d) {
        final text = d.exceptionAsString();
        if (text.contains('consumes the entire tile width')) errors.add(text);
      };
      for (final width in [240.0, 320.0, 420.0, 560.0]) {
        final before = errors.length;
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: width,
                  child: BookTile(
                    book: const Book(id: 1, title: 'Analisi matematica'),
                    onOpen: () {},
                    onAction: (_) {},
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        if (errors.length > before) {
          errors.add('scheda di ${width.toInt()} px');
        }
      }
      FlutterError.onError = previous;
      expect(errors, isEmpty);
    });

    test('nessun setState con una freccia che assegna un Future', () {
      // stessa causa del caso 1 nelle altre schermate (OneNote, Google
      // Drive, Whisper, Eliminati di recente)
      final bad = <String>[];
      final assign = RegExp(r'setState\(\(\) => (_?\w+) = ');
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = f.readAsStringSync();
        for (final m in assign.allMatches(src)) {
          final v = RegExp.escape(m[1]!);
          // dichiarazione del campo: «Future<…> _x;» o «Future<…> _x = …»
          if (RegExp('Future<[^;(){}=]*>\\??\\s+$v\\s*[;=]').hasMatch(src)) {
            bad.add('${f.path}: ${m[0]}');
          }
        }
      }
      expect(bad, isEmpty);
    });
  });
}

void main() {
  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  final total = <String, int>{};
  tearDownAll(() {
    // ignore: avoid_print
    print('scimmia: ${total['azioni'] ?? 0} azioni casuali senza errori');
  });

  _foundCases();

  if (!_long) {
    group('scimmia (giro breve)', () {
      for (final (sc, seed, steps, sem) in [
        (_Scenario.vuoto, 1, 90, false),
        (_Scenario.piano, 2, 160, true),
        (_Scenario.limiti, 3, 110, false),
      ]) {
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => _run(t, sc, seed, steps, semantics: sem, total: total),
          timeout: const Timeout(Duration(minutes: 2)),
        );
      }
    });
    return;
  }

  final only = Platform.environment['CRASH_R4_SEED'];
  final seeds = only != null
      ? [int.parse(only)]
      : [for (var i = 0; i < _env('CRASH_R4_SEEDS', 12); i++) 1000 + i];
  final steps = _env('CRASH_R4_ACTIONS', 1200);
  final scenarios = switch (Platform.environment['CRASH_R4_SCENARIO']) {
    final String n => [_Scenario.values.byName(n)],
    null => _Scenario.values,
  };
  group('scimmia (giro lungo)', () {
    for (final sc in scenarios) {
      for (final seed in seeds) {
        testWidgets(
          '${sc.name}, seme $seed, $steps azioni',
          (t) => _run(t, sc, seed, steps, semantics: seed.isOdd, total: total),
          timeout: const Timeout(Duration(minutes: 8)),
        );
      }
    }
  });
}
