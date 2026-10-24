import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../features/notes/markdown_lite.dart';

/// Lunghezza massima (in caratteri) di una formula disegnata: oltre, il
/// testo resta testo.
const int kMaxFormulaChars = 3000;

/// Formula LaTeX disegnata con flutter_math_fork. Con un errore di
/// sintassi (o un comando non supportato) mostra il testo originale, senza
/// mai interrompere la pagina.
class MathFormula extends StatelessWidget {
  const MathFormula(
    this.tex, {
    super.key,
    this.display = false,
    this.style,
    this.source,
  });

  final String tex;

  /// Stile «a sé» (più grande, frazioni e somme distese).
  final bool display;
  final TextStyle? style;

  /// Testo da mostrare se la formula non si legge (predefinito: il LaTeX
  /// con i suoi delimitatori).
  final String? source;

  @override
  Widget build(BuildContext context) {
    final base = DefaultTextStyle.of(context).style.merge(style);
    final fallback = source ?? (display ? '\$\$$tex\$\$' : '\$$tex\$');
    // Il disegno cresce più che linearmente con la lunghezza (16 000
    // caratteri bloccano l'interfaccia per diversi secondi, 200 000 per
    // sempre): una «formula» così lunga è un testo incollato per errore tra
    // due dollari, e si mostra com'è.
    if (tex.length > kMaxFormulaChars) {
      return Text(fallback, style: base.copyWith(fontFamily: 'IBMPlexMono'));
    }
    final math = Math.tex(
      tex,
      mathStyle: display ? MathStyle.display : MathStyle.text,
      textStyle: base,
      onErrorFallback: (_) => Text(
        fallback,
        style: base.copyWith(
          fontFamily: 'IBMPlexMono',
          color: Theme.of(context).colorScheme.error,
        ),
      ),
    );
    return Semantics(
      label: 'Formula: $tex',
      excludeSemantics: true,
      // Una formula più larga dello spazio (in una riga di testo non si
      // spezza) si rimpicciolisce invece di uscire dal bordo (RenderFlex
      // overflowed); se è più stretta resta com'è. Quando non si legge il
      // testo di ripiego resta testo, che va a capo.
      child: math.parseError != null
          ? math
          : FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: math,
            ),
    );
  }
}

/// Formula su righe proprie: centrata, scorre in orizzontale se è più
/// larga dello spazio.
class MathBlock extends StatelessWidget {
  const MathBlock(this.tex, {super.key, this.style});
  final String tex;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, c) => SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: c.maxWidth),
            child: Center(child: MathFormula(tex, display: true, style: style)),
          ),
        ),
      ),
    );
  }
}

/// Tratto di testo di una formula in linea (dentro un Text.rich).
InlineSpan mathSpan(MdSpan s, TextStyle? style) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: MathFormula(
    s.text,
    display: s.display,
    style: style,
    source: s.source,
  ),
);

/// Il testo potrebbe contenere una formula (controllo veloce prima di
/// analizzarlo).
bool mayContainMath(String text) =>
    text.contains(r'$') || text.contains(r'\(') || text.contains(r'\[');

/// Testo semplice (descrizioni, programmi, note di argomenti ed esami) con
/// le formule `$…$`, `$$…$$`, `\(…\)`, `\[…\]` disegnate; il resto resta
/// com'è scritto, a capo compresi. Senza formule è un normale [Text].
class MathText extends StatelessWidget {
  const MathText(
    this.text, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
  });

  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    if (!mayContainMath(text)) {
      return Text(
        text,
        style: style,
        maxLines: maxLines,
        overflow: overflow,
        textAlign: textAlign,
      );
    }
    final lines = text.replaceAll('\r\n', '\n').split('\n');
    final children = <InlineSpan>[];
    for (var i = 0; i < lines.length; i++) {
      if (i > 0) children.add(const TextSpan(text: '\n'));
      for (final s in parseMathOnly(lines[i])) {
        children.add(s.math ? mathSpan(s, style) : TextSpan(text: s.text));
      }
    }
    return Text.rich(
      TextSpan(style: style, children: children),
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
    );
  }
}
