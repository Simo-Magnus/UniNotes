// Widget «Registra lezione» (Android): avvio della registrazione dalla rotta
// `registra:avvia` con lo stesso percorso del pulsante «Registra» e ritorno
// alla schermata Home; controlli statici sul codice nativo dei widget
// (PendingIntent immutabili, nessun componente esportato nuovo, layout per
// misura, rotta d'avvio protetta).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/notification_plan.dart';
import 'package:university_notes/core/router/app_shell.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Microfono finto: permesso negabile, conta gli avvii.
class _Mic implements AudioRecorder {
  StreamController<Uint8List> pcm = StreamController<Uint8List>.broadcast();
  bool deny = false;
  int starts = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => !deny;
  @override
  Future<void> setOnConfigChanged(void Function(RecordConfig c)? cb) async {}
  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    starts++;
    if (pcm.isClosed) pcm = StreamController<Uint8List>.broadcast();
    return pcm.stream;
  }

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Setup {
  _Setup(this.s, this.mic, this.tmp);
  final AppServices s;
  final _Mic mic;
  final Directory tmp;
}

Future<_Setup> _start(WidgetTester t, {bool withCourse = true}) async {
  t.view.physicalSize = const Size(400, 860);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final mic = _Mic();
  late AppServices s;
  late Directory tmp;
  await t.runAsync(() async {
    tmp = await Directory.systemTemp.createTemp('un_widget_rec_');
    final db = await AppDatabase.openInMemory();
    s = AppServices(
      db,
      notes: NotesStore(
        SettingsRepository(db),
        root: () async => Directory(p.join(tmp.path, 'Appunti')),
      ),
      recorder: LectureRecorder(
        recorder: () => mic,
        workDir: () async => Directory(p.join(tmp.path, 'lavoro')),
        controls: () => const NoBackgroundControls(),
      ),
    );
    if (withCourse) await s.courses.insert(const Course(name: 'Analisi I'));
  });
  await t.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: const MaterialApp(
        locale: Locale('it', 'IT'),
        supportedLocales: [Locale('it', 'IT')],
        localizationsDelegates: [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: AppShell(),
      ),
    ),
  );
  await _settle(t);
  return _Setup(s, mic, tmp);
}

/// Caricamenti dal database e file veri (tempo reale) e fotogrammi.
Future<void> _settle(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _until(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 60 && !done(); i++) {
    await _settle(t, 1);
  }
}

/// Ferma la registrazione: lo stop aspetta anche timer del tempo finto (la
/// trascrizione dal vivo), quindi non si aspetta solo con runAsync (che non
/// finirebbe mai) ma alternando tempo vero e fotogrammi.
Future<void> _stop(WidgetTester t, LectureRecorder rec) async {
  if (!rec.active) return;
  unawaited(rec.stop());
  for (var i = 0; i < 100 && rec.active; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _finish(WidgetTester t, _Setup x) async {
  await _stop(t, x.s.recorder);
  // registratore chiuso come farebbe l'utente (openRecorder ricorda che è
  // aperto fino alla chiusura della pagina)
  // (la shell sotto il registratore è «fuori scena»)
  final shell = find.byType(AppShell, skipOffstage: false);
  if (shell.evaluate().isNotEmpty) {
    Navigator.of(t.element(shell)).popUntil((r) => r.isFirst);
    await _settle(t, 4);
  }
  await t.pumpWidget(const SizedBox());
  await t.pump(const Duration(seconds: 2));
  await t.runAsync(() async {
    await x.s.database.close();
    if (await x.tmp.exists()) await x.tmp.delete(recursive: true);
  });
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  var backs = 0;

  setUpAll(() async {
    Intl.defaultLocale = 'it_IT';
    await initializeDateFormatting('it_IT');
  });

  setUp(() {
    backs = 0;
    AppShell.prefetchSections = false;
    AppShell.quickStartFromWidget = true;
    RecorderScreen.backgroundDelay = const Duration(milliseconds: 50);
    RecorderScreen.toBackground = () async {
      backs++;
      return true;
    };
  });
  tearDown(() {
    AppShell.prefetchSections = true;
    AppShell.quickStartFromWidget = Platform.isAndroid;
    RecorderScreen.backgroundDelay = const Duration(milliseconds: 700);
  });

  testWidgets('registra:avvia: registra subito nel corso attuale, poi la '
      'schermata Home; la rotta vale una volta sola', (t) async {
    final x = await _start(t);
    final rec = x.s.recorder;
    x.s.openRoute.call(AppRoutes.recordStart);
    await _until(t, () => backs > 0);

    expect(find.byType(RecorderScreen), findsOneWidget);
    expect(rec.active, isTrue);
    expect(x.mic.starts, 1);
    expect(rec.courseName, 'Analisi I');
    // stesso nome predefinito del pulsante «Registra» («AAAA-MM-GG HH:MM»,
    // con i due punti simili consentiti nei nomi dei file)
    final now = DateTime.now();
    expect(
      p.basenameWithoutExtension(rec.path!),
      startsWith(
        '${now.year}-${now.month.toString().padLeft(2, '0')}-'
        '${now.day.toString().padLeft(2, '0')}',
      ),
    );
    expect(p.split(rec.path!), contains('Registrazioni'));
    // tornati alla Home una volta, la registrazione continua
    expect(backs, 1);
    expect(x.s.openRoute.pending, isNull);
    expect(rec.quickStartPending, isFalse);

    // salvata o fermata: nessuna ripartenza (la richiesta è consumata)
    await _stop(t, rec);
    await _settle(t, 8);
    expect(rec.active, isFalse);
    expect(x.mic.starts, 1);
    expect(backs, 1);
    expect(t.takeException(), isNull);
    await _finish(t, x);
  });

  testWidgets('registra:avvia con il permesso del microfono negato: '
      'registratore aperto, nessun avvio, si resta nell\'app', (t) async {
    final x = await _start(t);
    x.mic.deny = true;
    x.s.openRoute.call(AppRoutes.recordStart);
    await _until(
      t,
      () => find
          .textContaining('Permesso del microfono negato')
          .evaluate()
          .isNotEmpty,
    );
    expect(find.byType(RecorderScreen), findsOneWidget);
    expect(x.s.recorder.active, isFalse);
    expect(x.mic.starts, 0);
    expect(backs, 0);
    expect(
      find.textContaining('Permesso del microfono negato'),
      findsOneWidget,
    );
    expect(x.s.recorder.quickStartPending, isFalse);
    await _finish(t, x);
  });

  testWidgets('registra:avvia con il registratore già aperto o una '
      'registrazione in corso: una sola registrazione', (t) async {
    final x = await _start(t);
    final rec = x.s.recorder;
    // registratore aperto dal pulsante, niente registrazione
    x.s.openRoute.call(AppRoutes.record);
    await _settle(t);
    expect(find.byType(RecorderScreen), findsOneWidget);
    expect(rec.active, isFalse);
    // tocco sul widget con il registratore già aperto: parte lì
    x.s.openRoute.call(AppRoutes.recordStart);
    await _until(t, () => backs > 0);
    expect(rec.active, isTrue);
    expect(x.mic.starts, 1);
    // un altro tocco mentre registra (widget non ancora ridisegnato): niente
    // seconda registrazione né richiesta in sospeso
    x.s.openRoute.call(AppRoutes.recordStart);
    await _settle(t);
    expect(x.mic.starts, 1);
    expect(rec.quickStartPending, isFalse);
    expect(backs, 1);
    await _finish(t, x);
  });

  testWidgets('iOS e macOS (schema uninotes:// apribile da chiunque): '
      'registra:avvia apre solo il registratore', (t) async {
    AppShell.quickStartFromWidget = false;
    final x = await _start(t);
    x.s.openRoute.call(AppRoutes.recordStart);
    await _settle(t, 10);
    expect(find.byType(RecorderScreen), findsOneWidget);
    expect(x.s.recorder.active, isFalse);
    expect(x.mic.starts, 0);
    expect(backs, 0);
    await _finish(t, x);
  });

  testWidgets('registra:avvia senza insegnamenti: lo si dice, niente avvio', (
    t,
  ) async {
    final x = await _start(t, withCourse: false);
    x.s.openRoute.call(AppRoutes.recordStart);
    await _settle(t, 10);
    expect(x.s.recorder.active, isFalse);
    expect(backs, 0);
    expect(find.textContaining('Nessun insegnamento'), findsOneWidget);
    await _finish(t, x);
  });

  group('codice nativo dei widget (Android)', () {
    const kt =
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes';
    const res = 'android/app/src/main/res';

    test('ogni PendingIntent è immutabile', () {
      final files = Directory(kt)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.kt'));
      var count = 0;
      for (final f in files) {
        final src = f.readAsStringSync();
        for (final m in RegExp(
          r'PendingIntent\.get(Activity|Broadcast|Service|ForegroundService)\(',
        ).allMatches(src)) {
          // argomenti della chiamata fino alla parentesi che la chiude
          var depth = 0;
          var end = m.end - 1;
          for (var i = m.end - 1; i < src.length; i++) {
            if (src[i] == '(') depth++;
            if (src[i] == ')' && --depth == 0) {
              end = i;
              break;
            }
          }
          final call = src.substring(m.start, end + 1);
          count++;
          expect(
            call.contains('FLAG_IMMUTABLE'),
            isTrue,
            reason: '${p.basename(f.path)}: $call',
          );
          expect(call.contains('FLAG_MUTABLE'), isFalse, reason: call);
        }
      }
      // widget (apertura, comandi, mezzanotte, controllo) e notifica
      expect(count, greaterThanOrEqualTo(5));
    });

    test('nessun componente esportato nuovo; ricevitori dei widget e dei '
        'comandi non esportati', () {
      final manifest = _read('android/app/src/main/AndroidManifest.xml');
      final exported = [
        for (final m in RegExp(
          r'<(activity|receiver|service|provider)\b[^>]*>',
        ).allMatches(manifest))
          if (m.group(0)!.contains('android:exported="true"'))
            RegExp(r'android:name="([^"]+)"').firstMatch(m.group(0)!)!.group(1),
      ];
      expect(exported.toSet(), {
        '.MainActivity',
        '.ShareReceiverActivity',
        'com.linusu.flutter_web_auth_2.CallbackActivity',
      });
      for (final name in [
        '.widgets.UpcomingExamsWidget',
        '.widgets.RecordWidget',
        '.RecordingCommandReceiver',
      ]) {
        final tag = RegExp(
          '<receiver[^>]*android:name="${RegExp.escape(name)}"[^>]*>',
        ).firstMatch(manifest);
        expect(tag, isNotNull, reason: name);
        expect(tag!.group(0), contains('android:exported="false"'));
      }
    });

    test('registra:avvia solo dai widget dell\'app (codice segreto), i '
        'comandi del widget validati', () {
      final support = _read('$kt/widgets/WidgetSupport.kt');
      expect(
        support,
        contains('ROUTE_RECORD_START = "${AppRoutes.recordStart}"'),
      );
      expect(support, contains('MessageDigest.isEqual'));
      expect(support, contains('SecureRandom'));
      // senza il codice giusto: solo il registratore
      expect(support, contains('if (ok) route else ROUTE_RECORD'));
      final main = _read('$kt/MainActivity.kt');
      expect(main, contains('WidgetSupport.routeOf(this, intent)'));
      expect(main, isNot(contains('WidgetSupport.routeOf(intent)')));
      final notif = _read('$kt/RecordingNotification.kt');
      expect(notif, contains('in RecordingNotification.COMMANDS'));
      for (final c in [btnPause, btnResume, btnSave]) {
        expect(notif, contains('"$c"'));
      }
      final widget = _read('$kt/widgets/RecordWidget.kt');
      expect(widget, contains('CMD_DISCARD = "$btnDiscard"'));
    });

    test('layout per misura (Android 12+) con ripiego per Android 8-11', () {
      final support = _read('$kt/widgets/WidgetSupport.kt');
      expect(support, contains('RemoteViews(list.associateWith(build))'));
      expect(support, contains('Build.VERSION_CODES.S'));
      expect(support, contains('OPTION_APPWIDGET_SIZES'));
      expect(support, contains('OPTION_APPWIDGET_MIN_WIDTH'));
      for (final f in ['UpcomingExamsWidget.kt', 'RecordWidget.kt']) {
        final src = _read('$kt/widgets/$f');
        expect(src, contains('WidgetSupport.responsive('), reason: f);
        expect(src, contains('onAppWidgetOptionsChanged'), reason: f);
      }
      // fino a 6 prove, come il JSON dell'app
      expect(
        _read('$kt/widgets/WidgetPlan.kt'),
        contains('const val MAX_EXAMS = 6'),
      );
      // il registratore: tempo con il cronometro del sistema
      expect(
        _read('$res/layout/widget_registra_attivo.xml'),
        contains('<Chronometer'),
      );
    });

    test('nei layout dei widget solo viste ammesse dalle RemoteViews', () {
      const allowed = {
        'FrameLayout',
        'LinearLayout',
        'RelativeLayout',
        'GridLayout',
        'TextView',
        'ImageView',
        'ImageButton',
        'Button',
        'Chronometer',
        'ProgressBar',
      };
      final layouts = Directory('$res/layout')
          .listSync()
          .whereType<File>()
          .where((f) => p.basename(f.path).startsWith('widget_'));
      expect(layouts.length, greaterThanOrEqualTo(6));
      for (final f in layouts) {
        final src = f.readAsStringSync();
        for (final m in RegExp(r'<([A-Za-z][\w.]*)[\s>/]').allMatches(src)) {
          final tag = m.group(1)!;
          if (tag == 'xml') continue;
          expect(allowed, contains(tag), reason: '${p.basename(f.path)}: $tag');
        }
        // radice con l'id di sfondo del sistema (animazione d'apertura e
        // angoli arrotondati su Android 12+)
        expect(src, contains('android:id="@android:id/background"'));
      }
    });
  });
}
