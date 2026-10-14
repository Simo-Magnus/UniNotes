import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../utils/dates.dart';
import '../academic/year_widgets.dart';
import '../study/focus/focus_cards.dart' show editDailyGoal;
import '../study/focus/focus_screen.dart' show DailyGoalCard;
import 'dashboard_data.dart';
import 'widgets/books_card.dart';
import 'widgets/course_progress_card.dart';
import 'widgets/nudge_card.dart';
import 'widgets/quick_start_card.dart';
import 'widgets/recordings_card.dart';
import 'widgets/upcoming_exams_card.dart';
import 'widgets/weekly_study_card.dart';
import '../../core/academic/academic_year.dart';

/// Home: cosa fare adesso e come si sta andando.
/// In alto il corso e la data; poi «Inizia» (Sessione Studio, Registra
/// lezione, AI di riferimento), le prossime prove con lo stato, l'obiettivo
/// di oggi e lo studio della settimana, le ultime registrazioni con le
/// trascrizioni, moduli e argomenti, i libri.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  /// Larghezza minima del contenuto per la disposizione su due colonne.
  static const double _twoColumnWidth = 760;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Home'),
        actions: const [YearSelectorChip()],
      ),
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

/// Obiettivo di oggi (come in Sessioni Studio), con «Cambia».
class _Goal extends StatelessWidget {
  const _Goal();

  @override
  Widget build(BuildContext context) =>
      DailyGoalCard(onEditGoal: () => editDailyGoal(context));
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
        const NudgeCard(),
        QuickStartCard(data: data),
        UpcomingExamsCard(data: data),
        const _Goal(),
        WeeklyStudyCard(data: data),
        RecordingsCard(data: data),
        CourseProgressCard(data: data),
        BooksCard(data: data),
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
                        BooksCard(data: data),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        const _Goal(),
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

/// Intestazione della Home: in grande il corso di laurea e l'anno di corso,
/// sotto l'università e l'anno accademico («Cambia corso» è in alto nelle
/// Impostazioni). La data di oggi sta accanto al
/// titolo (unico punto dell'app in cui serve sempre: le scadenze e le
/// sessioni si leggono rispetto a oggi).
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
            // data di oggi ben visibile, subito dopo il titolo del corso
            style: theme.textTheme.titleMedium?.copyWith(
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
    final year = data.year ?? p.currentYear;
    final yearLabel = p.fuoriCorso && year == p.currentYear
        ? 'Fuori corso'
        : planYearLabel(year);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '${p.degreeName} · $yearLabel',
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: t.textPrimary,
                ),
              ),
              today,
            ],
          ),
          const SizedBox(height: 2),
          Text(
            '${p.universityName} · ${p.academicYearOf(year).label}',
            style: theme.textTheme.titleSmall?.copyWith(
              color: t.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
