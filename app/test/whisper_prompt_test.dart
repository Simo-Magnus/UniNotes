import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/services/whisper_service.dart';
import 'package:university_notes/features/notes/recorder/course_vocabulary.dart';
import 'package:university_notes/models/study.dart';

void main() {
  group('vocabolario del corso per Whisper', () {
    test('modulo in corso prima, poi gli altri; argomenti in corso prima', () {
      const mods = [
        StudyModule(id: 1, courseId: 7, name: 'Limiti', sort: 0),
        StudyModule(
          id: 2,
          courseId: 7,
          name: 'Equazioni differenziali',
          sort: 1,
        ),
        StudyModule(id: 3, courseId: 7, name: 'Serie', sort: 2),
      ];
      const topics = [
        Topic(
          id: 10,
          moduleId: 1,
          name: 'Limiti notevoli',
          status: TopicStatus.completed,
        ),
        Topic(id: 20, moduleId: 2, name: 'Problema di Cauchy', sort: 1),
        Topic(
          id: 21,
          moduleId: 2,
          name: 'Variabili separabili',
          status: TopicStatus.inProgress,
          sort: 2,
        ),
        Topic(id: 30, moduleId: 3, name: 'Serie di Taylor'),
      ];
      expect(courseVocabulary('Analisi 2', mods, topics), [
        'Analisi 2',
        'Equazioni differenziali',
        'Variabili separabili',
        'Problema di Cauchy',
        'Limiti',
        'Serie',
        'Limiti notevoli',
        'Serie di Taylor',
      ]);
      // nessun argomento in corso: il primo modulo con argomenti da fare
      expect(
        courseVocabulary('A', mods, [topics[0], topics[1], topics[3]])[1],
        'Equazioni differenziali',
      );
      expect(courseVocabulary('A', const [], const []), ['A']);
    });

    test('prompt: in ordine, senza doppioni, entro il limite di token', () {
      final p = buildWhisperPrompt([
        'Analisi 2',
        'Equazioni differenziali',
        'equazioni differenziali',
        ' ',
        'Problema di Cauchy',
      ])!;
      expect(
        p,
        'Lezione di Analisi 2: Equazioni differenziali, Problema di Cauchy.',
      );
      // molti argomenti: si tagliano gli ultimi (meno pertinenti), a voci
      // intere, e si resta sotto i 224 token di whisper.cpp
      final many = [
        'Fisica',
        for (var i = 0; i < 200; i++) 'Argomento numero $i della fisica',
      ];
      final long = buildWhisperPrompt(many)!;
      expect(
        estimateWhisperTokens(long),
        lessThanOrEqualTo(kWhisperPromptTokens),
      );
      expect(
        long,
        startsWith('Lezione di Fisica: Argomento numero 0 della fisica, '),
      );
      expect(long, endsWith('della fisica.'));
      expect(long, isNot(contains('numero 199')));
      expect(buildWhisperPrompt(const []), isNull);
      expect(buildWhisperPrompt(const ['  ']), isNull);
    });

    test('stima dei token prudente', () {
      expect(estimateWhisperTokens(''), 0);
      // parola di 6 lettere = 2 token, punteggiatura a parte
      expect(estimateWhisperTokens('lezione,'), 4);
      expect(estimateWhisperTokens('di'), 1);
    });

    test('il testo che ripete il prompt si scarta', () {
      const p = 'Lezione di Analisi 2: Equazioni differenziali, Cauchy.';
      expect(isPromptEcho('Equazioni differenziali, Cauchy.', p), isTrue);
      expect(isPromptEcho('lezione di analisi 2', p), isTrue);
      // due parole o testo vero: resta
      expect(isPromptEcho('Cauchy.', p), isFalse);
      expect(isPromptEcho('Oggi vediamo il problema di Cauchy', p), isFalse);
      expect(isPromptEcho('Equazioni differenziali, Cauchy', null), isFalse);
    });

    test('whisper-cli: prompt, VAD e soppressione dei token non verbali', () {
      expect(WhisperOptions.none.cliArgs, ['--suppress-nst']);
      final o = WhisperOptions(
        prompt: ' Lezione di Fisica. ',
        vad: File('v.bin'),
      );
      expect(o.cliArgs, [
        '--suppress-nst',
        '--prompt',
        'Lezione di Fisica.',
        '--vad',
        '--vad-model',
        'v.bin',
      ]);
    });
  });
}
