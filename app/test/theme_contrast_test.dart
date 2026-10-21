import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/core/theme/app_tokens.dart';
import 'package:university_notes/features/study/attachments.dart';
import 'package:university_notes/models/attachment.dart';

/// Contrasto WCAG delle coppie principali di colori dei temi chiaro e scuro
/// (anche ad alto contrasto): testi 4,5:1, elementi grafici e contorni 3:1.
void main() {
  /// Superfici su cui compaiono i testi: le fermate della card di vetro
  /// sopra il fondo più chiaro e più scuro, la card interna sopra la card,
  /// il fondo stesso (titoli di sezione fuori dalle card).
  List<Color> surfaces(AppTokens t) {
    final out = <Color>[...t.background];
    for (final bg in t.background) {
      for (final stop in t.cardGradient) {
        final card = Color.alphaBlend(stop, bg);
        out
          ..add(card)
          ..add(Color.alphaBlend(t.innerCard, card));
      }
    }
    return out;
  }

  double worst(Color fg, List<Color> on) =>
      on.map((s) => contrastRatio(fg, s)).reduce((a, b) => a < b ? a : b);

  final variants = <String, (AppTokens, ThemeData)>{
    'chiaro': (AppTokens.light, AppTheme.light()),
    'scuro': (AppTokens.dark, AppTheme.dark()),
    'chiaro alto contrasto': (
      AppTokens.light.highContrast(Brightness.light),
      AppTheme.light(highContrast: true),
    ),
    'scuro alto contrasto': (
      AppTokens.dark.highContrast(Brightness.dark),
      AppTheme.dark(highContrast: true),
    ),
  };

  for (final MapEntry(key: name, value: (t, theme)) in variants.entries) {
    group('tema $name', () {
      final on = surfaces(t);
      final scheme = theme.colorScheme;

      test('testi su fondo, card e card interne (4,5:1)', () {
        for (final (label, c) in [
          ('testo principale', t.textPrimary),
          ('testo secondario', t.textSecondary),
          ('testo attenuato', t.textMuted),
          ('azzurro (link, valori)', t.cyan),
          ('azzurro tenue (icone, etichette)', t.cyanSoft),
          ('esito positivo', t.success),
          ('avviso', t.warning),
          ('arancione come testo', t.orangeInk),
          ('errore', scheme.error),
          ('secondario dello schema', scheme.onSurfaceVariant),
        ]) {
          // il testo secondario del tema scuro è traslucido: si misura
          // composto sulla superficie
          final ratio = on
              .map((s) => contrastRatio(Color.alphaBlend(c, s), s))
              .reduce((a, b) => a < b ? a : b);
          expect(ratio, greaterThanOrEqualTo(4.5), reason: '$label: $ratio');
        }
      });

      test('pulsanti, voce attiva e contenitori (4,5:1)', () {
        for (final o in t.orangeGradient) {
          expect(contrastRatio(t.onOrange, o), greaterThanOrEqualTo(4.5));
        }
        expect(
          contrastRatio(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(4.5),
        );
        for (final n in t.navActive) {
          for (final bg in t.background) {
            final pill = Color.alphaBlend(
              n,
              Color.alphaBlend(t.navGradient.first, bg),
            );
            expect(
              contrastRatio(t.navActiveText, pill),
              greaterThanOrEqualTo(4.5),
            );
          }
        }
        for (final (fg, bg) in [
          (scheme.onPrimaryContainer, scheme.primaryContainer),
          (scheme.onSecondaryContainer, scheme.secondaryContainer),
          (scheme.onTertiaryContainer, scheme.tertiaryContainer),
          (scheme.onErrorContainer, scheme.errorContainer),
          (scheme.onInverseSurface, scheme.inverseSurface),
          (scheme.onSurface, scheme.surface),
        ]) {
          expect(contrastRatio(fg, bg), greaterThanOrEqualTo(4.5));
        }
        // avvisi in basso (snackbar)
        final snack = theme.snackBarTheme;
        expect(
          contrastRatio(snack.contentTextStyle!.color!, snack.backgroundColor!),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('grafici, tinte d\'area e contorni dei controlli (3:1)', () {
        for (final c in [
          ...t.chart,
          t.tintStudy,
          t.tintNotes,
          t.tintExams,
          t.tintBooks,
          t.cyanBright,
        ]) {
          expect(worst(c, on), greaterThanOrEqualTo(3), reason: '$c');
        }
        // le serie dei grafici sono distinguibili tra loro
        expect(t.chart.toSet().length, t.chart.length);
        expect(
          contrastRatio(scheme.outline, scheme.surfaceContainerLowest),
          greaterThanOrEqualTo(3),
        );
      });
    });
  }

  test('il tema chiaro ha una gerarchia: card più chiare del fondo', () {
    const t = AppTokens.light;
    final card = Color.alphaBlend(t.cardGradient.first, t.background[2]);
    for (final bg in t.background) {
      expect(card.computeLuminance(), greaterThan(bg.computeLuminance()));
    }
    // fondo né bianco piatto né grigio: una nebbia azzurra
    for (final bg in t.background) {
      expect(bg.b, greaterThan(bg.r));
      expect(bg.computeLuminance(), lessThan(0.95));
    }
  });

  testWidgets('esercizi negli allegati: 3:1 sul chiaro, scuro invariato', (
    tester,
  ) async {
    late Color light, dark;
    for (final (theme, set) in [
      (AppTheme.light(), (Color c) => light = c),
      (AppTheme.dark(), (Color c) => dark = c),
    ]) {
      // Theme diretto: MaterialApp animerebbe il passaggio tra i temi
      await tester.pumpWidget(
        Theme(
          data: theme,
          child: Builder(
            builder: (c) {
              set(AttachmentKind.exercises.colorOn(c));
              return const SizedBox();
            },
          ),
        ),
      );
    }
    expect(contrastRatio(light, Colors.white), greaterThanOrEqualTo(3));
    expect(
      contrastRatio(light, const Color(0xFFF3F8FC)),
      greaterThanOrEqualTo(3),
    );
    expect(dark, AttachmentKind.exercises.color);
    expect(dark, const Color(0xFFF57C00));
  });

  test('readableOn rende leggibili i colori fissi anche ai pallini (3:1)', () {
    for (final c in const [Colors.green, Colors.blue, Color(0xFF818CF8)]) {
      for (final b in Brightness.values) {
        final out = readableOn(c, b, minRatio: 3);
        final surface = b == Brightness.dark
            ? const Color(0xFF182335)
            : const Color(0xFFF3F8FC);
        expect(contrastRatio(out, surface), greaterThanOrEqualTo(3));
      }
    }
  });
}
