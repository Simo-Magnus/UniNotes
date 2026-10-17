import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show ConflictAlgorithm;
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/links/links_screen.dart';
import 'package:university_notes/features/links/microsoft_consent_sheet.dart';
import 'package:university_notes/features/settings/settings_screen.dart';

Future<(AppServices, Directory)> _services() async {
  final db = await AppDatabase.openInMemory();
  await db.db.insert('universities', {
    'id': 'polito',
    'name': 'Politecnico di Torino',
    'short_name': 'PoliTo',
    'color': 0xFF1565C0,
  }, conflictAlgorithm: ConflictAlgorithm.replace);
  final tmp = await Directory.systemTemp.createTemp('links_screen_');
  final s = AppServices(
    db,
    whisper: WhisperService(
      baseDir: () async => tmp,
      host: WhisperHost.windows,
      processRunner: (exe, _) async => throw ProcessException(exe, const []),
    ),
  );
  return (s, tmp);
}

Future<void> _pump(
  WidgetTester tester,
  Widget home,
  AppServices s,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Provider<AppServices>.value(
      value: s,
      child: MaterialApp(theme: AppTheme.dark(), home: home),
    ),
  );
  await _settle(tester);
}

/// Le letture (SQLite, file) avvengono fuori dal tempo finto: si alternano
/// attese reali e ridisegni finché i caricamenti a catena sono finiti.
Future<void> _settle(WidgetTester tester, [int rounds = 120]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('Collegamenti: tutte le card, una sola azione arancione', (
    tester,
  ) async {
    final (s, tmp) = (await tester.runAsync(_services))!;
    await _pump(tester, const LinksScreen(), s, const Size(1300, 6000));
    for (final title in [
      'Gemini',
      'Whisper',
      'AI di riferimento',
      'OneDrive',
      'Google Drive',
    ]) {
      // «Gemini» è anche tra le AI di riferimento
      expect(find.text(title), findsWidgets, reason: title);
    }
    // Niente più community, Claude Desktop né chiavi API di Gemini.
    expect(find.text('Gruppi e canali del corso'), findsNothing);
    expect(find.textContaining('Claude Desktop'), findsNothing);
    // Google Drive: accesso con Google (spento se la build non ha l'ID).
    expect(find.text('Accedi con Google'), findsOneWidget);
    // Tabella dei modelli: chiusa (a tendina), si apre con un tocco.
    expect(find.text('large-v3-turbo-q5_0'), findsNothing);
    await tester.tap(find.byKey(const Key('whisper-models')));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('large-v3-turbo-q5_0'), findsOneWidget);
    expect(find.text('consigliato'), findsOneWidget);
    expect(find.text('Scarica'), findsWidgets);
    expect(find.text('Pagina ufficiale del modello'), findsWidgets);
    // Gemini con l'account universitario: passi guidati.
    expect(find.text('Apri Gemini'), findsOneWidget);
    // Le AI di riferimento.
    for (final ai in [
      'ChatGPT',
      'Claude',
      'Microsoft Copilot',
      'Perplexity',
      'NotebookLM',
    ]) {
      expect(find.widgetWithText(ChoiceChip, ai), findsOneWidget, reason: ai);
    }
    // Caselle della sincronizzazione (OneDrive e Google Drive).
    expect(find.text('Registrazioni delle lezioni'), findsNWidgets(2));
    // Una sola azione principale (arancione): collegare OneDrive.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Accedi con Microsoft'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await s.database.close();
      await tmp.delete(recursive: true);
    });
  });

  testWidgets('OneDrive: link per l\'account universitario bloccato', (
    tester,
  ) async {
    final (s, tmp) = (await tester.runAsync(_services))!;
    await _pump(tester, const LinksScreen(), s, const Size(1300, 6000));
    // non collegato: il link c'è sempre (anche dopo un accesso interrotto)
    expect(find.text(kUniversityAccountHelp), findsOneWidget);
    await tester.tap(find.text(kUniversityAccountHelp));
    await _settle(tester, 20);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Il tuo ateneo deve approvare UniNotes'), findsOneWidget);
    expect(find.text('Usa un account Microsoft personale'), findsOneWidget);
    await tester.tap(find.byKey(const Key('consent-ask')));
    await _settle(tester, 20);
    await tester.pump(const Duration(seconds: 1));
    final text = tester
        .widget<SelectableText>(find.byKey(const Key('consent-request-text')))
        .data!;
    expect(text, contains(s.onedrive.builtInClientId));
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await s.database.close();
      await tmp.delete(recursive: true);
    });
  });

  testWidgets('Collegamenti sul telefono: nessun overflow', (tester) async {
    final (s, tmp) = (await tester.runAsync(_services))!;
    await _pump(tester, const LinksScreen(), s, const Size(390, 9000));
    expect(find.text('OneDrive'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.runAsync(() async {
      await s.database.close();
      await tmp.delete(recursive: true);
    });
  });

  testWidgets('Impostazioni senza AI e OneDrive (spostate)', (tester) async {
    final (s, tmp) = (await tester.runAsync(_services))!;
    await _pump(tester, const SettingsScreen(), s, const Size(1400, 2400));
    expect(find.text('Intelligenza artificiale'), findsNothing);
    expect(find.text('OneDrive e OneNote'), findsNothing);
    expect(find.text('Esporta/importa dati'), findsOneWidget);
    await tester.runAsync(() async {
      await s.database.close();
      await tmp.delete(recursive: true);
    });
  });
}
