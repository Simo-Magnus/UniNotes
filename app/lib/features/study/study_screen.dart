import 'package:flutter/material.dart';

import '../../core/feedback/feedback_service.dart';
import '../../widgets/common.dart';
import '../academic/year_widgets.dart';
import 'course_catalog.dart';
import 'stats_tab.dart';
import 'study_sessions_tab.dart';
import 'topics_tab.dart';

/// Sezione Studio: argomenti per insegnamento, Sessioni Studio (cronometro,
/// timer Focus e storico), statistiche.
class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});

  /// Scheda da aprire alla prossima apertura (0 Argomenti, 1 Sessioni
  /// Studio, 2 Statistiche), es. dal tocco su una notifica Focus.
  static int initialTab = 0;
  static const focusTab = kStudySessionsTab;

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  /// Ultimo corso selezionato in "Argomenti" (sopravvive al cambio sezione).
  static int? _lastCourseId;

  /// Scheda iniziale chiesta da fuori (una sola volta).
  late final int _initialTab = () {
    final i = StudyScreen.initialTab.clamp(0, 2);
    StudyScreen.initialTab = 0;
    return i;
  }();

  @override
  Widget build(BuildContext context) {
    // caratteri grandi: le schede scorrono invece di tagliare il testo
    final big = MediaQuery.textScalerOf(context).scale(13) > 13 * 1.15;
    return DefaultTabController(
      length: 3,
      initialIndex: _initialTab,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Studio'),
          actions: const [YearSelectorChip()],
          bottom: TabBar(
            isScrollable: big,
            tabAlignment: big ? TabAlignment.start : null,
            onTap: (_) => AppFeedback.of(context).toggle(),
            tabs: const [
              Tab(icon: Icon(Icons.account_tree_outlined), text: 'Argomenti'),
              Tab(icon: Icon(Icons.timer_outlined), text: 'Sessioni Studio'),
              Tab(icon: Icon(Icons.insights_outlined), text: 'Statistiche'),
            ],
          ),
        ),
        body: RevisionBuilder<CourseCatalog>(
          load: CourseCatalog.load,
          builder: (context, all) {
            if (all.isEmpty) {
              return const EmptyState(
                icon: Icons.school_outlined,
                message:
                    'Nessun insegnamento presente. Aggiungili nella sezione '
                    'Insegnamenti o aggiorna il database in Impostazioni.',
              );
            }
            // insegnamenti solo con il nome: niente scelta dell'ateneo (il
            // piano è già quello del corso di laurea scelto)
            final catalog = all;
            final selected = catalog.courses.any((c) => c.id == _lastCourseId)
                ? _lastCourseId
                : catalog.courses.firstOrNull?.id;
            return TabBarView(
              children: [
                TopicsTab(
                  catalog: catalog,
                  courseId: selected,
                  onCourseChanged: (id) => setState(() => _lastCourseId = id),
                ),
                StudySessionsTab(catalog: catalog),
                StatsTab(catalog: catalog),
              ],
            );
          },
        ),
      ),
    );
  }
}
