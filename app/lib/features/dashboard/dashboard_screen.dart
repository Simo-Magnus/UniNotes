import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../utils/dates.dart';
import '../academic/year_widgets.dart';
import 'dashboard_data.dart';
import 'widgets/course_progress_card.dart';
import 'widgets/nudge_card.dart';
import 'widgets/previous_years_card.dart';
import 'widgets/quick_start_card.dart';
import 'widgets/recordings_card.dart';
import 'widgets/upcoming_exams_card.dart';
import 'widgets/weekly_study_card.dart';

/// Home: cosa fare adesso e come si sta andando.
/// In alto il corso, l'anno (toccandolo si cambia) e la data; poi «Inizia»
/// (studio di oggi con l'obiettivo, Sessione Studio, Registra lezione), le
/// prossime prove con lo stato, lo studio della settimana, le ultime
/// registrazioni con le trascrizioni, moduli e argomenti di una suddivisione
/// (semestre). Toccando una card si apre la sua sezione (niente più card
/// dei Libri: i libri sono nella loro sezione).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  /// Larghezza minima del contenuto per la disposizione su due colonne.
  static const double _twoColumnWidth = 760;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Home')),
      body: RevisionBuilder<DashboardData>(
        load: DashboardData.load,
        builder: (context, data) => RefreshIndicator(
          onRefresh: () async => context.read<AppServices>().revision.bump(),
          child: LayoutBuilder(
            builder: (context, c) => c.maxWidth >= _twoColumnWidth
                ? _TwoColumns(data: data)
                : _OneColumn(data: data),
          ),
        ),
      ),
    );
  }
}

class _OneColumn extends StatelessWidget {
  const _OneColumn({required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _PathHeader(data: data),
        const YearStatusBanner(),
        const PreviousYearsHomeCard(),
        const NudgeCard(),
        QuickStartCard(data: data),
        UpcomingExamsCard(data: data),
        WeeklyStudyCard(data: data),
        RecordingsCard(data: data),
        CourseProgressCard(data: data),
      ],
    );
  }
}

class _TwoColumns extends StatelessWidget {
  const _TwoColumns({required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1400),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _PathHeader(data: data),
              const YearStatusBanner(),
              const PreviousYearsHomeCard(),
              const NudgeCard(),
              QuickStartCard(data: data),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        UpcomingExamsCard(data: data),
                        RecordingsCard(data: data),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        WeeklyStudyCard(data: data),
                        CourseProgressCard(data: data),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Intestazione della Home: in grande il corso di laurea e, accanto, l'anno
/// del piano con l'anno accademico («2° anno · 2026/27»): toccandolo si
/// sceglie l'anno mostrato in tutte le sezioni (non c'è più il selettore
/// nelle barre in alto). Sotto l'università e la data di oggi (unico punto
/// dell'app in cui serve sempre: le scadenze e le sessioni si leggono
/// rispetto a oggi). «Cambia corso» è in Impostazioni → Il mio percorso.
class _PathHeader extends StatelessWidget {
  const _PathHeader({required this.data});
  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final p = data.profile;
    final t = context.tokens;
    final theme = Theme.of(context);
    final today = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.today_outlined, size: 18, color: t.textMuted),
        const SizedBox(width: 6),
        // con i caratteri grandi la data va a capo invece di uscire
        Flexible(
          child: Text(
            capitalize(formatShortWeekdayDmy(data.now)),
            style: theme.textTheme.titleSmall?.copyWith(
              color: t.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
    if (p == null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Align(alignment: Alignment.centerRight, child: today),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                p.degreeName,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: t.textPrimary,
                ),
              ),
              YearMenuButton(
                builder: (context, profile, year) =>
                    _YearPill(label: profile.yearChipLabel(year)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                p.universityName,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: t.textMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              today,
            ],
          ),
        ],
      ),
    );
  }
}

/// Anno del piano accanto al nome del corso: pillola di vetro con la
/// freccia in giù, alta almeno 44 px (area di tocco).
class _YearPill extends StatelessWidget {
  const _YearPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Semantics(
      button: true,
      label: 'Anno di corso: $label. Tocca per cambiarlo',
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          widthFactor: 1,
          heightFactor: 1,
          child: Container(
            key: const Key('year-selector'),
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: t.navGradient,
              ),
              border: Border.all(color: t.navBorder),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                ),
                Icon(Icons.expand_more, size: 20, color: t.textSecondary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
