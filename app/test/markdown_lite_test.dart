import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/markdown_lite.dart';

void main() {
  test('blocchi', () {
    final b = parseMarkdown('''
# Titolo
Testo su
due righe.

## Sezione
- punto **uno**
  - sotto
1. primo
> citazione
---
```
x = 1
```
''');
    expect(b.map((x) => x.type).toList(), [
      MdBlockType.heading,
      MdBlockType.paragraph,
      MdBlockType.heading,
      MdBlockType.bullet,
      MdBlockType.bullet,
      MdBlockType.numbered,
      MdBlockType.quote,
      MdBlockType.rule,
      MdBlockType.code,
    ]);
    expect(b[0].level, 1);
    expect(b[1].plainText, 'Testo su due righe.');
    expect(b[4].level, 1);
    expect(b[5].number, 1);
    expect(b[8].raw, 'x = 1');
  });

  test('in linea: grassetto, corsivo, evidenziato, codice', () {
    final s = parseInline(
      'Il **teorema di ==Rolle==** vale *sempre* per `f(x)` e nome_file.',
    );
    String flags(MdSpan x) =>
        '${x.bold ? 'B' : ''}${x.italic ? 'I' : ''}${x.highlight ? 'H' : ''}${x.code ? 'C' : ''}';
    expect(s.map((x) => '${flags(x)}:${x.text}').toList(), [
      ':Il ',
      'B:teorema di ',
      'BH:Rolle',
      ': vale ',
      'I:sempre',
      ': per ',
      'C:f(x)',
      ' e nome_file.'.isEmpty ? '' : ': e nome_file.',
    ]);
  });

  test('marcatori senza chiusura restano testo', () {
    expect(parseInline('5 * 3 = 15').map((x) => x.text).join(), '5 * 3 = 15');
    expect(parseInline('a ** b').map((x) => x.text).join(), 'a ** b');
  });
}
