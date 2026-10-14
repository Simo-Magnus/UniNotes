import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_theme.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'course_detail_screen.dart';
import 'course_form.dart';
import 'course_list.dart';
import 'course_ui.dart';
import '../academic/year_widgets.dart';
import '../../core/constants/text_limits.dart';

/// Sezione Insegnamenti: gli insegnamenti dell'anno scelto nel selettore
/// (corso di laurea attuale), raggruppati per semestre, a scelta per
/// ultimi; filtri per stato e ricerca. Su schermi larghi master-detail.
class CoursesScreen extends StatefulWidget {
  const CoursesScreen({super.key});

  @override
  State<CoursesScreen> createState() => _CoursesScreenState();
}

class _CoursesScreenState extends State<CoursesScreen> {
  final _search = TextEditingController();

  /// Si apre sempre con il solo filtro «In corso» (le scelte non si
  /// salvano).
  CourseFilter _filter = const CourseFilter();
  int? _selectedId;

  @override
  void initState() {
    super.initState();
    // filtro salvato dalle versioni precedenti: non serve più
    context.read<AppServices>().settings.set('courses_status_filter', null);
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _open(Course c) {
    if (c.id == null) return;
    if (context.isWide) {
      setState(() => _selectedId = c.id);
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => CourseDetailScreen(courseId: c.id!)),
      );
    }
  }

  Future<void> _add() async {
    final id = await openCourseForm(context);
    if (id != null && mounted && context.isWide) {
      setState(() => _selectedId = id);
    }
  }

  void _toggleStatus(CourseStatus s, bool on) {
    final next = {..._filter.statuses};
    on ? next.add(s) : next.remove(s);
    setState(() => _filter = _filter.copyWith(statuses: next));
  }

  @override
  Widget build(BuildContext context) {
    final wide = context.isWide;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Insegnamenti'),
        actions: const [YearSelectorChip()],
      ),
      floatingActionButton: GlowFab(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('Nuovo insegnamento'),
      ),
      body: RevisionBuilder<CoursesData>(
        load: CoursesData.load,
        builder: (context, data) {
          final list = _buildList(data);
          if (!wide) return list;
          return Row(
            children: [
              SizedBox(width: 440, child: list),
              const VerticalDivider(width: 1),
              Expanded(
                child: _selectedId == null
                    ? const EmptyState(
                        icon: Icons.touch_app_outlined,
                        message:
                            'Seleziona un insegnamento per vederne i dettagli.',
                      )
                    : CourseDetailView(
                        key: ValueKey(_selectedId),
                        courseId: _selectedId!,
                        onDeleted: () => setState(() => _selectedId = null),
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildList(CoursesData data) {
    if (data.courses.isEmpty) {
      return EmptyState(
        icon: Icons.school_outlined,
        message:
            'Nessun insegnamento in questo anno.\nAggiungine uno oppure '
            'scegli il tuo corso di laurea in Impostazioni.',
        action: FilledButton.icon(
          onPressed: _add,
          icon: const Icon(Icons.add),
          label: const Text('Aggiungi insegnamento'),
        ),
      );
    }
    final visible = data.courses.where(_filter.matches);
    final groups = groupCourses(visible, data.universities);
    final header = _Filters(
      search: _search,
      filter: _filter,
      data: data,
      onQuery: (q) => setState(() => _filter = _filter.copyWith(query: q)),
      onStatus: _toggleStatus,
      resultCount: visible.length,
    );
    if (groups.isEmpty) {
      return ListView(
        children: [
          header,
          const SizedBox(
            height: 280,
            child: EmptyState(
              icon: Icons.search_off,
              message: 'Nessun insegnamento corrisponde ai filtri.',
            ),
          ),
        ],
      );
    }
    return CourseGroupedList(
      data: data,
      groups: groups,
      selectedId: _selectedId,
      onTap: _open,
      header: header,
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.search,
    required this.filter,
    required this.data,
    required this.onQuery,
    required this.onStatus,
    required this.resultCount,
  });

  final TextEditingController search;
  final CourseFilter filter;
  final CoursesData data;
  final ValueChanged<String> onQuery;
  final void Function(CourseStatus, bool) onStatus;
  final int resultCount;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: search,
            onChanged: onQuery,
            inputFormatters: TextLimits.max(TextLimits.search),
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search),
              hintText: 'Cerca per nome, codice, docente…',
              suffixIcon: search.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Cancella',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        search.clear();
                        onQuery('');
                      },
                    ),
            ),
          ),
          const SizedBox(height: 8),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final s in CourseStatus.values)
                FilterChip(
                  // l'icona resta visibile: niente spunta sopra
                  showCheckmark: false,
                  avatar: Icon(courseStatusIcon(s), size: 16),
                  label: Text(s.label),
                  tooltip: s.description,
                  selected: filter.statuses.contains(s),
                  onSelected: (on) => onStatus(s, on),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$resultCount insegnamenti su ${data.courses.length}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}
