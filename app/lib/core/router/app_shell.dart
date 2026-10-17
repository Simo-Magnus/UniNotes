import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:provider/provider.dart';

import '../../features/books/books_screen.dart';
import '../../features/cloud/incoming_files_host.dart';
import '../../features/courses/courses_screen.dart';
import '../../features/dashboard/dashboard_screen.dart';
import '../../features/exams/exam_detail.dart';
import '../../features/exams/exams_screen.dart';
import '../../features/links/links_screen.dart';
import '../../features/notes/notes_screen.dart';
import '../../features/notes/recorder/overlay_logic.dart';
import '../../features/reader/files_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/study/focus/focus_screen.dart' show openFocusScreen;
import '../../features/study/study_screen.dart';
import '../feedback/feedback_service.dart';
import '../reminders/notification_plan.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';

class AppDestination {
  const AppDestination(this.label, this.icon, this.selectedIcon, this.builder);
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final WidgetBuilder builder;
}

/// Sezioni dell'app. Le prime [_AppShellState._mobilePrimary] sono nella barra
/// in basso sul telefono, le altre in "Altro".
final List<AppDestination> kDestinations = [
  AppDestination(
    'Home',
    Icons.dashboard_outlined,
    Icons.dashboard,
    (_) => const DashboardScreen(),
  ),
  AppDestination(
    'Registra',
    Icons.mic_none_outlined,
    Icons.mic,
    (_) => const NotesScreen(),
  ),
  AppDestination(
    'Studio',
    Icons.timer_outlined,
    Icons.timer,
    (_) => const StudyScreen(),
  ),
  AppDestination(
    'Esami',
    Icons.assignment_outlined,
    Icons.assignment,
    (_) => const ExamsScreen(),
  ),
  AppDestination(
    'Libri',
    Icons.menu_book_outlined,
    Icons.menu_book,
    (_) => const BooksScreen(),
  ),
  AppDestination(
    'Insegnamenti',
    Icons.school_outlined,
    Icons.school,
    (_) => const CoursesScreen(),
  ),
  // «File» tra «Insegnamenti» e «Collegamenti»
  AppDestination(
    'File',
    Icons.folder_open_outlined,
    Icons.folder_open,
    (_) => const FilesScreen(),
  ),
  AppDestination(
    'Collegamenti',
    Icons.hub_outlined,
    Icons.hub,
    (_) => const LinksScreen(),
  ),
  AppDestination(
    'Impostazioni',
    Icons.settings_outlined,
    Icons.settings,
    (_) => const SettingsScreen(),
  ),
];

/// Su smartphone: barra in basso con le 4 sezioni principali + "Altro".
/// Su desktop/tablet largo: NavigationRail con tutte le sezioni.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Permette a una schermata (es. dashboard) di cambiare sezione.
  static void goTo(BuildContext context, String label) {
    context.findAncestorStateOfType<_AppShellState>()?._select(
      kDestinations.indexWhere((d) => d.label == label),
    );
  }

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _mobilePrimary = 4; // Home, Registra, Studio, Esami
  int _index = 0;
  late final AppServices _services = context.read<AppServices>();

  void _select(int i) {
    if (i >= 0) setState(() => _index = i);
  }

  @override
  void initState() {
    super.initState();
    _services.openRoute.addListener(_openRequested);
    // richiesta arrivata prima della shell (app aperta da una notifica)
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequested());
  }

  @override
  void dispose() {
    _services.openRoute.removeListener(_openRequested);
    super.dispose();
  }

  /// Apre la schermata chiesta da una notifica o da un widget della Home.
  void _openRequested() {
    if (!mounted) return;
    final route = _services.openRoute.take();
    if (route == null) return;
    int byLabel(String l) => kDestinations.indexWhere((d) => d.label == l);
    final examId = AppRoutes.examId(route);
    if (examId != null) {
      _select(byLabel('Esami'));
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ExamDetailScreen(examId: examId),
        ),
      );
    } else if (route == AppRoutes.focus) {
      // notifica della sessione Focus: Studio → Focus e la sessione in corso
      StudyScreen.initialTab = StudyScreen.focusTab;
      _select(byLabel('Studio'));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _services.focus.active && !_services.focus.screenVisible) {
          openFocusScreen(context);
        }
      });
    } else if (route == AppRoutes.record) {
      _select(byLabel('Registra'));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openRecorder(context);
      });
    } else if (AppRoutes.section(route) case final label?) {
      _select(byLabel(label));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Indietro (tasto del telefono): da una sezione si torna alla Home,
    // dalla Home si esce dall'app. Con una registrazione in corso l'app va
    // in background e continua a registrare.
    final recorder = _services.recorder;
    final focus = _services.focus;
    return ListenableBuilder(
      listenable: Listenable.merge([recorder, focus]),
      builder: (context, child) {
        // anche una sessione Focus continua con l'app in background
        final recording = recorder.active || focus.active;
        return PopScope(
          canPop: _index == 0 && !(recording && Platform.isAndroid),
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            switch (rootBackAction(
              index: _index,
              recording: recording,
              android: Platform.isAndroid,
            )) {
              case RootBack.home:
                _select(0);
              case RootBack.background:
                FlutterForegroundTask.minimizeApp();
              case RootBack.exit:
                break;
            }
          },
          child: child!,
        );
      },
      // file condivisi, aperti con l'app o trascinati sulla finestra (nella
      // sezione File il trascinamento apre il file, come prima)
      child: IncomingFilesHost(
        dropEnabled: kDestinations[_index].label != 'File',
        child: _buildShell(context),
      ),
    );
  }

  Widget _buildShell(BuildContext context) {
    final body = KeyedSubtree(
      key: ValueKey(_index),
      child: kDestinations[_index].builder(context),
    );

    if (context.isWide) {
      final t = context.tokens;
      return Scaffold(
        body: Row(
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: t.navGradient,
                ),
                border: Border(right: BorderSide(color: t.navBorder)),
              ),
              child: SafeArea(
                child: NavigationRail(
                  selectedIndex: _index,
                  onDestinationSelected: _select,
                  labelType: NavigationRailLabelType.all,
                  minWidth: 84,
                  destinations: [
                    for (final d in kDestinations)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    final inMore = _index >= _mobilePrimary;
    return Scaffold(
      extendBody: false,
      body: body,
      bottomNavigationBar: GlassNavBar(
        selectedIndex: inMore ? _mobilePrimary : _index,
        onSelected: (i) {
          if (i < _mobilePrimary) {
            _select(i);
          } else {
            _openMore();
          }
        },
        items: [
          for (final d in kDestinations.take(_mobilePrimary))
            (icon: d.icon, selectedIcon: d.selectedIcon, label: d.label),
          (
            icon: Icons.more_horiz,
            selectedIcon: Icons.more_horiz,
            label: inMore ? kDestinations[_index].label : 'Altro',
          ),
        ],
      ),
    );
  }

  Future<void> _openMore() async {
    final i = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = _mobilePrimary; i < kDestinations.length; i++)
              ListTile(
                leading: Icon(kDestinations[i].icon),
                title: Text(kDestinations[i].label),
                selected: i == _index,
                onTap: () => Navigator.pop(c, i),
              ),
          ],
        ),
      ),
    );
    if (i != null) _select(i);
  }
}

/// Barra di navigazione in vetro (58 px, raggio 29): voce attiva azzurra.
class GlassNavBar extends StatelessWidget {
  const GlassNavBar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<({IconData icon, IconData selectedIcon, String label})> items;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(29),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: t.navGradient,
            stops: const [0, 0.55, 1],
          ),
          border: Border.all(color: t.navBorder),
          boxShadow: const [
            BoxShadow(
              color: Color(0xF2000000),
              offset: Offset(0, 18),
              blurRadius: 34,
              spreadRadius: -12,
            ),
          ],
        ),
        padding: const EdgeInsets.all(5),
        child: Row(
          children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: _NavItem(
                  item: items[i],
                  active: i == selectedIndex,
                  onTap: () => onSelected(i),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.item,
    required this.active,
    required this.onTap,
  });
  final ({IconData icon, IconData selectedIcon, String label}) item;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final color = active ? t.navActiveText : t.textMuted;
    return Semantics(
      selected: active,
      button: true,
      label: item.label,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () {
          AppFeedback.of(context).toggle();
          onTap();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: active
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(24),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: t.navActive,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: t.cyan.withValues(alpha: 0.35),
                      offset: const Offset(0, 6),
                      blurRadius: 16,
                      spreadRadius: -8,
                    ),
                  ],
                )
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                active ? item.selectedIcon : item.icon,
                size: 21,
                color: color,
                shadows: active
                    ? [
                        Shadow(
                          color: t.cyanSoft.withValues(alpha: 0.8),
                          blurRadius: 6,
                        ),
                      ]
                    : null,
              ),
              const SizedBox(height: 2),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                // barra alta 58 (Design 3): con i caratteri grandi le voci
                // crescono fino a 1,3×; il nome intero resta nella semantica
                textScaler: MediaQuery.textScalerOf(
                  context,
                ).clamp(maxScaleFactor: 1.3),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
