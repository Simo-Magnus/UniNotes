// Impianto della prova a caso («monkey test»), usato da
// crash_r4_monkey_test.dart e crash_r6_monkey_test.dart.
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
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/router/back_guard.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/book_library.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/cloud/google_drive_service.dart';
import 'package:university_notes/features/cloud/onedrive_service.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/study/focus/focus_timer.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/core/services/loopback_oauth.dart';
import 'package:university_notes/features/cloud/graph_client.dart';
import 'package:university_notes/features/notes/recorder/system_speech.dart';
import 'package:university_notes/main.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/features/study/study_timer.dart';
import 'package:university_notes/repositories/settings_repository.dart';

import 'catalog_fixtures.dart';
import 'fake_parakeet.dart';
import 'fake_drive.dart';
import 'fake_google_drive.dart';
import 'fake_reminders.dart';
import 'reader_fuzz_corpus.dart';
import '../reader_fixtures.dart' show tinyPng;

// ---------------------------------------------------------------- finti

/// Microfono finto: silenzio a richiesta, nessun dispositivo vero.
class FakeMic implements AudioRecorder {
  /// Flusso della registrazione in corso: se ne apre uno nuovo a ogni
  /// `startStream` (uno chiuso da [endStream] non si può riusare).
  StreamController<Uint8List> pcm = StreamController<Uint8List>.broadcast();
  final _states = StreamController<RecordState>.broadcast();
  int starts = 0;

  /// Il prossimo `hasPermission` risponde false (permesso negato); poi torna
  /// vero.
  bool denyPermission = false;

  /// Il prossimo `startStream` lancia (microfono occupato); una volta sola.
  bool failStart = false;

  /// La prossima `pause`/`resume` lancia (come dopo una telefonata su iOS);
  /// una volta sola.
  bool failResume = false;

  /// Il sistema manda audio: [chunks] pezzi da 100 ms di rumore di
  /// ampiezza [amplitude] (0–1), 16 kHz mono 16 bit.
  void feed(Random r, {int chunks = 1, double amplitude = 0.2}) {
    if (pcm.isClosed || !pcm.hasListener) return;
    for (var c = 0; c < chunks; c++) {
      final b = ByteData(3200);
      for (var i = 0; i < 1600; i++) {
        b.setInt16(
          i * 2,
          ((r.nextDouble() * 2 - 1) * amplitude * 32767).round(),
          Endian.little,
        );
      }
      pcm.add(b.buffer.asUint8List());
    }
  }

  /// Dati di formato irregolare (un numero dispari di byte, vuoto, un solo
  /// campione): un driver rovinato.
  void feedOdd(Random r) {
    if (pcm.isClosed || !pcm.hasListener) return;
    pcm.add(
      Uint8List.fromList([
        for (var i = 0; i < [0, 1, 3, 7, 3201][r.nextInt(5)]; i++)
          r.nextInt(256),
      ]),
    );
  }

  /// Il microfono è stato preso da un'altra app: il flusso finisce.
  void endStream() {
    if (!pcm.isClosed) unawaited(pcm.close());
  }

  /// Il sistema mette in pausa (telefonata su iOS).
  void systemPause() => _states.add(RecordState.pause);

  @override
  Future<bool> hasPermission({bool request = true}) async {
    final deny = denyPermission;
    denyPermission = false;
    return !deny;
  }

  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig c)? cb) async {}
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    if (failStart) {
      failStart = false;
      throw StateError('microfono occupato');
    }
    starts++;
    if (pcm.isClosed) pcm = StreamController<Uint8List>.broadcast();
    return pcm.stream;
  }

  @override
  Stream<RecordState> onStateChanged() => _states.stream;
  @override
  Future<void> pause() async {
    if (failResume) {
      failResume = false;
      throw StateError('pausa non riuscita');
    }
  }

  @override
  Future<void> resume() async {
    if (failResume) {
      failResume = false;
      throw StateError('ripresa non riuscita');
    }
  }

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
final class PickedFile extends PlatformFile {
  PickedFile(this.file);
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
class FakePicker extends FilePickerPlatform {
  FakePicker(this.samples, this.saved, this.rnd, this.log);
  final Directory samples;
  final Directory saved;
  final Random rnd;
  final void Function(String) log;

  /// Nomi dei file da dare ai prossimi selettori (uno per volta), prima di
  /// tornare a sceglierli a caso: serve ad arrivare a un file preciso (un
  /// backup valido da importare).
  final List<String> queue = [];

  File? _queued() {
    while (queue.isNotEmpty) {
      final name = queue.removeAt(0);
      final f = File(p.join(samples.path, name));
      if (f.existsSync()) return f;
    }
    return null;
  }

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
    final queued = _queued();
    if (queued != null) {
      log('selettore: ${p.basename(queued.path)}');
      return PickedFile(queued);
    }
    if (rnd.nextInt(3) == 0) {
      log('selettore: annullato');
      return null;
    }
    final f = _files[rnd.nextInt(_files.length)];
    log('selettore: ${p.basename(f.path)}');
    return PickedFile(f);
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
    return [for (final f in all.take(n)) PickedFile(f)];
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
class MonkeyChannels {
  MonkeyChannels(this.tmp);
  final Directory tmp;
  final Set<String> seen = {};
  final List<String> external = [];
  static const _codec = StandardMethodCodec();

  /// Riconoscimento vocale del sistema finto (canale `speech`): se false il
  /// canale risponde come una piattaforma senza plugin.
  bool speech = false;
  static const speechChannel = 'io.github.simomagnus.universitynotes/speech';

  /// Sessione di riconoscimento aperta con `start` (0 = nessuna) e quanti
  /// pezzi di audio ha ricevuto.
  int speechSession = 0;
  int speechFed = 0;

  /// Il prossimo `start` del riconoscitore risponde false (non parte); una
  /// volta sola. (Un'attesa lunghissima non si prova: c'è il timeout dell'app.)
  bool speechStarts = true;

  /// L'evento [method] (`partial`, `result`, `error`, `ended`) del
  /// riconoscitore per la sessione [session] (predefinita: quella in corso).
  Future<void> speechEvent(String method, String text, {int? session}) {
    final args = <String, Object?>{
      'session': session ?? speechSession,
      'text': text,
      if (method == 'error') 'message': text,
      if (method == 'error') 'fatal': text.length.isOdd,
    };
    final done = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          speechChannel,
          _codec.encodeMethodCall(MethodCall(method, args)),
          (_) => done.complete(),
        );
    return done.future.timeout(const Duration(seconds: 1), onTimeout: () {});
  }

  /// Conversione audio finta (canale `audio`, Windows): copia il file e ogni
  /// tanto non riesce o dà un errore del sistema.
  bool audioCodec = false;
  int audioCalls = 0;
  static const audioChannel = 'io.github.simomagnus.universitynotes/audio';

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
      case 'dev.fluttercommunity.plus/connectivity':
        // connectivity_plus: sempre in rete (wifi)
        return Future.value(_ok(['wifi']));
      case 'dev.fluttercommunity.plus/connectivity_status':
        return Future.value(_ok(null));
      case audioChannel:
        final a = call?.arguments;
        if (!audioCodec || a is! Map) break;
        if (m != 'toM4a' && m != 'toWav') break;
        final n = audioCalls++ % 8;
        if (n == 6) return Future.value(_ok(false));
        if (n == 7) {
          return Future.value(
            _codec.encodeErrorEnvelope(
              code: 'codec',
              message: 'codec non disponibile (prova)',
            ),
          );
        }
        try {
          File('${a['input']}').copySync('${a['output']}');
        } catch (_) {
          return Future.value(_ok(false));
        }
        return Future.value(_ok(true));
      case speechChannel:
        if (!speech) break;
        switch (m) {
          case 'support':
            return Future.value(
              _ok({
                'available': true,
                'onDevice': true,
                'feedsAudio': true,
                'engine': 'prova',
              }),
            );
          case 'start':
            final a = call?.arguments;
            if (!speechStarts) {
              speechStarts = true;
              return Future.value(_ok(false));
            }
            speechSession = a is Map && a['session'] is int
                ? a['session'] as int
                : speechSession + 1;
            return Future.value(_ok(true));
          case 'feed':
            speechFed++;
            return Future.value(_ok(null));
          default:
            return Future.value(_ok(null));
        }
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
const kEmoji = '\u{1F600}';
final kHostile = <String>[
  'Fisica $kEmoji',
  '\u202Eelacitamatam\u202C Analisi',
  'Riga1\r\nRiga2\rRiga3',
  'e${'\u0301' * 60}',
  '\u0645\u0631\u062D\u0628\u0627 \u0628\u0627\u0644\u0639\u0627\u0644\u0645',
  '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}\u200D\u{1F466}' * 8,
  '\u200B\u200B',
  ' \u00A0\u2003\u3000 ',
  'Parola' * 400,
  kEmoji * 120,
  r'C:\Windows\..\..\x',
  '../../etc/passwd',
  '<b>html</b> & "virgolette"',
  r'$\frac{1}{0}$ $$\sqrt{-1}$$',
];

/// Testo scritto nei campi.
final kTyped = <String>[
  '',
  ' ',
  'a',
  'Analisi matematica',
  kEmoji,
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

String randomText(Random r) {
  if (r.nextInt(3) > 0) return kTyped[r.nextInt(kTyped.length)];
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
    kEmoji,
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
Uint8List wavBytes(int seconds) {
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
void writeSamples(Directory d, Random r) {
  d.createSync(recursive: true);
  void w(String name, List<int> bytes) =>
      File(p.join(d.path, name)).writeAsBytesSync(bytes);
  w(
    'appunti.md',
    utf8.encode('# Titolo\n\n- punto\n\n\$x^2\$ e testo $kEmoji'),
  );
  w('testo.txt', utf8.encode('Riga uno\nRiga due\n${'parola ' * 3000}'));
  w('vuoto.txt', const []);
  w('pagina.html', utf8.encode('<html><body><h1>T</h1><p>p<b>b</p>'));
  w('tabella.csv', utf8.encode('a;b;c\n1;2;3\n"x;y";4\n'));
  w('backup.json', utf8.encode('{"version": 99, "courses": [{"name": 1}]'));
  w('dati.json', utf8.encode(jsonEncode({'courses': [], 'exams': null})));
  w('rovinato.docx', List.generate(3000, (_) => r.nextInt(256)));
  w('rovinato.epub', utf8.encode('PK\u0003\u0004 non è uno zip'));
  w('lezione.wav', wavBytes(1));
  w('troncato.wav', wavBytes(1).sublist(0, 60));
  w('casuale.bin', List.generate(5000, (_) => r.nextInt(256)));
  w('nome $kEmoji con spazi.txt', utf8.encode('ciao'));
  w('immagine.png', [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]);
  w('dispense.zip', utf8.encode('PK'));
  w(
    'formule.tex',
    utf8.encode(r'\documentclass{article}\begin{document}$\int$'),
  );
}

// ---------------------------------------------------------------- scenari

/// Che cosa serve a uno scenario oltre al piano di studi.
class MonkeyOptions {
  const MonkeyOptions({
    this.liveSpeech = false,
    this.liveEngine = false,
    this.fakeClouds = false,
    this.corpus = false,
    this.allowLogin = false,
    this.platform = 'windows',
  });

  /// Riconoscimento vocale del sistema finto (canale `speech`) per il testo
  /// dal vivo del registratore.
  final bool liveSpeech;

  /// Parakeet finto installato, con il motore dal vivo e «Trascrivi con…».
  final bool liveEngine;

  /// OneDrive e Google Drive finti (server in memoria, accesso che riesce):
  /// si possono toccare «Accedi» e «Collega».
  final bool fakeClouds;

  /// File di prova di ogni formato del lettore nelle cartelle dell'app.
  final bool corpus;

  /// «Accedi…» e «Collega…» si toccano (servono [fakeClouds]).
  final bool allowLogin;

  /// Nome della piattaforma per i promemoria (`windows`, `android`…);
  /// `auto` = uno dei due a seconda del seme.
  final String platform;

  /// Con `platform: 'auto'` sceglie la piattaforma di questo seme.
  MonkeyOptions resolve(Random r) => platform != 'auto'
      ? this
      : MonkeyOptions(
          liveSpeech: liveSpeech,
          liveEngine: liveEngine,
          fakeClouds: fakeClouds,
          corpus: corpus,
          allowLogin: allowLogin,
          platform: r.nextBool() ? 'android' : 'windows',
        );
}

/// Accesso finto: riesce sempre.
class FakeOAuth extends LoopbackOAuth {
  FakeOAuth()
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

/// I finti di uno scenario, a portata della scimmia (per rompere le cose a
/// comando: rete assente, permessi tolti, microfono preso da un'altra app).
class MonkeyFakes {
  final mic = FakeMic();
  final notifications = FakeNotificationPlatform();
  final calendar = FakeCalendarBackend();
  final onedrive = FakeDrive();
  final google = FakeGoogleDrive();
  final vad = FakeVadEngine();

  /// Rete assente per OneDrive e Google Drive finti.
  bool offline = false;

  /// Le chiamate ai server finti rispondono con un errore 503.
  bool serverErrors = false;

  FakeParakeet? parakeet;

  /// Orologio del Focus: l'ora vera più questo scarto (la scimmia fa passare
  /// i minuti senza aspettarli).
  Duration clockOffset = Duration.zero;
  DateTime now() => DateTime.now().add(clockOffset);

  Future<GraphResponse> _guard(Future<GraphResponse> Function() call) async {
    if (offline) throw GraphException(0, 'Rete assente (prova).');
    if (serverErrors) {
      return GraphResponse(
        503,
        Uint8List.fromList(utf8.encode('{"error":{"message":"guasto"}}')),
      );
    }
    return call();
  }

  GraphTransport get onedriveTransport =>
      (method, url, {headers = const {}, body}) => _guard(
        () => onedrive.call(method, url, headers: headers, body: body),
      );

  GraphTransport get googleTransport =>
      (method, url, {headers = const {}, body}) =>
          _guard(() => google.call(method, url, headers: headers, body: body));
}

/// Voci della barra e della colonna di navigazione (intera etichetta).
final kNavigationLabels = [
  RegExp(
    r'^(\S+ \| )?(home|registra|studio|esami|libri|insegnamenti|file|'
    r'collegamenti|vantaggi|impostazioni|altro)$',
  ),
];

/// Un'azione propria di un'area, con il suo peso.
typedef MonkeyAction = ({
  String name,
  int weight,
  Future<void> Function(Monkey m) run,
});

/// Una parte dell'app su cui la scimmia insiste: ci torna da sola quando ne
/// esce, preferisce certi pulsanti e fa azioni sue (audio finto, tasti…).
abstract class MonkeyArea {
  const MonkeyArea();

  String get name;

  /// Percorso della shell (`sezione:Impostazioni`, `registra`…) con cui ci si
  /// arriva; null = [enter] fa da sé.
  String? get route => null;

  /// Porta l'app nell'area: chiude schermate e riquadri e apre la sezione.
  Future<void> enter(Monkey m) async {
    final r = route;
    m.log('area: $name');
    appNavigatorKey.currentState?.popUntil((x) => x.isFirst);
    await m.settle();
    if (r != null) m.setup.services.openRoute.call(r);
    await m.settle();
  }

  /// L'app è ancora nell'area? Se no, ci si torna presto.
  bool inArea(Monkey m) => true;

  /// Pulsanti (testo minuscolo) che la scimmia tocca più volentieri.
  List<RegExp> get prefer => const [];

  /// Quota di tocchi (per mille) fatti sui pulsanti preferiti.
  int get preferPerMille => 400;

  /// Pulsanti (testo minuscolo) che la scimmia evita: di solito la barra o la
  /// colonna di navigazione, che la porterebbe fuori dall'area.
  List<RegExp> get avoid => kNavigationLabels;

  /// Quota (per mille) dei tocchi su [avoid] che si evitano.
  int get avoidPerMille => 970;

  /// Azioni proprie dell'area.
  List<MonkeyAction> actions(Monkey m) => const [];

  /// Quota di passi (per mille) con un'azione propria.
  int get actionsPerMille => 150;

  /// Probabilità (per mille) di ricominciare da capo a ogni passo anche se
  /// ancora dentro.
  int get restartPerMille => 6;
}

/// Uno scenario della prova: dati di partenza, finti e area su cui insistere.
class MonkeyScenario {
  const MonkeyScenario(
    this.name,
    this.prepare, {
    this.area,
    this.options = const MonkeyOptions(),
  });
  final String name;

  /// Prepara i dati (database, file) prima dell'avvio dell'app.
  final Future<void> Function(AppServices s, Random r, Directory tmp) prepare;
  final MonkeyArea? area;
  final MonkeyOptions options;
}

class MonkeySetup {
  MonkeySetup(
    this.services,
    this.tmp,
    this.channels,
    this.fakes,
    this.scenario,
  );
  final AppServices services;
  final Directory tmp;
  final MonkeyChannels channels;
  final MonkeyFakes fakes;
  final MonkeyScenario scenario;
}

Future<AppServices> monkeyServices(
  AppDatabase db,
  Directory tmp, {
  MonkeyFakes? fakes,
  MonkeyOptions options = const MonkeyOptions(),
}) async {
  final f = fakes ?? MonkeyFakes();
  final settings = SettingsRepository(db);
  final notes = NotesStore(
    settings,
    root: () async => Directory(p.join(tmp.path, 'Appunti', 'Corsi')),
  );
  Future<Directory> support() async =>
      Directory(p.join(tmp.path, 'supporto'))..createSync(recursive: true);
  final secrets = MemoryCloudSecrets();
  final parakeet = f.parakeet = FakeParakeet(
    Directory(p.join(tmp.path, 'parakeet'))..createSync(recursive: true),
    isInstalled: options.liveEngine,
    engine: options.liveEngine ? f.vad : null,
  );
  final whisper = WhisperService(
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
    parakeet: parakeet,
  );
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
    whisper: whisper,
    onedrive: OneDriveService(
      settings,
      notes,
      secrets: secrets,
      stateDir: () async => tmp,
      transport: options.fakeClouds ? f.onedriveTransport : null,
      oauthFactory: options.fakeClouds ? (_, _) => FakeOAuth() : null,
      builtInClientId: options.fakeClouds
          ? '1a2b3c4d-1111-2222-3333-444455556666'
          : null,
      deviceName: options.fakeClouds ? 'PC' : null,
    ),
    googleDrive: GoogleDriveService(
      settings,
      notes,
      secrets: secrets,
      stateDir: () async => tmp,
      transport: options.fakeClouds ? f.googleTransport : null,
      oauthFactory: options.fakeClouds ? (_, _) => FakeOAuth() : null,
      builtInClientId: 'client.apps.googleusercontent.com',
      builtInClientSecret: '',
      deviceName: options.fakeClouds ? 'PC' : null,
    ),
    focusTimer: () => FocusTimer(clock: f.now),
    reminders: (s) => RemindersService(
      s,
      platform: f.notifications,
      calendarBackend: f.calendar,
      widgets: FakeHomeWidgets(),
      platformName: options.platform,
      isRecording: () => false,
      focusQuietUntil: () => null,
    ),
    recorder: LectureRecorder(
      recorder: () => f.mic,
      workDir: () async =>
          Directory(p.join(tmp.path, 'lavoro'))..createSync(recursive: true),
      whisper: options.liveEngine ? whisper : null,
      speech: options.liveSpeech ? SystemSpeech() : null,
      controls: () => const NoBackgroundControls(),
    ),
  );
}

/// Piano reale (PoliTO, fixture) al 2° anno nel 2026/27 con prove, studio,
/// libri, appunti e registrazioni.
Future<void> fillPlan(AppServices s, {required bool hostile}) async {
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
          name: kHostile[i % kHostile.length],
          universityId: first.universityId,
          degreeId: first.degreeId,
          year: 1 + i % 4,
          semester: '${1 + i % 3}',
          cfu: const [0.0, 0.5, 6.0, 12.0, 180.0, 1e9][i % 6],
          teacher: kHostile[(i + 3) % kHostile.length],
          description: kHostile[(i + 5) % kHostile.length],
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
        title: hostile ? kHostile[n % kHostile.length] : null,
        location: hostile ? kHostile[(n + 2) % kHostile.length] : 'Aula 1',
        notes: hostile ? kHostile[(n + 4) % kHostile.length] : null,
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
      StudyModule(courseId: id, name: hostile ? kHostile[n % 14] : 'Modulo 1'),
    );
    for (var t = 0; t < (hostile ? 12 : 3); t++) {
      await s.study.insertTopic(
        Topic(
          moduleId: m,
          name: hostile ? kHostile[(n + t) % 14] : 'Argomento ${t + 1}',
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
      '# Libro $b\n\n${hostile ? kHostile[b % 14] : 'Capitolo uno.'}\n' * 30,
    );
    await s.books.insert(
      Book(
        courseId: courses[b % courses.length].id,
        title: hostile ? kHostile[b % 14] : 'Libro $b',
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
      '# Appunti\n\nTesto con formula \$e^{i\\pi}+1=0\$ e $kEmoji.\n'
          '${hostile ? 'riga lunghissima ' * 3000 : ''}',
    );
    final rec = await s.notes.newRecordingPath(
      c,
      DateTime(2026, 10, 12, 8, 30),
      '.wav',
    );
    File(rec).writeAsBytesSync(wavBytes(2));
    final base = p.basenameWithoutExtension(rec);
    await s.notes.writeText(
      c,
      NoteFolder.transcripts,
      base,
      'Trascrizione della lezione. ${hostile ? kHostile.join(' ') : ''}',
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

Future<void> _noData(AppServices s, Random r, Directory tmp) async {}
Future<void> _normalPlan(AppServices s, Random r, Directory tmp) =>
    fillPlan(s, hostile: false);
Future<void> _hostilePlan(AppServices s, Random r, Directory tmp) =>
    fillPlan(s, hostile: true);

/// Gli scenari del quarto giro: primo avvio (onboarding), piano reale, casi
/// limite.
const kScenarioVuoto = MonkeyScenario('vuoto', _noData);
const kScenarioPiano = MonkeyScenario('piano', _normalPlan);
const kScenarioLimiti = MonkeyScenario('limiti', _hostilePlan);
const kBaseScenarios = [kScenarioVuoto, kScenarioPiano, kScenarioLimiti];

/// File di prova di ogni formato del lettore, buoni (in Libri) e rovinati
/// (in Materiali e Allegati), nelle cartelle dell'app: la sezione File li
/// elenca e il lettore li apre. Niente varianti enormi (la prova a caso fa
/// migliaia di azioni).
Future<List<String>> writeCorpus(AppServices s, Random r) async {
  final libri = await s.library.directory();
  final dirs = [
    await s.materialsLibrary.directory(),
    await s.attachmentsLibrary.directory(),
  ];
  final out = <String>[];
  var n = 0;
  final corpus = fuzzCorpus()..['.png'] = [tinyPng];
  for (final e in corpus.entries) {
    for (final bytes in e.value) {
      final good = File(p.join(libri.path, 'corpus_${n++}${e.key}'));
      good.writeAsBytesSync(bytes);
      out.add(good.path);
      var k = 0;
      for (final (_, b) in fuzzMutations(bytes, r, 1)) {
        if (b.length > 200000 || r.nextInt(5) != 0) continue;
        if (k++ >= 2) break;
        final f = File(
          p.join(dirs[r.nextInt(2)].path, 'rovinato_${n++}${e.key}'),
        );
        f.writeAsBytesSync(b);
        out.add(f.path);
      }
    }
  }
  return out;
}

Future<MonkeySetup> prepareScenario(MonkeyScenario sc, Random r) async {
  final tmp = await Directory.systemTemp.createTemp('r4_monkey_');
  writeSamples(Directory(p.join(tmp.path, 'campioni')), r);
  final db = await AppDatabase.openInMemory();
  final fakes = MonkeyFakes();
  final options = sc.options.resolve(Random(r.nextInt(1 << 20)));
  final s = await monkeyServices(db, tmp, fakes: fakes, options: options);
  await sc.prepare(s, r, tmp);
  if (options.corpus) await writeCorpus(s, r);
  final channels = MonkeyChannels(tmp)
    ..speech = options.liveSpeech
    ..audioCodec = options.liveSpeech || options.liveEngine;
  return MonkeySetup(s, tmp, channels, fakes, sc);
}

// ---------------------------------------------------------------- scimmia

/// Pulsanti che non si toccano: uscirebbero dall'app o userebbero dati e
/// account veri (accesso a OneDrive/Google/Outlook, pulizia completa con
/// chiusura dell'app, Esplora file, appunti di sistema di Windows).
const kDenied = <String>[
  'elimina tutti i dati',
  'apri cartella',
  'apri la cartella',
  'mostra nella cartella',
  'mostra nella sua cartella',
  'copia i file',
];

/// «Accedi…» e «Collega» da soli (OneDrive, Google Drive, calendario di
/// Outlook) si toccano solo con i server finti ([allowLogin]).
bool isDenied(String label, {bool allowLogin = false}) {
  final l = label.toLowerCase();
  if (kDenied.any(l.contains)) return true;
  if (allowLogin) return false;
  return l.contains('accedi') ||
      RegExp(r'(^|\|\s*)collega(\s*\||$)').hasMatch(l) ||
      l.contains('collega il calendario') ||
      l.contains('collega onedrive') ||
      l.contains('collega google');
}

class MonkeyTarget {
  MonkeyTarget(this.element, this.box, this.kind);
  final Element element;
  final RenderBox box;
  final String kind;
}

bool privateUse(String s) => s.runes.any((c) => c >= 0xE000 && c <= 0xF8FF);

String labelOf(Element e, {int depth = 8}) {
  final parts = <String>[];
  var budget = 400;
  void visit(Element el) {
    if (budget <= 0) return;
    final w = el.widget;
    if (w is RichText) {
      final t = w.text.toPlainText();
      if (!privateUse(t)) {
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
    return ++n < depth;
  });
  return parts.where((s) => s.trim().isNotEmpty).join(' | ');
}

String shortText(String s) {
  final one = s.replaceAll(RegExp(r'\s+'), ' ');
  final runes = one.runes.toList();
  return runes.length <= 60 ? one : '${String.fromCharCodes(runes.take(60))}…';
}

/// Un luogo dell'app da cui esce un elemento dal suo spazio («A RenderFlex
/// overflowed by N pixels», quinto giro R5-B): widget dell'app responsabile
/// (file:riga), lato, e in quali condizioni è successo.
class OverflowSpot {
  OverflowSpot(this.where, this.widget, this.edge);
  final String where;
  final String widget;
  final String edge;
  int count = 0;
  double maxPx = 0;
  final Set<String> windows = {};
  final Set<String> scales = {};
  final Set<String> themes = {};
  final Set<String> screens = {};
  String? firstAction;
}

final overflowPxRe = RegExp(r'overflowed by ([\d.]+) pixels on the (\w+)');
final appLocationRe = RegExp(
  r'file:///[A-Za-z]:/[^\s]*?/app/(lib/[^\s:]+\.dart):(\d+)',
);

/// Nomi dei widget dell'app sopra l'elemento che ha l'overflow, per capire in
/// quale schermata si trova (il primo è il più vicino).
String screenOf(FlutterErrorDetails d) {
  Element? element;
  try {
    for (final n in d.informationCollector?.call() ?? <DiagnosticsNode>[]) {
      final Object? v = n.value;
      if (v is DebugCreator) element = v.element;
    }
  } catch (_) {}
  if (element == null) return '?';
  final names = <String>[];
  try {
    element.visitAncestorElements((a) {
      final n = a.widget.runtimeType.toString();
      if (!n.startsWith('_') &&
          RegExp(
            r'(Screen|Page|Sheet|Dialog|Tab|Section|Card|Form|Panel|Tile|Bar|Row|Chip|Banner|Overlay)$',
          ).hasMatch(n)) {
        names.add(n);
      }
      return names.length < 4;
    });
  } catch (_) {}
  return names.join(' < ');
}

/// Larghezze dei 14 elementi più vicini sopra quello dell'errore (per capire
/// da dove viene uno spazio stretto): «Tipo:larghezza».
String widthsAbove(FlutterErrorDetails d) {
  Element? element;
  try {
    for (final n in d.informationCollector?.call() ?? <DiagnosticsNode>[]) {
      final Object? v = n.value;
      if (v is DebugCreator) element = v.element;
    }
  } catch (_) {}
  if (element == null) return '?';
  final out = <String>[];
  try {
    final ro = element.renderObject;
    if (ro is RenderBox && ro.hasSize) {
      out.add('${element.widget.runtimeType}:${ro.size.width.round()}');
    }
    var n = 0;
    element.visitAncestorElements((a) {
      final r = a.renderObject;
      final name = a.widget.runtimeType.toString();
      if (r is RenderBox &&
          r.hasSize &&
          (n < 6 ||
              const {
                'Row',
                'Expanded',
                'NavigationRail',
                'Scaffold',
                'AppShell',
                'DecoratedBox',
                'SingleChildScrollView',
                'IntrinsicHeight',
              }.contains(name) ||
              name.endsWith('Screen'))) {
        out.add('$name:${r.size.width.round()}');
      }
      return ++n < 80;
    });
  } catch (_) {}
  return out.join(' < ');
}

/// I vincoli di disposizione degli oggetti sopra l'elemento dell'errore (fino
/// a 45 livelli): da dove arriva uno spazio stretto.
String constraintsChain(FlutterErrorDetails d) {
  Element? element;
  try {
    for (final n in d.informationCollector?.call() ?? <DiagnosticsNode>[]) {
      final Object? v = n.value;
      if (v is DebugCreator) element = v.element;
    }
  } catch (_) {}
  if (element == null) return '?';
  final out = <String>[];
  RenderObject? ro = element.renderObject;
  for (var i = 0; ro != null && i < 45; i++, ro = ro.parent) {
    String c;
    try {
      c = ro is RenderBox ? '${ro.constraints}' : '';
    } catch (_) {
      c = '?';
    }
    out.add('${ro.runtimeType} $c');
  }
  return out.join(' < ');
}

/// Il fotogramma è stato disposto con i vincoli di una finestra diversa da
/// quella attuale: gli oggetti sopra l'errore hanno ancora la larghezza della
/// finestra di prima (la schermata è costruita con le misure nuove, per
/// esempio colonna di navigazione larga, ma disposta in 375 px). Succede solo
/// in flutter_test dopo un ridimensionamento in mezzo ad altre azioni (non
/// si riproduce con un ridimensionamento isolato) e produce falsi errori
/// («Trailing widget consumes…», overflow di una pagina schiacciata).
bool staleWindowConstraints(FlutterErrorDetails d, Size window) {
  bool stale(BoxConstraints c) =>
      c.hasTightWidth &&
      c.hasTightHeight &&
      ((c.maxWidth - window.width).abs() > 1 ||
          (c.maxHeight - window.height).abs() > 1);
  try {
    final root = RendererBinding.instance.renderViews.first.child;
    if (root is RenderBox && stale(root.constraints)) return true;
  } catch (_) {}
  // Pagina coperta da un'altra (l'Overlay non dispone le pagine sotto): dopo
  // un ridimensionamento resta con le misure della finestra di prima, ma si
  // ricostruisce con quelle nuove; un pezzo che si ridispone da solo (un
  // elenco, una sezione nascosta della shell che resta viva) usa i vincoli
  // vecchi con i widget nuovi (colonna di navigazione larga in 320 px). Solo
  // asserzioni di debug in una pagina che non si disegna: alla prima
  // apparizione si ridispone tutta con le misure giuste.
  try {
    Element? element;
    for (final n in d.informationCollector?.call() ?? <DiagnosticsNode>[]) {
      final Object? v = n.value;
      if (v is DebugCreator) element = v.element;
    }
    RenderObject? ro = element?.renderObject;
    RenderObject? below;
    for (var i = 0; ro != null && i < 400; i++) {
      if (ro.runtimeType.toString() == '_RenderTheater') {
        return below is RenderBox && stale(below.constraints);
      }
      below = ro;
      ro = ro.parent;
    }
  } catch (_) {}
  return false;
}

/// Misura della colonna di navigazione (se c'è) e scala dei caratteri che
/// vede, per capire perché la pagina accanto resta stretta.
String _railInfo() {
  try {
    Element? rail;
    void visit(Element e) {
      if (rail != null) return;
      if (e.widget is NavigationRail) {
        rail = e;
        return;
      }
      e.visitChildren(visit);
    }

    WidgetsBinding.instance.rootElement?.visitChildren(visit);
    final e = rail;
    if (e == null) return 'assente';
    final ro = e.renderObject;
    final size = ro is RenderBox ? '${ro.constraints}' : 'senza misura';
    return 'vincoli $size, 14 px diventano '
        '${MediaQuery.textScalerOf(e).scale(14).toStringAsFixed(1)} px';
  } catch (e) {
    return 'errore $e';
  }
}

String _describeShell() {
  final v = WidgetsBinding.instance.platformDispatcher.views.first;
  return 'vista ${v.physicalSize} (pixel ×${v.devicePixelRatio})';
}

class Monkey {
  Monkey(this.t, this.seed, this.setup)
    : rnd = Random(seed),
      pickRnd = Random(seed * 31 + 7);
  final WidgetTester t;
  final int seed;
  final MonkeySetup setup;
  final Random rnd;
  final Random pickRnd;
  final List<String> actions = [];
  final List<String> errors = [];
  final Map<String, OverflowSpot> overflows = {};

  /// Errori noti di Flutter, non dell'app (vedi il filtro in [runMonkey]).
  final Map<String, int> known = {};

  /// Azioni che hanno impiegato più di 10 s veri.
  final List<String> slow = [];
  int done = 0;
  int empty = 0;
  int maxEmpty = 0;

  /// Registra un overflow con il suo contesto (quinto giro, R5-B).
  void noteOverflow(FlutterErrorDetails d) {
    final full = d.toString();
    final m = overflowPxRe.firstMatch(full);
    final loc = appLocationRe.firstMatch(full);
    final where = loc == null ? 'fuori dall\'app' : '${loc[1]}:${loc[2]}';
    final lines = full.split('\n');
    final i = lines.indexWhere((l) => l.contains('error-causing widget'));
    final widget = i >= 0 && i + 1 < lines.length
        ? lines[i + 1].trim().split(' ').first
        : '?';
    final edge = m?[2] ?? '?';
    final spot = overflows.putIfAbsent(
      '$where $edge',
      () => OverflowSpot(where, widget, edge),
    );
    spot.count++;
    spot.maxPx = max(spot.maxPx, double.tryParse(m?[1] ?? '') ?? 0);
    final s = screen;
    spot.windows.add('${s.width.round()}×${s.height.round()}');
    spot.scales.add('×${t.platformDispatcher.textScaleFactor}');
    spot.themes.add(setup.services.themeMode.value.name);
    spot.screens.add(screenOf(d));
    spot.firstAction ??= actions.isEmpty ? '(avvio)' : actions.last;
    // dal quinto giro un overflow è un errore della prova (solo con
    // CRASH_R5_COLLECT=1 si raccolgono senza fermarsi, per fare l'elenco)
    if (!collectOverflows) {
      errors.add(
        'testo o elemento fuori dal suo spazio: ${m?[0] ?? lines.first} '
        '- $widget in $where; finestra ${spot.windows.last}, caratteri '
        '${spot.scales.last}, tema ${spot.themes.last}, '
        'schermata ${spot.screens.last}',
      );
    }
  }

  /// Quante volte è stato toccato ogni elemento (etichetta) o fatta ogni
  /// azione propria dell'area: serve a vedere che cosa raggiunge una prova.
  final Map<String, int> hits = {};

  /// Selettore dei file finto di questa prova (impostato da [runMonkey]).
  late FakePicker picker;

  void log(String s) {
    final label = RegExp('«([^»]*)»').firstMatch(s)?[1];
    final key = label != null
        ? shortText(label.split(' | ').first)
        : s.replaceAll(RegExp(r'[-\d]+'), '#');
    hits[key] = (hits[key] ?? 0) + 1;
    actions.add('${done + 1}: $s');
    if (actions.length > 40) actions.removeAt(0);
    // CRASH_R4_TRACE=1: ogni azione subito sullo schermo (per gli stalli,
    // quando la prova finisce per il tempo scaduto senza resoconto)
    // ignore: avoid_print
    if (monkeyTrace) print('[$seed] ${actions.last}');
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

  Size get screen => t.view.physicalSize / t.view.devicePixelRatio;

  bool _onScreen(Offset o) {
    final s = screen;
    return o.dx >= 0 && o.dy >= 0 && o.dx < s.width && o.dy < s.height;
  }

  /// [o] colpisce davvero [box] (niente dialoghi, barriere o altro sopra).
  bool _hits(RenderBox box, Offset o) {
    if (!_onScreen(o)) return false;
    final result = HitTestResult();
    t.binding.hitTestInView(result, o, t.view.viewId);
    return result.path.any((e) => identical(e.target, box));
  }

  List<MonkeyTarget> _collect() {
    final out = <MonkeyTarget>[];
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
          out.add(MonkeyTarget(el, ro, kind));
        }
      }
      el.visitChildren(visit);
    }

    t.binding.rootElement?.visitChildren(visit);
    return out;
  }

  /// Punto del bersaglio raggiungibile da un tocco (centro o punto a caso).
  Offset? _point(MonkeyTarget x) {
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
  (MonkeyTarget, Offset, String)? _pick(
    List<MonkeyTarget> all,
    Set<String> kinds,
  ) {
    final c = all.where((x) => kinds.contains(x.kind)).toList()..shuffle(rnd);
    // l'area su cui si insiste ha i suoi pulsanti preferiti
    final area = setup.scenario.area;
    if (area != null &&
        area.prefer.isNotEmpty &&
        kinds.contains('tocco') &&
        rnd.nextInt(1000) < area.preferPerMille) {
      for (final x in c.take(120)) {
        final label = labelOf(x.element);
        final l = label.toLowerCase();
        if (!area.prefer.any((re) => re.hasMatch(l)) || denied(label)) continue;
        final o = _point(x);
        if (o != null) return (x, o, label);
      }
    }
    for (final x in c.take(40)) {
      final o = _point(x);
      if (o == null) continue;
      final label = labelOf(x.element);
      if (denied(label)) continue;
      if (area != null &&
          kinds.contains('tocco') &&
          area.avoid.any((re) => re.hasMatch(label.toLowerCase())) &&
          rnd.nextInt(1000) < area.avoidPerMille) {
        continue;
      }
      return (x, o, label);
    }
    return null;
  }

  /// Pulsante da non toccare (vedi [isDenied]).
  bool denied(String label) =>
      isDenied(label, allowLogin: setup.scenario.options.allowLogin);

  /// Tutti gli elementi toccabili adesso.
  List<MonkeyTarget> targets() => _collect();

  /// Tocca un elemento toccabile adesso la cui etichetta (minuscola) combacia
  /// con [re]; false se non ce n'è uno raggiungibile.
  Future<bool> tapMatching(RegExp re, {String? what}) async {
    final c = _collect().where((x) => x.kind == 'tocco').toList()..shuffle(rnd);
    for (final x in c.take(120)) {
      final label = labelOf(x.element, depth: 30);
      if (!re.hasMatch(label.toLowerCase()) || denied(label)) continue;
      final o = _point(x);
      if (o == null) continue;
      log(
        'tocco ${what ?? 'mirato'} «${shortText(label)}» @${o.dx.round()},${o.dy.round()}',
      );
      await t.tapAt(o);
      return true;
    }
    if (monkeyTrace) {
      final all = [
        for (final x in c.take(30)) shortText(labelOf(x.element, depth: 30)),
      ];
      log('nessun elemento per /${re.pattern}/ fra: ${all.join(' ## ')}');
    }
    return false;
  }

  /// Tocca l'elemento con la chiave [key] (`Key('recorder-save')`), se c'è e
  /// si può toccare adesso.
  Future<bool> tapKey(String key) async {
    final found = find.byKey(Key(key)).evaluate();
    if (found.isEmpty) return false;
    final ro = found.first.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return false;
    final o = ro.localToGlobal(ro.size.center(Offset.zero));
    if (!_hits(ro, o)) return false;
    log('tocco la chiave «$key» @${o.dx.round()},${o.dy.round()}');
    await t.tapAt(o);
    return true;
  }

  /// Tocca il pulsante di tipo [button] che contiene l'icona [icon], se c'è e
  /// si può toccare adesso (per i pulsanti senza testo né chiave).
  Future<bool> tapIcon(IconData icon, {Type button = FilledButton}) async {
    final f = find
        .ancestor(
          of: find.byIcon(icon),
          matching: find.byWidgetPredicate((w) => w.runtimeType == button),
        )
        .hitTestable(at: Alignment.center);
    var found = f.evaluate().isNotEmpty;
    if (!found) {
      // fuori dallo schermo: la lista lo porta in vista
      final any = find.ancestor(
        of: find.byIcon(icon),
        matching: find.byWidgetPredicate((w) => w.runtimeType == button),
      );
      if (any.evaluate().isEmpty) return false;
      try {
        await t.ensureVisible(any.first);
      } catch (_) {
        return false;
      }
      await t.pump();
      found = f.evaluate().isNotEmpty;
    }
    if (!found) return false;
    log('tocco il pulsante con icona ${icon.codePoint.toRadixString(16)}');
    await t.tap(f.first, warnIfMissed: false);
    return true;
  }

  /// Tocca un elemento toccabile a caso con un'etichetta non vuota che non
  /// combacia con [exclude] (per andare avanti in una procedura guidata
  /// senza tornare indietro).
  Future<bool> tapAny({RegExp? exclude, String what = 'avanti'}) async {
    final c = _collect().where((x) => x.kind == 'tocco').toList()..shuffle(rnd);
    for (final x in c.take(80)) {
      final label = labelOf(x.element, depth: 30);
      if (label.trim().isEmpty || denied(label)) continue;
      if (exclude != null && exclude.hasMatch(label.toLowerCase())) continue;
      final o = _point(x);
      if (o == null) continue;
      log('tocco $what «${shortText(label)}» @${o.dx.round()},${o.dy.round()}');
      await t.tapAt(o);
      return true;
    }
    return false;
  }

  /// Scrive [text] nel primo campo di testo raggiungibile (o in uno a caso).
  Future<bool> typeInField(String text, {RegExp? matching}) async {
    final c = _collect().where((x) => x.kind == 'campo').toList()..shuffle(rnd);
    for (final x in c.take(40)) {
      final label = labelOf(x.element);
      if (matching != null && !matching.hasMatch(label.toLowerCase())) continue;
      final o = _point(x);
      if (o == null) continue;
      log('testo mirato in «${shortText(label)}»: ${text.length} caratteri');
      await t.tapAt(o);
      await t.pump();
      await t.enterText(find.byWidget(x.element.widget), text);
      return true;
    }
    return false;
  }

  /// Tasto con modificatori (Ctrl+F…).
  Future<void> shortcut(
    LogicalKeyboardKey key, {
    bool control = false,
    bool shift = false,
  }) async {
    log(
      'tasto ${control ? 'Ctrl+' : ''}${shift ? 'Maiusc+' : ''}${key.keyLabel}',
    );
    if (control) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(key);
    if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    if (control) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  }

  /// C'è sullo schermo un widget di tipo [T].
  bool shows<T extends Widget>() =>
      find.byType(T, skipOffstage: true).evaluate().isNotEmpty;

  /// Un tocco in [o] non deve finire su un pulsante da saltare.
  bool _safeAt(List<MonkeyTarget> all, Offset o) {
    if (!_onScreen(o)) return false;
    final result = HitTestResult();
    t.binding.hitTestInView(result, o, t.view.viewId);
    final hit = {for (final e in result.path) e.target};
    for (final x in all) {
      if (x.kind != 'tocco') continue;
      if (hit.contains(x.box) && denied(labelOf(x.element))) return false;
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
    // area su cui insistere: ci si torna se se ne è usciti (o ogni tanto da
    // capo) e ogni tanto si fa un'azione propria (audio finto, tasti…)
    final area = setup.scenario.area;
    if (area != null) {
      if (done == 0 ||
          (!area.inArea(this) && rnd.nextInt(100) < 30) ||
          rnd.nextInt(1000) < area.restartPerMille) {
        return area.enter(this);
      }
      if (rnd.nextInt(1000) < area.actionsPerMille) {
        final acts = area.actions(this);
        final total = acts.fold(0, (a, b) => a + b.weight);
        if (total > 0) {
          var k = rnd.nextInt(total);
          for (final a in acts) {
            k -= a.weight;
            if (k >= 0) continue;
            log(a.name);
            return a.run(this);
          }
        }
      }
    }
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
      if (hit == null) return back();
      final (x, o, label) = hit;
      log(
        'tocco «${shortText(label)}» (${x.element.widget.runtimeType}) '
        '@${o.dx.round()},${o.dy.round()}',
      );
      await t.tapAt(o);
    } else if (roll < 560) {
      final hit = _pick(all, taps);
      if (hit == null) return;
      final (x, o, label) = hit;
      log(
        'pressione lunga «${shortText(label)}» @${o.dx.round()},${o.dy.round()}',
      );
      await t.longPressAt(o);
    } else if (roll < 590) {
      final s = screen;
      final o = Offset(rnd.nextDouble() * s.width, rnd.nextDouble() * s.height);
      if (!_safeAt(all, o)) return;
      log('tocco a caso @${o.dx.round()},${o.dy.round()}');
      await t.tapAt(o);
    } else if (roll < 700) {
      final hit = _pick(all, {'campo'});
      if (hit == null) return;
      final (x, o, label) = hit;
      final text = randomText(rnd);
      log(
        'testo in «${shortText(label)}»: ${text.length} caratteri '
        '«${shortText(text)}»',
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
      await back();
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

  Future<void> back() async {
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

bool get monkeyLong => Platform.environment['CRASH_R4_MONKEY'] == '1';

bool get monkeyTrace => Platform.environment['CRASH_R4_TRACE'] == '1';

/// CRASH_R5_COLLECT=1: gli overflow si raccolgono e si riepilogano senza
/// fermare la prova (altrimenti sono un errore).
bool get collectOverflows => Platform.environment['CRASH_R5_COLLECT'] == '1';

/// Porta a termine [op] facendo avanzare il tempo finto e quello vero; se
/// non finisce in ~40 s finti / 3 s veri è uno stallo, registrato come
/// errore di [m].
Future<void> driveOp(
  WidgetTester t,
  Future<void> Function() op,
  String what,
  Monkey m,
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

int monkeyEnv(String k, int d) =>
    int.tryParse(Platform.environment[k] ?? '') ?? d;

/// Esegue la scimmia: true se nessun errore. Riempie [stats].
Future<void> runMonkey(
  WidgetTester t,
  MonkeyScenario sc,
  int seed,
  int steps, {
  bool semantics = false,
  Map<String, int>? total,
}) async {
  t.view.physicalSize = Monkey._sizes[seed % Monkey._sizes.length];
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final setup = (await t.runAsync(() => prepareScenario(sc, Random(seed))))!;
  final s = setup.services;
  final monkey = Monkey(t, seed, setup);
  // come in main(): «Indietro» su una pagina non ancora disegnata
  installBackGuard(appNavigatorKey);
  addTearDown(removeBackGuard);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.allMessagesHandler = setup.channels.handle;
  final previousPicker = FilePickerPlatform.instance;
  FilePickerPlatform.instance = monkey.picker = FakePicker(
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
    // («hasSize»: la stessa riga che ha già dato «Trailing widget consumes…»
    // nel fotogramma con i vincoli vecchi resta senza misura e lo dicono anche
    // gli oggetti sopra)
    if ((text.contains('overflowed by') ||
            text.contains('consumes the entire tile width') ||
            text.contains("'hasSize'")) &&
        staleWindowConstraints(d, monkey.screen)) {
      const why =
          'fotogramma con i vincoli della finestra di prima (flutter_test)';
      monkey.known[why] = (monkey.known[why] ?? 0) + 1;
      return;
    }
    if (text.contains('overflowed by')) {
      monkey.noteOverflow(d);
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
    // - menu di un DropdownButton più alto dello spazio disponibile;
    // - fotogramma disposto con i vincoli della finestra di prima (vedi
    //   [staleWindowConstraints]): «Trailing widget consumes…» e overflow di
    //   pagine schiacciate in 80-95 px;
    // - SnackBar mobile («floating») più alto dello spazio che lascia la
    //   barra di navigazione in una finestra di 320 px di altezza (asserzione
    //   solo di debug, in release l'avviso si sovrappone alla barra);
    // - albero semantico con `node.built` in debugCheckForBuilds (stessa
    //   riscrittura dell'albero semantico di Flutter 3.38);
    // - albero semantico (lettore di schermo acceso) con un `!` nullo in
    //   _RenderObjectSemantics._updateSemanticsNodeGeometry (riscrittura
    //   dell'albero semantico di Flutter 3.38): compare dopo una navigazione
    //   con le pagine che si chiudono, mai con pile del codice dell'app;
    // - barra di selezione del testo con `size == theater.size` in
    //   OverlayPortal.overlayChildLayoutBuilder (overlay.dart: l'overlay della
    //   barra si dispone con la misura del Theater di un fotogramma prima);
    // - barra di selezione del testo (Seleziona tutto, Copia…) con la sua
    //   trasformazione di un RenderFollowerLayer chiesta dall'overlay prima
    //   della disposizione;
    // - InputDatePickerFormField (selettore della data a testo) che riscrive
    //   il suo campo in didChangeDependencies mentre il tema o la scala dei
    //   caratteri cambiano e il Form si ricostruisce.
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
        : text.contains('Floating SnackBar presented off screen') &&
              stack.contains('_ScaffoldLayout.performLayout')
        ? 'SnackBar mobile fuori schermo (finestra di 320 px di altezza: '
              'barra di navigazione e pulsante occupano più dello schermo)'
        : text.contains('node.built') &&
              stack.contains('_RenderObjectSemantics.debugCheckForBuilds')
        ? 'albero semantico: nodo non ancora costruito in '
              'debugCheckForBuilds (lettore di schermo, pila senza codice '
              'dell app)'
        : text.contains('Null check operator') &&
              stack.contains(
                '_RenderObjectSemantics._updateSemanticsNodeGeometry',
              )
        ? 'albero semantico: geometria di un nodo non calcolata (solo con il '
              'lettore di schermo, pila senza codice dell app)'
        : text.contains('size == theater.size') &&
              stack.contains('_RenderLayoutBuilder._computeNewLayoutInfo')
        ? 'barra di selezione del testo: overlay con una misura diversa dal '
              'suo Theater durante la disposizione'
        : text.contains('cannot be reliably computed') &&
              text.contains('RenderFollowerLayer') &&
              stack.contains('_RenderLayoutBuilder._computeNewLayoutInfo')
        ? 'barra di selezione del testo: trasformazione di un '
              'RenderFollowerLayer chiesta prima della sua disposizione'
        : text.contains('called during build') &&
              stack.contains(
                '_InputDatePickerFormFieldState.didChangeDependencies',
              )
        ? 'selettore della data a testo: campo riscritto durante la '
              'ricostruzione (cambio di tema o di caratteri)'
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
              l.contains('file:///') ||
              l.contains('constraints:') ||
              l.contains('creator:'),
        )
        .take(16)
        .join('\n');
    final sz = monkey.screen;
    // spazio stretto inspiegabile: l'albero di disposizione (solo le righe con
    // misure dei primi livelli) per capire chi occupa la larghezza
    var tree = '';
    if (text.contains('consumes the entire tile width')) {
      try {
        final lines = RendererBinding.instance.renderViews.first
            .toStringDeep()
            .split('\n');
        final shown = lines
            .where(
              (l) =>
                  l.contains('size:') ||
                  l.contains('Rail') ||
                  l.contains('RenderFlex'),
            )
            .take(60)
            .join('\n');
        tree = '\nalbero di disposizione:\n$shown';
      } catch (e) {
        tree = '\nalbero non leggibile: $e';
      }
    }
    // nodo semantico con misure non finite: chi l'ha prodotto
    if (text.contains('offset.isFinite')) {
      try {
        final bad = <String>[];
        void walk(SemanticsNode n) {
          final r = n.rect;
          final m = n.transform;
          final finite =
              r.isFinite && (m == null || m.storage.every((v) => v.isFinite));
          if (!finite) {
            bad.add(
              'rect $r, trasformazione ${m == null ? 'nessuna' : m.storage.take(16).toList()}, '
              'etichetta «${n.label}», nodo $n',
            );
          }
          n.visitChildren((c) {
            walk(c);
            return true;
          });
        }

        final root = RendererBinding
            .instance
            .renderViews
            .first
            .owner
            ?.semanticsOwner
            ?.rootSemanticsNode;
        if (root != null) walk(root);
        tree = '\nnodi semantici non finiti: ${bad.take(5).join(' ## ')}';
      } catch (e) {
        tree = '\nalbero semantico non leggibile: $e';
      }
    }
    monkey.errors.add(
      '${d.exceptionAsString()}\n$where\n'
      'contesto: finestra ${sz.width.round()}×${sz.height.round()}, caratteri '
      '×${t.platformDispatcher.textScaleFactor}, tema '
      '${setup.services.themeMode.value.name}, schermata ${screenOf(d)}\n'
      'vincoli: ${constraintsChain(d)}\n'
      'larghezze: ${widthsAbove(d)}\n'
      'colonna di navigazione: ${_railInfo()}; ${_describeShell()}$tree\n'
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
      // si aspetta [done], completato alla fine del giro
      // ignore: unawaited_futures
      .run(() async {
        try {
          await t.pumpWidget(UniversityNotesApp(services: s));
          for (var i = 0; i < 6; i++) {
            await monkey.settle();
          }
          for (; monkey.done < steps; monkey.done++) {
            if (monkey.errors.isNotEmpty) break;
            if (monkeyLong && monkey.done % 100 == 0) {
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
  if (monkeyLong) print('  ${sc.name} $seed: azioni finite, chiusura');

  // chiusura: niente timer o registrazioni lasciati a metà
  // (le operazioni dell'app possono aspettare sia il tempo finto sia quello
  // vero: si fanno avanzare entrambi, mai solo dentro runAsync)
  // (un avvio ancora in corso — «Registra» toccato proprio all'ultimo passo —
  // finisce dopo il primo controllo: si riprova dopo aver lasciato correre
  // il tempo, finché registrazione e salvataggio non sono finiti)
  for (var round = 0; round < 4; round++) {
    for (var i = 0; i < 12; i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await t.pump(const Duration(milliseconds: 100));
    }
    if (s.recorder.active) {
      await driveOp(t, s.recorder.stop, 'fine della registrazione', monkey);
    } else if (!s.recorder.saving) {
      break;
    }
  }
  // sessione Focus, sincronizzazioni automatiche (timer periodici)
  if (s.focus.active) {
    await driveOp(t, s.focus.discard, 'fine della sessione Focus', monkey);
  }
  for (final c in s.clouds) {
    c.stopAutoSync();
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
  // `startAutoSync` crea il timer periodico dopo aver letto l'intervallo dal
  // database: uno avviato proprio negli ultimi passi nasce dopo il primo
  // `stopAutoSync`, si ferma adesso
  for (final c in s.clouds) {
    c.stopAutoSync();
  }
  await t.pump(const Duration(seconds: 1));
  await driveOp(t, s.database.close, 'chiusura del database', monkey);
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
    'testi fuori spazio ${monkey.overflows.values.fold(0, (a, b) => a + b.count)} '
    'in ${monkey.overflows.length} luoghi; '
    'schermate senza elementi toccabili per al massimo ${monkey.maxEmpty} passi; '
    'azioni lente: ${monkey.slow.isEmpty ? 'nessuna' : monkey.slow.join(', ')}; '
    'errori noti di Flutter: ${monkey.known.isEmpty ? 'nessuno' : monkey.known}; '
    'uscite finte: ${setup.channels.external.toSet().take(8).join(', ')}; '
    'canali senza plugin: ${setup.channels.seen.take(12).join(', ')}',
  );
  if (monkeyLong) {
    final top = monkey.hits.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    // una riga per prova: «TOCCHI|scenario|seme|azioni|distinti|etichetta=n;…»
    // ignore: avoid_print
    print(
      'TOCCHI|$name|$seed|${monkey.done}|${top.length}|'
      '${top.map((e) => '${e.key}=${e.value}').join(';')}',
    );
  }
  for (final o in monkey.overflows.values) {
    // una riga per luogo, da riepilogare con findstr/grep «OVERFLOW|»
    // ignore: avoid_print
    print(
      'OVERFLOW|${o.where}|${o.widget}|${o.edge}|${o.count}|'
      '${o.maxPx.toStringAsFixed(1)}|${o.windows.join(',')}|'
      '${o.scales.join(',')}|${o.themes.join(',')}|${o.screens.join(' / ')}|'
      '${o.firstAction}',
    );
  }
  if (total != null && monkey.errors.isEmpty) {
    total['azioni'] = (total['azioni'] ?? 0) + monkey.done;
  }
  expect(monkey.errors, isEmpty, reason: monkey.report(name));
}
