import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/feedback_service.dart';
import '../../core/feedback/motion.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/attachment.dart';
import '../../models/book.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../../utils/grade_math.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../books/book_filters.dart' show studyBooks, studyBooksLabel;
import '../books/book_opener.dart';
import '../notes/course_notes_screen.dart';
import 'attachments.dart' show removeStoredAttachments;
import 'course_catalog.dart';
import 'course_groups.dart';
import 'module_card.dart';
import 'module_order_dialog.dart';
import 'reorder_lift.dart';
import 'study_ai.dart';
import 'study_sessions_tab.dart' show openStudySession;
import 'study_widgets.dart';
import 'topic_logic.dart';
import '../notes/safe_files.dart';

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
/// L'insegnamento si cambia toccandone il nome nella card in alto: si apre
/// l'elenco diviso per semestre, annuali e OFA (anche su schermi larghi
/// non c'è più l'elenco laterale con lo stato degli insegnamenti).
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
    if (id == null) {
      return const EmptyState(
        icon: Icons.school_outlined,
        message: 'Seleziona un insegnamento per vederne moduli e argomenti.',
      );
    }
    return _CourseContent(
      key: ValueKey(id),
      catalog: catalog,
      courseId: id,
      onCourseChanged: onCourseChanged,
    );
  }
}

/// Sceglie un altro insegnamento (tocco sul nome nella card in alto):
/// elenco diviso per 1° e 2° semestre, annuali e OFA, solo con il nome.
/// Tenendo premuto un insegnamento e trascinandolo se ne cambia l'ordine
/// (dentro il suo gruppo); l'ordine si salva e vale in tutto Studio.
Future<int?> pickCourse(
  BuildContext context,
  CourseCatalog catalog,
  int? selected,
) async {
  final s = context.read<AppServices>();
  var changed = false;
  final id = await showModalBottomSheet<int>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(c).height * 0.8,
        ),
        child: CoursePickerList(
          courses: catalog.courses,
          selected: selected,
          onSelect: (id) => Navigator.pop(c, id),
          onReordered: (ids) {
            changed = true;
            saveStudyCourseOrder(s, ids).catchError(
              (Object e) => debugPrint('Ordine degli insegnamenti: $e'),
            );
          },
        ),
      ),
    ),
  );
  // l'ordine nuovo vale anche per i menu di Sessioni Studio e Statistiche
  if (changed) s.revision.bump();
  return id;
}

/// Elenco degli insegnamenti per gruppo (semestre, annuale, OFA) con
/// riordino: tieni premuto e trascina. [onReordered] riceve tutti gli id
/// nel nuovo ordine.
class CoursePickerList extends StatefulWidget {
  const CoursePickerList({
    super.key,
    required this.courses,
    required this.selected,
    required this.onSelect,
    required this.onReordered,
  });

  final List<Course> courses;
  final int? selected;
  final ValueChanged<int> onSelect;
  final ValueChanged<List<int>> onReordered;

  @override
  State<CoursePickerList> createState() => _CoursePickerListState();
}

class _CoursePickerListState extends State<CoursePickerList> {
  late List<StudyCourseGroup> _groups = groupStudyCourses(widget.courses);

  void _reorder(int group, int from, int to) {
    final g = _groups[group];
    final next = reorderList(g.courses, from, to);
    if (next == null) return;
    AppFeedback.of(context).toggle();
    setState(() {
      _groups = [
        for (var i = 0; i < _groups.length; i++)
          i == group ? StudyCourseGroup(g.label, next) : _groups[i],
      ];
    });
    widget.onReordered([
      for (final g in _groups)
        for (final c in g.courses) c.id!,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return CustomScrollView(
      shrinkWrap: true,
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Insegnamento', style: theme.textTheme.titleMedium),
                if (widget.courses.length > 1) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Tieni premuto un insegnamento e trascinalo per '
                    'cambiarne l\'ordine.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        for (var gi = 0; gi < _groups.length; gi++) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SectionHeader(_groups[gi].label),
            ),
          ),
          SliverReorderableList(
            // con l'indice: due semestri scritti in modo diverso
            // («1» e «1° semestre» dai dati importati) hanno la stessa
            // etichetta, e due chiavi uguali romperebbero l'elenco
            key: ValueKey('course-group-$gi-${_groups[gi].label}'),
            autoScrollerVelocityScalar: kReorderAutoScrollVelocity,
            itemCount: _groups[gi].courses.length,
            onReorderStart: (_) => AppFeedback.of(context).tap(),
            onReorderItem: (from, to) => _reorder(gi, from, to),
            proxyDecorator: liftProxy,
            itemBuilder: (context, i) {
              final course = _groups[gi].courses[i];
              return ReorderableDelayedDragStartListener(
                key: ValueKey('pick-course-${course.id}'),
                index: i,
                child: CoursePickTile(
                  // solo il nome dell'insegnamento
                  label: course.label,
                  selected: course.id == widget.selected,
                  onTap: () => widget.onSelect(course.id!),
                ),
              );
            },
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
      ],
    );
  }
}

/// Riga di un insegnamento nella scelta di Studio. L'insegnamento scelto
/// non usa l'azzurro (è il colore dei titoli dei gruppi «1° semestre»,
/// «Annuale»…) ma l'arancione dell'app, che nel Design 3 segna la scelta
/// dell'utente: barretta a sinistra, fondo appena tinto, nome in grassetto
/// e spunta. È l'arancione «da testo» ([AppTokens.orangeInk]), leggibile
/// sul fondo del foglio in entrambi i temi (verificato nei test).
class CoursePickTile extends StatelessWidget {
  const CoursePickTile({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Colore della scelta (barretta e spunta).
  static Color accentOf(BuildContext context) => context.tokens.orangeInk;

  /// Fondo della riga scelta.
  static Color tintOf(BuildContext context) => accentOf(context).withValues(
    alpha: Theme.of(context).brightness == Brightness.dark ? 0.14 : 0.10,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentOf(context);
    final duration = motion(context, const Duration(milliseconds: 160));
    return Semantics(
      selected: selected,
      button: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        child: Material(
          key: const Key('pick-course-tile'),
          color: selected ? tintOf(context) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Row(
                children: [
                  AnimatedContainer(
                    key: const Key('pick-course-bar'),
                    duration: duration,
                    width: 4,
                    height: 28,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: selected ? accent : Colors.transparent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Text(
                        label,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: context.tokens.textPrimary,
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ),
                  ),
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.check_rounded,
                        color: accent,
                        semanticLabel: 'Selezionato',
                      ),
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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

enum _CourseAction { arrange, removeAll }

class _CourseContentState extends State<_CourseContent> {
  int get courseId => widget.courseId;
  CourseCatalog get catalog => widget.catalog;

  Future<void> _addModule() async {
    final name = await promptText(
      context,
      title: 'Nuovo modulo',
      label: 'Nome',
    );
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

  /// Ordine dei moduli: finestra al centro con tutti i moduli, da
  /// riordinare tenendo premuto e trascinando.
  Future<void> _arrange(List<StudyModule> modules, [int? selectedId]) =>
      showModuleOrderDialog(context, modules: modules, selectedId: selectedId);

  /// «Rimuovi tutti i moduli»: moduli, argomenti e file allegati
  /// dell'insegnamento (dopo la conferma).
  Future<void> _removeAll(_CourseTopics data) async {
    if (data.modules.isEmpty) return;
    final m = data.modules.length, t = data.topics.length;
    final name = catalog.nameOf(courseId);
    final what = m == 1
        ? 'Il modulo di "$name" verrà eliminato'
        : 'I $m moduli di "$name" verranno eliminati';
    final extra = switch (t) {
      0 => 'i file allegati',
      1 => 'l\'argomento e i file allegati',
      _ => 'i $t argomenti e i file allegati',
    };
    final ok = await confirmDialog(
      context,
      'Rimuovere tutti i moduli?',
      '$what con $extra. Le sessioni di studio restano, senza modulo né '
          'argomento.',
    );
    if (!ok || !mounted) return;
    final s = context.read<AppServices>();
    for (final mod in data.modules) {
      await removeStoredAttachments(s, moduleId: mod.id);
      await s.study.deleteModule(mod.id!);
    }
    s.revision.bump();
    if (mounted) showSnack(context, 'Moduli rimossi.');
  }

  @override
  Widget build(BuildContext context) {
    final color = catalog.colorOf(courseId);
    return RevisionBuilder<_CourseTopics>(
      deps: [courseId],
      load: (s) async {
        // senza i libri rimossi (stanno in «Libri rimossi»)
        final books = studyBooks(await s.books.all(courseId: courseId));
        final available = <int>{};
        for (final b in books) {
          final path = b.filePath?.trim() ?? '';
          if (await s.library.fileOf(b) != null ||
              (path.isNotEmpty && await fileExistsQuick(path))) {
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
        final modules = data.modules;
        final theme = Theme.of(context);
        final header = GlassCard(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // tocca il nome per cambiare insegnamento; a destra il menu
                // dei moduli (ordine, rimuovi tutti)
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
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
                    ),
                    if (modules.isNotEmpty) _courseMenu(data),
                  ],
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
                  key: const Key('add-module-top'),
                  onPressed: _addModule,
                  icon: const Icon(Icons.add),
                  label: const Text('Aggiungi modulo'),
                ),
              ],
            ),
          ),
        );
        final list = ListView(
          padding: const EdgeInsets.only(bottom: 24),
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
                  'Tieni premuto un argomento e trascinalo per spostarlo; '
                  'tieni premuto il nome di un modulo per cambiare l\'ordine '
                  'dei moduli.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final m in modules)
              ModuleCard(
                key: ValueKey('module-${m.id}'),
                course: course,
                attachments: data.attachments,
                module: m,
                topics: data.of(m),
                color: color,
                onArrange: modules.length > 1
                    ? () => _arrange(modules, m.id)
                    : null,
              ),
            // sotto l'ultimo modulo: «Aggiungi modulo» senza tornare alla
            // card in alto (stessa azione). Riga a tutta larghezza al
            // livello delle card dei moduli, contornata: si distingue da
            // «Aggiungi argomento», che è un pulsante di testo dentro il
            // modulo. Senza moduli basta il pulsante in alto.
            if (modules.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                child: OutlinedButton.icon(
                  key: const Key('add-module-bottom'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: _addModule,
                  icon: const Icon(Icons.add),
                  label: const Text('Aggiungi modulo'),
                ),
              ),
          ],
        );
        // schermi larghi: niente elenco laterale, colonna centrata e leggibile
        if (!context.isWide) return list;
        return Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 880),
            child: list,
          ),
        );
      },
    );
  }

  Widget _courseMenu(_CourseTopics data) => PopupMenuButton<_CourseAction>(
    key: const Key('course-menu'),
    tooltip: 'Moduli dell\'insegnamento',
    onSelected: (a) => switch (a) {
      _CourseAction.arrange => _arrange(data.modules),
      _CourseAction.removeAll => _removeAll(data),
    },
    itemBuilder: (_) => [
      if (data.modules.length > 1)
        const PopupMenuItem(
          value: _CourseAction.arrange,
          child: ListTile(
            dense: true,
            leading: Icon(Icons.swap_vert_rounded),
            title: Text('Ordina i moduli'),
          ),
        ),
      const PopupMenuItem(
        value: _CourseAction.removeAll,
        child: ListTile(
          dense: true,
          leading: Icon(Icons.delete_sweep_outlined),
          title: Text('Rimuovi tutti i moduli'),
        ),
      ),
    ],
  );
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
    // il numero conta i libri, non i file scaricati
    return OutlinedButton.icon(
      onPressed: books.isEmpty ? null : () => _open(context),
      icon: const Icon(Icons.menu_book_outlined),
      label: Text(studyBooksLabel(books)),
    );
  }
}
