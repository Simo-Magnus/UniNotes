import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../core/services/app_services.dart';
import '../books/book_filters.dart';
import '../books/book_form.dart';
import '../study/course_catalog.dart';
import '../books/book_opener.dart';
import 'course_detail_sections.dart';
import 'course_ui.dart';
import 'material_opener.dart';

/// Libri obbligatori e consigliati del corso.
class CourseBooksSection extends StatelessWidget {
  const CourseBooksSection({super.key, required this.books, this.course});
  final List<Book> books;

  /// Corso a cui aggiungere libri fuori dall'elenco del database.
  final Course? course;

  Future<void> _add(BuildContext context) async {
    final s = context.read<AppServices>();
    final catalog = await CourseCatalog.load(s);
    if (!context.mounted) return;
    final saved = await showBookForm(
      context,
      catalog: catalog,
      initialCourseId: course?.id,
    );
    if (saved == null) return;
    await s.books.insert(saved);
    s.revision.bump();
  }

  @override
  Widget build(BuildContext context) {
    // Obbligatori prima, poi consigliati, poi non indicati.
    int rank(Book b) => b.required == true ? 0 : (b.required == false ? 1 : 2);
    final sorted = [...books]..sort((a, b) => rank(a).compareTo(rank(b)));
    return DetailSection(
      title: 'Libri',
      icon: Icons.menu_book_outlined,
      trailing: course == null
          ? null
          : TextButton.icon(
              key: const Key('course-add-books'),
              onPressed: () => _add(context),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Aggiungi libri'),
            ),
      children: [
        if (books.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Nessun libro collegato a questo corso.'),
          )
        else
          for (final b in sorted) _BookTile(book: b),
      ],
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final local = isDownloaded(book);
    final progress = readingProgress(book);
    final details = [
      if (book.author != null) book.author!,
      if (book.edition != null) '${book.edition} ed.',
      if (book.publisher != null) book.publisher!,
      if (book.year != null) '${book.year}',
    ].join(' · ');
    return ListTile(
      leading: Icon(
        local ? Icons.picture_as_pdf_outlined : Icons.book_outlined,
        color: local ? Colors.green.shade700 : scheme.outline,
      ),
      title: Text(book.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (details.isNotEmpty) Text(details),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (book.required == true)
                SmallBadge(
                  label: 'Obbligatorio',
                  color: scheme.error,
                  icon: Icons.priority_high,
                )
              else
                SmallBadge(
                  label: 'Consigliato',
                  color: scheme.primary,
                  icon: Icons.thumb_up_alt_outlined,
                ),
              if (progress != null)
                SmallBadge(
                  label: progress,
                  color: scheme.tertiary,
                  icon: Icons.bookmark_outline,
                ),
              SmallBadge(
                label: isInApp(book)
                    ? 'Nell\'app'
                    : (local ? 'Scaricato' : 'Non scaricato'),
                color: local ? Colors.green.shade700 : scheme.outline,
                icon: local ? Icons.download_done : Icons.cloud_off_outlined,
              ),
              if (book.language != null)
                SmallBadge(
                  label: book.language!,
                  color: scheme.tertiary,
                  icon: Icons.translate,
                ),
              SmallBadge(label: book.format.label, color: scheme.secondary),
            ],
          ),
        ],
      ),
      isThreeLine: true,
      trailing: local
          ? const Icon(Icons.open_in_new)
          : TextButton.icon(
              onPressed: () => attachBookFile(context, book),
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('Aggiungi'),
            ),
      onTap: () {
        if (local) {
          openBook(context, book);
        } else {
          attachBookFile(context, book);
        }
      },
    );
  }
}

/// Materiale didattico raggruppato per tipo e anno accademico.
class CourseMaterialsSection extends StatelessWidget {
  const CourseMaterialsSection({
    super.key,
    required this.course,
    required this.materials,
  });
  final Course course;
  final List<StudyMaterial> materials;

  @override
  Widget build(BuildContext context) {
    final byKind = <MaterialKind, List<StudyMaterial>>{};
    for (final m in materials) {
      byKind.putIfAbsent(m.kind, () => []).add(m);
    }
    return DetailSection(
      title: 'Materiale didattico',
      icon: Icons.folder_open_outlined,
      trailing: course.id == null
          ? null
          : TextButton.icon(
              onPressed: () => addMaterialFiles(context, course.id!),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Aggiungi file'),
            ),
      children: [
        _MaterialsBanner(
          found: course.materialsFound,
          note: course.materialsNote,
        ),
        if (materials.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text('Nessun materiale collegato a questo corso.'),
          )
        else
          for (final kind in MaterialKind.values)
            if (byKind[kind] != null)
              _KindGroup(kind: kind, items: byKind[kind]!),
      ],
    );
  }
}

class _MaterialsBanner extends StatelessWidget {
  const _MaterialsBanner({required this.found, required this.note});
  final bool? found;
  final String? note;

  @override
  Widget build(BuildContext context) {
    if (found == null && note == null) return const SizedBox.shrink();
    final ok = found ?? true;
    final color = ok ? const Color(0xFF34D399) : const Color(0xFF818CF8);
    final title = ok
        ? 'Materiale del docente trovato'
        : 'Materiale alternativo di altro docente${note == null ? '' : ': $note'}';
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(ok ? Icons.verified_outlined : Icons.swap_horiz, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600),
                ),
                if (ok && note != null) Text(note!),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KindGroup extends StatelessWidget {
  const _KindGroup({required this.kind, required this.items});
  final MaterialKind kind;
  final List<StudyMaterial> items;

  IconData get _icon => switch (kind) {
    MaterialKind.lecture => Icons.slideshow_outlined,
    MaterialKind.examText => Icons.quiz_outlined,
    MaterialKind.exercise => Icons.edit_note,
    MaterialKind.notice => Icons.campaign_outlined,
    MaterialKind.other => Icons.description_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final byYear = <String, List<StudyMaterial>>{};
    for (final m in items) {
      byYear
          .putIfAbsent(m.academicYear ?? 'Anno non indicato', () => [])
          .add(m);
    }
    final years = byYear.keys.toList()..sort((a, b) => b.compareTo(a));
    return ExpansionTile(
      leading: Icon(_icon),
      title: Text(kind.label),
      subtitle: Text('${items.length} file'),
      initiallyExpanded: kind == MaterialKind.lecture && items.length <= 20,
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final y in years) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'A.A. $y',
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
          for (final m in byYear[y]!) _MaterialTile(material: m),
        ],
      ],
    );
  }
}

class _MaterialTile extends StatelessWidget {
  const _MaterialTile({required this.material});
  final StudyMaterial material;

  @override
  Widget build(BuildContext context) {
    final m = material;
    final inApp = (m.storedFile ?? '').isNotEmpty;
    final hasFile = materialHasFile(m);
    final page = m.lastPage == null
        ? null
        : 'p. ${m.lastPage}${m.pageCount == null ? '' : '/${m.pageCount}'}';
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        !hasFile
            ? Icons.link_off
            : (inApp ? Icons.phone_android : Icons.insert_drive_file_outlined),
        size: 20,
      ),
      title: Text(m.title),
      subtitle: Text(
        [
          if (!hasFile) 'File non disponibile',
          if (hasFile && !inApp) 'Da copiare nell\'app (al primo tocco)',
          ?page,
          ?m.author,
        ].join(' · '),
      ),
      trailing: hasFile ? const Icon(Icons.chevron_right, size: 18) : null,
      onTap: hasFile ? () => openMaterial(context, m) : null,
    );
  }
}
