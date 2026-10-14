import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/feedback_service.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../models/attachment.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../../utils/grade_math.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../books/book_opener.dart';
import '../notes/course_notes_screen.dart';
import 'course_catalog.dart';
import 'module_card.dart';
import 'study_ai.dart';
import 'study_sessions_tab.dart' show openStudySession;
import 'study_widgets.dart';
import 'topic_logic.dart';

/// Moduli e argomenti di un corso.
class _CourseTopics {
  const _CourseTopics(
    this.modules,
    this.topics,
    this.attachments,
    this.books,
    this.availableBooks,
  );
  final List<StudyModule> modules;
  final List<Topic> topics;
  final List<Attachment> attachments;
  final List<Book> books;

  /// Id dei libri con il file nell'app (o un percorso esterno valido).
  final Set<int> availableBooks;

  List<Topic> of(StudyModule m) =>
      topics.where((t) => t.moduleId == m.id).toList();
}

/// Scheda "Argomenti": insegnamento → moduli → argomenti con avanzamento.
/// L'insegnamento si cambia toccandone il nome nella card in alto (su
/// schermi larghi anche dall'elenco a sinistra).
class TopicsTab extends StatelessWidget {
  const TopicsTab({
    super.key,
    required this.catalog,
    required this.courseId,
    required this.onCourseChanged,
  });

  final CourseCatalog catalog;
  final int? courseId;
  final ValueChanged<int?> onCourseChanged;

  @override
  Widget build(BuildContext context) {
    final id = courseId;
    final content = id == null
        ? const EmptyState(
            icon: Icons.school_outlined,
            message: 'Seleziona un insegnamento per vederne moduli e argomenti.',
          )
        : _CourseContent(
            key: ValueKey(id),
            catalog: catalog,
            courseId: id,
            onCourseChanged: onCourseChanged,
          );

    if (context.isWide) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 300,
            child: _CourseList(catalog, id, onCourseChanged),
          ),
          const VerticalDivider(width: 1),
          Expanded(child: content),
        ],
      );
    }
    return content;
  }
}

/// Elenco degli insegnamenti (schermi larghi): solo il nome.
class _CourseList extends StatelessWidget {
  const _CourseList(this.catalog, this.selected, this.onSelect);
  final CourseCatalog catalog;
  final int? selected;
  final ValueChanged<int?> onSelect;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        for (final c in catalog.courses)
          ListTile(
            title: Text(c.label, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Tooltip(
              message: c.status.description,
              child: Text(c.status.label),
            ),
            selected: c.id == selected,
            onTap: () => onSelect(c.id),
          ),
      ],
    );
  }
}

/// Sceglie un altro insegnamento (tocco sul nome nella card in alto).
Future<int?> pickCourse(
  BuildContext context,
  CourseCatalog catalog,
  int? selected,
) => showModalBottomSheet<int>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (c) => SafeArea(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.8),
      child: ListView(
        shrinkWrap: true,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text('Insegnamento', style: Theme.of(c).textTheme.titleMedium),
          ),
          for (final course in catalog.courses)
            ListTile(
              title: Text(course.label),
              subtitle: Text(course.status.label),
              selected: course.id == selected,
              trailing: course.id == selected ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(c, course.id),
            ),
        ],
      ),
    ),
  ),
);

class _CourseContent extends StatefulWidget {
  const _CourseContent({
    super.key,
    required this.catalog,
    required this.courseId,
    required this.onCourseChanged,
  });

  final CourseCatalog catalog;
  final int courseId;
  final ValueChanged<int?> onCourseChanged;

  @override
  State<_CourseContent> createState() => _CourseContentState();
}

class _CourseContentState extends State<_CourseContent> {
  /// Ordine mostrato dei moduli: cambia subito al rilascio, poi si salva.
  List<StudyModule>? _order;
  List<StudyModule>? _loaded;

  int get courseId => widget.courseId;
  CourseCatalog get catalog => widget.catalog;

  Future<void> _addModule() async {
    final name = await promptText(context, title: 'Nuovo modulo', label: 'Nome');
    if (name == null || !mounted) return;
    final s = context.read<AppServices>();
    final sort = await s.study.nextModuleSort(courseId);
    await s.study.insertModule(
      StudyModule(courseId: courseId, name: name, sort: sort),
    );
    s.revision.bump();
  }

  Future<void> _changeCourse() async {
    AppFeedback.of(context).tap();
    final id = await pickCourse(context, catalog, courseId);
    if (id != null && id != courseId) widget.onCourseChanged(id);
  }

  Future<void> _reorder(List<StudyModule> mods, int from, int to) async {
    final next = reorderList(mods, from, to);
    if (next == null) return;
    AppFeedback.of(context).toggle();
    setState(() => _order = next);
    final s = context.read<AppServices>();
    await s.study.reorderModules([for (final m in next) m.id!]);
    s.revision.bump();
  }

  @override
  Widget build(BuildContext context) {
    final color = catalog.colorOf(courseId);
    return RevisionBuilder<_CourseTopics>(
      deps: [courseId],
      load: (s) async {
        final books = await s.books.all(courseId: courseId);
        final available = <int>{};
        for (final b in books) {
          final path = b.filePath?.trim() ?? '';
          if (await s.library.fileOf(b) != null ||
              (path.isNotEmpty && await File(path).exists())) {
            available.add(b.id!);
          }
        }
        return _CourseTopics(
          await s.study.modules(courseId),
          await s.study.topicsOfCourse(courseId),
          await s.study.attachmentsOfCourse(courseId),
          books,
          available,
        );
      },
      builder: (context, data) {
        final course = catalog.byId[courseId]!;
        final progress = courseProgress(data.topics.map((t) => t.status));
        // dati nuovi dal database: l'ordine salvato prende il posto di
        // quello mostrato durante il trascinamento
        if (!identical(_loaded, data.modules)) {
          _loaded = data.modules;
          _order = null;
        }
        final modules = _order ?? data.modules;
        final theme = Theme.of(context);
        final header = GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // tocca il nome per cambiare insegnamento
                Semantics(
                  button: true,
                  hint: 'Cambia insegnamento',
                  child: InkWell(
                    key: const Key('course-name'),
                    borderRadius: BorderRadius.circular(8),
                    onTap: _changeCourse,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              catalog.nameOf(courseId),
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          Icon(
                            Icons.unfold_more,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ProgressRow(value: progress, label: 'Avanzamento'),
                const SizedBox(height: 4),
                Text(
                  '${data.modules.length} moduli · '
                  '${data.topics.length} argomenti',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _BooksButton(
                      course: course,
                      books: data.books,
                      available: data.availableBooks,
                    ),
                    OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => CourseNotesScreen(course: course),
                        ),
                      ),
                      icon: const Icon(Icons.mic_none),
                      label: const Text('Registrazioni'),
                    ),
                    FilledButton.tonalIcon(
                      key: const Key('course-focus'),
                      onPressed: () =>
                          openStudySession(context, courseId: courseId),
                      icon: const Icon(Icons.center_focus_strong_outlined),
                      label: const Text('Sessione focus'),
                    ),
                    FilledButton.icon(
                      onPressed: () => askAiStudy(context, course),
                      icon: const Icon(Icons.auto_awesome_outlined),
                      label: const Text('Revisiona con AI'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _addModule,
                  icon: const Icon(Icons.add),
                  label: const Text('Aggiungi modulo'),
                ),
              ],
            ),
          ),
        );
        return ReorderableListView.builder(
          padding: const EdgeInsets.only(bottom: 24),
          buildDefaultDragHandles: false,
          header: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              if (modules.isEmpty)
                const EmptyState(
                  icon: Icons.account_tree_outlined,
                  message:
                      'Nessun modulo. Aggiungi un modulo (es. "Limiti e '
                      'derivate") e poi i suoi argomenti.',
                )
              else if (modules.length > 1 || data.topics.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 2),
                  child: Text(
                    'Tieni premuto un modulo o un argomento e trascinalo per '
                    'spostarlo.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
          itemCount: modules.length,
          onReorderItem: (from, to) => _reorder(modules, from, to),
          proxyDecorator: reorderProxy,
          itemBuilder: (context, i) => ModuleCard(
            key: ValueKey('module-${modules[i].id}'),
            course: course,
            attachments: data.attachments,
            module: modules[i],
            topics: data.of(modules[i]),
            color: color,
            dragIndex: i,
          ),
        );
      },
    );
  }
}

/// Libri della materia: sempre l'elenco (obbligatori prima). Quelli già
/// scaricati hanno l'icona del libro e il testo pieno e si aprono con un
/// tocco; quelli da scaricare sono più chiari.
class _BooksButton extends StatelessWidget {
  const _BooksButton({
    required this.course,
    required this.books,
    required this.available,
  });

  final Course course;
  final List<Book> books;
  final Set<int> available;

  Future<void> _open(BuildContext context) async {
    final sorted = [...books]
      ..sort((a, b) {
        int rank(Book x) =>
            x.required == true ? 0 : (x.required == null ? 1 : 2);
        return rank(a).compareTo(rank(b));
      });
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(
                course.label,
                style: Theme.of(c).textTheme.titleMedium,
              ),
            ),
            for (final b in sorted)
              ListTile(
                leading: Icon(
                  available.contains(b.id)
                      ? Icons.menu_book
                      : Icons.cloud_download_outlined,
                ),
                title: Text(b.title),
                // senza indicazioni nel database il libro è consigliato
                subtitle: Text(
                  b.required == true ? 'Obbligatorio' : 'Facoltativo',
                ),
                enabled: available.contains(b.id),
                onTap: () {
                  Navigator.pop(c);
                  openBook(context, b);
                },
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final n = books.where((b) => available.contains(b.id)).length;
    return OutlinedButton.icon(
      onPressed: books.isEmpty ? null : () => _open(context),
      icon: const Icon(Icons.menu_book_outlined),
      label: Text(
        books.isEmpty
            ? 'Nessun libro'
            : (n == books.length ? 'Libri ($n)' : 'Libri ($n/${books.length})'),
      ),
    );
  }
}
