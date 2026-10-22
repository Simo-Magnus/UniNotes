import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'study_stats.dart';

/// Istogramma di minuti per periodo (asse Y in ore).
class MinutesBarChart extends StatelessWidget {
  const MinutesBarChart({
    super.key,
    required this.totals,
    required this.labelOf,
    required this.tooltipOf,
    required this.color,
    this.height = 180,
  });

  final List<PeriodTotal> totals;
  final String Function(DateTime start) labelOf;
  final String Function(DateTime start) tooltipOf;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final maxH =
        totals.fold<int>(0, (m, t) => t.minutes > m ? t.minutes : m) / 60;
    // Tacche "tonde" (0,5 / 1 / 2 / 5 / 10 … ore) e un margine sopra la barra
    // più alta: l'ultima etichetta non finisce attaccata al titolo.
    final step = _niceStep(maxH <= 0 ? 1.0 : maxH / 4);
    final top = maxH <= 0
        ? step * 2
        : (maxH / step).ceil() * step + step * 0.25;
    final small = theme.textTheme.labelSmall;
    final labelEvery = totals.length > 10 ? 2 : 1;
    return SizedBox(
      height: height,
      child: BarChart(
        BarChartData(
          maxY: top,
          minY: 0,
          gridData: FlGridData(
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) => FlLine(
              color: theme.dividerColor.withValues(alpha: 0.4),
              strokeWidth: 1,
            ),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(),
            rightTitles: const AxisTitles(),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 48,
                interval: step,
                getTitlesWidget: (v, meta) {
                  // niente etichetta sul bordo superiore (non è una tacca)
                  if (v == meta.max &&
                      (v / step - (v / step).round()).abs() > 1e-6) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      '${_fmtHours(v)} h',
                      style: small,
                      softWrap: false,
                      maxLines: 1,
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, meta) {
                  final i = v.toInt();
                  if (i < 0 || i >= totals.length) return const SizedBox();
                  final show = (totals.length - 1 - i) % labelEvery == 0;
                  return SideTitleWidget(
                    meta: meta,
                    child: Text(
                      show ? labelOf(totals[i].start) : '',
                      style: small,
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => theme.colorScheme.inverseSurface,
              getTooltipItem: (group, _, rod, _) {
                final t = totals[group.x];
                return BarTooltipItem(
                  '${tooltipOf(t.start)}\n${formatMinutes(t.minutes)}',
                  TextStyle(color: theme.colorScheme.onInverseSurface),
                );
              },
            ),
          ),
          barGroups: [
            for (var i = 0; i < totals.length; i++)
              BarChartGroupData(
                x: i,
                barRods: [
                  BarChartRodData(
                    toY: totals[i].minutes / 60,
                    color: color,
                    width: totals.length > 10 ? 10 : 18,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(4),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  static String _fmtHours(double v) => v == v.roundToDouble()
      ? v.toInt().toString()
      : v.toStringAsFixed(1).replaceAll('.', ',');

  /// Passo "tondo" più vicino a [raw] ore: 0,25 / 0,5 / 1 / 2 / 5 / 10 / 20 …
  static double _niceStep(double raw) {
    for (final s in const [0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0]) {
      if (raw <= s) return s;
    }
    // oltre le 100 ore per tacca (durate fuori scala nei dati importati) il
    // passo cresce di dieci in dieci: le tacche restano poche invece di
    // migliaia
    var s = 200.0;
    while (raw > s && s < 1e15) {
      s *= 10;
    }
    return s;
  }
}
