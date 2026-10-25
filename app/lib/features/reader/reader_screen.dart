import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../widgets/adaptive_row.dart';
import '../../widgets/app_snack_action.dart';
import '../../core/feedback/app_modals.dart';
import '../../core/reminders/notification_plan.dart' show AppRoutes;
import '../../core/services/app_services.dart';
import '../../core/services/external_launcher.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/share_files.dart';
import '../../widgets/undo_snack_bar.dart';
import '../../widgets/find_bar.dart';
import '../cloud/onenote_screen.dart';
import 'reader_controller.dart';
import 'reader_fidelity.dart';
import 'reader_formats.dart';
import 'reader_loader.dart';
import 'reader_store.dart';
import 'views/djvu_view.dart';
import 'views/document_view.dart';
import 'views/file_info_view.dart';
import 'views/image_view.dart';
import 'views/ink_view.dart';
import 'views/media_view.dart';
import 'views/outline_view.dart';
import 'views/pdf_view.dart';

/// Apre [path] nel lettore dell'app (qualsiasi formato: quelli non
/// mostrabili hanno "Apri con…" e "Condividi").
///
/// [initialPosition] e [onPosition] servono a chi salva la posizione nel
/// proprio archivio (libri e materiali: pagina del PDF); senza, la posizione
/// si ricorda nelle impostazioni, per percorso e dimensione del file.
Future<void> openInReader(
  BuildContext context,
  String path, {
  String? title,
  int? initialPosition,
  Future<void> Function(int position, int? count)? onPosition,
  String? initialQuery,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ReaderScreen(
      path: path,
      title: title,
      initialPosition: initialPosition,
      onPosition: onPosition,
      initialQuery: initialQuery,
    ),
  ),
);

/// Il lettore universale ("Lettore"): cornice comune a tutti i formati con
/// Ctrl+F, indice e segnalibri, vai a pagina, zoom, schermo intero,
/// condivisione e apertura esterna.
class ReaderScreen extends StatefulWidget {
  const ReaderScreen({
    super.key,
    required this.path,
    this.title,
    this.initialPosition,
    this.onPosition,
    this.initialQuery,
    this.store,
    this.askPartial = true,
  });

  final String path;
  final String? title;
  final int? initialPosition;
  final Future<void> Function(int position, int? count)? onPosition;
  final String? initialQuery;

  /// Memoria delle posizioni (nei test); di norma quella dell'app.
  final ReaderStore? store;

  /// Per i file a resa parziale chiedere all'apertura se usare l'app di
  /// riferimento (vedi reader_fidelity.dart).
  final bool askPartial;

  @override
  State<ReaderScreen> createState() => ReaderScreenState();
}

class _Loaded {
  const _Loaded(this.format, this.content, this.state);
  final ReaderFormat format;
  final ReaderContent content;
  final ReaderFileState state;
}

class ReaderScreenState extends State<ReaderScreen> {
  final pane = ReaderPaneController();
  final _query = TextEditingController();
  final _queryFocus = FocusNode();
  final _scaffold = GlobalKey<ScaffoldState>();
  ReaderStore? _store;
  late final Future<_Loaded> _future;

  bool _findOpen = false;
  bool _fullscreen = false;
  bool _noticeHidden = false;
  List<ReaderBookmark> _bookmarks = const [];

  Timer? _saveTimer;
  int? _pendingPos;
  int? _savedPos;
  int _lastPos = -1;

  /// Vista del documento (creata al primo disegno, poi riusata).
  Widget? _content;

  ReaderStore? _appStore() {
    try {
      return ReaderStore(context.read<AppServices>().settings);
    } catch (_) {
      return null;
    }
  }

  String get _title => widget.title ?? p.basename(widget.path);

  @override
  void initState() {
    super.initState();
    pane.addListener(_onPane);
    _store = widget.store ?? _appStore();
    _future = _prepare();
  }

  Future<_Loaded> _prepare() async {
    final store = _store;
    final results = await Future.wait<Object>([
      loadReaderContent(widget.path),
      // posizione e segnalibri illeggibili (preferenze rovinate): il file
      // si apre lo stesso, dall'inizio
      if (store != null)
        store.load(widget.path).catchError((_) => const ReaderFileState())
      else
        Future.value(const ReaderFileState()),
    ]);
    final (format, content) = results[0] as (ReaderFormat, ReaderContent);
    final state = results[1] as ReaderFileState;
    _bookmarks = state.bookmarks;
    _savedPos = widget.initialPosition ?? state.position;
    try {
      await store?.addRecent(widget.path, title: widget.title);
    } catch (_) {}
    final loaded = _Loaded(format, content, state);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkFidelity(loaded));
    final q = widget.initialQuery?.trim() ?? '';
    if (q.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _query.text = q;
        setState(() => _findOpen = true);
        pane.find(q);
      });
    }
    return loaded;
  }

  /// Resa parziale (formato o parti del file non mostrate): si chiede se
  /// aprire il file con l'app di riferimento, salvo una scelta già fatta
  /// con «Non chiedere più».
  Future<void> _checkFidelity(_Loaded l) async {
    if (!mounted || !widget.askPartial) return;
    final missing = readerShortfall(l.format, l.content);
    if (missing == null) return;
    final settings = _store?.settings;
    final saved = await savedPartialChoice(settings, l.format);
    if (!mounted || saved == PartialViewChoice.preview) return;
    if (saved == PartialViewChoice.external) {
      await _leaveTo(ExternalLauncher.openPath);
      return;
    }
    final choice = await askPartialView(
      context,
      format: l.format,
      missing: missing,
      settings: settings,
    );
    if (!mounted || choice != PartialViewChoice.external) return;
    await _leaveTo(ExternalLauncher.openWith);
  }

  /// Apre il file fuori dall'app e chiude il lettore (se l'apertura non
  /// riesce resta l'anteprima, con il messaggio).
  Future<void> _leaveTo(Future<LaunchResult> Function(String) open) async {
    final r = await open(widget.path);
    if (!mounted) return;
    if (r.ok) {
      // la finestra della domanda può essere ancora in chiusura: il lettore
      // si toglie anche se non è in cima
      final route = ModalRoute.of(context);
      if (route == null) return;
      final nav = Navigator.of(context);
      if (route.isCurrent) {
        nav.pop();
      } else if (route.isActive) {
        nav.removeRoute(route);
      }
    } else {
      showLaunchResult(context, r);
    }
  }

  @override
  void dispose() {
    _flush();
    pane
      ..removeListener(_onPane)
      ..dispose();
    _query.dispose();
    _queryFocus.dispose();
    if (_fullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _onPane() {
    if (pane.position != _lastPos) {
      _lastPos = pane.position;
      _positionChanged(pane.position);
    }
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------- Posizione

  void _positionChanged(int pos) {
    if (!pane.hasPositions) return;
    _pendingPos = pos;
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _flush);
  }

  Future<void> _flush() async {
    _saveTimer?.cancel();
    _saveTimer = null;
    final pos = _pendingPos;
    _pendingPos = null;
    if (pos == null || pos == _savedPos) return;
    _savedPos = pos;
    final count = pane.unitCount > 0 ? pane.unitCount : null;
    try {
      final save = widget.onPosition;
      if (save != null) {
        await save(pos, count);
      } else {
        await _store?.savePosition(widget.path, pos);
      }
    } catch (_) {}
  }

  // ----------------------------------------------------------- Ricerca

  void _openFind() {
    if (!pane.canFind) return;
    setState(() => _findOpen = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // la schermata può essere già chiusa (controller e fuoco eliminati)
      if (!mounted) return;
      _queryFocus.requestFocus();
      _query.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _query.text.length,
      );
    });
  }

  void _closeFind() {
    if (_fullscreen && !_findOpen) {
      _toggleFullscreen();
      return;
    }
    if (!_findOpen) return;
    pane.find('');
    setState(() => _findOpen = false);
  }

  // ------------------------------------------------------------ Azioni

  /// «Apri con…»: la scelta dell'app del sistema.
  Future<void> _openWith() async {
    final r = await ExternalLauncher.openWith(widget.path);
    if (mounted) showLaunchResult(context, r);
  }

  /// «Apri con l'app predefinita» (pagina dei file non mostrabili).
  Future<void> _openDefault() async {
    final r = await ExternalLauncher.openPath(widget.path);
    if (mounted) showLaunchResult(context, r);
  }

  Future<void> _share() =>
      shareFiles(context, [File(widget.path)], subject: _title);

  void _toggleFullscreen() {
    setState(() => _fullscreen = !_fullscreen);
    SystemChrome.setEnabledSystemUIMode(
      _fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
  }

  Future<void> _goToDialog() async {
    if (!pane.canGoTo) return;
    final u = await showAppDialog<int>(
      context: context,
      builder: (_) => GoToDialog(
        label: pane.unitLabel,
        current: pane.unit,
        count: pane.unitCount,
      ),
    );
    // dopo l'attesa il documento può essere cambiato (nessuna unità: clamp
    // con minimo > massimo darebbe un errore)
    if (u != null && pane.unitCount >= 1) {
      pane.goToUnit(u.clamp(1, pane.unitCount));
    }
  }

  Future<void> _addBookmark() async {
    final store = _store;
    if (store == null || !pane.hasPositions) return;
    final pos = pane.position;
    final label = pane.describe?.call(pos) ?? '${pane.unitLabel} ${pane.unit}';
    // segnalibro che c'era già in questo punto (si rimette con «Annulla»)
    ReaderBookmark? replaced;
    for (final b in _bookmarks) {
      if (b.position == pos) replaced = b;
    }
    final List<ReaderBookmark> list;
    try {
      list = await store.addBookmark(
        widget.path,
        ReaderBookmark(pos, label, DateTime.now()),
      );
    } catch (_) {
      // database non scrivibile (disco pieno): avviso invece di un errore
      if (mounted) showSnack(context, 'Impossibile salvare il segnalibro.');
      return;
    }
    if (!mounted) return;
    setState(() => _bookmarks = list);
    showUndoSnackBar(
      context,
      'Segnalibro aggiunto: $label',
      onUndo: () async {
        var l = await store.removeBookmark(widget.path, pos);
        if (replaced != null) {
          l = await store.addBookmark(widget.path, replaced);
        }
        if (mounted) setState(() => _bookmarks = l);
      },
    );
  }

  Future<void> _removeBookmark(ReaderBookmark b) async {
    final store = _store;
    if (store == null) return;
    final List<ReaderBookmark> list;
    try {
      list = await store.removeBookmark(widget.path, b.position);
    } catch (_) {
      if (mounted) showSnack(context, 'Impossibile eliminare il segnalibro.');
      return;
    }
    if (!mounted) return;
    setState(() => _bookmarks = list);
    showUndoSnackBar(
      context,
      'Segnalibro eliminato: ${b.label.isEmpty ? '- -' : b.label}',
      onUndo: () async {
        final l = await store.addBookmark(widget.path, b);
        if (mounted) setState(() => _bookmarks = l);
      },
    );
  }

  Future<void> _copyAll() async {
    final text = pane.plainText?.call();
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showSnack(context, 'Testo copiato negli appunti.');
  }

  Future<void> _openArchiveEntry(ArchiveEntry e) async {
    try {
      final out = await extractArchiveEntry(widget.path, e.name);
      if (mounted) await openInReader(context, out, title: p.basename(e.name));
    } catch (err) {
      if (!mounted) return;
      final why = switch (err) {
        FormatException(:final message) when message.trim().isNotEmpty =>
          ' ($message)',
        FileSystemException e => ': ${fileErrorMessage(e)}',
        ReaderFileTooLargeException() => ': l\'archivio è troppo grande.',
        ReaderTimeoutException() => ': l\'estrazione richiede troppo tempo.',
        _ => ': la voce è danneggiata o in un formato non supportato.',
      };
      showSnack(context, 'Impossibile aprire ${e.name}$why');
    }
  }

  /// Blocchi appunti di OneNote dall'account Microsoft collegato; senza
  /// OneDrive collegato un avviso con «Collega» (Collegamenti → OneDrive)
  /// invece di una schermata vuota con l'errore.
  Future<void> _openOneNote() async {
    final s = context.read<AppServices>();
    if (await s.onedrive.connected()) {
      if (!mounted) return;
      await Navigator.of(context)
          .push(MaterialPageRoute<void>(builder: (_) => const OneNoteScreen()));
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text(
            'Per aprire OneNote collega l\'account Microsoft in '
            'Collegamenti → OneDrive.',
          ),
          action: AppSnackBarAction(
            label: 'Collega',
            onPressed: () {
              if (!mounted) return;
              Navigator.of(context).popUntil((r) => r.isFirst);
              s.openRoute.call(AppRoutes.links);
            },
          ),
        ),
      );
  }

  /// Collegamento di un documento che non è una pagina web: nota di
  /// Obsidian ("note:nome"), etichetta ("tag:#nome", la si cerca) o file
  /// relativo (pagine di un'esportazione di Notion).
  Future<void> _openLink(String link) async {
    if (link.startsWith('tag:')) {
      final q = link.substring(4);
      _query.text = q;
      setState(() => _findOpen = true);
      pane.find(q);
      return;
    }
    if (link.startsWith('#')) return;
    final dir = p.dirname(widget.path);
    String? target;
    if (link.startsWith('note:')) {
      final name = link.substring(5).trim();
      final ext = p.extension(name).toLowerCase();
      final names = [
        if (ext.isEmpty || ext.length > 6) ...['$name.md', '$name.markdown'],
        name,
      ];
      for (final n in names) {
        final f = File(p.join(dir, n));
        if (f.existsSync()) {
          target = f.path;
          break;
        }
      }
      if (target == null) {
        for (final n in names) {
          target = findNear(dir, p.basename(n), depth: 2);
          if (target != null) break;
        }
      }
    } else {
      var rel = link.split('#').first;
      try {
        rel = Uri.decodeFull(rel);
      } catch (_) {}
      final full = p.normalize(p.join(dir, rel));
      // solo file vicini al documento: niente percorsi di rete o assoluti
      // (un link «\\server\x» farebbe accedere il PC a un altro computer)
      if (rel.isNotEmpty &&
          !rel.contains('://') &&
          !p.isAbsolute(rel) &&
          !rel.startsWith(r'\\') &&
          p.isWithin(p.dirname(dir), full)) {
        final f = File(full);
        if (f.existsSync()) target = f.path;
      }
    }
    if (!mounted) return;
    if (target == null) {
      showSnack(context, 'Nota non trovata: ${link.replaceFirst('note:', '')}');
      return;
    }
    await openInReader(context, target);
  }

  void _info(ReaderFormat format) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Informazioni file')),
          body: FileInfoView(
            path: widget.path,
            format: format,
            onOpenExternal: _openDefault,
            onShare: _share,
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------- Viste

  Widget _view(_Loaded l) {
    final start = _savedPos;
    return switch (l.content) {
      DocContent(:final doc) => DocumentView(
        doc: doc,
        controller: pane,
        initialPosition: start,
        onLink: _openLink,
      ),
      DjvuContent(:final doc, :final texts) => DjvuView(
        doc: doc,
        texts: texts,
        controller: pane,
        initialPage: start,
      ),
      PdfContent(:final path) => PdfView(
        path: path,
        controller: pane,
        initialPage: start,
      ),
      ImageContent(:final path, :final bytes, :final svg) => ImageView(
        path: path,
        bytes: bytes,
        svg: svg,
        controller: pane,
        onUnsupported: (context) => FileInfoView(
          path: widget.path,
          format: l.format,
          message:
              'Questa immagine (${l.format.label}) non si può decodificare su questo dispositivo.',
          onOpenExternal: _openDefault,
          onShare: _share,
        ),
      ),
      MediaContent(
        :final path,
        :final video,
        :final transcript,
        :final transcriptPath,
      ) =>
        MediaView(
          path: path,
          video: video,
          controller: pane,
          transcript: transcript,
          transcriptName: transcriptPath == null
              ? null
              : p.basename(transcriptPath),
          initialSeconds: start,
        ),
      InkContent(:final doc) => InkView(
        doc: doc,
        controller: pane,
        initialPage: start,
      ),
      OutlineContent(:final doc) => OutlineView(
        doc: doc,
        controller: pane,
        initialPosition: start,
      ),
      ArchiveContent(:final entries) => ArchiveView(
        entries: entries,
        controller: pane,
        onOpen: _openArchiveEntry,
      ),
      InfoContent(:final message, :final onenote) => FileInfoView(
        path: widget.path,
        format: l.format,
        message: message,
        onOpenExternal: _openDefault,
        onShare: _share,
        onOneNote: onenote ? _openOneNote : null,
      ),
    };
  }

  String? _notice(ReaderContent c) => switch (c) {
    DocContent(:final doc) => doc.notice,
    PdfContent(:final notice) => notice,
    InkContent(:final doc) => doc.notice,
    DjvuContent(:final notice) => notice,
    ArchiveContent(:final notice) => notice,
    _ => null,
  };

  Set<ReaderAction> _actions(ReaderContent c) => switch (c) {
    DocContent(:final actions) => actions,
    ArchiveContent(:final actions) => actions,
    _ => const {},
  };

  String? get _positionLabel {
    if (pane.unitCount <= 0 || pane.unit <= 0) return null;
    return '${pane.unitLabel} ${pane.unit} di ${pane.unitCount}';
  }

  /// Scorciatoie con Ctrl (e ⌘ su macOS).
  Map<ShortcutActivator, VoidCallback> get _shortcuts {
    final out = <ShortcutActivator, VoidCallback>{};
    void both(LogicalKeyboardKey key, VoidCallback f) {
      out[SingleActivator(key, control: true)] = f;
      out[SingleActivator(key, meta: true)] = f;
    }

    for (final k in [
      LogicalKeyboardKey.equal,
      LogicalKeyboardKey.add,
      LogicalKeyboardKey.numpadAdd,
    ]) {
      both(k, () => pane.zoom(1));
    }
    for (final k in [
      LogicalKeyboardKey.minus,
      LogicalKeyboardKey.numpadSubtract,
    ]) {
      both(k, () => pane.zoom(-1));
    }
    for (final k in [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0]) {
      both(k, () => pane.zoom(0));
    }
    both(LogicalKeyboardKey.keyD, _addBookmark);
    // ⌘G su macOS è "trova successivo": qui solo Ctrl+G.
    out[const SingleActivator(LogicalKeyboardKey.keyG, control: true)] =
        _goToDialog;
    out[const SingleActivator(LogicalKeyboardKey.f11)] = _toggleFullscreen;
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Loaded>(
      future: _future,
      builder: (context, snap) {
        final l = snap.data;
        if (snap.hasError) {
          // errore imprevisto: messaggio con «Apri con…» e «Condividi»,
          // come per i file che il lettore non mostra
          return Scaffold(
            appBar: AppBar(title: Text(_title)),
            body: FileInfoView(
              path: widget.path,
              format: detectFormat(widget.path),
              message:
                  'Impossibile aprire il file nell\'app: prova con un\'altra '
                  'app.',
              onOpenExternal: _openDefault,
              onShare: _share,
            ),
          );
        }
        if (l == null) {
          return Scaffold(
            appBar: AppBar(
              title: Text(_title, overflow: TextOverflow.ellipsis),
            ),
            body: const Center(child: CircularProgressIndicator()),
          );
        }
        return _scaffoldFor(context, l);
      },
    );
  }

  Widget _scaffoldFor(BuildContext context, _Loaded l) {
    final t = context.tokens;
    final narrow = MediaQuery.sizeOf(context).width < 600;
    final actions = _actions(l.content);
    var notice = _noticeHidden ? null : _notice(l.content);
    if (notice == null && actions.isNotEmpty && !_noticeHidden) {
      notice = actions.contains(ReaderAction.oneNote)
          ? 'Per la sezione completa usa OneNote.'
          : 'Per la resa completa aprilo con un\'altra app.';
    }
    final pos = _positionLabel;
    final hasDrawer = pane.hasPositions || pane.outline.isNotEmpty;
    final canBookmark = pane.hasPositions && _store != null;
    final body = FindShortcuts(
      onFind: _openFind,
      onClose: _closeFind,
      onNext: _findOpen ? () => pane.step(1) : null,
      onPrevious: _findOpen ? () => pane.step(-1) : null,
      extra: _shortcuts,
      child: Column(
        children: [
          if (_findOpen)
            FindBar(
              controller: _query,
              focusNode: _queryFocus,
              onChanged: pane.find,
              onNext: () => pane.step(1),
              onPrevious: () => pane.step(-1),
              onClose: _closeFind,
              total: pane.matchCount,
              current: pane.matchIndex,
              searching: pane.searching,
            ),
          if (notice != null && !_fullscreen)
            // l'avviso non occupa più di un terzo dell'altezza: con la finestra
            // bassa e i caratteri grandi scorre invece di spingere fuori il
            // documento (Column senza spazio)
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height / 3,
              ),
              child: SingleChildScrollView(
                child: Material(
                  color: t.navActive.first.withValues(alpha: 0.18),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                    // testo e pulsanti in una riga se c'è posto, altrimenti i
                    // pulsanti vanno sotto (finestra stretta, caratteri grandi:
                    // il testo non resta senza larghezza)
                    child: AdaptiveActionRow(
                      leading: Icon(
                        Icons.info_outline,
                        size: 18,
                        color: t.cyanSoft,
                      ),
                      gap: 10,
                      minBody: 160,
                      body: Text(
                        notice,
                        style: TextStyle(fontSize: 12, color: t.textSecondary),
                      ),
                      actionLabel: [
                        if (actions.contains(ReaderAction.oneNote)) 'OneNote',
                        if (actions.contains(ReaderAction.openWith))
                          'Apri con…',
                      ].join(' '),
                      actionExtra:
                          40.0 +
                          48.0 *
                              [
                                actions.contains(ReaderAction.oneNote),
                                actions.contains(ReaderAction.openWith),
                              ].where((x) => x).length,
                      action: Wrap(
                        alignment: WrapAlignment.end,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (actions.contains(ReaderAction.oneNote))
                            TextButton(
                              onPressed: _openOneNote,
                              child: const Text('OneNote'),
                            ),
                          if (actions.contains(ReaderAction.openWith))
                            TextButton(
                              onPressed: _openWith,
                              child: const Text('Apri con…'),
                            ),
                          IconButton(
                            tooltip: 'Nascondi',
                            icon: const Icon(Icons.close, size: 18),
                            onPressed: () =>
                                setState(() => _noticeHidden = true),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: Stack(
              children: [
                // Vista creata una volta sola: pagina, ricerca e zoom
                // aggiornano la barra senza ricostruire il documento.
                Positioned.fill(
                  child: RepaintBoundary(child: _content ??= _view(l)),
                ),
                if (_fullscreen)
                  Positioned(
                    top: MediaQuery.paddingOf(context).top + 8,
                    right: 8,
                    child: IconButton.filledTonal(
                      tooltip: 'Esci da schermo intero (F11)',
                      icon: const Icon(Icons.fullscreen_exit),
                      onPressed: _toggleFullscreen,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    final menu = PopupMenuButton<String>(
      tooltip: 'Altro',
      onSelected: (v) => switch (v) {
        'zoomIn' => pane.zoom(1),
        'zoomOut' => pane.zoom(-1),
        'zoomReset' => pane.zoom(0),
        'fit' => pane.toggleFit(),
        'bookmark' => _addBookmark(),
        'full' => _toggleFullscreen(),
        'copy' => _copyAll(),
        'open' => _openWith(),
        'share' => _share(),
        'info' => _info(l.format),
        _ => null,
      },
      itemBuilder: (_) => [
        if (pane.canZoom) ...[
          const PopupMenuItem(
            value: 'zoomIn',
            child: _MenuRow(Icons.zoom_in, 'Ingrandisci', 'Ctrl +'),
          ),
          const PopupMenuItem(
            value: 'zoomOut',
            child: _MenuRow(Icons.zoom_out, 'Riduci', 'Ctrl −'),
          ),
          PopupMenuItem(
            value: 'zoomReset',
            child: _MenuRow(
              Icons.fit_screen_outlined,
              l.content is PdfContent
                  ? 'Adatta alla larghezza'
                  : 'Dimensione normale',
              'Ctrl 0',
            ),
          ),
        ],
        if (pane.onToggleFit != null)
          CheckedPopupMenuItem(
            value: 'fit',
            checked: pane.fitWidth,
            child: const Text('Testo a tutta larghezza'),
          ),
        if (narrow && canBookmark)
          const PopupMenuItem(
            value: 'bookmark',
            child: _MenuRow(
              Icons.bookmark_add_outlined,
              'Aggiungi segnalibro',
              'Ctrl D',
            ),
          ),
        if (narrow)
          const PopupMenuItem(
            value: 'full',
            child: _MenuRow(Icons.fullscreen, 'Schermo intero', 'F11'),
          ),
        if (pane.plainText != null)
          const PopupMenuItem(
            value: 'copy',
            child: _MenuRow(
              Icons.copy_all_outlined,
              'Copia tutto il testo',
              null,
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'open',
          child: _MenuRow(Icons.open_in_new, 'Apri con…', null),
        ),
        const PopupMenuItem(
          value: 'share',
          child: _MenuRow(Icons.ios_share, 'Condividi', null),
        ),
        const PopupMenuItem(
          value: 'info',
          child: _MenuRow(Icons.info_outline, 'Informazioni file', null),
        ),
      ],
    );
    return Scaffold(
      key: _scaffold,
      appBar: _fullscreen
          ? null
          : AppBar(
              title: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title, overflow: TextOverflow.ellipsis),
                  Text(
                    pos ?? l.format.label,
                    style: TextStyle(
                      fontSize: 12,
                      color: pos == null ? t.textMuted : t.cyanSoft,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
              actions: [
                if (pane.canFind)
                  IconButton(
                    tooltip: 'Trova nel testo (Ctrl+F)',
                    icon: const Icon(Icons.search),
                    onPressed: _openFind,
                  ),
                if (pane.canGoTo)
                  IconButton(
                    tooltip: pane.unitLabel == 'Pagina'
                        ? 'Vai alla pagina (Ctrl+G)'
                        : 'Vai a… (Ctrl+G)',
                    icon: const Icon(Icons.find_in_page_outlined),
                    onPressed: _goToDialog,
                  ),
                if (hasDrawer)
                  IconButton(
                    tooltip: 'Indice e segnalibri',
                    icon: const Icon(Icons.toc),
                    onPressed: () => _scaffold.currentState?.openEndDrawer(),
                  ),
                if (!narrow && canBookmark)
                  IconButton(
                    tooltip: 'Aggiungi segnalibro (Ctrl+D)',
                    icon: const Icon(Icons.bookmark_add_outlined),
                    onPressed: _addBookmark,
                  ),
                if (!narrow)
                  IconButton(
                    tooltip: 'Schermo intero (F11)',
                    icon: const Icon(Icons.fullscreen),
                    onPressed: _toggleFullscreen,
                  ),
                menu,
              ],
            ),
      endDrawer: hasDrawer
          ? ReaderOutlineDrawer(
              outline: pane.outline,
              bookmarks: _bookmarks,
              current: pane.position,
              canBookmark: canBookmark,
              onGo: (pos) {
                Navigator.of(context).pop();
                pane.goToPosition(pos);
              },
              onAddBookmark: () {
                Navigator.of(context).pop();
                _addBookmark();
              },
              onRemoveBookmark: _removeBookmark,
            )
          : null,
      body: body,
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow(this.icon, this.label, this.shortcut);
  final IconData icon;
  final String label;
  final String? shortcut;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Icon(icon, size: 20),
      const SizedBox(width: 12),
      Expanded(child: Text(label)),
      if (shortcut != null)
        Text(
          shortcut!,
          style: TextStyle(fontSize: 12, color: context.tokens.textMuted),
        ),
    ],
  );
}

/// Indice del documento e segnalibri del file.
class ReaderOutlineDrawer extends StatelessWidget {
  const ReaderOutlineDrawer({
    super.key,
    required this.outline,
    required this.bookmarks,
    required this.current,
    required this.canBookmark,
    required this.onGo,
    required this.onAddBookmark,
    required this.onRemoveBookmark,
  });

  final List<ReaderTocItem> outline;
  final List<ReaderBookmark> bookmarks;
  final int current;
  final bool canBookmark;
  final ValueChanged<int> onGo;
  final VoidCallback onAddBookmark;
  final ValueChanged<ReaderBookmark> onRemoveBookmark;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    // Voce dell'indice in cui si trova la posizione corrente.
    var active = -1;
    for (var i = 0; i < outline.length; i++) {
      if (outline[i].position <= current) active = i;
    }
    return Drawer(
      width: 340,
      child: DefaultTabController(
        length: 2,
        child: SafeArea(
          child: Column(
            children: [
              TabBar(
                labelColor: t.navActiveText,
                indicatorColor: t.cyan,
                tabs: [
                  const Tab(text: 'Indice'),
                  Tab(
                    text: bookmarks.isEmpty
                        ? 'Segnalibri'
                        : 'Segnalibri (${bookmarks.length})',
                  ),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    outline.isEmpty
                        ? const EmptyState(
                            icon: Icons.toc,
                            message: 'Questo file non ha un indice.',
                          )
                        : ListView.builder(
                            itemCount: outline.length,
                            itemBuilder: (context, i) {
                              final e = outline[i];
                              return ListTile(
                                dense: true,
                                selected: i == active,
                                selectedColor: t.cyanSoft,
                                contentPadding: EdgeInsets.only(
                                  left: 16.0 + 16 * e.level.clamp(0, 6),
                                  right: 12,
                                ),
                                title: Text(
                                  e.title,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontWeight: e.level == 0
                                        ? FontWeight.w600
                                        : FontWeight.w400,
                                  ),
                                ),
                                onTap: () => onGo(e.position),
                              );
                            },
                          ),
                    Column(
                      children: [
                        if (canBookmark)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: onAddBookmark,
                                icon: const Icon(Icons.bookmark_add_outlined),
                                label: const Text('Aggiungi segnalibro qui'),
                              ),
                            ),
                          ),
                        Expanded(
                          child: bookmarks.isEmpty
                              ? const EmptyState(
                                  icon: Icons.bookmark_border,
                                  message: 'Nessun segnalibro in questo file.',
                                )
                              : ListView(
                                  children: [
                                    for (final b in bookmarks)
                                      ListTile(
                                        leading: Icon(
                                          Icons.bookmark,
                                          color: t.cyanSoft,
                                        ),
                                        title: Text(
                                          b.label.isEmpty ? '- -' : b.label,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        onTap: () => onGo(b.position),
                                        trailing: IconButton(
                                          tooltip: 'Elimina segnalibro',
                                          icon: const Icon(
                                            Icons.delete_outline,
                                          ),
                                          onPressed: () => onRemoveBookmark(b),
                                        ),
                                      ),
                                  ],
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Finestra "Vai a…": possiede il proprio controller, così non viene
/// eliminato mentre l'animazione di chiusura lo usa ancora.
class GoToDialog extends StatefulWidget {
  const GoToDialog({
    super.key,
    required this.label,
    required this.current,
    required this.count,
  });
  final String label;
  final int current;
  final int count;

  @override
  State<GoToDialog> createState() => _GoToDialogState();
}

class _GoToDialogState extends State<GoToDialog> {
  late final _ctrl = TextEditingController(text: '${widget.current}');

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, int.tryParse(_ctrl.text.trim()));

  @override
  Widget build(BuildContext context) {
    final label = widget.label;
    return AlertDialog(
      scrollable: true,
      title: Text(
        label == 'Pagina' ? 'Vai alla pagina' : 'Vai a: ${label.toLowerCase()}',
      ),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: '$label (1–${widget.count})'),
        onSubmitted: (_) => _submit(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Vai')),
      ],
    );
  }
}
