import 'dart:async';
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
import '../../features/exams/previous_years_screen.dart' show openPreviousYears;
import '../../features/links/links_screen.dart';
import '../../features/links/whisper_card.dart' show WhisperCard;
import '../../features/notes/notes_screen.dart';
import '../../features/notes/recorder/overlay_logic.dart';
import '../../features/perks/perks_screen.dart';
import '../../features/reader/files_screen.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/study/focus/focus_screen.dart' show openFocusScreen;
import '../../features/study/study_screen.dart';
import '../feedback/app_modals.dart';
import '../feedback/feedback_service.dart';
import '../feedback/motion.dart' show motion;
import '../reminders/notification_plan.dart';
import '../services/app_services.dart';
import '../theme/app_theme.dart';
import '../theme/app_tokens.dart';
import 'section_stack.dart';

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
  // offerte per studenti con l'email universitaria
  AppDestination(
    'Vantaggi',
    Icons.local_offer_outlined,
    Icons.local_offer,
    (_) => const PerksScreen(),
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

  /// Sezioni preparate nascoste dopo l'avvio (le altre della barra in basso,
  /// vedi [SectionStack.prefetch]). Le prove possono spegnerlo.
  @visibleForTesting
  static bool prefetchSections = true;

  /// `registra:avvia` avvia subito la registrazione solo su Android, dove il
  /// lato nativo la accetta solo dai widget dell'app (codice segreto in
  /// WidgetSupport.routeOf). Su iOS e macOS lo schema `uninotes://` lo può
  /// aprire qualunque app o pagina web: lì la rotta apre solo il
  /// registratore. Le prove lo accendono.
  @visibleForTesting
  static bool quickStartFromWidget = Platform.isAndroid;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  static const _mobilePrimary = 4; // Home, Registra, Studio, Esami

  /// Preparate nascoste dopo l'avvio: le altre sezioni della barra in basso
  /// (le più usate; le altre si costruiscono alla prima apertura).
  static final List<int> _prefetch = [
    for (var i = 1; i < _mobilePrimary; i++) i,
  ];
  int _index = 0;
  late final AppServices _services = context.read<AppServices>();

  /// La pila delle sezioni resta la stessa anche quando la finestra passa
  /// dalla barra in basso alla colonna di navigazione (rotazione del tablet,
  /// finestra ridimensionata): le sezioni non si ricostruiscono.
  final _stack = GlobalKey<SectionStackState>();

  /// Scorrimento principale di ogni sezione.
  final List<ScrollController> _scrollers = [
    for (var i = 0; i < kDestinations.length; i++) ScrollController(),
  ];

  /// Cambia quando cambiano corso, percorso o anno mostrato: le sezioni
  /// nascoste si ricostruiscono da zero (filtri e scelte del corso di prima).
  Object? _resetKey;

  /// [user]: tocco sulla barra o sulla colonna; sulla voce già attiva riporta
  /// la sezione in cima (come su iOS).
  void _select(int i, {bool user = false}) {
    if (i < 0) return;
    if (i == _index) {
      if (user) _stack.currentState?.scrollToTop();
      return;
    }
    setState(() => _index = i);
  }

  Object _currentResetKey() {
    final p = _services.profile.value;
    return (
      p?.universityId,
      p?.degreeId,
      p?.curriculum,
      p?.currentYear,
      p?.startYear,
      p?.referenceAa.label,
      _services.selectedYear.value,
    );
  }

  void _onProfile() {
    final k = _currentResetKey();
    if (k != _resetKey && mounted) setState(() => _resetKey = k);
  }

  @override
  void initState() {
    super.initState();
    _resetKey = _currentResetKey();
    _services.profile.addListener(_onProfile);
    _services.selectedYear.addListener(_onProfile);
    _services.openRoute.addListener(_openRequested);
    // richiesta arrivata prima della shell (app aperta da una notifica)
    WidgetsBinding.instance.addPostFrameCallback((_) => _openRequested());
    // card di Whisper in Collegamenti già pronta alla prima apertura
    if (AppShell.prefetchSections) {
      _whisperPrefetch = Timer(
        const Duration(seconds: 4),
        () => WhisperCard.prefetch(_services.whisper),
      );
    }
  }

  Timer? _whisperPrefetch;

  @override
  void dispose() {
    _whisperPrefetch?.cancel();
    _services.openRoute.removeListener(_openRequested);
    _services.profile.removeListener(_onProfile);
    _services.selectedYear.removeListener(_onProfile);
    for (final c in _scrollers) {
      c.dispose();
    }
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
        if (mounted &&
            _services.focus.active &&
            !_services.focus.screenVisible) {
          openFocusScreen(context);
        }
      });
    } else if (route == AppRoutes.previousYears) {
      // promemoria degli esami degli anni precedenti: Esami → Anni precedenti
      _select(byLabel('Esami'));
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) openPreviousYears(context);
      });
    } else if (route == AppRoutes.record || route == AppRoutes.recordStart) {
      // widget «Registra lezione» (Android): la schermata del registratore
      // avvia subito la registrazione e poi torna alla schermata Home
      if (route == AppRoutes.recordStart && AppShell.quickStartFromWidget) {
        _services.recorder.requestQuickStart();
      }
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
    // sezioni persistenti con il passaggio animato (section_stack.dart): ogni
    // sezione si costruisce alla prima apertura e poi resta viva nascosta,
    // quindi tornandoci non riparte da zero (niente cerchio di caricamento)
    final body = SectionStack(
      key: _stack,
      index: _index,
      count: kDestinations.length,
      builder: (context, i) => kDestinations[i].builder(context),
      controllers: _scrollers,
      resetKey: _resetKey,
      prefetch: AppShell.prefetchSections ? _prefetch : const [],
    );

    // tocco sulla barra di stato di iOS (lo gestisce lo Scaffold della
    // shell): riporta in cima la sezione visibile
    return PrimaryScrollController(
      controller: _scrollers[_index],
      child: _frame(context, body),
    );
  }

  Widget _frame(BuildContext context, Widget body) {
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
                // dieci voci con le etichette: con i caratteri grandi o la
                // finestra bassa la colonna scorre invece di uscire dallo
                // schermo (la rail non scorre da sola)
                child: LayoutBuilder(
                  builder: (context, constraints) => SingleChildScrollView(
                    // non è la lista della sezione: fuori dallo scorrimento
                    // principale (barra di stato, «torna in cima»)
                    primary: false,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: IntrinsicHeight(
                        child: NavigationRail(
                          selectedIndex: _index,
                          onDestinationSelected: (i) => _select(i, user: true),
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
                  ),
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
            _select(i, user: true);
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
    final i = await showAppSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        // scorre se la finestra è bassa (320 px in orizzontale) o i caratteri
        // sono grandi: l'elenco non esce dal foglio
        child: SingleChildScrollView(
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
      ),
    );
    if (i != null) _select(i, user: true);
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
          boxShadow: t.floatShadows,
        ),
        padding: const EdgeInsets.all(5),
        child: LayoutBuilder(
          builder: (context, c) {
            final widths = navItemWidths(context, items, c.maxWidth);
            return Row(
              children: [
                for (var i = 0; i < items.length; i++)
                  SizedBox(
                    width: widths[i],
                    child: _NavItem(
                      item: items[i],
                      active: i == selectedIndex,
                      onTap: () => onSelected(i),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Stile dell'etichetta di una voce della barra.
TextStyle _navLabelStyle(BuildContext context, bool active, Color color) =>
    DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: 11,
        fontWeight: active ? FontWeight.w600 : FontWeight.w500,
        color: color,
      ),
    );

/// Scala dei caratteri delle etichette: barra alta 58, le voci crescono
/// fino a 1,3× con i caratteri grandi.
TextScaler _navScaler(BuildContext context) =>
    MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);

/// Larghezze delle voci della barra: uguali finché ogni etichetta ci sta
/// intera; se una è più lunga della sua parte («Impostazioni», «Collegamenti»
/// sul telefono) prende il posto che le serve e le altre si dividono il
/// resto. Se nemmeno così ci stanno tutte, le larghezze seguono la lunghezza
/// delle etichette e il testo si rimpicciolisce (FittedBox) invece di
/// troncarsi con i puntini.
List<double> navItemWidths(
  BuildContext context,
  List<({IconData icon, IconData selectedIcon, String label})> items,
  double total,
) {
  final n = items.length;
  if (n == 0 || !total.isFinite || total <= 0) {
    return List<double>.filled(n, 0);
  }
  final scaler = _navScaler(context);
  final dir = Directionality.of(context);
  // margine interno di ogni voce (4 + 4) e peso massimo (la voce attiva)
  const pad = 8.0;
  final need = <double>[
    for (final it in items)
      () {
        final p = TextPainter(
          text: TextSpan(
            text: it.label,
            style: _navLabelStyle(context, true, Colors.black),
          ),
          textDirection: dir,
          textScaler: scaler,
          maxLines: 1,
        )..layout();
        final w = p.width + pad;
        p.dispose();
        return w;
      }(),
  ];
  final base = total / n;
  if (need.every((w) => w <= base)) return List<double>.filled(n, base);
  // le voci troppo lunghe prendono quanto serve, le altre dividono il resto
  final long = [
    for (var i = 0; i < n; i++)
      if (need[i] > base) i,
  ];
  final longSum = long.fold<double>(0, (a, i) => a + need[i]);
  final others = n - long.length;
  if (others > 0) {
    final rest = (total - longSum) / others;
    final maxOther = [
      for (var i = 0; i < n; i++)
        if (need[i] <= base) need[i],
    ].fold<double>(0, (a, b) => b > a ? b : a);
    if (rest >= maxOther) {
      return [for (var i = 0; i < n; i++) need[i] > base ? need[i] : rest];
    }
  }
  final sum = need.fold<double>(0, (a, b) => a + b);
  return [for (final w in need) w * total / sum];
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
          duration: motion(context, const Duration(milliseconds: 200)),
          curve: Curves.easeOutCubic,
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
              // il nome si legge sempre intero: la voce è larga quanto serve
              // (navItemWidths); se non c'è posto per tutti il testo si
              // rimpicciolisce, mai puntini
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    item.label,
                    maxLines: 1,
                    softWrap: false,
                    textScaler: _navScaler(context),
                    style: _navLabelStyle(context, active, color),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
