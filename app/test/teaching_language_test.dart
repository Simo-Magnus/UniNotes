import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/teaching_language.dart';
import 'package:university_notes/models/course.dart';

void main() {
  test('insegnamento offerto anche in inglese: lingua riconosciuta e campi '
      'scambiati', () {
    final ins = Insegnamento.fromJson({
      'id': 'polito-l-8-ingegneria-informatica-16acfye',
      'nome': 'Analisi matematica I',
      'codice': '16ACFYE',
      'docenti': ['A. Grillo'],
      'url': 'https://didattica.polito.it/it',
      'libri': [
        {'titolo': 'Analisi Matematica 1', 'autori': 'Canuto, Tabacco'},
      ],
      'varianti': [
        {
          'lingua': 'en',
          'codice': '04KWQYE',
          'nome': 'Mathematical analysis I',
          'docenti': ['B. Franci'],
          'url': 'https://didattica.polito.it/en',
          'libri': [
            {'titolo': 'Mathematical Analysis I', 'autori': 'Canuto, Tabacco'},
          ],
        },
      ],
    })!;
    expect(ins.varianti.single.codice, '04KWQYE');
    expect(ins.varianti.single.libri.single.titolo, 'Mathematical Analysis I');

    final lang = TeachingLanguage('polito', ins);
    expect(lang.hasEnglish, isTrue);
    const it = Course(
      name: 'Analisi matematica I',
      code: '16ACFYE',
      teacher: 'A. Grillo',
      syllabusUrl: 'https://didattica.polito.it/it',
    );
    expect(lang.isEnglish(it), isFalse);

    final en = lang.apply(it, english: true);
    expect(en.name, 'Mathematical analysis I');
    expect(en.code, '04KWQYE');
    expect(en.teacher, 'B. Franci');
    expect(en.syllabusUrl, 'https://didattica.polito.it/en');
    expect(lang.isEnglish(en), isTrue);

    final back = lang.apply(en, english: false);
    expect(back.name, 'Analisi matematica I');
    expect(back.code, '16ACFYE');
    expect(lang.isEnglish(back), isFalse);
  });

  test('senza varianti nessuna scelta della lingua', () {
    final ins = Insegnamento.fromJson({'id': 'x', 'nome': 'Chimica'})!;
    expect(TeachingLanguage('polito', ins).hasEnglish, isFalse);
  });
}
