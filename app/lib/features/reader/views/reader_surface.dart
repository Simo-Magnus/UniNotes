import 'package:flutter/material.dart';

/// Colori della "pagina" dei documenti: superficie di lettura piena (non
/// vetro), calda nel tema chiaro e blu notte in quello scuro.
@immutable
class ReaderSurface {
  const ReaderSurface._({
    required this.background,
    required this.text,
    required this.muted,
    required this.rule,
    required this.tableHeader,
    required this.tableBorder,
    required this.link,
    required this.codeBackground,
  });

  final Color background;
  final Color text;
  final Color muted;
  final Color rule;
  final Color tableHeader;
  final Color tableBorder;
  final Color link;
  final Color codeBackground;

  static const dark = ReaderSurface._(
    background: Color(0xFF0B1320),
    text: Color(0xFFE3E9F1),
    muted: Color(0xFF8FA9C4),
    rule: Color(0x29A0CDFF),
    tableHeader: Color(0x1438BDF8),
    tableBorder: Color(0x24A0CDFF),
    link: Color(0xFF7DD3FC),
    codeBackground: Color(0x0FFFFFFF),
  );

  static const light = ReaderSurface._(
    background: Color(0xFFFBF9F4),
    text: Color(0xFF1B2330),
    muted: Color(0xFF5B708A),
    rule: Color(0x1F0B2545),
    tableHeader: Color(0x140EA5E9),
    tableBorder: Color(0x260B2545),
    link: Color(0xFF0369A1),
    codeBackground: Color(0x0A0B2545),
  );

  static ReaderSurface of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? dark : light;
}
