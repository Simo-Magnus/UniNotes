import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Token del sistema visivo "Design 3": fondo a strati, card di vetro,
/// azzurro = ciò che fa la macchina (stati calcolati, voce attiva),
/// arancione = l'azione dell'utente (una sola per schermata).
@immutable
class AppTokens extends ThemeExtension<AppTokens> {
  const AppTokens({
    required this.background,
    required this.lights,
    required this.vignette,
    required this.cardGradient,
    required this.cardBorder,
    required this.cardShadows,
    required this.lightThread,
    required this.spotlight,
    required this.innerCard,
    required this.innerBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.cyan,
    required this.cyanBright,
    required this.cyanSoft,
    required this.orangeGradient,
    required this.onOrange,
    required this.navGradient,
    required this.navBorder,
    required this.navActive,
    required this.navActiveText,
    required this.tintStudy,
    required this.tintNotes,
    required this.tintExams,
    required this.tintBooks,
    required this.success,
    required this.warning,
    required this.orangeInk,
    required this.floatShadows,
    required this.chart,
  });

  /// Base lineare del fondo (dall'alto in basso).
  final List<Color> background;

  /// Luci ellittiche del fondo.
  final List<BackgroundLight> lights;

  /// Ombra ai bordi (solo tema scuro).
  final Color vignette;

  final List<Color> cardGradient;
  final Color cardBorder;
  final List<BoxShadow> cardShadows;

  /// Filo di luce sul bordo alto delle card (null = solo bordo).
  final Color? lightThread;

  /// Faretto interno in alto nelle card.
  final Color spotlight;

  final Color innerCard;
  final Color innerBorder;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  final Color cyan;
  final Color cyanBright;
  final Color cyanSoft;

  final List<Color> orangeGradient;
  final Color onOrange;

  final List<Color> navGradient;
  final Color navBorder;
  final List<Color> navActive;
  final Color navActiveText;

  /// Tinte di supporto: solo per icone o etichette d'area, mai per azioni,
  /// fondi o pulsanti (Studio indaco, Esami viola, Libri verde).
  final Color tintStudy;
  final Color tintNotes;
  final Color tintExams;
  final Color tintBooks;

  /// Stati leggibili come testo o icona sulle card (WCAG AA 4,5:1): esito
  /// positivo (superato, completato, collegato) e avviso (in scadenza, da
  /// controllare). L'errore è `ColorScheme.error`.
  final Color success;
  final Color warning;

  /// Arancione usato come testo o icona (l'arancione pieno dei pulsanti
  /// sul fondo chiaro non è leggibile come testo).
  final Color orangeInk;

  /// Ombra degli elementi che galleggiano sul contenuto (barra di
  /// navigazione, riquadri flottanti).
  final List<BoxShadow> floatShadows;

  /// Serie dei grafici (categorie): tonalità distinte tra loro e leggibili
  /// sul fondo delle card (almeno 3:1, elementi grafici WCAG).
  final List<Color> chart;

  static const dark = AppTokens(
    background: [
      Color(0xFF02060F),
      Color(0xFF030B18),
      Color(0xFF041122),
      Color(0xFF041426),
      Color(0xFF020A16),
    ],
    lights: [
      BackgroundLight(Alignment(0, -0.44), Size(0.72, 0.30), Color(0x2638A0FF)),
      BackgroundLight(Alignment(0, 0.36), Size(0.72, 0.30), Color(0x2138A0FF)),
      BackgroundLight(
        Alignment(-0.6, -0.88),
        Size(0.56, 0.24),
        Color(0x292563EB),
      ),
    ],
    vignette: Color(0x9E000000),
    cardGradient: [
      Color(0x16FFFFFF),
      Color(0x08FFFFFF),
      Color(0x03FFFFFF),
      Color(0x57000814),
    ],
    cardBorder: Color(0x1CA0CDFF),
    cardShadows: [
      BoxShadow(
        color: Color(0xEB000000),
        offset: Offset(0, 12),
        blurRadius: 26,
        spreadRadius: -16,
      ),
    ],
    lightThread: Color(0x6BBEE4FF),
    spotlight: Color(0x2138BDF8),
    innerCard: Color(0x0DFFFFFF),
    innerBorder: Color(0x1AFFFFFF),
    textPrimary: Color(0xFFF3F7FB),
    textSecondary: Color(0xBFEBF5FF),
    textMuted: Color(0xFF8FA9C4),
    cyan: Color(0xFF38BDF8),
    cyanBright: Color(0xFF7DE8FF),
    cyanSoft: Color(0xFF7DD3FC),
    orangeGradient: [Color(0xFFFFB064), Color(0xFFFF8A1F), Color(0xFFE86F08)],
    onOrange: Color(0xFF1A0B00),
    navGradient: [Color(0x1FFFFFFF), Color(0x09FFFFFF), Color(0x2E000000)],
    navBorder: Color(0x24FFFFFF),
    navActive: [Color(0x4738BDF8), Color(0x1F0E74BE)],
    navActiveText: Color(0xFFDCF0FF),
    tintStudy: Color(0xFF818CF8),
    tintNotes: Color(0xFFC084FC),
    tintExams: Color(0xFFC084FC),
    tintBooks: Color(0xFF34D399),
    success: Color(0xFF34D399),
    warning: Color(0xFFFBBF24),
    orangeInk: Color(0xFFFFB064),
    floatShadows: [
      BoxShadow(
        color: Color(0xF2000000),
        offset: Offset(0, 18),
        blurRadius: 34,
        spreadRadius: -12,
      ),
    ],
    chart: [
      Color(0xFF38BDF8), // azzurro
      Color(0xFF818CF8), // indaco
      Color(0xFF2DD4BF), // verde acqua
      Color(0xFFC084FC), // viola
      Color(0xFFFBBF24), // ambra
      Color(0xFFF472B6), // rosa
      Color(0xFF94A3B8), // grigio ardesia
    ],
  );

  /// Tema chiaro «mattina limpida» (riprogettato il 21/10/2026): fondo
  /// nebbia azzurra con luci di cielo, card bianche nette con bordo sottile
  /// e doppia ombra morbida (contatto + profondità), filo di luce azzurro in
  /// alto come nel tema scuro, card interne velate d'azzurro invece che di
  /// grigio. Testi ardesia-blu con contrasto AA anche sul fondo più scuro.
  static const light = AppTokens(
    background: [
      Color(0xFFF0F5FB),
      Color(0xFFEBF1F8),
      Color(0xFFE6EDF6),
      Color(0xFFE8EFF7),
      Color(0xFFEEF3F9),
    ],
    lights: [
      // cielo in alto a sinistra, riflesso a destra, luce bassa al centro:
      // solo azzurri (mai l'arancione nel fondo)
      BackgroundLight(
        Alignment(-0.7, -0.92),
        Size(0.75, 0.30),
        Color(0x337DD3FC),
      ),
      BackgroundLight(Alignment(0.85, -0.25), Size(0.6, 0.28), Color(0x1F93C5FD)),
      BackgroundLight(Alignment(0, 0.62), Size(0.8, 0.32), Color(0x1A7DD3FC)),
    ],
    vignette: Color(0x00000000),
    // vetro chiaro: bianco quasi pieno che lascia appena passare il cielo
    cardGradient: [
      Color(0xFFFFFFFF),
      Color(0xFCFFFFFF),
      Color(0xFAFEFFFF),
      Color(0xF7FAFCFF),
    ],
    cardBorder: Color(0xFFDAE3ED),
    cardShadows: [
      BoxShadow(
        color: Color(0x0F0F172A),
        offset: Offset(0, 1),
        blurRadius: 2,
      ),
      BoxShadow(
        color: Color(0x1A1E3A5F),
        offset: Offset(0, 10),
        blurRadius: 28,
        spreadRadius: -12,
      ),
    ],
    lightThread: Color(0x8C38BDF8),
    spotlight: Color(0x0D38BDF8),
    innerCard: Color(0x0D0369A1),
    innerBorder: Color(0x240369A1),
    textPrimary: Color(0xFF0F172A),
    textSecondary: Color(0xFF334155),
    textMuted: Color(0xFF52627A),
    cyan: Color(0xFF0369A1),
    cyanBright: Color(0xFF0284C7),
    cyanSoft: Color(0xFF086190),
    orangeGradient: [Color(0xFFFFB064), Color(0xFFFF8A1F), Color(0xFFE86F08)],
    onOrange: Color(0xFF1A0B00),
    navGradient: [Color(0xFAFFFFFF), Color(0xF5FFFFFF), Color(0xF2F6F9FD)],
    navBorder: Color(0xFFD6E0EB),
    navActive: [Color(0xFFE0F2FE), Color(0xFFCDE9FB)],
    navActiveText: Color(0xFF075985),
    tintStudy: Color(0xFF4F46E5),
    tintNotes: Color(0xFF7E22CE),
    tintExams: Color(0xFF7E22CE),
    tintBooks: Color(0xFF047857),
    success: Color(0xFF047857),
    warning: Color(0xFFA35208),
    orangeInk: Color(0xFFB93F0B),
    floatShadows: [
      BoxShadow(
        color: Color(0x140F172A),
        offset: Offset(0, 2),
        blurRadius: 6,
      ),
      BoxShadow(
        color: Color(0x241E3A5F),
        offset: Offset(0, 8),
        blurRadius: 24,
        spreadRadius: -8,
      ),
    ],
    chart: [
      Color(0xFF0284C7), // azzurro
      Color(0xFF4F46E5), // indaco
      Color(0xFF0D9488), // verde acqua
      Color(0xFF9333EA), // viola
      Color(0xFFB45309), // ambra
      Color(0xFFDB2777), // rosa
      Color(0xFF64748B), // grigio ardesia
    ],
  );

  /// Alto contrasto (Impostazioni → Aspetto): testi più chiari (o più scuri
  /// nel tema chiaro), bordi più marcati, card quasi opache invece delle
  /// trasparenze deboli. Arancione e azzurro restano quelli di Design 3,
  /// l'azzurro solo un po' più luminoso (o più scuro) per il contrasto.
  AppTokens highContrast(Brightness b) {
    final dark = b == Brightness.dark;
    return AppTokens(
      background: background,
      lights: lights,
      vignette: vignette,
      cardGradient: dark
          ? const [
              Color(0xF2152238),
              Color(0xF2111D31),
              Color(0xF20E192B),
              Color(0xF20A1424),
            ]
          : const [
              Color(0xFFFFFFFF),
              Color(0xFFFFFFFF),
              Color(0xFFFDFEFF),
              Color(0xFFF8FBFF),
            ],
      cardBorder: dark ? const Color(0x80A0CDFF) : const Color(0xFF7B8CA3),
      cardShadows: cardShadows,
      lightThread: lightThread,
      spotlight: dark ? const Color(0x1438BDF8) : const Color(0x0038BDF8),
      innerCard: dark ? const Color(0x1FFFFFFF) : const Color(0x140369A1),
      innerBorder: dark ? const Color(0x66FFFFFF) : const Color(0xFF8A9BB1),
      textPrimary: dark ? const Color(0xFFFFFFFF) : const Color(0xFF020617),
      textSecondary: dark ? const Color(0xFFE8F1FB) : const Color(0xFF1E293B),
      textMuted: dark ? const Color(0xFFC6D6E8) : const Color(0xFF334155),
      cyan: dark ? const Color(0xFF7DD3FC) : const Color(0xFF075985),
      cyanBright: dark ? const Color(0xFFA5F3FC) : const Color(0xFF0369A1),
      cyanSoft: dark ? const Color(0xFFBAE6FD) : const Color(0xFF0C4A6E),
      orangeGradient: orangeGradient,
      onOrange: onOrange,
      navGradient: dark
          ? const [Color(0xF0142236), Color(0xF00E1A2C), Color(0xF00A1322)]
          : const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFF6F9FD)],
      navBorder: dark ? const Color(0x99FFFFFF) : const Color(0xFF7B8CA3),
      navActive: dark
          ? const [Color(0x7338BDF8), Color(0x4D0E74BE)]
          : const [Color(0xFFBAE6FD), Color(0xFFA5DAF8)],
      navActiveText: dark ? const Color(0xFFFFFFFF) : const Color(0xFF062F4A),
      tintStudy: dark ? const Color(0xFFA5B4FC) : const Color(0xFF3730A3),
      tintNotes: dark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8),
      tintExams: dark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8),
      tintBooks: dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
      success: dark ? const Color(0xFF6EE7B7) : const Color(0xFF065F46),
      warning: dark ? const Color(0xFFFCD34D) : const Color(0xFF854D0E),
      orangeInk: dark ? const Color(0xFFFFC58F) : const Color(0xFF9A3412),
      floatShadows: floatShadows,
      chart: chart,
    );
  }

  @override
  AppTokens copyWith() => this;

  @override
  AppTokens lerp(ThemeExtension<AppTokens>? other, double t) =>
      (other is AppTokens && t >= 0.5) ? other : this;
}

/// Luce ellittica: centro, semiassi in frazione della larghezza/altezza.
@immutable
class BackgroundLight {
  const BackgroundLight(this.center, this.radii, this.color);
  final Alignment center;
  final Size radii;
  final Color color;
}

/// Scale del sistema: testo, raggi, spazi.
abstract final class AppScale {
  static const text = [11.0, 13.0, 15.0, 17.0, 22.0, 34.0, 48.0];
  static const radiusSmall = 10.0;
  static const radiusInner = 16.0;
  static const radiusButton = 14.0;
  static const radiusCard = 22.0;
  static const radiusLarge = 28.0;
}

extension TokensContext on BuildContext {
  AppTokens get tokens =>
      Theme.of(this).extension<AppTokens>() ?? AppTokens.dark;
}

/// Colore dei calendari leggibile sul fondo: schiarito nel tema scuro (i
/// colori delle università sono scelti per fondi chiari).
///
/// [minRatio] 4,5 per i testi; 3 basta per pallini, barre e icone che non
/// sono testo (contrasto degli elementi grafici WCAG).
Color readableOn(Color c, Brightness b, {double minRatio = 4.5}) {
  // Fondo di riferimento: le card dei due temi (vetro su sfondo); nel tema
  // chiaro la card interna velata d'azzurro, la più scura delle due.
  final surface = b == Brightness.dark
      ? const Color(0xFF182335)
      : const Color(0xFFF3F8FC);
  return ensureContrast(c, surface, b, minRatio: minRatio);
}

/// Rapporto di contrasto WCAG tra due colori (1…21).
double contrastRatio(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

/// [c] schiarito (tema scuro) o scurito (tema chiaro) quanto basta per avere
/// almeno [minRatio] di contrasto su [surface] (4,5:1 = testo WCAG AA),
/// mantenendo tinta e saturazione.
Color ensureContrast(
  Color c,
  Color surface,
  Brightness b, {
  double minRatio = 4.5,
}) {
  if (contrastRatio(c, surface) >= minRatio) return c;
  var hsl = HSLColor.fromColor(c);
  for (var i = 0; i < 40; i++) {
    final l = b == Brightness.dark
        ? (hsl.lightness + 0.02).clamp(0.0, 1.0)
        : (hsl.lightness - 0.02).clamp(0.0, 1.0);
    hsl = hsl.withLightness(l);
    final out = hsl.toColor();
    if (contrastRatio(out, surface) >= minRatio) return out;
  }
  return b == Brightness.dark ? Colors.white : Colors.black;
}
