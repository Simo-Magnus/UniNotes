import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:record/record.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/lecture_recorder.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/background_controls.dart';
import 'package:university_notes/features/notes/recorder/recording_overlay.dart';
import 'package:university_notes/repositories/settings_repository.dart';

class _FakeRecorder implements AudioRecorder {
  final pcm = StreamController<Uint8List>.broadcast();
  bool paused = false;

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
  Future<void> pause() async => paused = true;
  @override
  Future<void> resume() async => paused = false;
  @override
  Future<String?> stop() async => null;
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Notifica finta: registra ciò che mostrerebbe e preme i pulsanti come
/// farebbe l'utente.
class _FakeControls implements BackgroundControls {
  void Function(RecorderCommand c)? _onCommand;
  bool shown = false;
  bool paused = false;
  int updates = 0;

  @override
  set onCommand(void Function(RecorderCommand c)? f) => _onCommand = f;

  /// Pulsante della notifica premuto (id come quelli della notifica).
  void press(String id) => _onCommand?.call(recorderCommandFor(id)!);

  /// Testi che la notifica mostra ora.
  RecordingNotificationContent get content =>
      recordingNotificationContent(course: 'Analisi', paused: paused);

  @override
  Future<String?> start({
    required String course,
    required Duration elapsed,
    required bool paused,
  }) async {
    shown = true;
    this.paused = paused;
    return null;
  }

  @override
  Future<void> update({required Duration elapsed, required bool paused}) async {
    updates++;
    this.paused = paused;
  }

  @override
  Future<void> stop() async => shown = false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('testi della notifica: «Pausa» mentre registra, «Riprendi» in '
      'pausa, «Salva» sempre', () {
    final rec = recordingNotificationContent(course: 'Fisica', paused: false);
    expect(rec.title, 'Registrazione in corso');
    expect(rec.course, 'Fisica');
    expect(rec.primaryText, 'Pausa');
    expect(rec.primaryId, btnPause);
    expect(rec.buttons.map((b) => b.text), ['Pausa', 'Salva']);
    expect(rec.buttons.map((b) => b.id), [btnPause, btnSave]);

    final paused = recordingNotificationContent(course: 'Fisica', paused: true);
    expect(paused.title, 'Registrazione in pausa');
    expect(paused.primaryText, 'Riprendi');
    expect(paused.primaryId, btnResume);
    expect(paused.buttons.map((b) => b.text), ['Riprendi', 'Salva']);
  });

  test('pulsanti → comandi del registratore', () {
    expect(recorderCommandFor(btnPause), RecorderCommand.pause);
    expect(recorderCommandFor(btnResume), RecorderCommand.resume);
    expect(recorderCommandFor(btnSave), RecorderCommand.save);
    expect(recorderCommandFor('apri'), RecorderCommand.open);
    expect(recorderCommandFor('pronto'), isNull);
    expect(recorderCommandFor(null), isNull);
  });

  test('i pulsanti della notifica nativa arrivano al registratore', () async {
    final n = AndroidRecordingNotification();
    final got = <RecorderCommand>[];
    n.onCommand = got.add;
    const codec = StandardMethodCodec();
    Future<void> press(String id) => TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          'io.github.simomagnus.universitynotes/registrazione',
          codec.encodeMethodCall(MethodCall('command', id)),
          (_) {},
        );
    await press(btnPause);
    await press(btnResume);
    await press(btnSave);
    // notifica tolta dalla tendina a registratore fermo: nessun comando
    await press('nascosta');
    expect(got, [
      RecorderCommand.pause,
      RecorderCommand.resume,
      RecorderCommand.save,
    ]);
  });

  testWidgets('notifica: Pausa, Riprendi e Salva (con il nome predefinito, '
      'senza domande) e la notifica sparisce', (t) async {
    late Directory tmp;
    late AppServices s;
    final fake = _FakeRecorder();
    final controls = _FakeControls();
    await t.runAsync(() async {
      tmp = await Directory.systemTemp.createTemp('un_notif_');
      final db = await AppDatabase.openInMemory();
      final store = NotesStore(
        SettingsRepository(db),
        root: () async => Directory(p.join(tmp.path, 'Appunti')),
      );
      s = AppServices(
        db,
        notes: store,
        recorder: LectureRecorder(
          recorder: () => fake,
          workDir: () async => Directory(p.join(tmp.path, 'lavoro')),
          controls: () => controls,
        ),
      );
    });
    addTearDown(() async {
      await t.runAsync(() async {
        await s.database.close();
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
    });
    await t.pumpWidget(
      Provider<AppServices>.value(
        value: s,
        child: MaterialApp(
          navigatorKey: appNavigatorKey,
          builder: (context, child) => RecordingOverlayHost(child: child!),
          home: const Scaffold(body: Text('Home')),
        ),
      ),
    );
    final dir = p.join(tmp.path, 'Appunti', 'Analisi', 'Registrazioni');
    await t.runAsync(() async {
      await s.recorder.start(
        p.join(dir, '2026-10-21 09-00 Lezione.m4a'),
        course: 'Analisi',
      );
      fake.pcm.add(Uint8List(32000));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await t.pump();
    expect(controls.shown, isTrue);
    expect(controls.content.primaryText, 'Pausa');

    // «Pausa» dalla notifica: il registratore si ferma, il pulsante diventa
    // «Riprendi»
    Future<void> pressAndWait(String id, int updates) => t.runAsync(() async {
      controls.press(id);
      // l'aggiornamento della notifica arriva dopo il salvataggio del WAV
      for (var i = 0; i < 100 && controls.updates < updates; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await pressAndWait(controls.content.primaryId, 1);
    expect(s.recorder.paused, isTrue);
    expect(fake.paused, isTrue);
    expect(controls.content.primaryText, 'Riprendi');
    expect(controls.content.title, 'Registrazione in pausa');

    // «Riprendi»
    await pressAndWait(controls.content.primaryId, 2);
    expect(s.recorder.paused, isFalse);
    expect(controls.content.primaryText, 'Pausa');
    expect(controls.updates, 2);

    // «Salva»: stesso salvataggio del pulsante dell'app, senza dialoghi
    controls.press(btnSave);
    for (var i = 0; i < 100 && (s.recorder.active || s.recorder.saving); i++) {
      await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await t.pump();
    }
    expect(s.recorder.active, isFalse);
    expect(controls.shown, isFalse, reason: 'la notifica sparisce');
    expect(find.byType(AlertDialog), findsNothing);
    final saved = await t.runAsync(
      () async => Directory(dir).list().map((e) => p.basename(e.path)).toList(),
    );
    // nei test la compressione non c'è: resta il WAV, con il nome previsto
    expect(saved, contains('2026-10-21 09-00 Lezione.wav'));
    await t.pump(const Duration(seconds: 5));
  });
}
