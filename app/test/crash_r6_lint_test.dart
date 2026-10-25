// Sesto giro della caccia ai crash: casi trovati con le regole di analisi
// più severe (analysis_options.yaml, «Sesto giro: regole di analisi» in
// docs/avvio_ed_errori.md).
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/reminders/reminders_service.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/desktop_window.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/recorder/recording_session.dart';

import 'support/fake_reminders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(sqfliteFfiInit);

  group('finestra del PC e area di notifica (discarded_futures)', () {
    const tray = MethodChannel('tray_manager');
    const window = MethodChannel('window_manager');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() {
      messenger.setMockMethodCallHandler(tray, null);
      messenger.setMockMethodCallHandler(window, null);
    });

    test('l\'icona che non si toglie non impedisce di riaprire la finestra '
        'durante una registrazione', () async {
      final windowCalls = <String>[];
      messenger.setMockMethodCallHandler(tray, (call) async {
        // area di notifica del sistema bloccata: l'icona non si toglie
        if (call.method == 'destroy') {
          throw PlatformException(code: 'tray', message: 'icona bloccata');
        }
        return null;
      });
      messenger.setMockMethodCallHandler(window, (call) async {
        windowCalls.add(call.method);
        return call.method == 'isMinimized' ? false : null;
      });
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final recorder = LectureRecorder()..phase = RecorderPhase.recording;
      final s = AppServices(
        db,
        recorder: recorder,
        reminders: (s) => RemindersService(
          s,
          platform: FakeNotificationPlatform(),
          calendarBackend: FakeCalendarBackend(),
          widgets: FakeHomeWidgets(),
          platformName: 'windows',
          isRecording: () => true,
        ),
      );
      final dw = DesktopWindow(s);
      // X della finestra con la registrazione in corso: icona nell'area di
      // notifica e finestra nascosta
      await dw.onWindowClose();
      expect(windowCalls, contains('hide'));
      windowCalls.clear();
      // tocco sull'icona: prima l'errore di «destroy» fermava tutto prima
      // di «show» (errore non gestito e finestra nascosta per sempre)
      final errors = <Object>[];
      await runZonedGuarded(() async {
        dw.onTrayIconMouseDown();
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }, (e, _) => errors.add(e));
      expect(errors, isEmpty);
      expect(windowCalls, containsAllInOrder(['show', 'focus']));
    });

    test('«Salva la registrazione» dall\'icona che non riesce lo dice con '
        'una notifica (finestra nascosta)', () async {
      messenger.setMockMethodCallHandler(tray, (call) async => null);
      messenger.setMockMethodCallHandler(
        window,
        (call) async => call.method == 'isMinimized' ? false : null,
      );
      final db = await AppDatabase.openInMemory();
      addTearDown(db.close);
      final platform = FakeNotificationPlatform();
      final s = AppServices(
        db,
        recorder: _FailingRecorder()..phase = RecorderPhase.recording,
        reminders: (s) => RemindersService(
          s,
          platform: platform,
          calendarBackend: FakeCalendarBackend(),
          widgets: FakeHomeWidgets(),
          platformName: 'windows',
          isRecording: () => true,
        ),
      );
      final dw = DesktopWindow(s);
      await dw.onWindowClose();
      platform.shown.clear();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        dw.onTrayMenuItemClick(MenuItem(key: 'save'));
        for (var i = 0; i < 10; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      }, (e, _) => errors.add(e));
      // prima: errore non gestito e nessun avviso
      expect(errors, isEmpty);
      expect(platform.shown.map((n) => n.title), ['Registrazione non salvata']);
    });
  });
}

/// Registratore il cui arresto non riesce (disco pieno).
class _FailingRecorder extends LectureRecorder {
  @override
  Future<RecordingTake?> stop() async =>
      throw const FileSystemException('Spazio esaurito sul disco');
}
