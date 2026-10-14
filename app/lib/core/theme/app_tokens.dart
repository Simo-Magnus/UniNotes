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
  );

  static const light = AppTokens(
    background: [
      Color(0xFFF4F9FF),
      Color(0xFFEFF6FE),
      Color(0xFFEAF3FD),
      Color(0xFFEDF5FE),
      Color(0xFFF5F9FE),
    ],
    lights: [
      BackgroundLight(Alignment(0, -0.44), Size(0.72, 0.30), Color(0x1A38A0FF)),
      BackgroundLight(Alignment(0, 0.36), Size(0.72, 0.30), Color(0x1438A0FF)),
      BackgroundLight(
        Alignment(-0.6, -0.88),
        Size(0.56, 0.24),
        Color(0x142563EB),
      ),
    ],
    vignette: Color(0x00000000),
    cardGradient: [
      Color(0xD9FFFFFF),
      Color(0xC7FFFFFF),
      Color(0xBFFFFFFF),
      Color(0xB8F6FAFF),
    ],
    cardBorder: Color(0x1A0F2A4D),
    cardShadows: [
      BoxShadow(
        color: Color(0x1F0B2545),
        offset: Offset(0, 6),
        blurRadius: 16,
        spreadRadius: -8,
      ),
    ],
    lightThread: null,
    spotlight: Color(0x1238BDF8),
    innerCard: Color(0x0A0B2545),
    innerBorder: Color(0x140B2545),
    textPrimary: Color(0xFF0B1726),
    textSecondary: Color(0xFF34475E),
    textMuted: Color(0xFF5B708A),
    cyan: Color(0xFF0369A1),
    cyanBright: Color(0xFF0284C7),
    cyanSoft: Color(0xFF0277BD),
    orangeGradient: [Color(0xFFFFB064), Color(0xFFFF8A1F), Color(0xFFE86F08)],
    onOrange: Color(0xFF1A0B00),
    navGradient: [Color(0xF2FFFFFF), Color(0xE6FFFFFF), Color(0xE0F3F8FE)],
    navBorder: Color(0x1A0F2A4D),
    navActive: [Color(0x330EA5E9), Color(0x140284C7)],
    navActiveText: Color(0xFF075985),
    tintStudy: Color(0xFF4F46E5),
    tintNotes: Color(0xFF9333EA),
    tintExams: Color(0xFF9333EA),
    tintBooks: Color(0xFF059669),
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
      cardBorder: dark ? const Color(0x80A0CDFF) : const Color(0x800F2A4D),
      cardShadows: cardShadows,
      lightThread: lightThread,
      spotlight: dark ? const Color(0x1438BDF8) : const Color(0x0A38BDF8),
      innerCard: dark ? const Color(0x1FFFFFFF) : const Color(0x140B2545),
      innerBorder: dark ? const Color(0x66FFFFFF) : const Color(0x660B2545),
      textPrimary: dark ? const Color(0xFFFFFFFF) : const Color(0xFF02070F),
      textSecondary: dark ? const Color(0xFFE8F1FB) : const Color(0xFF15212F),
      textMuted: dark ? const Color(0xFFC6D6E8) : const Color(0xFF2B3B4E),
      cyan: dark ? const Color(0xFF7DD3FC) : const Color(0xFF075985),
      cyanBright: dark ? const Color(0xFFA5F3FC) : const Color(0xFF0369A1),
      cyanSoft: dark ? const Color(0xFFBAE6FD) : const Color(0xFF0C4A6E),
      orangeGradient: orangeGradient,
      onOrange: onOrange,
      navGradient: dark
          ? const [Color(0xF0142236), Color(0xF00E1A2C), Color(0xF00A1322)]
          : const [Color(0xFFFFFFFF), Color(0xFFFFFFFF), Color(0xFFF6F9FD)],
      navBorder: dark ? const Color(0x99FFFFFF) : const Color(0x800F2A4D),
      navActive: dark
          ? const [Color(0x7338BDF8), Color(0x4D0E74BE)]
          : const [Color(0x590EA5E9), Color(0x330284C7)],
      navActiveText: dark ? const Color(0xFFFFFFFF) : const Color(0xFF062F4A),
      tintStudy: dark ? const Color(0xFFA5B4FC) : const Color(0xFF3730A3),
      tintNotes: dark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8),
      tintExams: dark ? const Color(0xFFD8B4FE) : const Color(0xFF6B21A8),
      tintBooks: dark ? const Color(0xFF6EE7B7) : const Color(0xFF047857),
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
Color readableOn(Color c, Brightness b) {
  // Fondo di riferimento: le card dei due temi (vetro su sfondo).
  final surface = b == Brightness.dark
      ? const Color(0xFF182335)
      : const Color(0xFFFCFDFF);
  return ensureContrast(c, surface, b);
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
