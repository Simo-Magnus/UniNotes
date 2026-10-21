import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/study.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'course_catalog.dart';
import 'minutes_bar_chart.dart';
import 'study_stats.dart';
import 'study_widgets.dart';
import '../../utils/dates.dart';

enum _Range {
  week('7 giorni', 7),
  month('30 giorni', 30),
  all('Sempre', null);

  const _Range(this.label, this.days);
  final String label;
  final int? days;
}

class _StatsData {
  const _StatsData(this.sessions, this.topicNames);
  final List<StudySession> sessions;
  final Map<int, String> topicNames;
}

/// Scheda "Statistiche": totali, ripartizioni e grafici temporali.
class StatsTab extends StatefulWidget {
  const StatsTab({super.key, required this.catalog});
  final CourseCatalog catalog;

  @override
  State<StatsTab> createState() => _StatsTabState();
}

class _StatsTabState extends State<StatsTab> {
  _Range _range = _Range.month;

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<_StatsData>(
      load: (s) async {
        final sessions = await s.study.sessions();
        final topics = await s.study.allTopics();
        return _StatsData(sessions, {for (final t in topics) t.id!: t.name});
      },
      builder: (context, all) {
        final data = _StatsData([
          for (final x in all.sessions)
            if (widget.catalog.shows(x.courseId)) x,
        ], all.topicNames);
        if (data.sessions.isEmpty) {
          return const EmptyState(
            icon: Icons.insights_outlined,
            message:
                'Ancora nessuna sessione di studio: le statistiche '
                'compariranno qui.',
          );
        }
        return _content(context, data);
      },
    );
  }

  Widget _content(BuildContext context, _StatsData data) {
    final now = DateTime.now();
    final days = _range.days;
    final from = days == null
        ? null
        : DateTime(now.year, now.month, now.day - days + 1);
    final inRange = from == null
        ? data.sessions
        : data.sessions.where((s) => !s.start.isBefore(from)).toList();
    final color = Theme.of(context).colorScheme.primary;
    final total = totalMinutes(inRange);

    final charts = [
      _ChartCard(
        title: 'Giornaliero (ultimi 14 giorni)',
        child: MinutesBarChart(
          totals: dailyTotals(data.sessions, today: now),
          labelOf: (d) => '${d.day}',
          tooltipOf: formatShortWeekdayDmy,
          color: color,
        ),
      ),
      _ChartCard(
        title: 'Settimanale (ultime 8 settimane)',
        child: MinutesBarChart(
          totals: weeklyTotals(data.sessions, today: now),
          labelOf: DateFormat('dd/MM').format,
          tooltipOf: (d) => 'Settimana dal ${formatDmy(d)}',
          color: color,
        ),
      ),
      _ChartCard(
        title: 'Mensile (ultimi 6 mesi)',
        child: MinutesBarChart(
          totals: monthlyTotals(data.sessions, today: now),
          labelOf: DateFormat('MMM', 'it_IT').format,
          tooltipOf: DateFormat('MMMM y', 'it_IT').format,
          color: color,
        ),
      ),
    ];

    final breakdowns = [
      _BreakdownCard(
        total: total,
        title: 'Per materia',
        rows: [
          for (final e in sortedByMinutes(minutesByCourse(inRange)))
            _Row(
              widget.catalog.nameOf(e.key),
              e.value,
              widget.catalog.colorOf(e.key),
            ),
        ],
      ),
      _BreakdownCard(
        total: total,
        title: 'Per argomento',
        rows: [
          for (final e in sortedByMinutes(minutesByTopic(inRange)).take(15))
            _Row(
              e.key == null
                  ? 'Senza argomento'
                  : data.topicNames[e.key] ?? 'Argomento eliminato',
              e.value,
              color,
            ),
        ],
      ),
      _BreakdownCard(
        total: total,
        title: 'Per attività',
        rows: [
          for (final e in sortedByMinutes(minutesByActivity(inRange)))
            _Row(
              e.key.label,
              e.value,
              // colori Material leggibili anche sul bianco del tema chiaro
              readableOn(
                _activityColor(e.key),
                Theme.of(context).brightness,
                minRatio: 3,
              ),
            ),
        ],
      ),
    ];

    final wide = context.isWide;
    return ListView(
      padding: const EdgeInsets.only(top: 8, bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: SegmentedButton<_Range>(
            segments: [
              for (final r in _Range.values)
                ButtonSegment(value: r, label: Text(r.label)),
            ],
            selected: {_range},
            onSelectionChanged: (s) => setState(() => _range = s.first),
          ),
        ),
        _Summary(sessions: inRange, days: days),
        if (wide) ...[
          _grid(breakdowns),
          _grid(charts),
        ] else ...[
          ...breakdowns,
          ...charts,
        ],
      ],
    );
  }

  /// Più colonne su schermi larghi.
  Widget _grid(List<Widget> children) => LayoutBuilder(
    builder: (context, c) {
      final cols = c.maxWidth >= 1200 ? 3 : 2;
      final w = (c.maxWidth / cols).floorToDouble();
      return Wrap(
        children: [for (final x in children) SizedBox(width: w, child: x)],
      );
    },
  );

  static Color _activityColor(ActivityType a) => switch (a) {
    ActivityType.theory => Colors.indigo,
    ActivityType.exercises => Colors.teal,
    ActivityType.review => Colors.purple,
    ActivityType.reading => Colors.brown,
    ActivityType.simulation => Colors.deepOrange,
    ActivityType.other => Colors.blueGrey,
  };
}

class _Summary extends StatelessWidget {
  const _Summary({required this.sessions, required this.days});
  final List<StudySession> sessions;
  final int? days;

  @override
  Widget build(BuildContext context) {
    final total = totalMinutes(sessions);
    final activeDays = sessions.map((s) => dayStart(s.start)).toSet().length;
    final d = days;
    final perDay = d != null
        ? total ~/ d
        : (activeDays == 0 ? 0 : total ~/ activeDays);
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _Tile('Tempo totale', formatMinutes(total), Icons.timer),
          _Tile(
            'Di cui in Focus',
            formatMinutes(totalMinutes(sessions.where((s) => s.focus))),
            Icons.center_focus_strong_outlined,
          ),
          _Tile('Sessioni', '${sessions.length}', Icons.event_note),
          _Tile('Giorni di studio', '$activeDays', Icons.calendar_today),
          _Tile(
            days != null ? 'Media al giorno' : 'Media per giorno attivo',
            formatMinutes(perDay),
            Icons.trending_up,
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 170,
      child: GlassCard(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: theme.colorScheme.primary),
              const SizedBox(height: 4),
              Text(value, style: theme.textTheme.titleLarge),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassCard(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 20),
          child,
        ],
      ),
    ),
  );
}

class _Row {
  const _Row(this.label, this.minutes, this.color);
  final String label;
  final int minutes;
  final Color color;
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.title,
    required this.rows,
    required this.total,
  });
  final String title;
  final List<_Row> rows;

  /// Totale del periodo: le barre mostrano la quota percentuale.
  final int total;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            if (rows.isEmpty) const Text('Nessun dato nel periodo.'),
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // solo il nome (niente pallino): il colore resta
                    // nella barra
                    Row(
                      children: [
                        Expanded(
                          child: Text(r.label, overflow: TextOverflow.ellipsis),
                        ),
                        Text(formatMinutes(r.minutes)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    ProgressRow(
                      value: total == 0 ? 0 : r.minutes / total,
                      color: r.color,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
