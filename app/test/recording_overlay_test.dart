import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'package:university_notes/features/notes/recycle_bin.dart';
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

void main() {
  testWidgets(
    'riquadro sopra le schermate: pausa, X → «Salvare?», Elimina con conferma',
    (t) async {
      t.view.physicalSize = const Size(420, 860);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      late Directory tmp;
      late AppServices s;
      final fake = _FakeRecorder();
      await t.runAsync(() async {
        tmp = await Directory.systemTemp.createTemp('un_overlay_');
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
            controls: () => const NoBackgroundControls(),
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
            home: const Scaffold(body: Center(child: Text('Home'))),
          ),
        ),
      );
      await t.pump();
      expect(find.text('Analisi matematica I'), findsNothing);

      final target = p.join(
        tmp.path,
        'Appunti',
        'Analisi',
        'Registrazioni',
        '2026-10-12 08-30 Lezione.m4a',
      );
      await t.runAsync(() async {
        await s.recorder.start(target, course: 'Analisi matematica I');
        fake.pcm.add(Uint8List(32000));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await t.pump();
      // registratore chiuso: il riquadro c'è, sopra la schermata
      expect(find.text('Analisi matematica I'), findsOneWidget);
      expect(find.text('00:00:01'), findsOneWidget);
      expect(find.text('Home'), findsOneWidget);

      // il registratore aperto nasconde il riquadro
      s.recorder.screenVisible = true;
      await t.pump();
      expect(find.text('Analisi matematica I'), findsNothing);
      s.recorder.screenVisible = false;
      await t.pump();

      // Uscendo dal registratore (la pagina si chiude a metà fotogramma) il
      // riquadro compare subito, senza bisogno di un altro tocco.
      appNavigatorKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => _RecorderLike(s.recorder)),
      );
      await t.pump(const Duration(milliseconds: 400));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.text('Analisi matematica I'), findsNothing);
      appNavigatorKey.currentState!.pop();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 200));
      }
      expect(s.recorder.screenVisible, isFalse);
      expect(find.text('Analisi matematica I'), findsOneWidget);
      // il riquadro si ridimensiona dalla maniglia, non sotto il minimo
      expect(find.bySemanticsLabel('Ridimensiona il riquadro'), findsOneWidget);

      // Pausa dal riquadro
      await t.runAsync(() async {
        await t.tap(find.bySemanticsLabel('Metti in pausa'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await t.pump();
      expect(fake.paused, isTrue);
      expect(find.text('00:00:01 · In pausa'), findsOneWidget);

      // X → due soli pulsanti (Elimina, Salva); toccando fuori la
      // registrazione continua
      await t.tap(
        find.bySemanticsLabel('Chiudi: salva o elimina la registrazione'),
      );
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Salvare la registrazione?'), findsOneWidget);
      expect(find.text('Annulla'), findsNothing);
      await t.tapAt(const Offset(10, 10));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('Salvare la registrazione?'), findsNothing);
      expect(s.recorder.active, isTrue);

      // X → Elimina → conferma chiara → nel cestino
      await t.tap(
        find.bySemanticsLabel('Chiudi: salva o elimina la registrazione'),
      );
      await t.pump(const Duration(milliseconds: 300));
      await t.tap(find.byKey(const Key('recording-delete')));
      // la conferma legge «Non chiedere più» dalle impostazioni (database)
      for (var i = 0; i < 20; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await t.pump(const Duration(milliseconds: 50));
        if (find.text('Eliminare la registrazione?').evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.text('Eliminare la registrazione?'), findsOneWidget);
      // due pulsanti più la casella «Non chiedere più»
      expect(find.text('Non chiedere più'), findsOneWidget);
      await t.tap(find.byKey(const Key('recording-delete-dont-ask')));
      await t.pump();
      await t.tap(find.byKey(const Key('recording-delete-confirm')));
      // fermata e spostamento nel cestino (file veri: tempo reale)
      var trashed = const <TrashEntry>[];
      for (var i = 0; i < 100 && trashed.isEmpty; i++) {
        await t.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await t.pump();
        if (!s.recorder.active && !s.recorder.saving) {
          trashed = (await t.runAsync(s.trash.list))!;
        }
      }
      expect(s.recorder.active, isFalse);
      expect(find.text('Analisi matematica I'), findsNothing);
      expect(trashed.single.title, '2026-10-12 08-30 Lezione');
      expect(trashed.single.isAudio, isTrue);
      // la prossima volta non si chiede più (si ripristina dalle
      // Impostazioni: chiavi «dont_ask_»)
      expect(
        await t.runAsync(() => s.settings.get(kDontAskDeleteRecordingKey)),
        '1',
      );
      await t.pump(const Duration(seconds: 5));
    },
  );
}

/// Pagina come il registratore: aperta nasconde il riquadro, chiudendosi
/// (dispose) lo rimette.
class _RecorderLike extends StatefulWidget {
  const _RecorderLike(this.rec);
  final LectureRecorder rec;

  @override
  State<_RecorderLike> createState() => _RecorderLikeState();
}

class _RecorderLikeState extends State<_RecorderLike> {
  @override
  void initState() {
    super.initState();
    widget.rec.screenVisible = true;
  }

  @override
  void dispose() {
    widget.rec.screenVisible = false;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Text('Registratore'));
}
