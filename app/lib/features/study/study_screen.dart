import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/feedback/feedback_service.dart';
import '../../widgets/common.dart';
import '../../widgets/tab_fit.dart';
import 'course_catalog.dart';
import 'course_groups.dart';
import 'stats_tab.dart';
import 'study_sessions_tab.dart';
import 'topics_tab.dart';

/// Sezione Studio: argomenti per insegnamento, Sessioni Studio (cronometro,
/// timer Focus e storico), statistiche.
class StudyScreen extends StatefulWidget {
  const StudyScreen({super.key});

  /// Scheda chiesta da fuori (0 Argomenti, 1 Sessioni Studio, 2
  /// Statistiche), es. dal tocco su una notifica Focus o da «Avvia» nella
  /// Home; null = nessuna richiesta. Vale anche se Studio è già costruita
  /// (le sezioni restano vive nascoste): la scheda cambia subito.
  static final ValueNotifier<int?> tabRequest = ValueNotifier(null);

  /// Scheda da aprire (vedi [tabRequest]).
  static int get initialTab => tabRequest.value ?? 0;
  static set initialTab(int i) => tabRequest.value = i;
  static const focusTab = kStudySessionsTab;

  @override
  State<StudyScreen> createState() => _StudyScreenState();
}

class _StudyScreenState extends State<StudyScreen> {
  /// Ultimo corso selezionato in "Argomenti" (sopravvive al cambio sezione).
  static int? _lastCourseId;

  /// Scheda iniziale chiesta da fuori (una sola volta).
  late final int _initialTab = _takeRequest() ?? 0;

  /// Controllo delle schede (dal DefaultTabController qui sotto).
  TabController? _tabs;

  /// Prende la richiesta in sospeso (e la toglie).
  static int? _takeRequest() {
    final i = StudyScreen.tabRequest.value;
    if (i == null) return null;
    StudyScreen.tabRequest.value = null;
    return i.clamp(0, 2);
  }

  @override
  void initState() {
    super.initState();
    StudyScreen.tabRequest.addListener(_onRequest);
  }

  @override
  void dispose() {
    StudyScreen.tabRequest.removeListener(_onRequest);
    super.dispose();
  }

  /// Richiesta arrivata con Studio già costruita.
  void _onRequest() {
    final tabs = _tabs;
    if (!mounted || tabs == null || StudyScreen.tabRequest.value == null) {
      return;
    }
    final i = _takeRequest()!;
    if (tabs.index != i) tabs.index = i;
  }

  @override
  Widget build(BuildContext context) {
    // caratteri grandi: le schede scorrono invece di tagliare il testo
    // (o quando una scritta non sta intera nella sua scheda, come «Sessioni
    // Studio» a 360 dp)
    final big =
        MediaQuery.textScalerOf(context).scale(13) > 13 * 1.15 ||
        tabsNeedScroll(context, const [
          'Argomenti',
          'Sessioni Studio',
          'Statistiche',
        ], MediaQuery.sizeOf(context).width);
    return DefaultTabController(
      length: 3,
      initialIndex: _initialTab,
      child: Builder(builder: (context) => _scaffold(context, big)),
    );
  }

  Widget _scaffold(BuildContext context, bool big) {
    _tabs = DefaultTabController.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Studio'),
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
        // insegnamenti nell'ordine scelto in Studio (tieni premuto e
        // trascina nell'elenco degli insegnamenti)
        load: (s) async {
          final catalog = await CourseCatalog.load(s);
          final order = await loadStudyCourseOrder(s);
          return catalog.ordered((c) => applyCourseOrder(c, order));
        },
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
          // all'apertura il primo insegnamento in corso (nell'ordine
          // scelto), altrimenti il primo
          final selected = catalog.courses.any((c) => c.id == _lastCourseId)
              ? _lastCourseId
              : (catalog.courses
                            .where((c) => c.status == CourseStatus.active)
                            .firstOrNull ??
                        catalog.courses.firstOrNull)
                    ?.id;
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
    );
  }
}
