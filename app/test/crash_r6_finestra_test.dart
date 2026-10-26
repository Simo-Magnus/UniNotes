// Finestra del PC (Windows): X che chiude subito e riapertura dalla barra
// delle applicazioni senza nero. Vedi docs/registratore.md, «Windows:
// chiusura immediata» e «Windows: niente schermo nero riaprendo dalla
// barra delle applicazioni».
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/desktop_window.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';

import 'support/fake_reminders.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('chiusura della finestra (Dart)', () {
    const tray = MethodChannel('tray_manager');
    const window = MethodChannel('window_manager');
    const runner = MethodChannel(DesktopWindow.finestraChannel);
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // chiamate a finestra, runner e area di notifica, in ordine
    late List<String> calls;

    setUp(() {
      calls = [];
      messenger.setMockMethodCallHandler(tray, (call) async {
        calls.add('tray.${call.method}');
        return null;
      });
      messenger.setMockMethodCallHandler(window, (call) async {
        calls.add('window.${call.method}');
        return call.method == 'isMinimized' ? false : null;
      });
      messenger.setMockMethodCallHandler(runner, (call) async {
        calls.add('runner.${call.method}');
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(tray, null);
      messenger.setMockMethodCallHandler(window, null);
      messenger.setMockMethodCallHandler(runner, null);
    });

    Future<AppServices> services({required bool recording}) async {
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final recorder = LectureRecorder();
      if (recording) recorder.phase = RecorderPhase.recording;
      return AppServices(
        db,
        recorder: recorder,
        reminders: (s) => RemindersService(
          s,
          platform: FakeNotificationPlatform(),
          calendarBackend: FakeCalendarBackend(),
          widgets: FakeHomeWidgets(),
          platformName: 'windows',
          isRecording: () => recording,
        ),
      );
    }

    test('X senza registrazione: il runner nasconde la finestra prima di '
        'tutto il resto, poi database e uscita', () async {
      final s = await services(recording: false);
      final dw = DesktopWindow(s, windows: true);
      // il motore chiede se uscire (prima X): si esce
      expect(await dw.onExitRequested(), AppExitResponse.exit);
      expect(calls, isEmpty);
      // poi la X arriva a window_manager
      await dw.onWindowClose();
      expect(calls.first, 'runner.uscita');
      expect(
        calls,
        containsAllInOrder([
          'runner.uscita',
          'window.setPreventClose',
          'window.destroy',
        ]),
      );
      // una seconda X durante l'uscita non rifà nulla
      calls.clear();
      await dw.onWindowClose();
      expect(calls, isEmpty);
    });

    test('X con una registrazione in corso (Windows): il motore non esce, la '
        'finestra va nell\'area di notifica e la registrazione continua',
        () async {
      final s = await services(recording: true);
      final dw = DesktopWindow(s, windows: true);
      expect(await dw.onExitRequested(), AppExitResponse.cancel);
      expect(s.recorder.active, isTrue);
      expect(
        calls,
        containsAllInOrder(['tray.setIcon', 'window.hide', 'runner.nascosta']),
      );
      expect(calls, isNot(contains('runner.uscita')));
      expect(calls, isNot(contains('window.destroy')));
    });

    test('area di notifica non disponibile: la finestra torna visibile '
        '(niente app invisibile con la registrazione in corso)', () async {
      messenger.setMockMethodCallHandler(tray, (call) async {
        calls.add('tray.${call.method}');
        if (call.method == 'setIcon') {
          throw PlatformException(code: 'tray', message: 'non disponibile');
        }
        return null;
      });
      final s = await services(recording: true);
      final dw = DesktopWindow(s, windows: true);
      expect(await dw.onExitRequested(), AppExitResponse.cancel);
      expect(calls, containsAllInOrder(['runner.nascosta', 'window.show']));
      expect(calls, isNot(contains('window.hide')));
    });

    test('fuori da Windows niente canale del runner e l\'uscita del sistema '
        'esce', () async {
      final s = await services(recording: false);
      final dw = DesktopWindow(s, windows: false);
      expect(await dw.onExitRequested(), AppExitResponse.exit);
      await dw.onWindowClose();
      expect(calls.where((c) => c.startsWith('runner.')), isEmpty);
      expect(calls, contains('window.destroy'));
    });

    test('runner assente (canale senza risposta): l\'uscita va avanti',
        () async {
      messenger.setMockMethodCallHandler(runner, null);
      final s = await services(recording: false);
      final dw = DesktopWindow(s, windows: true);
      await dw.onWindowClose();
      expect(calls, contains('window.destroy'));
    });
  });

  group('runner di Windows (controlli statici)', () {
    final fw = _read('windows/runner/flutter_window.cpp');
    final main = _read('windows/runner/main.cpp');
    final handler = fw.substring(fw.indexOf('FlutterWindow::MessageHandler'));
    final plugins = handler.indexOf('HandleTopLevelWindowProc');

    test('la X nasconde la finestra prima dei plugin e del motore', () {
      final close = handler.indexOf('case WM_CLOSE:');
      expect(close, greaterThan(0));
      expect(close, lessThan(plugins));
      final block = handler.substring(close, handler.indexOf('break;', close));
      expect(block, contains('SW_HIDE'));
      expect(block, contains('kClosingAsked'));
      // senza risposta dall'app la finestra torna visibile
      expect(fw, contains('kCloseTimer'));
      expect(fw, contains('ShowWindow(hwnd, SW_SHOW)'));
    });

    test('canale «finestra»: uscita e area di notifica', () {
      expect(fw, contains(DesktopWindow.finestraChannel));
      expect(fw, contains('"uscita"'));
      expect(fw, contains('"nascosta"'));
      final destroy = fw.substring(fw.indexOf('void FlutterWindow::OnDestroy'));
      expect(
        destroy.indexOf('window_channel_ = nullptr'),
        lessThan(destroy.indexOf('flutter_controller_ = nullptr')),
      );
    });

    test('ripristino dalla barra: serie di frame forzati, vista non '
        'ridimensionata a 0x0', () {
      final size = handler.indexOf('case WM_SIZE:');
      expect(size, lessThan(plugins));
      expect(handler.substring(size, plugins), contains('StartRedraws'));
      expect(fw, contains('kRedrawCount'));
      final w32 = _read('windows/runner/win32_window.cpp');
      expect(w32, contains('wparam == SIZE_MINIMIZED'));
    });

    test('ultima immagine copiata prima di ridurre o nascondere e dipinta '
        'al ritorno al posto del fondo', () {
      final pre = handler.substring(0, plugins);
      final pos = pre.indexOf('case WM_WINDOWPOSCHANGING:');
      expect(pos, greaterThan(0));
      final posBlock = pre.substring(pos, pre.indexOf('break;', pos));
      expect(posBlock, contains('-32000'));
      expect(posBlock, contains('KeepLastFrame(hwnd)'));
      final show = pre.indexOf('case WM_SHOWWINDOW:');
      expect(
        pre.substring(show, pre.indexOf('break;', show)),
        contains('KeepLastFrame(hwnd)'),
      );
      final erase = pre.indexOf('case WM_ERASEBKGND:');
      expect(
        pre.substring(erase, pre.indexOf('break;', erase)),
        contains('PaintSnapshot'),
      );
      // copia dalla superficie della finestra, scartata se tutta nera, e
      // liberata finiti i frame forzati
      final capture = fw.substring(
        fw.indexOf('void FlutterWindow::CaptureSnapshot'),
      );
      expect(capture, contains('BitBlt(mdc, 0, 0, w, h, wdc'));
      expect(capture, contains('ok = any;'));
      final timer = pre.substring(pre.indexOf('wparam == kRedrawTimer'));
      expect(
        timer.substring(0, timer.indexOf('return 0;')),
        contains('DropSnapshot()'),
      );
    });

    test('seconda copia: aspetta quella che si sta chiudendo invece di '
        'passarle gli argomenti', () {
      expect(main, contains('WaitForClosingCopy(single_instance)'));
      final focus = main.substring(main.indexOf('bool FocusRunningWindow()'));
      expect(focus, contains('ClosingState(window) != 0'));
      // la copia unica si libera solo con finestra e motore già chiusi
      final loopEnd = main.indexOf('fine del ciclo dei messaggi');
      final scopeEnd = main.indexOf(RegExp(r'\r?\n  \}\r?\n'), loopEnd);
      final release = main.indexOf('CloseHandle(single_instance)', loopEnd);
      expect(scopeEnd, greaterThan(loopEnd));
      expect(release, greaterThan(scopeEnd));
      expect(main.substring(loopEnd, scopeEnd), contains('kClosingQuit'));
    });
  });
}
