import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/links/ai_assistants.dart';
import 'package:university_notes/features/links/link_settings.dart';
import 'package:university_notes/features/notes/ai_prompts.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/repositories/settings_repository.dart';

void main() {
  const course = Course(name: 'Analisi matematica I', cfu: 10);

  test('tutte le AI richieste, con sito, pacchetto e App Store', () {
    expect(
      ReferenceAi.values.map((a) => a.label),
      containsAll([
        'ChatGPT',
        'Claude',
        'Microsoft Copilot',
        'Perplexity',
        'NotebookLM',
        'Gemini',
      ]),
    );
    final hosts = {for (final a in ReferenceAi.values) a: a.webUri.host};
    expect(hosts[ReferenceAi.chatgpt], 'chatgpt.com');
    expect(hosts[ReferenceAi.claude], 'claude.ai');
    expect(hosts[ReferenceAi.copilot], 'copilot.microsoft.com');
    expect(hosts[ReferenceAi.perplexity], 'www.perplexity.ai');
    expect(hosts[ReferenceAi.notebooklm], 'notebooklm.google.com');
    expect(hosts[ReferenceAi.gemini], 'gemini.google.com');
    for (final a in ReferenceAi.values) {
      expect(a.webUri.scheme, 'https');
      expect(a.playStoreUri.queryParameters['id'], a.androidPackage);
      expect(
        a.appStoreUri.toString(),
        startsWith('https://apps.apple.com/app/id'),
      );
    }
    expect(ReferenceAi.parse('perplexity'), ReferenceAi.perplexity);
    expect(ReferenceAi.parse(null), ReferenceAi.defaultAi);
  });

  test('testo precompilato solo dove documentato e solo se corto', () {
    expect(
      ReferenceAi.chatgpt.prefillUri('Ciao mondo').toString(),
      'https://chatgpt.com/?q=Ciao+mondo',
    );
    expect(
      ReferenceAi.claude.prefillUri('Domande').toString(),
      'https://claude.ai/new?q=Domande',
    );
    expect(
      ReferenceAi.perplexity.prefillUri('limiti').toString(),
      'https://www.perplexity.ai/search?q=limiti',
    );
    expect(ReferenceAi.copilot.prefillUri('x'), isNull);
    expect(ReferenceAi.notebooklm.prefillUri('x'), isNull);
    expect(ReferenceAi.gemini.prefillUri('x'), isNull);
    expect(ReferenceAi.chatgpt.prefillUri('à' * 2000), isNull);
  });

  test('richieste pronte per ogni AI e ogni compito', () {
    for (final ai in ReferenceAi.values) {
      for (final t in AiTask.values) {
        final p = t.prompt(course, ai, files: ['Appunti.md', 'Libro.pdf']);
        expect(p, contains('Analisi matematica I'), reason: '$ai $t');
        expect(p, contains('10 CFU'));
        expect(p, contains('- Appunti.md'));
        expect(p, contains('- Libro.pdf'));
        expect(p, contains('italiano'));
        expect(p, contains('non presente nel materiale'));
        expect(p, contains('# Compito'));
        expect(p, contains('# Formato della risposta'));
      }
    }
    expect(
      AiTask.flashcards.prompt(course, ReferenceAi.chatgpt),
      contains('Anki'),
    );
    expect(
      AiTask.summary.prompt(course, ReferenceAi.notebooklm, files: ['a.md']),
      contains('fonti'),
    );
    expect(
      AiTask.review.prompt(course, ReferenceAi.perplexity),
      contains('Non cercare sul web'),
    );
    expect(
      AiTask.review.prompt(course, ReferenceAi.claude),
      isNot(contains('Non cercare sul web')),
    );
    expect(
      AiTask.plan.prompt(
        course,
        ReferenceAi.gemini,
        examDate: DateTime(2027, 1, 20),
        today: DateTime(2027, 1, 10),
      ),
      allOf(contains('20/01/2027'), contains('tra 10 giorni')),
    );
    expect(AiTask.flashcards.description, 'Domande e risposte brevi da ripassare');
    expect(manualTranscriptionPrompt('Fisica'), contains('[hh:mm:ss]'));
    expect(
      manualTranscriptionPrompt('Fisica', notebook: true),
      startsWith('Usa come fonte'),
    );
  });

  test('AI di riferimento salvata nelle impostazioni', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final s = SettingsRepository(db);
    expect(await s.referenceAi(), ReferenceAi.chatgpt);
    await s.setReferenceAi(ReferenceAi.notebooklm);
    expect(await s.referenceAi(), ReferenceAi.notebooklm);
  });
}
