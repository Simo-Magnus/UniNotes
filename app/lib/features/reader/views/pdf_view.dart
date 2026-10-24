import 'dart:io';

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../../../core/feedback/app_modals.dart';
import '../pdf_highlights.dart';
import '../reader_controller.dart';
import '../reader_text.dart';
import 'reader_surface.dart';

/// PDF con pdfrx: ricerca nel testo (senza maiuscole né accenti, risultati
/// evidenziati sulla pagina), indice del PDF, vai alla pagina, zoom ed
/// evidenziatore (seleziona il testo → colore nel menu; salvato nell'app).
class PdfView extends StatefulWidget {
  const PdfView({
    super.key,
    required this.path,
    required this.controller,
    this.initialPage,
  });
  final String path;
  final ReaderPaneController controller;
  final int? initialPage;

  @override
  State<PdfView> createState() => _PdfViewState();
}

class _PdfViewState extends State<PdfView> {
  final _pdf = PdfViewerController();
  // pdfrx richiede che il documento sia caricato prima di creare il
  // ricercatore: nasce in [_onReady]. Una ricerca chiesta prima resta in attesa.
  PdfTextSearcher? _searcher;
  String? _pendingQuery;
  late final int _initial = (widget.initialPage ?? 1) < 1
      ? 1
      : (widget.initialPage ?? 1);

  ReaderPaneController get _c => widget.controller;

  static final bool _phone = Platform.isAndroid || Platform.isIOS;

  late final PdfHighlights _hl = PdfHighlights(widget.path)
    ..addListener(_repaint)
    ..load();

  void _repaint() {
    if (mounted && _pdf.isReady) _pdf.invalidate();
  }

  /// Voci dell'evidenziatore nel menu del testo selezionato.
  void _menuItems(
    PdfViewerContextMenuBuilderParams params,
    List<ContextMenuButtonItem> items,
  ) {
    final sel = params.textSelectionDelegate;
    if (!sel.hasSelectedText) return;
    Future<void> run(Future<void> Function(List<PdfPageTextRange>) f) async {
      try {
        final ranges = await sel.getSelectedTextRanges();
        params.dismissContextMenu();
        await f(ranges);
        await sel.clearTextSelection();
      } catch (e) {
        // disco pieno, cartella non scrivibile, selezione non più valida
        if (!mounted) return;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Impossibile salvare l\'evidenziazione.'),
          ),
        );
      }
    }

    for (final (name, color) in kHighlightColors) {
      items.add(
        ContextMenuButtonItem(
          label: 'Evidenzia ($name)',
          onPressed: () => run((r) => _hl.add(r, color)),
        ),
      );
    }
    if (_hl.items.isNotEmpty) {
      items.add(
        ContextMenuButtonItem(
          label: 'Togli evidenziazione',
          onPressed: () => run(_hl.removeOverlapping),
        ),
      );
    }
  }

  @override
  void initState() {
    super.initState();
    _c.update(() {
      _c
        ..unitLabel = 'Pagina'
        ..unit = _initial
        ..position = _initial
        ..onFind = _find
        ..onStep = ((d) =>
            d > 0 ? _searcher?.goToNextMatch() : _searcher?.goToPrevMatch())
        ..onGoToUnit = _goTo
        ..onGoToPosition = _goTo
        ..describe = ((p) => 'Pagina $p')
        ..onZoom = _zoom;
    });
  }

  @override
  void dispose() {
    _hl
      ..removeListener(_repaint)
      ..dispose();
    _searcher
      ?..removeListener(_onSearch)
      ..dispose();
    super.dispose();
  }

  void _find(String q) {
    final query = q.trim();
    final searcher = _searcher;
    if (searcher == null) {
      _pendingQuery = query;
      return;
    }
    if (query.isEmpty) {
      searcher.resetTextSearch();
      return;
    }
    searcher.startTextSearch(
      accentInsensitivePattern(query),
      searchImmediately: true,
    );
  }

  void _onSearch() {
    final searcher = _searcher;
    if (!mounted || searcher == null) return;
    _c.update(() {
      _c
        ..matchCount = searcher.matches.length
        ..matchIndex = searcher.currentIndex
        ..searching = searcher.isSearching;
    });
  }

  Future<void> _goTo(int page) async {
    // PDF senza pagine: clamp(1, 0) lancerebbe un errore
    if (!_pdf.isReady || _pdf.pageCount < 1) return;
    await _pdf.goToPage(pageNumber: page.clamp(1, _pdf.pageCount));
  }

  Future<void> _zoom(int dir) async {
    if (!_pdf.isReady) return;
    if (dir > 0) {
      await _pdf.zoomUp();
    } else if (dir < 0) {
      await _pdf.zoomDown();
    } else {
      final m = _pdf.calcMatrixFitWidthForPage(
        pageNumber: _pdf.pageNumber ?? 1,
      );
      if (m != null) await _pdf.goTo(m);
    }
  }

  Future<void> _onReady(
    PdfDocument document,
    PdfViewerController controller,
  ) async {
    final count = document.pages.length;
    _c.update(() => _c.unitCount = count);
    if (_searcher == null && mounted) {
      setState(() => _searcher = PdfTextSearcher(_pdf)..addListener(_onSearch));
      final q = _pendingQuery;
      _pendingQuery = null;
      if (q != null) _find(q);
    }
    try {
      final outline = await document.loadOutline();
      final items = <ReaderTocItem>[];
      void walk(List<PdfOutlineNode> nodes, int level) {
        for (final n in nodes) {
          final page = n.dest?.pageNumber;
          if (page != null) {
            items.add(ReaderTocItem(n.title, page, level: level));
          }
          walk(n.children, level + 1);
        }
      }

      walk(outline, 0);
      if (mounted) _c.update(() => _c.outline = items);
    } catch (_) {}
  }

  void _onPageChanged(int? page) {
    if (page == null || !mounted) return;
    _c.update(() {
      _c
        ..unit = page
        ..position = page;
    });
  }

  /// PDF protetto da password: la si chiede (null = annulla).
  Future<String?> _askPassword() async {
    if (!mounted) return null;
    return showAppDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final surface = ReaderSurface.of(context);
    return PdfViewer.file(
      widget.path,
      passwordProvider: _askPassword,
      controller: _pdf,
      initialPageNumber: _initial,
      params: PdfViewerParams(
        // telefono: meno pagine pronte in memoria (risparmio di RAM e batteria)
        maxImageBytesCachedOnMemory: _phone
            ? 40 * 1024 * 1024
            : 100 * 1024 * 1024,
        horizontalCacheExtent: _phone ? 0.5 : 1.0,
        verticalCacheExtent: _phone ? 0.5 : 1.0,
        backgroundColor: Theme.of(context).brightness == Brightness.dark
            ? const Color(0xFF050B14)
            : const Color(0xFFE7ECF2),
        onViewerReady: _onReady,
        onPageChanged: _onPageChanged,
        pagePaintCallbacks: [
          _hl.paint,
          (canvas, rect, page) =>
              _searcher?.pageTextMatchPaintCallback(canvas, rect, page),
        ],
        customizeContextMenuItems: _menuItems,
        errorBannerBuilder: (context, error, stackTrace, documentRef) =>
            ColoredBox(
              color: surface.background,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    'Impossibile aprire il PDF:\n$error',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: surface.text),
                  ),
                ),
              ),
            ),
      ),
    );
  }
}

/// Finestra della password del PDF (possiede il proprio controller).
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog();

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _ctrl.text);

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: const Text('PDF protetto da password'),
    content: TextField(
      controller: _ctrl,
      autofocus: true,
      obscureText: true,
      decoration: const InputDecoration(labelText: 'Password'),
      onSubmitted: (_) => _submit(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Annulla'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Apri')),
    ],
  );
}
