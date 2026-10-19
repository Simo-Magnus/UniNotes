import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/spoken_math.dart';

void main() {
  String c(String s) => spokenMathToLatex(s);

  group('esempi della richiesta', () {
    test('«due terzi» → frazione', () {
      expect(c('due terzi'), r'$\frac{2}{3}$');
      expect(c('Ne resta due terzi.'), r'Ne resta $\frac{2}{3}$.');
    });

    test('«integrale da 2 a pi greco» → integrale con gli estremi', () {
      expect(c('integrale da 2 a pi greco'), r'$\int_{2}^{\pi}$');
      expect(
        c("Calcoliamo l'integrale da zero a uno di x al quadrato in dx."),
        r"Calcoliamo l'$\int_{0}^{1} x^{2} \, dx$.",
      );
    });
  });

  group('numeri e frazioni', () {
    test('numeri in lettere', () {
      expect(italianNumber('ventitré'), 23);
      expect(italianNumber('ventuno'), 21);
      expect(italianNumber('trentotto'), 38);
      expect(italianNumber('centoventi'), 120);
      expect(italianNumber('duemilaventisei'), 2026);
      expect(italianNumber('mille'), 1000);
      expect(italianNumber('centro'), isNull);
      expect(italianNumber('trentino'), isNull);
    });

    test('frazioni dette e scritte', () {
      expect(c('un mezzo'), r'$\frac{1}{2}$');
      expect(c('tre quarti'), r'$\frac{3}{4}$');
      expect(c('pi greco mezzi'), r'$\frac{\pi}{2}$');
      expect(c('x fratto due'), r'$\frac{x}{2}$');
      expect(c('a su b'), r'a su b', reason: 'a è un articolo');
      expect(c('b su c'), r'$\frac{b}{c}$');
      expect(c('tre undicesimi'), r'$\frac{3}{11}$');
      expect(c('tre virgola quattordici per due'), r'$3{,}14 \cdot 2$');
    });
  });

  group('operatori, potenze e relazioni', () {
    test('somma di quadrati', () {
      expect(
        c('x al quadrato più y al quadrato uguale r al quadrato'),
        r'$x^{2} + y^{2} = r^{2}$',
      );
    });

    test('potenze, radici e pedici', () {
      expect(c('e alla x'), r'$e^{x}$');
      expect(c('x elevato alla n'), r'$x^{n}$');
      expect(c('dieci alla meno tre'), r'$10^{-3}$');
      expect(c('x quadro più uno'), r'$x^{2} + 1$');
      expect(c('la radice quadrata di due'), r'la $\sqrt{2}$');
      expect(c('radice cubica di otto uguale due'), r'$\sqrt[3]{8} = 2$');
      expect(c('x con zero più uno'), r'$x_{0} + 1$');
      expect(c('n fattoriale'), r'$n!$');
    });

    test('relazioni', () {
      expect(c('x minore o uguale a tre'), r'$x \leq 3$');
      expect(c('y maggiore di zero'), r'$y > 0$');
      expect(c('due più due fa quattro'), r'$2 + 2 = 4$');
      expect(c('x diverso da zero'), r'$x \neq 0$');
      expect(c('2 + 3 = 5'), r'$2 + 3 = 5$');
    });

    test('lettere greche e costanti', () {
      expect(c('alfa più beta'), r'$\alpha + \beta$');
      expect(c('delta maiuscolo x'), r'$\Delta$ x');
      expect(c('due pi greco erre'), r'$2\pi$ erre');
      expect(c('x tende a più infinito'), r'$x \to +\infty$');
    });
  });

  group('strutture', () {
    test('limite (prima o dopo la funzione)', () {
      expect(
        c(
          'il limite per x che tende a zero di seno di x fratto x è uguale '
          'a uno',
        ),
        r'il $\lim_{x \to 0} \frac{\sin x}{x} = 1$',
      );
      expect(
        c('limite di uno fratto x per x che tende a infinito'),
        r'$\lim_{x \to \infty} \frac{1}{x}$',
      );
    });

    test('somme e produttorie', () {
      expect(
        c('la somma per k che va da 1 a n di k al quadrato'),
        r'la $\sum_{k=1}^{n} k^{2}$',
      );
      expect(
        c('sommatoria da i uguale uno a n di x con i'),
        r'$\sum_{i=1}^{n} x_{i}$',
      );
    });

    test('funzioni, parentesi e derivate', () {
      expect(c('f di x uguale x al cubo'), r'$f(x) = x^{3}$');
      expect(
        c('seno di aperta parentesi x più uno chiusa parentesi'),
        r'$\sin \left(x + 1\right)$',
      );
      expect(c('logaritmo in base due di otto'), r'$\log_{2} 8$');
      expect(c('due seno di x'), r'$2\sin x$');
      expect(
        c('derivata di x al quadrato rispetto a x'),
        r'$\frac{d}{dx} x^{2}$',
      );
    });
  });

  group('il testo normale resta com\'è', () {
    for (final s in [
      'Oggi parliamo di limiti.',
      'Ci vediamo alle tre per la lezione.',
      'Più o meno è così, meno male.',
      'La somma di due numeri pari è pari.',
      'Aspetta due secondi.',
      'Il terzo capitolo è il più lungo.',
      'Lezione del 19/10/2026 alle 10:30.',
      'Il costo è 5 più IVA.',
      'Tu sei più bravo di me.',
      'Una funzione continua.',
      'Il delta del Po.',
      'Studiamo la versione alfa.',
      '',
    ]) {
      test(s.isEmpty ? '(vuoto)' : s, () => expect(c(s), s));
    }

    test('le formule già scritte non si toccano', () {
      expect(c(r'Sia $x^2$ più uno'), r'Sia $x^2$ più uno');
      expect(c(r'$$\int f$$ e due terzi'), r'$$\int f$$ e $\frac{2}{3}$');
    });
  });
}
