import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/reader/reader_screen.dart';
import 'package:university_notes/features/reader/reader_store.dart';
import 'package:university_notes/features/reader/views/document_view.dart';
import 'package:university_notes/repositories/settings_repository.dart';
import 'package:university_notes/widgets/find_bar.dart';

import 'reader_fixtures.dart';

Future<void> _settle(WidgetTester t, [int n = 12]) async {
  for (var i = 0; i < n; i++) {
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 40)),
    );
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _key(
  WidgetTester t,
  LogicalKeyboardKey key, {
  bool control = false,
  bool shift = false,
}) async {
  if (control) await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(key);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  if (control) await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

void main() {
  late Directory tmp;
  late AppDatabase db;
  late ReaderStore store;

  Future<String> write(WidgetTester t, String name, List<int> bytes) async {
    final f = File(p.join(tmp.path, name));
    await t.runAsync(() => f.writeAsBytes(bytes));
    return f.path;
  }

  Future<void> open(
    WidgetTester t,
    String path, {
    Size size = const Size(1000, 800),
  }) async {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: ReaderScreen(key: ValueKey(path), path: path, store: store),
      ),
    );
    await _settle(t);
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('um_reader_ui_');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  testWidgets('Ctrl+F: contatore, successivo/precedente, senza accenti, Esc', (
    t,
  ) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final text = [
      'Perché studiare analisi?',
      for (var i = 0; i < 80; i++) 'Riga di riempimento $i.\n',
      'Ecco perche: il limite.',
      'PERCHÉ no.',
    ].join('\n');
    final path = await write(t, 'note.txt', utf8.encode(text));
    await open(t, path);
    expect(find.byType(DocumentView), findsOneWidget);
    expect(find.byType(FindBar), findsNothing);

    await _key(t, LogicalKeyboardKey.keyF, control: true);
    await t.pump();
    expect(find.byType(FindBar), findsOneWidget);

    await t.enterText(find.byType(TextField), 'perche');
    await t.pump();
    expect(find.text('1 di 3'), findsOneWidget);

    await t.testTextInput.receiveAction(TextInputAction.search);
    await t.pump();
    expect(find.text('2 di 3'), findsOneWidget);
    // L'ultimo risultato, in fondo al file, è stato portato in vista.
    await _settle(t, 3);
    expect(
      find.textContaining('Ecco perche', findRichText: true),
      findsOneWidget,
    );

    await _key(t, LogicalKeyboardKey.enter, shift: true);
    expect(find.text('1 di 3'), findsOneWidget);
    await _key(t, LogicalKeyboardKey.f3);
    expect(find.text('2 di 3'), findsOneWidget);
    await _key(t, LogicalKeyboardKey.f3, shift: true);
    await _key(t, LogicalKeyboardKey.f3, shift: true);
    expect(find.text('3 di 3'), findsOneWidget);

    await t.enterText(find.byType(TextField), 'nessuno');
    await t.pump();
    expect(find.text('Nessun risultato'), findsOneWidget);

    await _key(t, LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.byType(FindBar), findsNothing);

    // Il pulsante nella barra (telefono) apre la stessa ricerca.
    await t.tap(find.byTooltip('Trova nel testo (Ctrl+F)'));
    await t.pump();
    expect(find.byType(FindBar), findsOneWidget);
    await t.runAsync(db.close);
  });

  testWidgets('Word: indice dai titoli, pagine, segnalibri salvati', (t) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final path = await write(t, 'Relazione.docx', buildDocx());
    await open(t, path);
    expect(find.text('Pagina 1 di 2'), findsOneWidget);
    expect(
      find.textContaining('Introduzione', findRichText: true),
      findsWidgets,
    );

    await t.tap(find.byTooltip('Indice e segnalibri'));
    await t.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Introduzione'), findsOneWidget);
    await t.tap(find.text('Segnalibri'));
    await t.pumpAndSettle();
    await t.tap(find.text('Aggiungi segnalibro qui'));
    // il salvataggio è asincrono: si aspetta finché arriva (macchine lente)
    var saved = (await t.runAsync(() => store.load(path)))!;
    for (var i = 0; i < 50 && saved.bookmarks.isEmpty; i++) {
      await _settle(t, 1);
      saved = (await t.runAsync(() => store.load(path)))!;
    }
    expect(saved.bookmarks, hasLength(1));
    expect(saved.bookmarks.single.label, contains('Pagina 1'));
    // Aperto dal lettore: tra i recenti.
    final recent = (await t.runAsync(store.recent))!;
    expect(recent.single.path, path);
    await t.runAsync(db.close);
  });

  testWidgets('vai a pagina e posizione ricordata alla riapertura', (t) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final path = await write(t, 'slide.pptx', buildPptx());
    await open(t, path, size: const Size(1000, 300));
    expect(find.text('Diapositiva 1 di 2'), findsOneWidget);

    await _key(t, LogicalKeyboardKey.keyG, control: true);
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField).last, '2');
    await t.tap(find.text('Vai'));
    await _settle(t, 4);
    expect(find.text('Diapositiva 2 di 2'), findsOneWidget);

    // Chiudendo si salva subito la posizione.
    await t.pumpWidget(const SizedBox());
    await _settle(t, 4);
    final s = (await t.runAsync(() => store.load(path)))!;
    expect(s.position, greaterThan(0));

    await open(t, path, size: const Size(1000, 300));
    await _settle(t, 4);
    expect(find.text('Diapositiva 2 di 2'), findsOneWidget);
    await t.runAsync(db.close);
  });

  testWidgets('foglio di calcolo: schede dei fogli, zoom del testo', (t) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final path = await write(t, 'voti.xlsx', buildXlsx());
    await open(t, path);
    expect(find.widgetWithText(ChoiceChip, 'Voti'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'Note'), findsOneWidget);
    expect(find.text('Foglio 1 di 2'), findsOneWidget);

    double sizeOf(String s) {
      final rich = t.widget<RichText>(
        find
            .byWidgetPredicate(
              (w) => w is RichText && w.text.toPlainText() == s,
            )
            .first,
      );
      double? size;
      rich.text.visitChildren((span) {
        if (span is TextSpan && span.text == s) {
          size = span.style?.fontSize;
          return false;
        }
        return true;
      });
      return size!;
    }

    final before = sizeOf('Analisi');
    await _key(t, LogicalKeyboardKey.equal, control: true);
    await t.pump();
    expect(sizeOf('Analisi'), greaterThan(before));
    await _key(t, LogicalKeyboardKey.digit0, control: true);
    await t.pump();
    expect(sizeOf('Analisi'), before);
    await t.runAsync(db.close);
  });

  testWidgets('CSV largo: tabella con scorrimento orizzontale', (t) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final header = [for (var i = 0; i < 30; i++) 'Colonna numero $i'].join(';');
    final row = [for (var i = 0; i < 30; i++) 'valore $i'].join(';');
    final path = await write(t, 'largo.csv', utf8.encode('$header\n$row\n'));
    await open(t, path, size: const Size(600, 800));
    expect(t.takeException(), isNull);
    expect(find.textContaining('Colonna numero 0', findRichText: true), findsOneWidget);
    await t.drag(find.textContaining('valore 1', findRichText: true).first, const Offset(-400, 0));
    await t.pump();
    expect(t.takeException(), isNull);
    await t.runAsync(db.close);
  });

  testWidgets('formato non mostrabile: informazioni, Apri con, Condividi', (
    t,
  ) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final path = await write(t, 'scansione.djvu', ascii.encode('AT&TFORM'));
    await open(t, path, size: const Size(420, 800));
    expect(find.textContaining('DjVu'), findsWidgets);
    expect(find.text('Apri con l\'app predefinita'), findsOneWidget);
    expect(find.text('Condividi'), findsOneWidget);
    expect(find.byTooltip('Trova nel testo (Ctrl+F)'), findsNothing);
    await t.runAsync(db.close);
  });

  testWidgets('registrazione con trascrizione: cerca nella trascrizione', (
    t,
  ) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    await write(
      t,
      'lezione.srt',
      utf8.encode(
        '1\n00:00:05,000 --> 00:00:07,000\nIl teorema di Lagrange\n\n2\n00:01:00,000 --> 00:01:02,000\nE poi Rolle\n',
      ),
    );
    final path = await write(t, 'lezione.mp3', [
      ...ascii.encode('ID3'),
      3,
      0,
      0,
      0,
      0,
      0,
      0,
    ]);
    await open(t, path);
    expect(
      find.text('Riproduzione non disponibile in questo ambiente.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Trascrizione', findRichText: true),
      findsWidgets,
    );
    expect(find.textContaining('0:05', findRichText: true), findsOneWidget);
    await _key(t, LogicalKeyboardKey.keyF, control: true);
    await t.pump();
    await t.enterText(find.byType(TextField), 'rolle');
    await t.pump();
    expect(find.text('1 di 1'), findsOneWidget);
    await t.runAsync(db.close);
  });

  testWidgets('appunti Xournal++ e mappa mentale: ricerca nei testi', (
    t,
  ) async {
    db = (await t.runAsync(AppDatabase.openInMemory))!;
    store = ReaderStore(SettingsRepository(db));
    final xopp = await write(t, 'appunti.xopp', buildXopp());
    await open(t, xopp);
    expect(find.text('Pagina 1 di 2'), findsOneWidget);
    await _key(t, LogicalKeyboardKey.keyF, control: true);
    await t.pump();
    await t.enterText(find.byType(TextField), 'derivata');
    await t.pump();
    expect(find.text('1 di 1'), findsOneWidget);

    final mm = await write(
      t,
      'mappa.mm',
      utf8.encode(
        '<map><node TEXT="Fisica"><node TEXT="Meccanica"><node TEXT="Cinematica"/></node></node></map>',
      ),
    );
    await open(t, mm);
    expect(find.text('Cinematica'), findsOneWidget);
    await t.tap(find.byTooltip('Comprimi').first);
    await t.pump();
    expect(find.text('Cinematica'), findsNothing);
    await _key(t, LogicalKeyboardKey.keyF, control: true);
    await t.pump();
    await t.enterText(find.byType(TextField), 'cinematica');
    await _settle(t, 3);
    expect(find.text('1 di 1'), findsOneWidget);
    expect(find.text('Cinematica'), findsOneWidget);
    await t.runAsync(db.close);
  });

  testWidgets('FindShortcuts: F3 senza ricerca aperta apre la ricerca', (
    t,
  ) async {
    var opened = 0;
    await t.pumpWidget(
      MaterialApp(
        home: FindShortcuts(
          onFind: () => opened++,
          onClose: () {},
          child: const SizedBox(),
        ),
      ),
    );
    await _key(t, LogicalKeyboardKey.f3);
    await _key(t, LogicalKeyboardKey.keyF, control: true);
    expect(opened, 2);
  });
}
