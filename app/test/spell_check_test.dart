import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/spell_check.dart';

class _FakeMobile extends SpellCheckService {
  Locale? locale;
  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    this.locale = locale;
    return [
      const SuggestionSpan(TextRange(start: 0, end: 4), ['ciao']),
      // dentro la formula: non si sottolinea
      const SuggestionSpan(TextRange(start: 6, end: 10), ['frac']),
    ];
  }
}

/// Servizio finto: «ciaoo» è errato; «boom» fa fallire il controllo.
class _CountingService extends SpellCheckService {
  final calls = <String>[];
  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    calls.add(text);
    if (text.contains('boom')) throw StateError('non disponibile');
    final i = text.indexOf('ciaoo');
    return [
      if (i >= 0) SuggestionSpan(TextRange(start: i, end: i + 5), ['ciao']),
    ];
  }
}

/// La prima volta il controllo è superato da uno più recente (null).
class _NullOnceService extends SpellCheckService {
  int calls = 0;
  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    calls++;
    if (calls == 1) return null;
    return [const SuggestionSpan(TextRange(start: 0, end: 5), [])];
  }
}

bool _wavy(TextSpan s) =>
    s.style?.decoration == TextDecoration.underline &&
    s.style?.decorationStyle == TextDecorationStyle.wavy;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('misspelledSpans: linea rossa in lettura', () {
    test('parole errate sottolineate (ondulata rossa), testo identico', () {
      const text = 'ciaoo a tutti, bellaa giornata';
      final spans = misspelledSpans(text, const [
        SuggestionSpan(TextRange(start: 15, end: 21), ['bella']),
        SuggestionSpan(TextRange(start: 0, end: 5), ['ciao']),
      ]);
      expect(spans.map((s) => s.text), [
        'ciaoo',
        ' a tutti, ',
        'bellaa',
        ' giornata',
      ]);
      expect(spans.map(_wavy), [true, false, true, false]);
      expect(
        spans.first.style?.decorationColor,
        TextField.materialMisspelledTextStyle.decorationColor,
      );
      // il testo letto dai lettori di schermo è lo stesso
      final root = TextSpan(children: spans);
      expect(root.toPlainText(), text);
      expect(root.getSemanticsInformation().map((i) => i.text).join(), text);
    });

    test('senza errori un solo tratto, con lo stile dato', () {
      const style = TextStyle(fontWeight: FontWeight.w700);
      final spans = misspelledSpans('tutto bene', const [], style: style);
      expect(spans, hasLength(1));
      expect(spans.single.text, 'tutto bene');
      expect(spans.single.style, style);
      expect(misspelledSpans('', const []), isEmpty);
    });

    test('lo stile del testo resta anche sulle parole errate', () {
      const style = TextStyle(fontWeight: FontWeight.w700);
      final spans = misspelledSpans('ciaoo', const [
        SuggestionSpan(TextRange(start: 0, end: 5), []),
      ], style: style);
      expect(spans.single.style?.fontWeight, FontWeight.w700);
      expect(_wavy(spans.single), isTrue);
    });

    test('un tratto di un testo più grande: posizioni con formule e spazi', () {
      // due frasi separate da uno spazio, la seconda con una formula
      const a = 'Prima ciaoo.';
      const b = r'Vale $x$ e ciaoo.';
      const all = '$a $b';
      final errors = [
        const SuggestionSpan(TextRange(start: 6, end: 11), []),
        SuggestionSpan(
          TextRange(
            start: a.length + 1 + b.lastIndexOf('ciaoo'),
            end: a.length + 1 + b.lastIndexOf('ciaoo') + 5,
          ),
          const [],
        ),
      ];
      // seconda frase: il suo testo comincia dopo la prima e lo spazio
      final second = misspelledSpans(b, errors, offset: a.length + 1);
      expect(second.map((s) => s.text), [r'Vale $x$ e ', 'ciaoo', '.']);
      expect(second.map(_wavy), [false, true, false]);
      // parte di testo dopo la formula (tratto da 8 a fine, come in
      // _reading dell'editor): solo l'errore dentro il tratto
      final tail = misspelledSpans(
        all,
        errors,
        start: a.length + 1 + 8,
        end: all.length,
      );
      expect(tail.map((s) => s.text).join(), ' e ciaoo.');
      expect(tail.where(_wavy).map((s) => s.text), ['ciaoo']);
      // prima parte: l'errore della seconda frase non entra
      final head = misspelledSpans(all, errors, end: a.length);
      expect(head.where(_wavy).map((s) => s.text), ['ciaoo']);
      expect(head.map((s) => s.text).join(), a);
    });

    test('errori fuori misura o sovrapposti non rompono il testo', () {
      const text = 'abc def';
      final spans = misspelledSpans(text, const [
        SuggestionSpan(TextRange(start: -1, end: 2), []),
        SuggestionSpan(TextRange(start: 1, end: 4), []),
        SuggestionSpan(TextRange(start: 6, end: 40), []),
      ]);
      expect(spans.map((s) => s.text).join(), text);
      expect(spans.where(_wavy).map((s) => s.text), ['ab', 'c ', 'f']);
    });
  });

  group('ReadingSpellChecker', () {
    const delay = Duration(milliseconds: 5);

    Future<void> settle(ReadingSpellChecker c) {
      final done = Completer<void>();
      void listener() {
        if (!done.isCompleted) done.complete();
      }

      c.addListener(listener);
      return done.future
          .timeout(const Duration(seconds: 2))
          .whenComplete(() => c.removeListener(listener));
    }

    test('chiede gli errori una volta per testo, senza ripetere', () async {
      final service = _CountingService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      expect(c.enabled, isTrue);
      // all'inizio nessun errore e il controllo non è ancora partito
      expect(c.errorsOf('ciaoo a tutti'), isEmpty);
      expect(service.calls, isEmpty);
      await settle(c);
      expect(service.calls, ['ciaoo a tutti']);
      expect(
        c.errorsOf('ciaoo a tutti').single.range,
        const TextRange(start: 0, end: 5),
      );
      // stesso testo: nessuna nuova richiesta
      expect(c.errorsOf('ciaoo a tutti'), hasLength(1));
      await Future<void>.delayed(delay * 4);
      expect(service.calls, hasLength(1));
      // un testo nuovo: si controlla solo quello
      expect(c.errorsOf('frase nuova'), isEmpty);
      await settle(c);
      expect(service.calls, ['ciaoo a tutti', 'frase nuova']);
    });

    test('più testi insieme: uno dopo l\'altro, dopo il ritardo', () async {
      final service = _CountingService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      for (final t in ['uno', 'due ciaoo', 'tre', 'uno']) {
        c.errorsOf(t);
      }
      expect(service.calls, isEmpty);
      await settle(c);
      expect(service.calls, ['uno', 'due ciaoo', 'tre']);
      expect(c.errorsOf('due ciaoo'), hasLength(1));
      expect(c.errorsOf('uno'), isEmpty);
    });

    test('se il controllo fallisce il testo resta senza errori', () async {
      final service = _CountingService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      c.errorsOf('boom ciaoo');
      c.errorsOf('bene ciaoo');
      await settle(c);
      expect(c.errorsOf('boom ciaoo'), isEmpty);
      expect(c.errorsOf('bene ciaoo'), hasLength(1));
      // non si riprova all'infinito
      await Future<void>.delayed(delay * 4);
      expect(service.calls.where((x) => x.startsWith('boom')), hasLength(1));
    });

    test('un controllo superato da uno più recente si riprova', () async {
      final service = _NullOnceService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      c.errorsOf('ciaoo');
      // il primo tentativo non dà nulla, il secondo sì
      await settle(c);
      expect(c.errorsOf('ciaoo'), hasLength(1));
      expect(service.calls, 2);
    });

    test('cambiando lingua si ricomincia', () async {
      final service = _CountingService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      c.errorsOf('ciaoo');
      await settle(c);
      c.language = 'en';
      expect(c.language, 'en');
      expect(c.errorsOf('ciaoo'), isEmpty);
      await settle(c);
      expect(service.calls, ['ciaoo', 'ciaoo']);
    });

    test('testo vuoto: niente da controllare', () async {
      final service = _CountingService();
      final c = ReadingSpellChecker(service: service, delay: delay);
      addTearDown(c.dispose);
      expect(c.errorsOf('   '), isEmpty);
      await Future<void>.delayed(delay * 4);
      expect(service.calls, isEmpty);
    });
  });

  const channel = MethodChannel(SystemSpellCheckService.channelName);
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'languages') return {'it': true, 'en': false};
          final texts = (call.arguments as Map)['texts'] as List;
          // «ciaoo» errato ovunque compaia
          return [
            for (final t in texts.cast<String>())
              [
                if (t.indexOf('ciaoo') case final i when i >= 0)
                  [
                    i,
                    i + 5,
                    ['ciao', 'ciano'],
                  ],
              ],
          ];
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'PC: una riga alla volta, con i risultati delle righe già viste',
    () async {
      final s = SystemSpellCheckService(platform: TargetPlatform.windows);
      final spans = await s.fetchSpellCheckSuggestions(
        const Locale('it'),
        'prima riga\nciaoo a tutti',
      );
      expect(spans, [
        const SuggestionSpan(TextRange(start: 11, end: 16), ['ciao', 'ciano']),
      ]);
      expect(calls.single.arguments, {
        'texts': ['prima riga', 'ciaoo a tutti'],
        'languages': ['it', 'en'],
      });
      // cambia solo la prima riga: si manda solo quella
      final again = await s.fetchSpellCheckSuggestions(
        const Locale('it'),
        'prima riga!\nciaoo a tutti',
      );
      expect(again!.single.range, const TextRange(start: 12, end: 17));
      expect((calls.last.arguments as Map)['texts'], ['prima riga!']);
      // lezione in inglese: l'inglese prima
      final en = SystemSpellCheckService(
        primary: 'en',
        platform: TargetPlatform.macOS,
      );
      await en.fetchSpellCheckSuggestions(const Locale('it'), 'hello');
      expect((calls.last.arguments as Map)['languages'], ['en', 'it']);
    },
  );

  test('formule e indirizzi web non si controllano', () {
    const text = r'ciaoo $\frac{2}{3}$ e https://esempio.it/ciaoo';
    final spans = filterSpellCheckSpans(text, const [
      SuggestionSpan(TextRange(start: 0, end: 5), []),
      SuggestionSpan(TextRange(start: 8, end: 12), []),
      SuggestionSpan(TextRange(start: 41, end: 46), []),
    ]);
    expect(spans.map((s) => s.range.start), [0]);
  });

  test(
    'telefono: il servizio del sistema nella lingua della lezione',
    () async {
      final fake = _FakeMobile();
      final s = SystemSpellCheckService(
        primary: 'en',
        mobile: fake,
        platform: TargetPlatform.android,
      );
      final spans = await s.fetchSpellCheckSuggestions(
        const Locale('it'),
        r'helo $\frac{1}{2}$',
      );
      expect(fake.locale, const Locale('en', 'US'));
      expect(spans!.map((x) => x.range.start), [0]);
      expect(calls, isEmpty);
    },
  );

  test('errori dal canale nativo e avviso sulle lingue mancanti', () {
    expect(
      parseNativeSpellErrors([
        [
          5,
          9,
          ['casa'],
        ],
        [0, 3],
        ['x'],
        [4, 4, []],
      ]).map((s) => '${s.range.start}-${s.range.end} ${s.suggestions}'),
      ['0-3 []', '5-9 [casa]'],
    );
    expect(spellLanguageOf('en-US'), 'en');
    expect(spellLanguageOf(null), 'it');
    expect(
      spellCheckLanguagesText((it: false, en: true), mac: false),
      contains('installa la lingua italiana in Windows'),
    );
    expect(
      spellCheckLanguagesText((it: true, en: false), mac: true),
      contains('macOS'),
    );
    expect(spellCheckLanguagesText((it: true, en: true), mac: false), isNull);
  });
}
