import 'package:flutter/painting.dart';

/// Decisioni del riquadro «Registrazione in corso» sopra le schermate e del
/// tasto Indietro: funzioni pure (test in test/recorder_logic_test.dart).

/// Il riquadro si vede quando si registra (anche in pausa) e la schermata
/// del registratore non è aperta. Durante il salvataggio resta, con
/// l'indicazione «Salvo…».
bool showRecordingPill({
  required bool recording,
  required bool recorderVisible,
  bool saving = false,
}) => (recording || saving) && !recorderVisible;

/// Il riquadro della sessione Focus si vede durante la sessione (anche in
/// pausa) quando la sua schermata non è aperta.
bool showFocusPill({required bool active, required bool screenVisible}) =>
    active && !screenVisible;

/// Cosa fa «Indietro» nella schermata principale dell'app.
enum RootBack {
  /// Da una sezione si torna alla Home.
  home,

  /// Dalla Home con una registrazione in corso (Android): l'app va in
  /// background e la registrazione continua.
  background,

  /// Dalla Home senza registrazione: si esce come sempre.
  exit,
}

RootBack rootBackAction({
  required int index,
  required bool recording,
  required bool android,
}) {
  if (index != 0) return RootBack.home;
  if (recording && android) return RootBack.background;
  return RootBack.exit;
}

/// Spazio tenuto libero sotto il riquadro sul telefono (barra di
/// navigazione in basso).
const double kPillBottomReserve = 76;

/// Larghezza della maniglia per ridimensionare, a destra dei riquadri.
const double kPillHandleWidth = 24;

/// Larghezza minima del riquadro: pallino, livello e tre pulsanti da 48 px
/// restano visibili (il testo si accorcia fino a sparire).
const double kPillMinWidth = 232;

/// Larghezza massima (e predefinita) del riquadro.
const double kPillMaxWidth = 400;

/// Larghezza del riquadro: quella scelta con la maniglia ([chosen], null =
/// predefinita) entro il minimo e lo spazio dello schermo.
double pillWidth(double? chosen, double screenWidth) {
  final max = (screenWidth - 24 - kPillHandleWidth).clamp(
    kPillMinWidth,
    kPillMaxWidth,
  );
  final v = chosen ?? max;
  return v < kPillMinWidth ? kPillMinWidth : (v > max ? max : v);
}

/// Posizione iniziale: in alto al centro, sotto la barra del titolo (lontano
/// dal pulsante «Registra» e dalla barra in basso).
Offset defaultPillOffset(Size screen, Size pill, EdgeInsets safe) {
  const toolbar = 56.0;
  final x = (screen.width - pill.width) / 2;
  final y = safe.top + toolbar + 8;
  return clampPillOffset(Offset(x, y), screen, pill, safe: safe);
}

/// Il riquadro trascinato resta dentro lo schermo, nelle aree sicure (notch,
/// barra di stato, barra dei gesti) e sopra la barra di navigazione.
Offset clampPillOffset(
  Offset o,
  Size screen,
  Size pill, {
  EdgeInsets safe = EdgeInsets.zero,
  double margin = 8,
  double bottomReserve = 0,
}) {
  final minX = safe.left + margin;
  final maxX = screen.width - safe.right - margin - pill.width;
  final minY = safe.top + margin;
  final maxY =
      screen.height - safe.bottom - margin - bottomReserve - pill.height;
  double clamp(double v, double lo, double hi) =>
      hi < lo ? lo : (v < lo ? lo : (v > hi ? hi : v));
  return Offset(clamp(o.dx, minX, maxX), clamp(o.dy, minY, maxY));
}

/// Scelta nel dialogo «Salvare la registrazione?».
enum RecordingCloseChoice { save, delete, cancel }
