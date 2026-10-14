import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../notes/markdown_view.dart' show findActiveColor, findMatchColor;
import '../djvu/djvu_document.dart';
import '../djvu/djvu_text.dart';
import '../reader_controller.dart';
import '../reader_text.dart';
import 'pinch.dart';

/// Testo di una pagina pronto per la ricerca: parole unite da spazi e
/// inizio di ogni parola nel testo.
class _PageIndex {
  _PageIndex(DjvuPageText t) {
    if (t.words.isEmpty) {
      text = t.text;
      return;
    }
    final b = StringBuffer();
    for (final w in t.words) {
      if (b.isNotEmpty) b.write(' ');
      starts.add(b.length);
      b.write(w.text);
    }
    text = b.toString();
  }
  late final String text;
  final starts = <int>[];
  late final String folded = foldText(text);

  /// Parole toccate dall'intervallo [s, e).
  List<int> words(int s, int e) {
    final out = <int>[];
    for (var i = 0; i < starts.length; i++) {
      final ws = starts[i];
      final we = i + 1 < starts.length ? starts[i + 1] - 1 : text.length;
      if (ws < e && we > s) out.add(i);
    }
    return out;
  }
}

class _Match {
  const _Match(this.page, this.words);
  final int page;
  final List<int> words;
}

/// Pagine DjVu: una alla volta, disegnate in un isolate alla risoluzione
/// che serve (ridotta per le scansioni grandi) e tenute in una piccola
/// memoria; ricerca nel testo nascosto con le parole evidenziate sulla
/// pagina, indice dai segnalibri, vai alla pagina, zoom.
class DjvuView extends StatefulWidget {
  const DjvuView({
    super.key,
    required this.doc,
    required this.texts,
    required this.controller,
    this.initialPage,
  });

  final DjvuDocument doc;
  final List<DjvuPageText> texts;
  final ReaderPaneController controller;
  final int? initialPage;

  @override
  State<DjvuView> createState() => _DjvuViewState();
}

class _DjvuViewState extends State<DjvuView> {
  final _scroll = ScrollController();
  final _list = ListController();
  double _zoom = 1;
  late final List<_PageIndex> _index = [
    for (final t in widget.texts) _PageIndex(t),
  ];
  List<_Match> _matches = const [];
  int? _current;
  int _lastFirst = -1;

  /// Pagine disegnate: (pagina, riduzione) → immagine. Le più vecchie si
  /// liberano oltre [_maxCached].
  final _cache = <(int, int), ui.Image>{};
  static const _maxCached = 8;
  final _rendering = <(int, int)>{};
  final _failed = <int>{};
  bool _disposed = false;

  ReaderPaneController get _c => widget.controller;
  List<DjvuPage> get _pages => widget.doc.pages;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    final hasText = _index.any((p) => p.text.trim().isNotEmpty);
    _c.update(() {
      _c
        ..unitLabel = 'Pagina'
        ..unitCount = _pages.length
        ..unit = 1
        ..position = 1
        ..onFind = hasText ? _find : null
        ..onStep = _step
        ..onGoToUnit = ((u) => _jump(u - 1))
        ..onGoToPosition = ((p) => _jump(p - 1))
        ..describe = ((p) => 'Pagina $p')
        ..outline = [
          for (final o in widget.doc.outline)
            if (o.page >= 0) ReaderTocItem(o.title, o.page + 1, level: o.level),
        ]
        ..onZoom = ((d) => setState(
          () => _zoom = d == 0
              ? 1
              : (_zoom * (d > 0 ? 1.25 : 0.8)).clamp(0.5, 6.0),
        ))
        ..plainText = hasText
            ? () => [
                for (var i = 0; i < widget.texts.length; i++)
                  widget.texts[i].text.trim(),
              ].where((t) => t.isNotEmpty).join('\n\n')
            : null;
    });
    final start = widget.initialPage;
    if (start != null && start > 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _jump(start - 1));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    for (final i in _cache.values) {
      i.dispose();
    }
    _cache.clear();
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  void _jump(int page) {
    if (!_list.isAttached || !_scroll.hasClients) return;
    _list.jumpToItem(
      index: page.clamp(0, _pages.length - 1),
      scrollController: _scroll,
      alignment: 0,
    );
  }

  void _onScroll() {
    _updateUnit();
    // La lista si sistema dopo il disegno (altezze delle pagine stimate):
    // si ricontrolla allora.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateUnit();
    });
  }

  void _updateUnit() {
    if (!_list.isAttached || !_scroll.hasClients) return;
    final range = _list.visibleRange;
    if (range == null) return;
    // In fondo al documento la pagina è l'ultima visibile.
    final pos = _scroll.position;
    final atEnd =
        pos.maxScrollExtent > 0 && pos.pixels >= pos.maxScrollExtent - 1;
    final page = atEnd ? range.$2 : range.$1;
    if (page == _lastFirst) return;
    _lastFirst = page;
    _c.update(() {
      _c
        ..unit = page + 1
        ..position = page + 1;
    });
  }

  // ------------------------------------------------------------ Ricerca

  void _find(String q) {
    final query = q.trim();
    final out = <_Match>[];
    if (query.isNotEmpty) {
      for (var p = 0; p < _index.length; p++) {
        final idx = _index[p];
        for (final s in findFolded(idx.text, query, foldedText: idx.folded)) {
          out.add(_Match(p, idx.words(s, s + query.length)));
        }
      }
    }
    var cur = out.isEmpty ? null : 0;
    if (out.isNotEmpty && _list.isAttached) {
      final first = _list.visibleRange?.$1 ?? 0;
      final after = out.indexWhere((m) => m.page >= first);
      cur = after < 0 ? 0 : after;
    }
    setState(() {
      _matches = out;
      _current = cur;
    });
    _report();
  }

  void _step(int d) {
    if (_matches.isEmpty) return;
    setState(() => _current = ((_current ?? 0) + d) % _matches.length);
    _report();
  }

  void _report() {
    _c.update(() {
      _c
        ..matchCount = _matches.length
        ..matchIndex = _current;
    });
    final cur = _current;
    if (cur != null) _jump(_matches[cur].page);
  }

  // ------------------------------------------------------------ Disegno

  ui.Image? _best(int page, int reduction) {
    ui.Image? best;
    var bestR = 1 << 30;
    for (final e in _cache.entries) {
      if (e.key.$1 != page) continue;
      // La più vicina, preferendo quelle più nitide.
      final d = (e.key.$2 - reduction).abs() * (e.key.$2 > reduction ? 2 : 1);
      if (d < bestR) {
        bestR = d;
        best = e.value;
      }
    }
    return best;
  }

  void _request(int page, int reduction) {
    final key = (page, reduction);
    if (_cache.containsKey(key)) {
      // Usata di recente: in fondo alla coda.
      final img = _cache.remove(key)!;
      _cache[key] = img;
      return;
    }
    // Al massimo due pagine alla volta: le altre si chiedono di nuovo al
    // disegno che segue la fine di una pagina.
    if (_rendering.contains(key) ||
        _failed.contains(page) ||
        _rendering.length >= 2) {
      return;
    }
    _rendering.add(key);
    unawaited(_render(page, reduction));
  }

  Future<void> _render(int page, int reduction) async {
    final key = (page, reduction);
    try {
      final data = widget.doc.pageData(page);
      final bm = await Isolate.run(
        () => renderDjvuPage(data, reduction: reduction),
      );
      final c = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        bm.rgba,
        bm.width,
        bm.height,
        ui.PixelFormat.rgba8888,
        c.complete,
      );
      final image = await c.future;
      if (_disposed) {
        image.dispose();
        return;
      }
      _cache[key] = image;
      while (_cache.length > _maxCached) {
        final k = _cache.keys.first;
        _cache.remove(k)?.dispose();
      }
    } catch (_) {
      _failed.add(page);
    } finally {
      _rendering.remove(key);
    }
    if (mounted && !_disposed) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final b = Theme.of(context).brightness;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ColoredBox(
      color: b == Brightness.dark
          ? const Color(0xFF050B14)
          : const Color(0xFFE7ECF2),
      child: PinchScaleListener(
        scale: _zoom,
        min: 0.5,
        max: 6,
        onScale: (v) => setState(() => _zoom = v),
        child: LayoutBuilder(
          builder: (context, box) {
            final avail = math.max(100.0, box.maxWidth - 32);
            // Ogni pagina alla larghezza della vista (al massimo 1400 px).
            double factor(DjvuPage p) =>
                math.min(avail, 1400) / math.max(1, p.viewWidth) * _zoom;
            final widest = _pages.fold(
              0.0,
              (w, p) => math.max(w, p.viewWidth * factor(p)),
            );
            Widget list = SuperListView.builder(
              controller: _scroll,
              listController: _list,
              padding: const EdgeInsets.symmetric(vertical: 16),
              itemCount: _pages.length,
              itemBuilder: (context, i) {
                final p = _pages[i];
                final f = factor(p);
                final shownW = p.viewWidth * f;
                final r = math.max(
                  1,
                  math.min(16, (p.viewWidth / (shownW * dpr)).floor()),
                );
                _request(i, r);
                final cur = _current == null ? null : _matches[_current!];
                final hits = <int, bool>{};
                for (final m in _matches) {
                  if (m.page != i) continue;
                  for (final w in m.words) {
                    hits[w] = (hits[w] ?? false) || identical(m, cur);
                  }
                }
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: _DjvuPageTile(
                      page: p,
                      number: i + 1,
                      factor: f,
                      image: _best(i, r),
                      failed: _failed.contains(i),
                      words: widget.texts[i].words,
                      hits: hits,
                      activeColor: findActiveColor(b),
                      matchColor: findMatchColor(b),
                    ),
                  ),
                );
              },
            );
            if (widest > avail) {
              list = SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: widest + 32, child: list),
              );
            }
            return list;
          },
        ),
      ),
    );
  }
}

class _DjvuPageTile extends StatelessWidget {
  const _DjvuPageTile({
    required this.page,
    required this.number,
    required this.factor,
    required this.image,
    required this.failed,
    required this.words,
    required this.hits,
    required this.activeColor,
    required this.matchColor,
  });

  final DjvuPage page;
  final int number;
  final double factor;
  final ui.Image? image;
  final bool failed;
  final List<DjvuWord> words;

  /// Parole trovate → risultato attivo.
  final Map<int, bool> hits;
  final Color activeColor;
  final Color matchColor;

  /// Rettangolo di una parola sulla pagina mostrata (con la rotazione).
  Rect _rect(DjvuWord w) {
    final pw = page.width.toDouble(), ph = page.height.toDouble();
    final l = w.left.toDouble(), t = w.top.toDouble();
    final r = w.right.toDouble(), b = w.bottom.toDouble();
    final Rect rect = switch (page.rotation) {
      1 => Rect.fromLTRB(t, pw - r, b, pw - l),
      2 => Rect.fromLTRB(pw - r, ph - b, pw - l, ph - t),
      3 => Rect.fromLTRB(ph - b, l, ph - t, r),
      _ => Rect.fromLTRB(l, t, r, b),
    };
    return Rect.fromLTRB(
      rect.left * factor,
      rect.top * factor,
      rect.right * factor,
      rect.bottom * factor,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = page.viewWidth * factor, h = page.viewHeight * factor;
    final img = image;
    return Semantics(
      label: 'Pagina $number',
      child: Container(
        width: w,
        height: h,
        decoration: const BoxDecoration(
          color: Colors.white,
          boxShadow: [
            BoxShadow(
              color: Color(0x55000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Stack(
          children: [
            if (img != null)
              Positioned.fill(
                child: RawImage(
                  image: img,
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.medium,
                ),
              )
            else
              Center(
                child: failed
                    ? const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'Pagina non decodificabile',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Color(0xFF5B708A)),
                        ),
                      )
                    : const SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2.5),
                      ),
              ),
            for (final e in hits.entries)
              if (e.key < words.length)
                Positioned.fromRect(
                  rect: _rect(words[e.key]).inflate(1),
                  child: IgnorePointer(
                    child: ColoredBox(
                      color: (e.value ? activeColor : matchColor).withValues(
                        alpha: 0.45,
                      ),
                    ),
                  ),
                ),
          ],
        ),
      ),
    );
  }
}
