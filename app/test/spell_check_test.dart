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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
