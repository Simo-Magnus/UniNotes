import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/build_flags.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/app_uninstall.dart';
import 'package:university_notes/core/services/msix_paths.dart';
import 'package:university_notes/features/settings/erase_all.dart';
import 'package:university_notes/features/settings/logic/data_eraser.dart';
import 'package:university_notes/features/settings/uninstall_mode.dart';

/// Eliminazione finta: tutte le voci disponibili, ricorda le scelte.
class _FakeEraser extends DataEraser {
  _FakeEraser(super.s);
  Set<EraseItem>? erased;

  @override
  Future<List<EraseOption>> options() async => [
    for (final i in EraseItem.values) EraseOption(i, available: true),
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

/// Build per il Microsoft Store (`--dart-define=STORE=microsoft`): niente
/// aggiornamenti dell'app dal sito e niente disinstallatore da avviare.
void main() {
  const store = StoreRules('microsoft');
  const site = StoreRules('github');

  test('build senza STORE: canale del sito', () {
    expect(kMicrosoftStoreBuild, isFalse);
    expect(const StoreRules().store, 'github');
  });

  test('niente controllo né download di nuove versioni fuori dal sito', () {
    expect(store.selfUpdate, isFalse);
    expect(const StoreRules('play').selfUpdate, isFalse);
    expect(const StoreRules('appstore').selfUpdate, isFalse);
    expect(site.selfUpdate, isTrue);
  });

  test('niente disinstallatore di Inno Setup nello Store', () {
    expect(store.microsoftStore, isTrue);
    expect(store.windowsUninstaller, isFalse);
    expect(site.windowsUninstaller, isTrue);
  });

  test('--disinstalla si ignora nella build dello Store', () {
    const args = [kUninstallArg];
    expect(
      AppUninstall.handlesUninstallArg(args, kUninstallArg, rules: store),
      isFalse,
    );
    expect(
      AppUninstall.handlesUninstallArg(args, kUninstallArg, rules: site),
      isTrue,
    );
    expect(
      AppUninstall.handlesUninstallArg(const [], kUninstallArg, rules: site),
      isFalse,
    );
  });

  test('nello Store nessuna identità dell\'installazione', () async {
    expect(await AppUninstall.installIdentity(rules: store), isNull);
  });

  test('disinstallazione nello Store: si apre «App installate»', () async {
    final opened = <Uri>[];
    final r = await AppUninstall.windowsStore(
      open: (u) async {
        opened.add(u);
        return true;
      },
    );
    expect(r.started, isFalse);
    expect(r.message, contains('App installate'));
    expect(opened, [Uri.parse('ms-settings:appsfeatures')]);
    // anche se Impostazioni non si apre resta la spiegazione
    final failed = await AppUninstall.windowsStore(
      open: (_) async => throw Exception('no'),
    );
    expect(failed.message, AppUninstall.windowsStoreMessage);
  });

  group('«Disinstalla UniNotes» nello Store', () {
    late AppServices s;
    setUp(() async => s = AppServices(await AppDatabase.openInMemory()));
    tearDown(() => s.database.close());

    testWidgets('elimina i dati, poi spiega come togliere l\'app', (
      tester,
    ) async {
      final eraser = _FakeEraser(s);
      var quit = 0;
      final opened = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => runEraseFlow(
                context,
                mode: EraseFlowMode.uninstall,
                eraser: eraser,
                windowsStore: true,
                uninstall: () => AppUninstall.windowsStore(
                  open: (u) async {
                    opened.add(u);
                    return true;
                  },
                ),
                quit: () => quit++,
              ),
              child: const Text('apri'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('apri'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Elimina tutto'));
      await tester.pumpAndSettle();
      // cloud e calendario fra le voci, come nelle altre build
      expect(find.textContaining(EraseItem.onedrive.label), findsOneWidget);
      expect(
        find.textContaining('«App installate» di Windows'),
        findsOneWidget,
      );
      expect(find.textContaining('Poi UniNotes si disinstalla'), findsNothing);
      await tester.tap(find.text('Elimina e disinstalla'));
      await tester.pumpAndSettle();
      expect(eraser.erased, EraseItem.values.toSet());
      expect(opened, [AppUninstall.windowsAppsSettings]);
      expect(find.text('Dati eliminati'), findsOneWidget);
      expect(find.textContaining('Windows elimina'), findsOneWidget);
      expect(quit, 0);
      await tester.tap(find.text('Chiudi'));
      expect(quit, 1);
    });
  });

  group('percorsi del pacchetto MSIX', () {
    const family = 'Nome.UniNotes_abc123';
    const roaming = r'C:\Users\Studente\AppData\Roaming';
    const local = r'C:\Users\Studente\AppData\Local';
    const pkg =
        r'C:\Users\Studente\AppData\Local\Packages\Nome.UniNotes_abc123';

    String? map(String path, {Set<String> existing = const {}}) =>
        MsixPaths.mapPath(
          path,
          family: family,
          roaming: roaming,
          local: local,
          exists: existing.contains,
        );

    test('file creato dall\'app in AppData → cartella del pacchetto', () {
      const book =
          '$pkg\\LocalCache\\Roaming\\UniNotes\\UniNotes\\libri\\a.pdf';
      expect(
        map(
          r'C:\Users\Studente\AppData\Roaming\UniNotes\UniNotes\libri\a.pdf',
          existing: {book},
        ),
        book,
      );
      const temp = '$pkg\\LocalCache\\Local\\Temp\\UniNotes AI\\x.md';
      expect(
        map(
          r'C:\Users\Studente\AppData\Local\Temp\UniNotes AI\x.md',
          existing: {temp},
        ),
        temp,
      );
    });

    test('file non scritto nel pacchetto o fuori da AppData: invariato', () {
      // installazione precedente con UniNotes_setup.exe: file al suo posto
      expect(
        map(r'C:\Users\Studente\AppData\Roaming\UniNotes\UniNotes\a.pdf'),
        isNull,
      );
      expect(map(r'C:\Users\Studente\Documents\UniNotes\Corsi\a.m4a'), isNull);
      expect(map('$pkg\\LocalState\\a.txt', existing: {'x'}), isNull);
    });
  });
}
