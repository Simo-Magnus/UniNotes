import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show SpellCheckService, SuggestionSpan, rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../widgets/find_bar.dart';
import '../../widgets/math_text.dart';
import '../reader/reader_text.dart';
import 'markdown_lite.dart';
import 'spell_check.dart';

/// Colore dell'evidenziatore (concetti chiave): giallo da evidenziatore,
/// distinto dall'arancione delle azioni.
Color highlightColor(Brightness b) =>
    b == Brightness.dark ? const Color(0x59F5D04C) : const Color(0x80FFE45C);

/// Colori della ricerca: tutti i risultati e quello attivo.
Color findMatchColor(Brightness b) =>
    b == Brightness.dark ? const Color(0x6638BDF8) : const Color(0x5538BDF8);
Color findActiveColor(Brightness b) =>
    b == Brightness.dark ? const Color(0xFFF97316) : const Color(0xFFFDBA74);

/// Indici (inizio) delle occorrenze di [query] in [text], senza maiuscole
/// né accenti ("perche" trova "perché"), come nel lettore.
List<int> findOccurrences(String text, String query) => findFolded(text, query);

/// Vista del Markdown essenziale (trascrizioni, riassunti, appunti), con il
/// testo selezionabile e copiabile. Con [query] evidenzia i risultati della
/// ricerca; quello di indice [activeMatch] riceve [activeKey] (per portarlo
/// in vista).
///
/// Con [spellLanguage] ('it' o 'en') le parole errate hanno la linea
/// ondulata rossa del controllo ortografico anche in lettura
/// ([ReadingSpellChecker], un blocco di testo alla volta; formule e codice
/// non si controllano); senza, il testo non si controlla (es. risposte
/// dell'AI).
class MarkdownLiteView extends StatefulWidget {
  const MarkdownLiteView(
    this.text, {
    super.key,
    this.padding,
    this.query,
    this.activeMatch,
    this.activeKey,
    this.scrollController,
    this.spellLanguage,
    this.spellService,
  });
  final String text;
  final EdgeInsets? padding;
  final String? query;
  final int? activeMatch;
  final GlobalKey? activeKey;
  final ScrollController? scrollController;

  /// Lingua principale del controllo ortografico in lettura (null = nessun
  /// controllo).
  final String? spellLanguage;

  /// Servizio del controllo ortografico al posto di quello del sistema (per
  /// i test).
  final SpellCheckService? spellService;

  /// Testi cercabili nell'ordine di visualizzazione (stesso conteggio di
  /// build). Le formule sono disegni, non testo: non si cercano.
  static Iterable<String> _searchable(List<MdBlock> blocks) sync* {
    for (final b in blocks) {
      if (b.type == MdBlockType.code) {
        yield b.raw ?? '';
      } else if (b.type != MdBlockType.math) {
        for (final s in b.spans) {
          if (!s.math) yield s.text;
        }
      }
    }
  }

  /// Numero di risultati di [query] nel testo visualizzato.
  static int countMatches(String text, String query) => query.trim().isEmpty
      ? 0
      : _searchable(parseMarkdown(text))
            .fold(0, (n, t) => n + findOccurrences(t, query).length);

  @override
  State<MarkdownLiteView> createState() => _MarkdownLiteViewState();
}

class _MarkdownLiteViewState extends State<MarkdownLiteView> {
  /// Controllo ortografico in lettura (null = nessun controllo).
  ReadingSpellChecker? _checker;

  @override
  void initState() {
    super.initState();
    _syncChecker();
  }

  @override
  void didUpdateWidget(MarkdownLiteView old) {
    super.didUpdateWidget(old);
    if (old.spellService != widget.spellService) {
      _checker?.dispose();
      _checker = null;
    }
    _syncChecker();
  }

  void _syncChecker() {
    final language = widget.spellLanguage;
    if (language == null) {
      _checker?.dispose();
      _checker = null;
    } else if (_checker == null) {
      _checker = ReadingSpellChecker(
        language: language,
        service: widget.spellService,
      )..addListener(_spellChanged);
    } else {
      _checker!.language = language;
    }
  }

  void _spellChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _checker?.dispose();
    super.dispose();
  }

  /// Il testo di un blocco per il controllo ortografico: i tratti di testo
  /// uno dopo l'altro (così una parola in parte in grassetto resta una
  /// parola) con uno spazio al posto di formule e di codice. [starts] dà
  /// dove comincia ogni tratto.
  (String, List<int>) _blockText(List<MdSpan> list) {
    final b = StringBuffer();
    final starts = <int>[];
    for (final s in list) {
      starts.add(b.length);
      b.write(s.math || s.code ? ' ' * (s.math ? 1 : s.text.length) : s.text);
    }
    return (b.toString(), starts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = theme.textTheme;
    final blocks = parseMarkdown(widget.text);
    final q = widget.query ?? '';
    final activeMatch = widget.activeMatch;
    var counter = 0;
    var activeHere = false;

    // Spezza un testo nei risultati della ricerca (evidenziati) e nelle
    // parole errate ([errors] sono nelle posizioni di un testo più grande
    // in cui [text] comincia a [offset]).
    List<InlineSpan> split(
      String text,
      TextStyle? style, {
      List<SuggestionSpan> errors = const [],
      int offset = 0,
    }) {
      final hits = findOccurrences(text, q);
      if (hits.isEmpty) {
        return errors.isEmpty
            ? [TextSpan(text: text, style: style)]
            : misspelledSpans(text, errors, style: style, offset: offset);
      }
      final out = <InlineSpan>[];
      var i = 0;
      for (final j in hits) {
        if (j > i) {
          out.addAll(
            misspelledSpans(
              text,
              errors,
              style: style,
              start: i,
              end: j,
              offset: offset,
            ),
          );
        }
        final active = counter == activeMatch;
        if (active) activeHere = true;
        out.addAll(
          misspelledSpans(
            text,
            errors,
            style: (style ?? const TextStyle()).copyWith(
              backgroundColor: active
                  ? findActiveColor(theme.brightness)
                  : findMatchColor(theme.brightness),
            ),
            start: j,
            end: j + q.length,
            offset: offset,
          ),
        );
        counter++;
        i = j + q.length;
      }
      if (i < text.length) {
        out.addAll(
          misspelledSpans(
            text,
            errors,
            style: style,
            start: i,
            offset: offset,
          ),
        );
      }
      return out;
    }

    TextSpan spans(List<MdSpan> list, TextStyle base) {
      final checker = _checker;
      final (block, starts) = checker == null
          ? ('', const <int>[])
          : _blockText(list);
      final errors = checker == null
          ? const <SuggestionSpan>[]
          : checker.errorsOf(block);
      return TextSpan(
        style: base,
        children: [
          for (final (i, s) in list.indexed)
            if (s.math)
              mathSpan(
                s,
                base.copyWith(
                  fontWeight: s.bold ? FontWeight.w700 : null,
                  backgroundColor: s.highlight
                      ? highlightColor(theme.brightness)
                      : null,
                ),
              )
            else
              ...split(
                s.text,
                TextStyle(
                  fontWeight: s.bold ? FontWeight.w700 : null,
                  fontStyle: s.italic ? FontStyle.italic : null,
                  fontFamily: s.code ? 'IBMPlexMono' : null,
                  backgroundColor: s.highlight
                      ? highlightColor(theme.brightness)
                      : (s.code
                            ? theme.colorScheme.surfaceContainerHighest
                            : null),
                ),
                errors: s.code ? const [] : errors,
                offset: i < starts.length ? starts[i] : 0,
              ),
        ],
      );
    }

    final body = t.bodyLarge!.copyWith(height: 1.55);
    final children = <Widget>[];
    for (final b in blocks) {
      activeHere = false;
      final Widget w;
      switch (b.type) {
        case MdBlockType.heading:
          final style = switch (b.level) {
            1 => t.headlineSmall,
            2 => t.titleLarge,
            3 => t.titleMedium,
            _ => t.titleSmall,
          }!.copyWith(fontWeight: FontWeight.w700);
          w = Padding(
            padding: EdgeInsets.only(top: b.level <= 2 ? 20 : 14, bottom: 6),
            child: Text.rich(spans(b.spans, style)),
          );
        case MdBlockType.paragraph:
          w = Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text.rich(spans(b.spans, body)),
          );
        case MdBlockType.bullet || MdBlockType.numbered:
          w = Padding(
            padding: EdgeInsets.only(left: 6.0 + 18 * b.level, bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 22,
                  child: Text(
                    b.type == MdBlockType.numbered ? '${b.number}.' : '•',
                    style: body.copyWith(color: theme.colorScheme.primary),
                  ),
                ),
                Expanded(child: Text.rich(spans(b.spans, body))),
              ],
            ),
          );
        case MdBlockType.quote:
          w = Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(color: theme.colorScheme.primary, width: 3),
              ),
            ),
            child: Text.rich(
              spans(b.spans, body.copyWith(fontStyle: FontStyle.italic)),
            ),
          );
        case MdBlockType.rule:
          w = const Divider(height: 28);
        case MdBlockType.math:
          w = Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: MathBlock(b.raw ?? '', style: body),
          );
        case MdBlockType.code:
          final code = body.copyWith(fontFamily: 'IBMPlexMono', fontSize: 13);
          w = Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text.rich(
              TextSpan(style: code, children: split(b.raw ?? '', null)),
            ),
          );
      }
      children.add(
        activeHere && widget.activeKey != null
            ? KeyedSubtree(key: widget.activeKey, child: w)
            : w,
      );
    }
    // Colonna (non lista pigra): il risultato attivo deve esistere per
    // poterlo portare in vista anche se è lontano.
    return SelectionArea(
      child: SingleChildScrollView(
        controller: widget.scrollController,
        padding: widget.padding ?? const EdgeInsets.fromLTRB(20, 12, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }
}

/// Markdown con ricerca: Ctrl+F (o [openFind], es. dal pulsante nella barra)
/// apre la barra "Trova nel testo" con evidenziazione e precedente/successivo.
class SearchableMarkdownView extends StatefulWidget {
  const SearchableMarkdownView(
    this.text, {
    super.key,
    this.padding,
    this.initialQuery,
    this.spellLanguage,
    this.spellService,
  });
  final String text;
  final EdgeInsets? padding;

  /// Lingua principale del controllo ortografico in lettura (null = nessun
  /// controllo), vedi [MarkdownLiteView].
  final String? spellLanguage;

  /// Servizio del controllo ortografico al posto di quello del sistema (per
  /// i test).
  final SpellCheckService? spellService;

  /// Ricerca già aperta con questo testo (es. arrivando da una ricerca
  /// nell'elenco dei file).
  final String? initialQuery;

  @override
  State<SearchableMarkdownView> createState() => SearchableMarkdownViewState();
}

class SearchableMarkdownViewState extends State<SearchableMarkdownView> {
  final _query = TextEditingController();
  final _focus = FocusNode();
  final _activeKey = GlobalKey();
  bool _open = false;
  int _total = 0;
  int? _current;

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      _open = true;
      _query.text = q;
      _total = MarkdownLiteView.countMatches(widget.text, q);
      _current = _total == 0 ? null : 0;
      _reveal();
    }
  }

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  void openFind() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  void _close() => setState(() {
    _open = false;
    _current = null;
  });

  void _search(String q) {
    final n = MarkdownLiteView.countMatches(widget.text, q.trim());
    setState(() {
      _total = n;
      _current = n == 0 ? null : 0;
    });
    _reveal();
  }

  void _step(int d) {
    if (_total == 0) return;
    setState(() => _current = ((_current ?? -d) + d) % _total);
    _reveal();
  }

  void _reveal() => WidgetsBinding.instance.addPostFrameCallback((_) {
    final c = _activeKey.currentContext;
    if (c != null && c.mounted) {
      Scrollable.ensureVisible(
        c,
        alignment: 0.3,
        duration: const Duration(milliseconds: 200),
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final q = _open ? _query.text.trim() : '';
    return FindShortcuts(
      onFind: openFind,
      onClose: _close,
      child: Column(
        children: [
          if (_open)
            FindBar(
              controller: _query,
              focusNode: _focus,
              onChanged: _search,
              onNext: () => _step(1),
              onPrevious: () => _step(-1),
              onClose: _close,
              total: _total,
              current: _current,
            ),
          Expanded(
            child: MarkdownLiteView(
              widget.text,
              padding: widget.padding,
              query: q,
              activeMatch: _current,
              activeKey: _activeKey,
              spellLanguage: widget.spellLanguage,
              spellService: widget.spellService,
            ),
          ),
        ],
      ),
    );
  }
}

/// PDF A4 dal Markdown (grassetto, corsivo, evidenziato, titoli, elenchi),
/// con i caratteri IBM Plex inclusi nell'app.
Future<List<int>> markdownToPdf(
  String text, {
  required String title,
  String? subtitle,
}) async {
  Future<pw.Font> font(String name) async =>
      pw.Font.ttf(await rootBundle.load('assets/fonts/$name.ttf'));
  final regular = await font('IBMPlexSans-Regular');
  final bold = await font('IBMPlexSans-Bold');
  final italic = await font('IBMPlexSans-Italic');
  final semi = await font('IBMPlexSans-SemiBold');
  final mono = await font('IBMPlexMono-Regular');
  final ink = PdfColor.fromHex('#16202B');
  final accent = PdfColor.fromHex('#0B6FA4');
  final mark = PdfColor.fromHex('#FFE45C');

  pw.TextSpan spans(List<MdSpan> list, pw.TextStyle base) => pw.TextSpan(
    style: base,
    children: [
      for (final s in list)
        pw.TextSpan(
          // formule: il LaTeX così com'è, in carattere monospaziato
          text: s.source,
          style: pw.TextStyle(
            font: s.code || s.math
                ? mono
                : (s.bold ? bold : (s.italic ? italic : null)),
            background: s.highlight ? pw.BoxDecoration(color: mark) : null,
          ),
        ),
    ],
  );

  final body = pw.TextStyle(
    font: regular,
    fontSize: 10.5,
    lineSpacing: 3,
    color: ink,
  );
  final doc = pw.Document(title: title, author: 'UniNotes');
  final widgets = <pw.Widget>[
    pw.Text(
      title,
      style: pw.TextStyle(font: bold, fontSize: 20, color: ink),
    ),
    if (subtitle != null)
      pw.Padding(
        padding: const pw.EdgeInsets.only(top: 4),
        child: pw.Text(
          subtitle,
          style: body.copyWith(color: PdfColors.grey700),
        ),
      ),
    pw.SizedBox(height: 14),
  ];
  for (final b in parseMarkdown(text)) {
    switch (b.type) {
      case MdBlockType.heading:
        final size = switch (b.level) {
          1 => 17.0,
          2 => 14.5,
          3 => 12.5,
          _ => 11.5,
        };
        widgets.add(
          pw.Padding(
            padding: pw.EdgeInsets.only(top: b.level <= 2 ? 14 : 10, bottom: 4),
            child: pw.RichText(
              text: spans(
                b.spans,
                body.copyWith(
                  font: semi,
                  fontSize: size,
                  color: b.level <= 2 ? accent : ink,
                ),
              ),
            ),
          ),
        );
      case MdBlockType.paragraph:
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 7),
            child: pw.RichText(text: spans(b.spans, body)),
          ),
        );
      case MdBlockType.bullet || MdBlockType.numbered:
        widgets.add(
          pw.Padding(
            padding: pw.EdgeInsets.only(left: 4.0 + 14 * b.level, bottom: 4),
            child: pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.SizedBox(
                  width: 16,
                  child: pw.Text(
                    b.type == MdBlockType.numbered ? '${b.number}.' : '•',
                    style: body.copyWith(color: accent),
                  ),
                ),
                pw.Expanded(child: pw.RichText(text: spans(b.spans, body))),
              ],
            ),
          ),
        );
      case MdBlockType.quote:
        widgets.add(
          pw.Container(
            margin: const pw.EdgeInsets.only(bottom: 7),
            padding: const pw.EdgeInsets.only(left: 8),
            decoration: pw.BoxDecoration(
              border: pw.Border(left: pw.BorderSide(color: accent, width: 2)),
            ),
            child: pw.RichText(
              text: spans(b.spans, body.copyWith(font: italic)),
            ),
          ),
        );
      case MdBlockType.rule:
        widgets.add(pw.Divider(color: PdfColors.grey400, thickness: 0.5));
      case MdBlockType.math:
        widgets.add(
          pw.Padding(
            padding: const pw.EdgeInsets.only(bottom: 7),
            child: pw.Center(
              child: pw.Text(
                '\$\$${b.raw ?? ''}\$\$',
                style: body.copyWith(font: mono, fontSize: 9.5),
              ),
            ),
          ),
        );
      case MdBlockType.code:
        widgets.add(
          pw.Container(
            width: double.infinity,
            margin: const pw.EdgeInsets.only(bottom: 7),
            padding: const pw.EdgeInsets.all(8),
            color: PdfColors.grey100,
            child: pw.Text(
              b.raw ?? '',
              style: body.copyWith(font: mono, fontSize: 9.5),
            ),
          ),
        );
    }
  }
  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(48, 44, 48, 44),
      theme: pw.ThemeData.withFont(base: regular, bold: bold, italic: italic),
      footer: (c) => pw.Align(
        alignment: pw.Alignment.centerRight,
        child: pw.Text(
          '${c.pageNumber} / ${c.pagesCount}',
          style: body.copyWith(fontSize: 8.5, color: PdfColors.grey600),
        ),
      ),
      build: (_) => widgets,
    ),
  );
  return doc.save();
}
