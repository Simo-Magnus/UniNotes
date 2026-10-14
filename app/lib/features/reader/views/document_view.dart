import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/services/external_launcher.dart';
import '../../../core/theme/app_tokens.dart';
import '../../notes/markdown_view.dart' show findActiveColor, findMatchColor;
import '../reader_controller.dart';
import '../reader_document.dart';
import '../reader_text.dart';
import 'image_view.dart';
import 'pinch.dart';
import 'reader_surface.dart';

/// Elemento della lista: un blocco o l'intestazione di una sezione.
class _Item {
  const _Item(this.block, this.section, {this.header = false});
  final RBlock block;
  final int section;
  final bool header;
}

/// Risultato della ricerca: elemento, testo (cella) e intervallo.
class _Match {
  const _Match(this.item, this.text, this.start, this.end);
  final int item;
  final int text;
  final int start;
  final int end;
}

/// Vista dei documenti di testo ([RDoc]): lista pigra di blocchi su una
/// superficie di lettura, con ricerca (evidenziazione e salti precisi),
/// indice, unità (pagine, diapositive, fogli), dimensione del testo e
/// pizzico per ingrandire.
class DocumentView extends StatefulWidget {
  const DocumentView({
    super.key,
    required this.doc,
    required this.controller,
    this.initialPosition,
    this.onSeek,
    this.onLink,
    this.padding = const EdgeInsets.fromLTRB(20, 16, 20, 48),
  });

  final RDoc doc;
  final ReaderPaneController controller;
  final int? initialPosition;

  /// Tocco su un tempo (trascrizioni): salta nella registrazione.
  final ValueChanged<double>? onSeek;

  /// Collegamento che non è una pagina web (note di Obsidian, etichette,
  /// file relativi): lo gestisce il lettore.
  final ValueChanged<String>? onLink;
  final EdgeInsets padding;

  @override
  State<DocumentView> createState() => DocumentViewState();
}

class DocumentViewState extends State<DocumentView> {
  final _scroll = ScrollController();
  final _hScroll = ScrollController();
  final _list = ListController();
  final _activeKey = GlobalKey();
  final _recognizers = <String, TapGestureRecognizer>{};

  late List<_Item> _items;
  late List<int> _blockStart;
  late List<double> _tableWidths;
  List<List<String>?> _folded = const [];

  double _scale = 1;
  bool _fit = false;
  String _query = '';
  List<_Match> _matches = const [];
  Map<int, List<int>> _byItem = const {};
  int? _current;
  int _lastFirst = -1;

  ReaderPaneController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _build();
    _scroll.addListener(_onScroll);
    _register();
    final start = widget.initialPosition;
    if (start != null && start > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => jumpTo(start));
    }
  }

  @override
  void didUpdateWidget(DocumentView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.doc != widget.doc) {
      _build();
      if (_query.isNotEmpty) _find(_query);
    }
    if (oldWidget.controller != widget.controller) _register();
  }

  @override
  void dispose() {
    for (final r in _recognizers.values) {
      r.dispose();
    }
    _scroll.dispose();
    _hScroll.dispose();
    _list.dispose();
    super.dispose();
  }

  void _build() {
    final doc = widget.doc;
    final items = <_Item>[];
    final starts = <int>[];
    final headers = doc.sections.length > 1;
    final labelled = <int>{};
    for (var s = 0; s < doc.sections.length; s++) {
      final sec = doc.sections[s];
      if (headers) {
        items.add(
          _Item(
            RBreak(sec.title.isEmpty ? '${doc.unitLabel} ${s + 1}' : sec.title),
            s,
            header: true,
          ),
        );
      }
      starts.add(items.length);
      for (final b in sec.blocks) {
        items.add(_Item(b, s));
        if (b is RTableRow && b.label != null) labelled.add(b.table);
      }
    }
    _items = items;
    _blockStart = starts;
    _folded = List.filled(items.length, null);
    _tableWidths = [
      for (var t = 0; t < doc.tables.length; t++)
        doc.tables[t].columns.fold(0.0, (w, c) => w + _colWidth(c, 1)) +
            (labelled.contains(t) ? 44 : 0),
    ];
  }

  void _register() {
    final doc = widget.doc;
    _c.update(() {
      _c
        ..onFind = _find
        ..onStep = _step
        ..unitLabel = doc.unitLabel
        ..unitCount = doc.sections.length
        ..unit = 1
        ..onGoToUnit = ((u) => jumpTo(_sectionTop(u - 1)))
        ..onGoToPosition = jumpTo
        ..describe = _describe
        ..outline = [
          for (final e in doc.outline)
            if (e.section < _blockStart.length)
              ReaderTocItem(
                e.title,
                e.block == 0
                    ? _sectionTop(e.section)
                    : _blockStart[e.section] + e.block,
                level: e.level,
              ),
        ]
        ..onZoom = _zoom
        ..fitWidth = _fit
        ..onToggleFit = _toggleFit
        ..plainText = (() => doc.plainText);
    });
  }

  void _toggleFit() {
    setState(() => _fit = !_fit);
    _c.update(() => _c.fitWidth = _fit);
  }

  /// Primo elemento della sezione (l'intestazione, se c'è).
  int _sectionTop(int s) {
    if (s < 0 || s >= _blockStart.length) return 0;
    final start = _blockStart[s];
    return start > 0 &&
            _items[start - 1].header &&
            _items[start - 1].section == s
        ? start - 1
        : start;
  }

  String _describe(int position) {
    if (position < 0 || position >= _items.length) return '';
    final it = _items[position];
    final unit = widget.doc.sections.length > 1
        ? '${widget.doc.unitLabel} ${it.section + 1}'
        : null;
    var text = it.block.texts.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.length > 60) text = '${text.substring(0, 60)}…';
    return [?unit, if (text.isNotEmpty) text].join(' · ');
  }

  void _zoom(int dir) {
    setState(() {
      _scale = dir == 0
          ? 1
          : (_scale * (dir > 0 ? 1.1 : 1 / 1.1)).clamp(0.6, 3.0);
    });
  }

  // ------------------------------------------------------------- Ricerca

  List<String> _foldedOf(int i) =>
      _folded[i] ??= [for (final t in _items[i].block.texts) foldText(t)];

  void _find(String query) {
    final q = query.trim();
    final matches = <_Match>[];
    final byItem = <int, List<int>>{};
    if (q.isNotEmpty) {
      final len = q.length;
      for (var i = 0; i < _items.length; i++) {
        final texts = _items[i].block.texts;
        final folded = _foldedOf(i);
        for (var t = 0; t < texts.length; t++) {
          for (final s in findFolded(texts[t], q, foldedText: folded[t])) {
            byItem.putIfAbsent(i, () => []).add(matches.length);
            matches.add(_Match(i, t, s, s + len));
          }
        }
      }
    }
    // Il primo risultato dopo il punto in cui si sta leggendo.
    int? current;
    if (matches.isNotEmpty) {
      final first = _firstVisible();
      final after = matches.indexWhere((m) => m.item >= first);
      current = after < 0 ? 0 : after;
    }
    setState(() {
      _query = q;
      _matches = matches;
      _byItem = byItem;
      _current = current;
    });
    _c.update(() {
      _c
        ..matchCount = matches.length
        ..matchIndex = current;
    });
    _reveal();
  }

  void _step(int d) {
    if (_matches.isEmpty) return;
    final n = _matches.length;
    setState(() => _current = ((_current ?? (d > 0 ? -1 : 0)) + d) % n);
    _c.update(() => _c.matchIndex = _current);
    _reveal();
  }

  int _firstVisible() {
    if (!_list.isAttached) return 0;
    return _list.visibleRange?.$1 ?? 0;
  }

  void _reveal() {
    final cur = _current;
    if (cur == null || !_list.isAttached) return;
    final item = _matches[cur].item;
    final range = _list.visibleRange;
    final visible = range != null && item > range.$1 && item < range.$2;
    if (!visible && _scroll.hasClients) {
      _list.jumpToItem(index: item, scrollController: _scroll, alignment: 0.3);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _showActive());
  }

  /// Porta in vista il punto esatto del risultato (anche in un blocco lungo).
  void _showActive() {
    final cur = _current;
    final ctx = _activeKey.currentContext;
    if (cur == null || ctx == null || !ctx.mounted) return;
    final ro = ctx.findRenderObject();
    RenderParagraph? para;
    void visit(RenderObject r) {
      if (para != null) return;
      if (r is RenderParagraph) {
        para = r;
        return;
      }
      r.visitChildren(visit);
    }

    if (ro != null) visit(ro);
    final m = _matches[cur];
    final p = para;
    if (p != null && p.attached) {
      final boxes = p.getBoxesForSelection(
        TextSelection(baseOffset: m.start, extentOffset: m.end),
      );
      if (boxes.isNotEmpty) {
        p.showOnScreen(
          rect: boxes.first.toRect().inflate(40),
          duration: const Duration(milliseconds: 150),
        );
        return;
      }
    }
    ro?.showOnScreen(duration: const Duration(milliseconds: 150));
  }

  // ------------------------------------------------------------ Posizione

  /// Porta l'elemento [index] in cima alla vista.
  void jumpTo(int index) {
    if (!mounted ||
        !_list.isAttached ||
        !_scroll.hasClients ||
        _items.isEmpty) {
      return;
    }
    _list.jumpToItem(
      index: index.clamp(0, _items.length - 1),
      scrollController: _scroll,
      alignment: 0,
    );
  }

  void _onScroll() {
    if (!_list.isAttached) return;
    final range = _list.visibleRange;
    if (range == null) return;
    // In fondo al documento l'unità è l'ultima visibile (non quella in cima).
    final pos = _scroll.position;
    final atEnd =
        pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 1;
    final first = range.$1;
    final unitItem = atEnd ? range.$2 : first;
    if (first >= _items.length || unitItem >= _items.length) return;
    if (first == _lastFirst && !atEnd) return;
    _lastFirst = first;
    _c.update(() {
      _c
        ..position = unitItem
        ..unit = _items[unitItem].section + 1;
    });
  }

  // ------------------------------------------------------------ Disegno

  static double _colWidth(int chars, double scale) =>
      ((chars.clamp(3, 42) * 7.6) + 18) * scale;

  TapGestureRecognizer _recognizer(String key, VoidCallback onTap) {
    final r = _recognizers.putIfAbsent(key, TapGestureRecognizer.new);
    r.onTap = onTap;
    return r;
  }

  /// Tratti con le evidenziazioni dei risultati [hits] (inizio, fine, attivo).
  List<InlineSpan> _spans(
    List<RSpan> spans,
    TextStyle base,
    List<(int, int, bool)> hits,
    String keyPrefix,
    ReaderSurface surface,
    Brightness b,
  ) {
    final out = <InlineSpan>[];
    var offset = 0;
    for (var k = 0; k < spans.length; k++) {
      final s = spans[k];
      var style = base.copyWith(
        fontWeight: s.bold ? FontWeight.w700 : null,
        fontStyle: s.italic ? FontStyle.italic : null,
        fontFamily: s.mono ? 'IBMPlexMono' : null,
        fontSize: s.mono && !widget.doc.mono
            ? (base.fontSize ?? 16) * 0.9
            : null,
        decoration: TextDecoration.combine([
          if (s.underline || s.link != null) TextDecoration.underline,
          if (s.strike) TextDecoration.lineThrough,
        ]),
      );
      GestureRecognizer? rec;
      final link = s.link;
      final secs = s.seconds;
      if (secs != null && widget.onSeek != null) {
        style = style.copyWith(
          color: surface.link,
          fontWeight: FontWeight.w600,
        );
        rec = _recognizer('$keyPrefix:$k', () => widget.onSeek!(secs));
      } else if (link != null &&
          (link.startsWith('http://') ||
              link.startsWith('https://') ||
              link.startsWith('mailto:'))) {
        style = style.copyWith(color: surface.link);
        rec = _recognizer(
          '$keyPrefix:$k',
          () => ExternalLauncher.openUrl(link),
        );
      } else if (link != null && widget.onLink != null) {
        final tag = link.startsWith('tag:');
        style = style.copyWith(
          color: surface.link,
          decoration: tag ? TextDecoration.none : null,
          fontWeight: tag ? FontWeight.w600 : null,
        );
        rec = _recognizer('$keyPrefix:$k', () => widget.onLink!(link));
      }
      final text = s.text;
      final end = offset + text.length;
      var i = 0;
      for (final (hs, he, active) in hits) {
        if (he <= offset || hs >= end) continue;
        final a = math.max(hs, offset) - offset;
        final z = math.min(he, end) - offset;
        if (a > i) {
          out.add(
            TextSpan(text: text.substring(i, a), style: style, recognizer: rec),
          );
        }
        out.add(
          TextSpan(
            text: text.substring(a, z),
            style: style.copyWith(
              backgroundColor: active ? findActiveColor(b) : findMatchColor(b),
            ),
            recognizer: rec,
          ),
        );
        i = z;
      }
      if (i < text.length) {
        out.add(
          TextSpan(text: text.substring(i), style: style, recognizer: rec),
        );
      }
      offset = end;
    }
    return out;
  }

  List<(int, int, bool)> _hits(int item, int text) {
    final ids = _byItem[item];
    if (ids == null) return const [];
    return [
      for (final id in ids)
        if (_matches[id].text == text)
          (_matches[id].start, _matches[id].end, id == _current),
    ];
  }

  bool _activeIn(int item, [int? text]) {
    final cur = _current;
    if (cur == null) return false;
    final m = _matches[cur];
    return m.item == item && (text == null || m.text == text);
  }

  Widget _buildItem(BuildContext context, int i, double width) {
    final theme = Theme.of(context);
    final surface = ReaderSurface.of(context);
    final b = theme.brightness;
    final it = _items[i];
    final s = _scale;
    final mono = widget.doc.mono;
    final base = TextStyle(
      fontSize: (mono ? 13.5 : 16) * s,
      height: mono ? 1.45 : 1.6,
      color: surface.text,
      fontFamily: mono ? 'IBMPlexMono' : null,
    );
    final block = it.block;
    Widget child;
    switch (block) {
      case RBreak():
        final hits = _hits(i, 0);
        child = Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 28 * s, bottom: 10 * s),
          child: Row(
            children: [
              Flexible(
                child: Text.rich(
                  key: _activeIn(i) ? _activeKey : null,
                  TextSpan(
                    children: _spans(
                      [RSpan(block.label)],
                      TextStyle(
                        fontSize: 12 * s,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.3,
                        color: surface.muted,
                      ),
                      hits,
                      '$i',
                      surface,
                      b,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: Divider(color: surface.rule)),
            ],
          ),
        );
      case RRule():
        child = Padding(
          padding: EdgeInsets.symmetric(vertical: 12 * s),
          child: Divider(color: surface.rule),
        );
      case RImage():
        child = Padding(
          padding: EdgeInsets.symmetric(vertical: 8 * s),
          child: Column(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImageViewerPage(
                      bytes: block.bytes,
                      title: block.caption ?? 'Immagine',
                    ),
                  ),
                ),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 1100 * s),
                  child: Image.memory(
                    block.bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => Container(
                      padding: const EdgeInsets.all(12),
                      color: surface.codeBackground,
                      child: Text(
                        'Immagine in un formato non mostrabile',
                        style: TextStyle(
                          color: surface.muted,
                          fontSize: 12 * s,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if ((block.caption ?? '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text.rich(
                    key: _activeIn(i) ? _activeKey : null,
                    TextSpan(
                      children: _spans(
                        [RSpan(block.caption!)],
                        TextStyle(
                          fontSize: 12 * s,
                          color: surface.muted,
                          fontStyle: FontStyle.italic,
                        ),
                        _hits(i, 0),
                        '$i',
                        surface,
                        b,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      case RTableRow():
        child = _row(block, i, surface, b);
      case RPara():
        child = _para(block, i, base, surface, b, theme);
    }
    if (block is RTableRow) return child;
    final double maxW = _fit ? double.infinity : 780 * math.min(s, 1.5);
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: math.min(maxW, width)),
        child: child,
      ),
    );
  }

  Widget _para(
    RPara p,
    int i,
    TextStyle base,
    ReaderSurface surface,
    Brightness b,
    ThemeData theme,
  ) {
    final s = _scale;
    final mono = widget.doc.mono;
    var style = base;
    var pad = EdgeInsets.only(bottom: mono ? 0 : 10 * s);
    switch (p.style) {
      case RStyle.h1:
        style = base.copyWith(
          fontSize: 26 * s,
          fontWeight: FontWeight.w700,
          height: 1.3,
        );
        pad = EdgeInsets.only(top: 18 * s, bottom: 10 * s);
      case RStyle.h2:
        style = base.copyWith(
          fontSize: 21 * s,
          fontWeight: FontWeight.w700,
          height: 1.3,
        );
        pad = EdgeInsets.only(top: 16 * s, bottom: 8 * s);
      case RStyle.h3:
        style = base.copyWith(
          fontSize: 18 * s,
          fontWeight: FontWeight.w600,
          height: 1.35,
        );
        pad = EdgeInsets.only(top: 12 * s, bottom: 6 * s);
      case RStyle.h4:
        style = base.copyWith(fontSize: 16 * s, fontWeight: FontWeight.w600);
        pad = EdgeInsets.only(top: 10 * s, bottom: 4 * s);
      case RStyle.caption:
        style = base.copyWith(fontSize: 12.5 * s, color: surface.muted);
      case RStyle.quote:
        style = base.copyWith(fontStyle: FontStyle.italic);
      case RStyle.code:
        style = base.copyWith(
          fontFamily: 'IBMPlexMono',
          fontSize: 13.5 * s,
          height: 1.45,
        );
      case RStyle.body || RStyle.list:
        break;
    }
    final text = Text.rich(
      key: _activeIn(i) ? _activeKey : null,
      TextSpan(children: _spans(p.spans, style, _hits(i, 0), '$i', surface, b)),
    );
    switch (p.style) {
      case RStyle.quote:
        return Container(
          margin: EdgeInsets.only(bottom: 10 * s),
          padding: EdgeInsets.fromLTRB(12 * s, 4 * s, 4 * s, 4 * s),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: context.tokens.cyan, width: 3),
            ),
          ),
          child: text,
        );
      case RStyle.code:
        return Container(
          width: double.infinity,
          margin: EdgeInsets.only(bottom: 10 * s),
          padding: EdgeInsets.all(12 * s),
          decoration: BoxDecoration(
            color: surface.codeBackground,
            borderRadius: BorderRadius.circular(10),
          ),
          child: text,
        );
      case RStyle.list:
        return Padding(
          padding: EdgeInsets.only(left: (4 + 20 * p.level) * s, bottom: 6 * s),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 26 * s,
                child: Text(
                  p.marker ?? '•',
                  style: style.copyWith(color: context.tokens.cyan),
                ),
              ),
              Expanded(child: text),
            ],
          ),
        );
      default:
        return Padding(padding: pad, child: text);
    }
  }

  Widget _row(RTableRow r, int i, ReaderSurface surface, Brightness b) {
    final s = _scale;
    final cols = r.table < widget.doc.tables.length
        ? widget.doc.tables[r.table].columns
        : const <int>[];
    final style = TextStyle(
      fontSize: 13.5 * s,
      height: 1.35,
      color: surface.text,
      fontWeight: r.header ? FontWeight.w600 : null,
    );
    final border = BorderSide(color: surface.tableBorder);
    final width = r.table < _tableWidths.length
        ? _tableWidths[r.table] * s
        : null;
    return Container(
      width: width,
      decoration: BoxDecoration(
        color: r.header ? surface.tableHeader : null,
        border: Border(bottom: border),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (r.label != null)
              Container(
                width: 44 * s,
                padding: EdgeInsets.symmetric(
                  horizontal: 6 * s,
                  vertical: 5 * s,
                ),
                decoration: BoxDecoration(
                  color: surface.codeBackground,
                  border: Border(right: border),
                ),
                alignment: Alignment.topRight,
                child: Text(
                  r.label!,
                  style: style.copyWith(
                    color: surface.muted,
                    fontSize: 11.5 * s,
                  ),
                ),
              ),
            for (var c = 0; c < math.max(r.cells.length, cols.length); c++)
              Container(
                width: _colWidth(c < cols.length ? cols[c] : 6, s),
                padding: EdgeInsets.symmetric(
                  horizontal: 8 * s,
                  vertical: 5 * s,
                ),
                decoration: BoxDecoration(border: Border(right: border)),
                child: c >= r.cells.length
                    ? const SizedBox.shrink()
                    : Text.rich(
                        key: _activeIn(i, c) ? _activeKey : null,
                        TextSpan(
                          children: _spans(
                            [RSpan(r.cells[c])],
                            style,
                            _hits(i, c),
                            '$i.$c',
                            surface,
                            b,
                          ),
                        ),
                      ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = ReaderSurface.of(context);
    if (_items.isEmpty) {
      return ColoredBox(
        color: surface.background,
        child: Center(
          child: Text(
            'Il documento non contiene testo leggibile.',
            style: TextStyle(color: surface.muted),
          ),
        ),
      );
    }
    final doc = widget.doc;
    return ColoredBox(
      color: surface.background,
      child: Column(
        children: [
          Expanded(
            child: PinchScaleListener(
              scale: _scale,
              onScale: (v) => setState(() => _scale = v),
              child: LayoutBuilder(
                builder: (context, c) {
                  final pad = widget.padding;
                  final view = c.maxWidth - pad.horizontal;
                  final wide = _tableWidths.fold(0.0, math.max) * _scale;
                  final content = math.max(view, wide);
                  Widget list = SelectionArea(
                    child: Scrollbar(
                      controller: _scroll,
                      child: SuperListView.builder(
                        controller: _scroll,
                        listController: _list,
                        padding: pad,
                        itemCount: _items.length,
                        itemBuilder: (context, i) => Align(
                          alignment: Alignment.topLeft,
                          child: SizedBox(
                            width: _items[i].block is RTableRow
                                ? content
                                : view,
                            child: _buildItem(context, i, view),
                          ),
                        ),
                      ),
                    ),
                  );
                  if (wide > view) {
                    list = Scrollbar(
                      controller: _hScroll,
                      child: SingleChildScrollView(
                        controller: _hScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: content + pad.horizontal,
                          child: list,
                        ),
                      ),
                    );
                  }
                  return list;
                },
              ),
            ),
          ),
          if (doc.tabs && doc.sections.length > 1) _tabs(context),
        ],
      ),
    );
  }

  /// Schede dei fogli (in basso, come nei fogli di calcolo).
  Widget _tabs(BuildContext context) {
    final t = context.tokens;
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.navGradient,
          ),
          border: Border(top: BorderSide(color: t.navBorder)),
        ),
        height: 52,
        child: ListenableBuilder(
          listenable: _c,
          builder: (context, _) => ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              for (var s = 0; s < widget.doc.sections.length; s++)
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(
                      widget.doc.sections[s].title.isEmpty
                          ? '${widget.doc.unitLabel} ${s + 1}'
                          : widget.doc.sections[s].title,
                    ),
                    selected: _c.unit == s + 1,
                    onSelected: (_) => jumpTo(_sectionTop(s)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
