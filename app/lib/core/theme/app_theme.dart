import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../widgets/glass_border.dart';
import '../feedback/motion.dart' show kCalmPageTransitions;
import 'app_tokens.dart';

/// Tema "Design 3" (scuro predefinito, chiaro speculare). Fondo e card sono
/// disegnati da AppBackground e GlassCard; qui i componenti Material.
class AppTheme {
  /// [highContrast]: Impostazioni → Aspetto → Alto contrasto.
  static ThemeData light({bool highContrast = false}) =>
      _build(Brightness.light, highContrast: highContrast);
  static ThemeData dark({bool highContrast = false}) =>
      _build(Brightness.dark, highContrast: highContrast);

  static const fontFamily = 'IBMPlexSans';

  /// Barra di stato trasparente con icone leggibili sul fondo del tema
  /// (chiare sul tema scuro, scure sul tema chiaro).
  static SystemUiOverlayStyle overlayStyle(Brightness b) {
    final dark = b == Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
      // iOS: luminosità del fondo sotto la barra di stato
      statusBarBrightness: b,
    );
  }

  static ThemeData _build(Brightness b, {bool highContrast = false}) {
    final dark = b == Brightness.dark;
    final hc = highContrast;
    final base = dark ? AppTokens.dark : AppTokens.light;
    final t = hc ? base.highContrast(b) : base;
    final scheme = ColorScheme(
      brightness: b,
      primary: t.cyan,
      onPrimary: dark ? const Color(0xFF021222) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF0C3550)
          : const Color(0xFFD7EEFB),
      onPrimaryContainer: dark
          ? const Color(0xFFDCF0FF)
          : const Color(0xFF07344F),
      secondary: t.cyanSoft,
      onSecondary: dark ? const Color(0xFF021222) : Colors.white,
      secondaryContainer: dark
          ? const Color(0xFF12304A)
          : const Color(0xFFE2F1FB),
      onSecondaryContainer: dark
          ? const Color(0xFFDCF0FF)
          : const Color(0xFF0B3A57),
      tertiary: t.tintStudy,
      onTertiary: Colors.white,
      tertiaryContainer: dark
          ? const Color(0xFF242A5C)
          : const Color(0xFFE6E8FD),
      onTertiaryContainer: dark
          ? const Color(0xFFE0E3FF)
          : const Color(0xFF1E1B4B),
      error: dark ? const Color(0xFFF87171) : const Color(0xFFC62828),
      onError: dark ? const Color(0xFF2A0606) : Colors.white,
      errorContainer: dark ? const Color(0xFF4A1414) : const Color(0xFFFDE2E2),
      onErrorContainer: dark
          ? const Color(0xFFFFDADA)
          : const Color(0xFF5C0B0B),
      surface: dark ? const Color(0xFF0A1628) : const Color(0xFFF7FAFE),
      onSurface: t.textPrimary,
      onSurfaceVariant: hc
          ? t.textSecondary
          : (dark ? const Color(0xFFA9BED6) : const Color(0xFF4A5F78)),
      surfaceContainerLowest: dark ? const Color(0xFF050D1A) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF0B1729)
          : const Color(0xFFF3F7FC),
      surfaceContainer: dark
          ? const Color(0xFF0F1D31)
          : const Color(0xFFEDF3FA),
      surfaceContainerHigh: dark
          ? const Color(0xFF132339)
          : const Color(0xFFE6EEF7),
      surfaceContainerHighest: dark
          ? const Color(0xFF182A42)
          : const Color(0xFFDFE9F4),
      outline: hc
          ? t.textMuted
          : (dark ? const Color(0xFF6F86A0) : const Color(0xFF6A7F98)),
      outlineVariant: hc
          ? (dark ? const Color(0xFF52688A) : const Color(0xFF7A8CA3))
          : (dark ? const Color(0xFF1E3045) : const Color(0xFFD3DEEA)),
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: dark ? const Color(0xFFE6EEF7) : const Color(0xFF0F1D31),
      onInverseSurface: dark
          ? const Color(0xFF0B1726)
          : const Color(0xFFF3F7FB),
      inversePrimary: dark ? const Color(0xFF0369A1) : const Color(0xFF7DD3FC),
      surfaceTint: Colors.transparent,
    );

    TextStyle s(
      double size,
      FontWeight w, {
      Color? color,
      double? height,
      double? spacing,
    }) => TextStyle(
      fontFamily: fontFamily,
      fontSize: size,
      fontWeight: w,
      color: color ?? t.textPrimary,
      height: height,
      letterSpacing: spacing,
    );
    final text = TextTheme(
      displayLarge: s(48, FontWeight.w300, height: 1.1),
      displayMedium: s(34, FontWeight.w300, height: 1.15),
      displaySmall: s(34, FontWeight.w300, height: 1.15),
      headlineLarge: s(34, FontWeight.w600, height: 1.15),
      headlineMedium: s(22, FontWeight.w600, height: 1.25),
      headlineSmall: s(22, FontWeight.w600, height: 1.25),
      titleLarge: s(22, FontWeight.w600, height: 1.25),
      titleMedium: s(17, FontWeight.w600, height: 1.3),
      titleSmall: s(15, FontWeight.w600, height: 1.3),
      bodyLarge: s(15, FontWeight.w400, height: 1.45),
      bodyMedium: s(13, FontWeight.w400, height: 1.45, color: t.textSecondary),
      bodySmall: s(12, FontWeight.w400, height: 1.4, color: t.textMuted),
      labelLarge: s(13, FontWeight.w600),
      labelMedium: s(11, FontWeight.w600, spacing: 0.4),
      labelSmall: s(11, FontWeight.w600, spacing: 0.4, color: t.textMuted),
    );

    final secondaryBorder = hc
        ? (dark ? const Color(0x99FFFFFF) : const Color(0x990F2A4D))
        : (dark ? const Color(0x24FFFFFF) : const Color(0x260F2A4D));
    final secondaryFill = dark
        ? const [Color(0x1AFFFFFF), Color(0x08FFFFFF)]
        : const [Color(0xFFFFFFFF), Color(0xFFF2F6FB)];
    const buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(AppScale.radiusButton)),
    );
    const minSize = Size(44, 40);

    // Primario arancione: sfumatura, rilievo interno e ombra neutra.
    Widget orangeBackground(
      BuildContext context,
      Set<WidgetState> states,
      Widget? child,
    ) {
      final disabled = states.contains(WidgetState.disabled);
      return DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppScale.radiusButton),
          gradient: disabled
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: t.orangeGradient,
                  stops: const [0, 0.52, 1],
                ),
          color: disabled ? t.textMuted.withValues(alpha: 0.18) : null,
          boxShadow: disabled
              ? null
              : const [
                  BoxShadow(
                    color: Color(0xBF000000),
                    offset: Offset(0, 6),
                    blurRadius: 14,
                    spreadRadius: -8,
                  ),
                ],
        ),
        // Rilievo: luce in alto e ombra in basso (bordo uniforme con raggio).
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppScale.radiusButton),
            gradient: disabled
                ? null
                : const LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0xBFFFECD2),
                      Color(0x00FFECD2),
                      Color(0x00963C00),
                      Color(0x59963C00),
                    ],
                    stops: [0, 0.07, 0.88, 1],
                  ),
          ),
          child: child,
        ),
      );
    }

    Widget glassBackground(
      BuildContext context,
      Set<WidgetState> states,
      Widget? child,
    ) => DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppScale.radiusButton),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: secondaryFill,
        ),
        border: Border.all(color: secondaryBorder),
      ),
      child: child,
    );

    final fieldFill = hc
        ? (dark ? const Color(0x1FFFFFFF) : Colors.white)
        : (dark ? const Color(0x0DFFFFFF) : const Color(0xCCFFFFFF));
    final fieldBorder = hc
        ? (dark ? const Color(0x99A0CDFF) : const Color(0x990F2A4D))
        : (dark ? const Color(0x24A0CDFF) : const Color(0x260F2A4D));
    OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppScale.radiusButton),
      borderSide: BorderSide(color: c, width: w),
    );

    return ThemeData(
      brightness: b,
      colorScheme: scheme,
      useMaterial3: true,
      fontFamily: fontFamily,
      textTheme: text,
      primaryTextTheme: text,
      extensions: [t],
      scaffoldBackgroundColor: Colors.transparent,
      canvasColor: scheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,
      splashFactory: InkSparkle.splashFactory,
      // transizioni uguali in tutta l'app, ferme con «Riduci animazioni»
      pageTransitionsTheme: kCalmPageTransitions,
      dividerTheme: DividerThemeData(
        color: t.cardBorder,
        thickness: 1,
        space: 1,
      ),
      iconTheme: IconThemeData(color: t.textSecondary, size: 22),
      // Menu a tendina larghi quanto il campo, con le voci allineate al testo
      // del campo (senza, sporgono di qualche pixel ai lati).
      buttonTheme: ButtonThemeData(colorScheme: scheme, alignedDropdown: true),
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        foregroundColor: t.textPrimary,
        titleTextStyle: s(17, FontWeight.w600),
        // Fondo trasparente: senza questo le icone restano chiare anche sul
        // tema chiaro.
        systemOverlayStyle: overlayStyle(b),
      ),
      cardTheme: CardThemeData(
        color: dark ? const Color(0xE60F1D31) : const Color(0xF2FFFFFF),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppScale.radiusCard),
          side: BorderSide(color: t.cardBorder),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundBuilder: orangeBackground,
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? t.textMuted : t.onOrange,
          ),
          overlayColor: WidgetStatePropertyAll(
            t.onOrange.withValues(alpha: 0.08),
          ),
          shape: const WidgetStatePropertyAll(buttonShape),
          minimumSize: const WidgetStatePropertyAll(minSize),
          padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          ),
          textStyle: WidgetStatePropertyAll(s(13, FontWeight.w700)),
          elevation: const WidgetStatePropertyAll(0),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          backgroundBuilder: glassBackground,
          backgroundColor: const WidgetStatePropertyAll(Colors.transparent),
          foregroundColor: WidgetStatePropertyAll(t.textPrimary),
          shadowColor: const WidgetStatePropertyAll(Colors.transparent),
          elevation: const WidgetStatePropertyAll(0),
          shape: const WidgetStatePropertyAll(buttonShape),
          minimumSize: const WidgetStatePropertyAll(minSize),
          textStyle: WidgetStatePropertyAll(s(13, FontWeight.w600)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          backgroundBuilder: glassBackground,
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) =>
                s.contains(WidgetState.disabled) ? t.textMuted : t.textPrimary,
          ),
          side: const WidgetStatePropertyAll(BorderSide.none),
          shape: const WidgetStatePropertyAll(buttonShape),
          minimumSize: const WidgetStatePropertyAll(minSize),
          textStyle: WidgetStatePropertyAll(s(13, FontWeight.w600)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(t.cyan),
          shape: const WidgetStatePropertyAll(buttonShape),
          minimumSize: const WidgetStatePropertyAll(minSize),
          textStyle: WidgetStatePropertyAll(s(13, FontWeight.w600)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(t.textSecondary),
          minimumSize: const WidgetStatePropertyAll(Size(44, 44)),
        ),
      ),
      // Flottante: stesso arancione, l'unico con l'alone (galleggia sul contenuto).
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: t.orangeGradient[1],
        foregroundColor: t.onOrange,
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        extendedTextStyle: s(13, FontWeight.w700),
        shape: const StadiumBorder(),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: fieldFill,
        border: field(fieldBorder),
        enabledBorder: field(fieldBorder),
        focusedBorder: field(t.cyan, 1.5),
        errorBorder: field(scheme.error),
        labelStyle: s(13, FontWeight.w400, color: t.textMuted),
        hintStyle: s(13, FontWeight.w400, color: t.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 12,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: dark
            ? const Color(0x0FFFFFFF)
            : const Color(0xCCFFFFFF),
        selectedColor: t.navActive.first,
        side: BorderSide(color: secondaryBorder),
        labelStyle: s(13, FontWeight.w500, color: t.textSecondary),
        secondaryLabelStyle: s(13, FontWeight.w600, color: t.navActiveText),
        shape: const StadiumBorder(),
        checkmarkColor: t.navActiveText,
        iconTheme: IconThemeData(color: t.cyanSoft, size: 18),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? t.navActive.first
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected)
                ? t.navActiveText
                : t.textSecondary,
          ),
          side: WidgetStatePropertyAll(BorderSide(color: secondaryBorder)),
          textStyle: WidgetStatePropertyAll(s(13, FontWeight.w600)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        iconColor: t.textSecondary,
        titleTextStyle: s(15, FontWeight.w500),
        subtitleTextStyle: s(13, FontWeight.w400, color: t.textMuted),
      ),
      // Finestre, card dal basso e menu: stesso materiale di vetro delle
      // sezioni-card (vedi GlassBorder), non un fondo piatto.
      dialogTheme: DialogThemeData(
        backgroundColor: dark ? const Color(0xFF0B1729) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 16,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.9 : 0.25),
        barrierColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.35),
        shape: GlassBorder(
          tokens: t,
          dark: dark,
          borderRadius: BorderRadius.circular(AppScale.radiusCard),
        ),
        titleTextStyle: s(17, FontWeight.w600),
        contentTextStyle: s(
          13,
          FontWeight.w400,
          color: t.textSecondary,
          height: 1.45,
        ),
      ),
      // Card che salgono dal basso: vetro come le sezioni-card, angoli
      // ampi, maniglia azzurra, ombra e fondo scurito; su PC larghe al
      // massimo 680 px e centrate invece che a tutta finestra.
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: dark
            ? const Color(0xFF0C1A2E)
            : const Color(0xFFF8FBFF),
        modalBackgroundColor: dark
            ? const Color(0xFF0C1A2E)
            : const Color(0xFFF8FBFF),
        surfaceTintColor: Colors.transparent,
        shape: GlassBorder(
          tokens: t,
          dark: dark,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        ),
        showDragHandle: true,
        dragHandleColor: t.cyan.withValues(alpha: 0.7),
        dragHandleSize: const Size(44, 5),
        elevation: 12,
        modalElevation: 12,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        modalBarrierColor: Colors.black.withValues(alpha: dark ? 0.6 : 0.4),
        constraints: const BoxConstraints(maxWidth: 680),
        clipBehavior: Clip.antiAlias,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: dark ? const Color(0xFF0F1D31) : Colors.white,
        surfaceTintColor: Colors.transparent,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.9 : 0.25),
        shape: GlassBorder(
          tokens: t,
          dark: dark,
          spotlight: false,
          borderRadius: BorderRadius.circular(AppScale.radiusInner),
        ),
        textStyle: s(13, FontWeight.w500),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: dark
            ? const Color(0xFF132339)
            : const Color(0xFF0F1D31),
        contentTextStyle: s(
          13,
          FontWeight.w500,
          color: const Color(0xFFF3F7FB),
        ),
        actionTextColor: const Color(0xFF7DD3FC),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppScale.radiusButton),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: t.cyan,
        linearTrackColor: t.textPrimary.withValues(alpha: 0.09),
        circularTrackColor: Colors.transparent,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? Colors.white : t.textMuted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? t.cyan
              : t.textPrimary.withValues(alpha: 0.12),
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? t.cyan : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: t.textMuted, width: 1.5),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: t.navActiveText,
        unselectedLabelColor: t.textMuted,
        indicatorColor: t.cyan,
        dividerColor: t.cardBorder,
        labelStyle: s(13, FontWeight.w600),
        unselectedLabelStyle: s(13, FontWeight.w500),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        indicatorColor: t.navActive.first,
        selectedIconTheme: IconThemeData(color: t.navActiveText),
        unselectedIconTheme: IconThemeData(color: t.textMuted),
        selectedLabelTextStyle: s(11, FontWeight.w600, color: t.navActiveText),
        unselectedLabelTextStyle: s(11, FontWeight.w500, color: t.textMuted),
      ),
      expansionTileTheme: ExpansionTileThemeData(
        iconColor: t.cyan,
        collapsedIconColor: t.textMuted,
        textColor: t.textPrimary,
        collapsedTextColor: t.textPrimary,
        shape: const Border(),
        collapsedShape: const Border(),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF182A42) : const Color(0xFF0F1D31),
          borderRadius: BorderRadius.circular(AppScale.radiusSmall),
        ),
        textStyle: s(11, FontWeight.w500, color: const Color(0xFFF3F7FB)),
      ),
      datePickerTheme: DatePickerThemeData(
        backgroundColor: dark ? const Color(0xFF0B1729) : Colors.white,
        surfaceTintColor: Colors.transparent,
        shape: GlassBorder(
          tokens: t,
          dark: dark,
          spotlight: false,
          borderRadius: BorderRadius.circular(AppScale.radiusCard),
        ),
      ),
      timePickerTheme: TimePickerThemeData(
        backgroundColor: dark ? const Color(0xFF0B1729) : Colors.white,
        shape: GlassBorder(
          tokens: t,
          dark: dark,
          spotlight: false,
          borderRadius: BorderRadius.circular(AppScale.radiusCard),
        ),
      ),
    );
  }
}

/// Larghezza oltre la quale si usa il layout desktop (NavigationRail, più colonne).
const double kWideLayoutBreakpoint = 840;

extension LayoutContext on BuildContext {
  bool get isWide => MediaQuery.sizeOf(this).width >= kWideLayoutBreakpoint;
}
