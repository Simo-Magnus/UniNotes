import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/academic/student_profile.dart';
import '../../core/catalog/contribute.dart';
import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/services/external_launcher.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../../widgets/undo_snack_bar.dart';
import '../academic/year_widgets.dart';
import '../settings/logic/file_transfer.dart';
import '../study/course_catalog.dart';
import 'book_filter_bar.dart';
import 'book_filters.dart';
import 'book_form.dart';
import 'book_opener.dart';
import 'book_tile.dart';
import 'unsaved_books_dialog.dart';

class _BooksData {
  const _BooksData(this.catalog, this.books, this.profile, this.year);
  final CourseCatalog catalog;
  final List<Book> books;
  final StudentProfile? profile;
  final int? year;
}

/// Catalogo personale dei libri, filtrabile e raggruppato per materia.
class BooksScreen extends StatefulWidget {
  const BooksScreen({super.key});

  @override
  State<BooksScreen> createState() => _BooksScreenState();
}

class _BooksScreenState extends State<BooksScreen> {
  BookFilter _filter = const BookFilter();
  CourseCatalog? _catalog;

  Future<_BooksData> _load(AppServices s) async {
    final catalog = await CourseCatalog.load(s);
    final ids = catalog.visibleIds;
    // Con un percorso: solo i libri dei corsi dell'anno scelto (e quelli
    // senza materia).
    final books = [
      for (final b in await s.books.all())
        if (ids == null || b.courseId == null || ids.contains(b.courseId)) b,
    ];
    _catalog = catalog;
    return _BooksData(catalog, books, s.profile.value, s.selectedYear.value);
  }

  Future<void> _edit([Book? book, int? courseId]) async {
    final catalog = _catalog;
    if (catalog == null) return;
    final cid = courseId ?? _filter.courseId;
    final saved = await showBookForm(
      context,
      catalog: catalog,
      book: book,
      initialCourseId: cid == BookFilter.noCourse ? null : cid,
    );
    if (saved == null || !mounted) return;
    final s = context.read<AppServices>();
    if (saved.id == null) {
      await s.books.insert(saved);
    } else {
      await s.books.update(saved);
    }
    s.revision.bump();
  }

  Future<void> _openFolder(Book b) async {
    final path = b.filePath?.trim();
    if (path == null || path.isEmpty) return;
    final dir = FileSystemEntity.isDirectorySync(path) ? path : p.dirname(path);
    final r = await ExternalLauncher.openPath(dir);
    if (mounted) showLaunchResult(context, r);
  }

  Future<void> _saveCopy(Book b) async {
    final s = context.read<AppServices>();
    try {
      final file = await s.library.fileOf(b);
      if (file == null) {
        if (mounted) showSnack(context, 'Il file non è nell\'app.');
        return;
      }
      final name = p.basename(file.path);
      final ext = p.extension(name).toLowerCase();
      final dest = await FileTransfer.saveBytes(
        dialogTitle: 'Salva una copia del libro',
        fileName: name,
        bytes: await file.readAsBytes(),
        mimeType: switch (ext) {
          '.pdf' => 'application/pdf',
          '.epub' => 'application/epub+zip',
          _ => 'application/octet-stream',
        },
      );
      if (dest != null && mounted) showSnack(context, 'Copia salvata: $dest');
    } catch (e) {
      if (mounted) showSnack(context, 'Salvataggio non riuscito: $e');
    }
  }

  Future<void> _removeFromApp(Book b) async {
    final ok = await confirmDialog(
      context,
      'Rimuovere il file dall\'app?',
      'La copia di "${b.title}" salvata nell\'app verrà eliminata; il libro '
          'resta nel catalogo e il file originale non viene toccato.',
    );
    if (!ok || !mounted) return;
    final s = context.read<AppServices>();
    await s.books.update(b.withFile(storedFile: () => null));
    s.revision.bump();
    if (!mounted) return;
    // la copia si cancella alla chiusura dell'avviso, così «Annulla» la
    // rimette com'era
    showUndoSnackBar(
      context,
      'Copia di «${b.title}» tolta dall\'app.',
      onUndo: () async {
        await s.books.update(b);
        s.revision.bump();
      },
      onCommit: () => s.library.remove(b.storedFile),
    );
  }

  Future<void> _delete(Book b) async {
    final ok = await confirmDialog(
      context,
      'Eliminare il libro?',
      '"${b.title}" verrà rimosso dal catalogo insieme alla copia salvata '
          'nell\'app (il file originale non viene toccato).',
    );
    if (!ok || !mounted) return;
    final s = context.read<AppServices>();
    await s.books.delete(b.id!);
    s.revision.bump();
    if (!mounted) return;
    showUndoSnackBar(
      context,
      'Libro eliminato: «${b.title}».',
      onUndo: () async {
        await s.books.insert(b);
        s.revision.bump();
      },
      onCommit: () => s.library.remove(b.storedFile),
    );
  }

  /// Tieni / Rimuovi / Ripristina un libro proposto dal catalogo. La scelta
  /// resta anche dopo gli aggiornamenti del database.
  Future<void> _choose(Book b, CatalogChoice? choice) async {
    final s = context.read<AppServices>();
    await s.books.update(b.withChoice(catalogChoice: () => choice));
    s.revision.bump();
    if (!mounted) return;
    final message = choice == CatalogChoice.removed
        ? 'Libro rimosso: lo ritrovi in "Libri rimossi".'
        : b.isRemoved
        ? 'Libro ripristinato.'
        : choice == CatalogChoice.kept
        ? 'Libro salvato.'
        : null;
    if (message == null) return;
    // «Annulla»: la scelta di prima (anche la spunta verde)
    showUndoSnackBar(
      context,
      message,
      onUndo: () async {
        await s.books.update(b);
        s.revision.bump();
      },
    );
  }

  /// «Elimina libri non salvati» di un insegnamento: toglie i libri proposti
  /// a cui non è stata messa la spunta verde ([isUnsaved]), come la X di
  /// ognuno: finiscono in «Libri rimossi» (ripristinabili) e restano tolti
  /// anche dopo gli aggiornamenti del database. Nessun file viene toccato:
  /// i libri con un file, gli obbligatori e quelli aggiunti a mano restano.
  Future<void> _deleteUnsaved(Course c, List<Book> unsaved) async {
    if (unsaved.isEmpty) return;
    final ok = await confirmDeleteUnsavedBooks(
      context,
      course: c.name,
      count: unsaved.length,
    );
    if (!ok || !mounted) return;
    final s = context.read<AppServices>();
    for (final b in unsaved) {
      await s.books.update(
        b.withChoice(catalogChoice: () => CatalogChoice.removed),
      );
    }
    s.revision.bump();
    if (!mounted) return;
    showUndoSnackBar(
      context,
      unsaved.length == 1
          ? 'Libro non salvato eliminato: lo ritrovi in "Libri rimossi".'
          : '${unsaved.length} libri non salvati eliminati: li ritrovi in '
                '"Libri rimossi".',
      onUndo: () async {
        for (final b in unsaved) {
          await s.books.update(b);
        }
        s.revision.bump();
      },
    );
  }

  Future<void> _report(Course c) async {
    final url = contributionIssueUrl(
      kind: ContributionKind.books,
      profile: context.read<AppServices>().profile.value,
      course: c,
      year: c.year,
    );
    final r = await ExternalLauncher.openUrl(url.toString());
    if (mounted) showLaunchResult(context, r);
  }

  void _onAction(Book b, BookAction a) => switch (a) {
    BookAction.edit => _edit(b),
    BookAction.openFolder => _openFolder(b),
    BookAction.saveCopy => _saveCopy(b),
    BookAction.removeFromApp => _removeFromApp(b),
    BookAction.delete => _delete(b),
    BookAction.keep => _choose(b, CatalogChoice.kept),
    BookAction.remove => _choose(b, CatalogChoice.removed),
    BookAction.restore => _choose(b, b.userEdited ? CatalogChoice.kept : null),
    BookAction.attachFile => attachBookFile(context, b),
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Libri')),
      floatingActionButton: GlowFab(
        onPressed: () => _edit(),
        icon: const Icon(Icons.add),
        label: const Text('Aggiungi libro'),
      ),
      body: RevisionBuilder<_BooksData>(
        load: _load,
        builder: (context, data) {
          if (data.books.isEmpty && data.catalog.courses.isEmpty) {
            return EmptyState(
              icon: Icons.menu_book_outlined,
              message: 'Nessun libro nel catalogo: aggiungine uno.',
              action: FilledButton.icon(
                onPressed: () => _edit(),
                icon: const Icon(Icons.add),
                label: const Text('Aggiungi libro'),
              ),
            );
          }
          return _body(context, data);
        },
      ),
    );
  }

  Widget _body(BuildContext context, _BooksData data) {
    final catalog = data.catalog;
    final filtered = filterBooks(
      data.books,
      _filter,
      courseName: catalog.nameOf,
    );
    final visible = data.books.where((b) => !b.isRemoved).toList();
    final removedCount = data.books.length - visible.length;
    final covered = coursesWithRequiredCovered(visible);
    final order = [for (final c in catalog.courses) c.id!];
    final groups = {
      for (final g in groupBooksByCourse(filtered, order)) g.key: g.value,
    };
    // Con un percorso e senza filtri: ogni insegnamento dell'anno compare,
    // anche senza libri ("Libri da aggiungere").
    final showAll = data.profile != null && !_filter.isActive;
    final sections = <Widget>[];
    // prima gli insegnamenti con i libri noti (da scaricare o già presenti),
    // poi quelli senza libri, per cui si chiede di aggiungerli; in ciascun
    // gruppo gli insegnamenti a scelta restano per ultimi
    final ordered = [
      for (final c in catalog.courses)
        if (groups[c.id] != null) c,
      for (final c in catalog.courses)
        if (groups[c.id] == null) c,
    ];
    for (final c in ordered) {
      final list = groups[c.id];
      if (list == null && !showAll) continue;
      // libri non salvati dell'insegnamento (anche fuori dai filtri)
      final unsaved = [
        for (final b in visible)
          if (b.courseId == c.id && isUnsaved(b)) b,
      ];
      sections.add(
        _GroupHeader(
          catalog,
          c.id,
          list?.length ?? 0,
          onAdd: () => _edit(null, c.id),
          unsaved: unsaved.length,
          onDeleteUnsaved: () => _deleteUnsaved(c, unsaved),
        ),
      );
      sections.add(
        list == null
            ? _MissingBooks(
                course: c,
                onReport: () => _report(c),
                onAdd: () => _edit(null, c.id),
              )
            : _grid(list, covered),
      );
    }
    final orphans = groups[null];
    if (orphans != null) {
      sections
        ..add(_GroupHeader(catalog, null, orphans.length))
        ..add(_grid(orphans, covered));
    }
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: BookFilterBar(
            catalog: catalog,
            filter: _filter,
            onChanged: (f) => setState(() => _filter = f),
            summary: _summary(visible),
          ),
        ),
        if (removedCount > 0 || _filter.removed)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  key: const Key('removed-books-filter'),
                  showCheckmark: false,
                  avatar: const Icon(Icons.visibility_off_outlined),
                  label: Text('Libri rimossi ($removedCount)'),
                  selected: _filter.removed,
                  onSelected: (v) =>
                      setState(() => _filter = _filter.copyWith(removed: v)),
                ),
              ),
            ),
          ),
        if (sections.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyState(
              icon: Icons.filter_alt_off_outlined,
              message: _filter.removed
                  ? 'Nessun libro rimosso.'
                  : 'Nessun libro corrisponde ai filtri.',
            ),
          ),
        for (final w in sections) SliverToBoxAdapter(child: w),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ],
    );
  }

  /// «n/m»: n posseduti (scaricati o segnati come posseduti), m totali; solo
  /// il numero, senza la parola «Libri».
  static String _summary(List<Book> all) {
    final owned = all
        .where((b) => isDownloaded(b) || b.ownership == BookOwnership.owned)
        .length;
    return '$owned/${all.length}';
  }

  Widget _grid(List<Book> books, Set<int> covered) => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth >= 1100 ? 2 : 1;
      final w = (c.maxWidth / cols).floorToDouble();
      return Wrap(
        children: [
          for (final b in books)
            SizedBox(
              width: w,
              child: GlassCard(
                child: BookTile(
                  key: ValueKey(b.id),
                  book: b,
                  toProcure: needsProcurement(b, covered: covered),
                  onOpen: () => openBook(context, b),
                  onAction: (a) => _onAction(b, a),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// Intestazione di un insegnamento: nome, numero di libri, «Aggiungi libro
/// extra» e, se ci sono libri proposti non salvati ([unsaved]), il menu con
/// «Elimina libri non salvati».
class _GroupHeader extends StatelessWidget {
  const _GroupHeader(
    this.catalog,
    this.courseId,
    this.count, {
    this.onAdd,
    this.unsaved = 0,
    this.onDeleteUnsaved,
  });
  final CourseCatalog catalog;
  final int? courseId;
  final int count;
  final VoidCallback? onAdd;
  final int unsaved;
  final VoidCallback? onDeleteUnsaved;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // solo il nome dell'insegnamento: niente pallino né riquadro con il
    // nome dell'università
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              catalog.nameOf(courseId),
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ),
          if (count > 0) Text('$count', style: theme.textTheme.bodySmall),
          if (onAdd != null)
            IconButton(
              tooltip: 'Aggiungi libro extra',
              icon: const Icon(Icons.add),
              onPressed: onAdd,
            ),
          if (unsaved > 0 && onDeleteUnsaved != null)
            PopupMenuButton<String>(
              key: ValueKey('course-books-menu-$courseId'),
              tooltip: 'Altre azioni',
              onSelected: (_) => onDeleteUnsaved!(),
              itemBuilder: (_) => [
                PopupMenuItem<String>(
                  key: ValueKey('delete-unsaved-$courseId'),
                  value: 'delete-unsaved',
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.delete_sweep_outlined),
                    title: const Text('Elimina libri non salvati'),
                    subtitle: Text(
                      unsaved == 1
                          ? '1 libro senza spunta verde'
                          : '$unsaved libri senza spunta verde',
                    ),
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Insegnamento senza libri: "Da aggiungere" (o "nessun libro previsto")
/// con la segnalazione precompilata su GitHub.
class _MissingBooks extends StatelessWidget {
  const _MissingBooks({
    required this.course,
    required this.onReport,
    required this.onAdd,
  });
  final Course course;
  final VoidCallback onReport;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final none = course.booksStatus == 'nessun_libro';
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Tinta d'area dei Libri: solo sull'icona.
                Icon(Icons.menu_book_outlined, size: 18, color: t.tintBooks),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    none ? 'Nessun libro previsto' : 'Libri da aggiungere',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: t.textPrimary,
                    ),
                  ),
                ),
                if (!none) const MutedChip('Da aggiungere'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              none
                  ? 'Il programma non indica libri di testo.'
                  : 'Il database non ha ancora i libri di questo '
                        'insegnamento: segnalali così compaiono a tutti.',
              style: TextStyle(fontSize: 13, color: t.textMuted),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (!none)
                  OutlinedButton.icon(
                    onPressed: onReport,
                    icon: const Icon(Icons.flag_outlined, size: 18),
                    label: const Text('Segnala i libri'),
                  ),
                TextButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Aggiungi libro'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
