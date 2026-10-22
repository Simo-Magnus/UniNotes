import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/undo_snack_bar.dart';
import 'reader_formats.dart';
import 'reader_screen.dart';
import 'reader_store.dart';
import 'reader_text.dart';
import 'views/file_info_view.dart';
import '../../core/constants/text_limits.dart';

/// Cartella dell'app mostrata nella sezione File.
class AppFolder {
  const AppFolder(this.label, this.icon, this.dir, this.description);
  final String label;
  final IconData icon;
  final Directory dir;
  final String description;
}

/// Cartelle dello studente: libri, materiali, allegati, appunti.
Future<List<AppFolder>> appFolders(AppServices s) async => [
  AppFolder(
    'Appunti',
    Icons.mic_none,
    await s.notes.root(),
    'Lezioni registrate, trascrizioni e appunti personali dei corsi',
  ),
  AppFolder(
    'Libri',
    Icons.menu_book_outlined,
    await s.library.directory(),
    'Libri scaricati degli insegnamenti',
  ),
  AppFolder(
    'Materiali',
    Icons.school_outlined,
    await s.materialsLibrary.directory(),
    'Materiale didattico dei corsi',
  ),
  AppFolder(
    'Allegati',
    Icons.attach_file,
    await s.attachmentsLibrary.directory(),
    'File di teoria, esercizi e ripasso allegati agli argomenti dei moduli',
  ),
];

/// Massimo di file indicizzati per la ricerca per nome.
const _maxIndexed = 8000;

/// Tutti i file sotto [dirs] (senza cartelle e file nascosti).
Future<List<File>> listFilesDeep(
  List<Directory> dirs, {
  int max = _maxIndexed,
}) async {
  final out = <File>[];
  for (final d in dirs) {
    if (!await d.exists()) continue;
    try {
      // le sottocartelle illeggibili si saltano senza fermare l'elenco
      await for (final e
          in d
              .list(recursive: true, followLinks: false)
              .handleError((Object _) {})) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: d.path);
        if (p.split(rel).any((part) => part.startsWith('.')) ||
            rel.endsWith('.part')) {
          continue;
        }
        out.add(e);
        if (out.length >= max) return out;
      }
    } catch (_) {}
  }
  return out;
}

class _FilesData {
  const _FilesData(this.folders, this.counts, this.recent, this.index);
  final List<AppFolder> folders;
  final List<int> counts;
  final List<RecentFile> recent;
  final List<File> index;
}

/// File: le cartelle dell'app, i file recenti e la ricerca per nome; ogni
/// file si apre nel lettore interno. Niente «Apri un file…»: la sezione
/// mostra i file dell'app (sul computer un file si può ancora trascinare
/// qui per aprirlo).
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key});

  @override
  State<FilesScreen> createState() => _FilesScreenState();
}

class _FilesScreenState extends State<FilesScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _dragging = false;
  int _reload = 0;

  /// «Mostra altri»: tutti i recenti ricordati invece dei primi venti.
  bool _allRecent = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<_FilesData> _load(AppServices s) async {
    final folders = await appFolders(s);
    final index = await listFilesDeep([for (final f in folders) f.dir]);
    final counts = [
      for (final f in folders)
        index.where((x) => p.isWithin(f.dir.path, x.path)).length,
    ];
    final recent = await ReaderStore(s.settings).recent();
    return _FilesData(folders, counts, recent, index);
  }

  Future<void> _open(String path, {String? title}) async {
    await openInReader(context, path, title: title);
    if (mounted) setState(() => _reload++);
  }

  Future<void> _forget(RecentFile r) => _changeRecent(
    (store) => store.removeRecent(r.path),
    '«${r.title}» tolto dai recenti.',
  );

  Future<void> _clearRecent() => _changeRecent(
    (store) => store.clearRecent(),
    'Elenco dei recenti cancellato.',
  );

  /// Modifica dei recenti con «Annulla» (l'elenco torna com'era).
  Future<void> _changeRecent(
    Future<void> Function(ReaderStore store) change,
    String message,
  ) async {
    final store = ReaderStore(context.read<AppServices>().settings);
    final before = await store.recent();
    await change(store);
    if (!mounted) return;
    setState(() => _reload++);
    showUndoSnackBar(
      context,
      message,
      onUndo: () async {
        await store.setRecent(before);
        if (mounted) setState(() => _reload++);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body = RevisionBuilder<_FilesData>(
      load: _load,
      deps: [_reload],
      builder: (context, data) => _body(context, data),
    );
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      body = DropTarget(
        onDragEntered: (_) => setState(() => _dragging = true),
        onDragExited: (_) => setState(() => _dragging = false),
        onDragDone: (d) {
          setState(() => _dragging = false);
          if (d.files.isNotEmpty) _open(d.files.first.path);
        },
        child: Stack(
          children: [
            Positioned.fill(child: body),
            if (_dragging)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    margin: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.tokens.cyan.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AppScale.radiusCard),
                      border: Border.all(color: context.tokens.cyan, width: 2),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      'Rilascia il file per aprirlo',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: context.tokens.textPrimary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('File'),
        actions: [
          IconButton(
            tooltip: 'Formati supportati',
            icon: const Icon(Icons.help_outline),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const SupportedFormatsDialog(),
            ),
          ),
        ],
      ),
      body: body,
    );
  }

  Widget _body(BuildContext context, _FilesData data) {
    final t = context.tokens;
    final q = _query.trim();
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          child: TextField(
            controller: _search,
            inputFormatters: TextLimits.max(TextLimits.search),
            decoration: InputDecoration(
              hintText: 'Cerca per nome in tutte le cartelle',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: q.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Cancella',
                      icon: const Icon(Icons.close),
                      onPressed: () => setState(() {
                        _search.clear();
                        _query = '';
                      }),
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (q.isNotEmpty)
          _results(context, data, q)
        else ...[
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const CardHeader(
                  title: 'Cartelle dell\'app',
                  icon: Icons.folder_open_outlined,
                ),
                for (var i = 0; i < data.folders.length; i++)
                  ListTile(
                    leading: Icon(data.folders[i].icon, color: t.cyanSoft),
                    // nomi delle cartelle un po' più grandi
                    title: Text(
                      data.folders[i].label,
                      style: Theme.of(context).textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      data.folders[i].description,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      '${data.counts[i]}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: t.cyanSoft,
                      ),
                    ),
                    onTap: () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => FolderBrowserScreen(
                            dir: data.folders[i].dir,
                            title: data.folders[i].label,
                          ),
                        ),
                      );
                      if (mounted) setState(() => _reload++);
                    },
                  ),
                const SizedBox(height: 6),
              ],
            ),
          ),
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CardHeader(
                  title: 'Recenti',
                  icon: Icons.history,
                  trailing: data.recent.isEmpty
                      ? null
                      : TextButton(
                          onPressed: _clearRecent,
                          child: const Text('Cancella elenco'),
                        ),
                ),
                if (data.recent.isEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
                    child: Text(
                      'I file aperti nel lettore compaiono qui.',
                      style: TextStyle(color: t.textMuted, fontSize: 13),
                    ),
                  ),
                for (final r in data.recent.take(
                  _allRecent ? ReaderStore.maxRecent : ReaderStore.shownRecent,
                ))
                  _recentTile(context, r),
                if (data.recent.length > ReaderStore.shownRecent)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: TextButton.icon(
                        key: const Key('recent-more'),
                        onPressed: () =>
                            setState(() => _allRecent = !_allRecent),
                        icon: Icon(
                          _allRecent ? Icons.expand_less : Icons.expand_more,
                        ),
                        label: Text(
                          _allRecent
                              ? 'Mostra meno'
                              : 'Mostra altri '
                                    '(${data.recent.length - ReaderStore.shownRecent})',
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _recentTile(BuildContext context, RecentFile r) {
    final t = context.tokens;
    final exists = File(r.path).existsSync();
    final f = detectFormat(r.path);
    return ListTile(
      leading: Icon(
        readerFamilyIcon(f.family),
        color: exists ? t.cyanSoft : t.textMuted,
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        exists
            ? '${f.label} · ${formatDateTime(r.opened)}'
            : 'Non più disponibile su questo dispositivo',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      enabled: exists,
      onTap: exists ? () => _open(r.path, title: r.title) : null,
      trailing: IconButton(
        tooltip: 'Togli dai recenti',
        icon: const Icon(Icons.close),
        onPressed: () => _forget(r),
      ),
    );
  }

  Widget _results(BuildContext context, _FilesData data, String q) {
    final t = context.tokens;
    final fq = foldText(q);
    final hits = [
      for (final f in data.index)
        if (foldText(p.basename(f.path)).contains(fq)) f,
    ];
    String folderOf(File f) {
      for (final d in data.folders) {
        if (p.isWithin(d.dir.path, f.path)) {
          final rel = p.dirname(p.relative(f.path, from: d.dir.path));
          return rel == '.'
              ? d.label
              : '${d.label} › ${rel.replaceAll(Platform.pathSeparator, ' › ')}';
        }
      }
      return p.dirname(f.path);
    }

    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CardHeader(
            title: 'Risultati',
            trailing: Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                '${hits.length}',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: t.cyanSoft,
                ),
              ),
            ),
          ),
          if (hits.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
              child: Text(
                'Nessun file con «$q» nel nome.',
                style: TextStyle(color: t.textMuted),
              ),
            ),
          for (final f in hits.take(200))
            ListTile(
              leading: Icon(
                readerFamilyIcon(detectFormat(f.path).family),
                color: t.cyanSoft,
              ),
              title: Text(
                p.basename(f.path),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                folderOf(f),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => _open(f.path),
            ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

/// Esplora una cartella: sottocartelle e file, ognuno apribile nel lettore.
class FolderBrowserScreen extends StatefulWidget {
  const FolderBrowserScreen({
    super.key,
    required this.dir,
    required this.title,
  });
  final Directory dir;
  final String title;

  @override
  State<FolderBrowserScreen> createState() => _FolderBrowserScreenState();
}

class _FolderBrowserScreenState extends State<FolderBrowserScreen> {
  late Future<List<FileSystemEntity>> _entries = _list();

  Future<List<FileSystemEntity>> _list() async {
    if (!await widget.dir.exists()) return const [];
    // Cartella o voci senza permesso di lettura (scheda SD, cartelle di
    // sistema): si mostrano le voci leggibili invece di una rotella infinita.
    final all = <FileSystemEntity>[];
    try {
      await for (final e in widget.dir.list().handleError((Object _) {})) {
        // i collegamenti rotti arrivano come Link: non si aprono
        if (e is! File && e is! Directory) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.') || e.path.endsWith('.part')) continue;
        all.add(e);
      }
    } on FileSystemException {
      // elenco interrotto: restano le voci già lette
    }
    all.sort((a, b) {
      final da = a is Directory ? 0 : 1;
      final db = b is Directory ? 0 : 1;
      if (da != db) return da - db;
      return p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase());
    });
    return all;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title, overflow: TextOverflow.ellipsis),
      ),
      body: FutureBuilder<List<FileSystemEntity>>(
        future: _entries,
        builder: (context, snap) {
          final list = snap.data;
          if (list == null) {
            return const Center(child: CircularProgressIndicator());
          }
          if (list.isEmpty) {
            return const EmptyState(
              icon: Icons.folder_off_outlined,
              message: 'La cartella è vuota.',
            );
          }
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              GlassCard(
                child: Column(
                  children: [
                    for (final e in list)
                      if (e is Directory)
                        ListTile(
                          leading: Icon(
                            Icons.folder_outlined,
                            color: t.cyanSoft,
                          ),
                          title: Text(p.basename(e.path)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => FolderBrowserScreen(
                                dir: e,
                                title: p.basename(e.path),
                              ),
                            ),
                          ),
                        )
                      else
                        _fileTile(context, e as File),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _fileTile(BuildContext context, File f) {
    final t = context.tokens;
    final format = detectFormat(f.path);
    var size = '- -';
    try {
      size = formatBytes(f.lengthSync());
    } catch (_) {}
    return ListTile(
      leading: Icon(
        readerFamilyIcon(format.family),
        color: format.supported ? t.cyanSoft : t.textMuted,
      ),
      title: Text(
        p.basename(f.path),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text('${format.label} · $size'),
      onTap: () async {
        await openInReader(context, f.path);
        if (mounted) {
          setState(() {
            _entries = _list();
          });
        }
      },
    );
  }
}

/// Elenco dei formati che il lettore apre (dalla tabella dei formati).
class SupportedFormatsDialog extends StatelessWidget {
  const SupportedFormatsDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final byFamily = <ReaderFamily, List<ReaderFormat>>{};
    for (final f in kReaderFormats) {
      byFamily.putIfAbsent(f.family, () => []).add(f);
    }
    return AlertDialog(
      title: const Text('Formati supportati'),
      content: SizedBox(
        width: 520,
        child: ListView(
          shrinkWrap: true,
          children: [
            Text(
              '«Semplificato»: l\'app ne mostra una versione ridotta (per '
              'esempio solo il testo) e all\'apertura propone l\'app di '
              'riferimento. Lo stesso vale per i file con parti che l\'app '
              'non disegna, come grafici e formule.',
              style: TextStyle(
                fontSize: 12.5,
                color: t.textMuted,
                height: 1.45,
              ),
            ),
            for (final e in byFamily.entries) ...[
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 2),
                child: Row(
                  children: [
                    Icon(readerFamilyIcon(e.key), size: 18, color: t.cyanSoft),
                    const SizedBox(width: 8),
                    Text(
                      e.key.label,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              // Un'estensione per pezzo: si va a capo solo tra un'estensione
              // e l'altra, mai a metà.
              Wrap(
                spacing: 10,
                children: [
                  for (final f in e.value)
                    Text(
                      switch (f.fidelity) {
                        ReaderFidelity.full => f.extension,
                        ReaderFidelity.partial =>
                          '${f.extension}\u00A0(semplificato)',
                        ReaderFidelity.unsupported =>
                          '${f.extension}\u00A0(Apri\u00A0con…)',
                      },
                      style: TextStyle(
                        fontSize: 13,
                        color: t.textSecondary,
                        height: 1.5,
                      ),
                    ),
                ],
              ),
            ],
            for (final (app, hint) in kReaderHints)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '$app: ',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      TextSpan(text: hint),
                    ],
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    color: t.textSecondary,
                    height: 1.5,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Chiudi'),
        ),
      ],
    );
  }
}
