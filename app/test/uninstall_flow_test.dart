import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/app_uninstall.dart';
import 'package:university_notes/features/settings/erase_all.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';

/// Eliminazione finta: elenco fisso, ricorda le voci ricevute.
class _FakeEraser extends DataEraser {
  _FakeEraser(super.s);
  Set<EraseItem>? erased;

  @override
  Future<List<EraseOption>> options() async => [
    for (final i in EraseItem.values)
      EraseOption(
        i,
        available: i != EraseItem.onenote && i != EraseItem.googleDrive,
        bytes: i == EraseItem.whisper ? 150 * 1024 * 1024 : null,
      ),
  ];

  @override
  Future<EraseReport> run(
    Set<EraseItem> items, {
    void Function(String step)? onStep,
  }) async {
    erased = items;
    return EraseReport();
  }
}

void main() {
  late AppServices s;
  late _FakeEraser eraser;
  var quit = 0;
  var uninstalls = 0;

  setUp(() async {
    s = AppServices(await AppDatabase.openInMemory());
    eraser = _FakeEraser(s);
    quit = 0;
    uninstalls = 0;
  });
  tearDown(() => s.database.close());

  Future<void> start(WidgetTester tester, EraseFlowMode mode) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => runEraseFlow(
              context,
              mode: mode,
              eraser: eraser,
              uninstall: () async {
                uninstalls++;
                return const UninstallResult.started();
              },
              quit: () => quit++,
            ),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('apri'));
    await tester.pumpAndSettle();
  }

  /// Pulsanti del dialogo aperto (mai più di due).
  int dialogButtons() =>
      find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.byWidgetPredicate(
              (w) => w is TextButton || w is FilledButton,
            ),
          )
          .evaluate()
          .length;

  testWidgets('Elimina tutto → conferma → disinstallazione', (tester) async {
    await start(tester, EraseFlowMode.uninstall);
    expect(find.text('Disinstalla UniNotes'), findsOneWidget);
    expect(dialogButtons(), 2);
    await tester.tap(find.text('Elimina tutto'));
    await tester.pumpAndSettle();
    expect(find.text('Confermi?'), findsOneWidget);
    expect(find.textContaining('Poi UniNotes si disinstalla'), findsOneWidget);
    expect(dialogButtons(), 2);
    await tester.tap(find.text('Elimina e disinstalla'));
    await tester.pumpAndSettle();
    expect(eraser.erased, isNot(contains(EraseItem.onenote)));
    expect(eraser.erased, contains(EraseItem.onedrive));
    expect(eraser.erased!.length, EraseItem.values.length - 2);
    expect(uninstalls, 1);
    expect(quit, 1);
  });

  testWidgets('Scegli cosa eliminare → solo alcune voci → tieni l\'app', (
    tester,
  ) async {
    await start(tester, EraseFlowMode.uninstall);
    await tester.tap(find.text('Scegli cosa eliminare'));
    await tester.pumpAndSettle();
    expect(find.byType(CheckboxListTile), findsNWidgets(EraseItem.values.length));
    expect(dialogButtons(), 2);
    // OneNote non ha niente da eliminare: spenta
    final onenote = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('erase-onenote')),
    );
    expect(onenote.onChanged, isNull);
    expect(find.textContaining('150,0 MB'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('erase-whisper')));
    await tester.tap(find.byKey(const ValueKey('erase-whisper')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina e disinstalla'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Modelli di Whisper (150,0 MB)'), findsOneWidget);
    await tester.tap(find.text('Elimina e disinstalla'));
    await tester.pumpAndSettle();
    expect(eraser.erased, {EraseItem.whisper});
    // scelta parziale: disinstallare comunque o tenere l'app
    expect(find.text('Disinstallare UniNotes?'), findsOneWidget);
    expect(dialogButtons(), 2);
    await tester.tap(find.text('Tieni l\'app'));
    await tester.pumpAndSettle();
    expect(uninstalls, 0);
    expect(find.text('Dati eliminati'), findsOneWidget);
    await tester.tap(find.text('Chiudi'));
    expect(quit, 1);
  });

  testWidgets('Elimina tutti i dati: nessuna disinstallazione', (tester) async {
    await start(tester, EraseFlowMode.eraseOnly);
    await tester.tap(find.text('Elimina tutto'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Elimina'));
    await tester.pumpAndSettle();
    expect(eraser.erased, isNotNull);
    expect(uninstalls, 0);
    expect(find.text('Dati eliminati'), findsOneWidget);
  });

  testWidgets('disinstallatore di Windows: chiudendo restano i dati', (
    tester,
  ) async {
    await start(tester, EraseFlowMode.windowsUninstaller);
    expect(find.textContaining('si sta disinstallando'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5)); // fuori dal dialogo
    await tester.pumpAndSettle();
    expect(eraser.erased, isNull);
    expect(quit, 1);
    expect(uninstalls, 0);
  });

  test('dimensioni leggibili', () {
    expect(formatBytes(0), '0 KB');
    expect(formatBytes(1500), '2 KB');
    expect(formatBytes(3 * 1024 * 1024 + 400 * 1024), '3,4 MB');
    expect(formatBytes(1288490189), '1,2 GB');
  });
}
