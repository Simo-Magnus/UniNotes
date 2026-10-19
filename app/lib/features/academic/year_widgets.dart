import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/student_profile.dart';
import '../../core/academic/year_completion.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/glass.dart';
import 'year_grades_screen.dart';

/// Etichetta spenta per un dato non ancora presente nel database
/// ("Da aggiungere"): nessun colore, come il dato mancante.
class MutedChip extends StatelessWidget {
  const MutedChip(this.label, {super.key, this.icon});
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: t.innerCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.innerBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: t.textMuted),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: t.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// Scelta dell'anno del piano: toccando [child] (nella Home, la scritta
/// dell'anno accanto al nome del corso di laurea) si apre il menu degli
/// anni con lo stato di ciascuno («in corso», «completato»…). L'anno scelto
/// vale per tutte le sezioni ([AppServices.selectedYear]). Invisibile senza
/// profilo.
class YearMenuButton extends StatefulWidget {
  const YearMenuButton({super.key, required this.builder});

  /// Contenuto toccabile per l'anno [selected] del profilo [profile].
  final Widget Function(
    BuildContext context,
    StudentProfile profile,
    int selected,
  )
  builder;

  @override
  State<YearMenuButton> createState() => _YearMenuButtonState();
}

class _YearMenuButtonState extends State<YearMenuButton> {
  late final AppServices _s = context.read<AppServices>();
  Map<int, PlanYearStatus> _status = const {};

  @override
  void initState() {
    super.initState();
    _s.revision.addListener(_load);
    _s.profile.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _s.revision.removeListener(_load);
    _s.profile.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    if (_s.profile.value == null) return;
    final years = await _s.profiles.planYears();
    if (!mounted) return;
    setState(() => _status = {for (final y in years) y.year: y.status});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<StudentProfile?>(
      valueListenable: _s.profile,
      builder: (context, profile, _) {
        if (profile == null) return const SizedBox.shrink();
        return ValueListenableBuilder<int?>(
          valueListenable: _s.selectedYear,
          builder: (context, selected, _) =>
              _menu(context, profile, selected ?? profile.currentYear),
        );
      },
    );
  }

  Widget _menu(BuildContext context, StudentProfile p, int selected) {
    final t = context.tokens;
    return PopupMenuButton<int>(
      tooltip: 'Cambia anno',
      position: PopupMenuPosition.under,
      onSelected: _s.selectYear,
      itemBuilder: (_) => [
        for (final y in planYearsOf(p))
          PopupMenuItem(
            value: y,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    p.yearChipLabel(y),
                    style: TextStyle(
                      fontWeight: y == selected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _statusLabel(p, y),
                  style: TextStyle(fontSize: 11, color: t.textMuted),
                ),
              ],
            ),
          ),
      ],
      child: widget.builder(context, p, selected),
    );
  }

  String _statusLabel(StudentProfile p, int y) {
    if (y == p.currentYear) return 'in corso';
    final s = _status[y];
    if (y < p.currentYear) {
      return switch (s) {
        PlanYearStatus.completato => 'completato',
        PlanYearStatus.completatoParziale => 'in parte',
        _ => 'da completare',
      };
    }
    return 'futuro';
  }
}

/// Riquadro sull'anno mostrato quando non è quello in corso: anni passati
/// da segnare come completati (solo voti), anni futuri con voti facoltativi.
class YearStatusBanner extends StatelessWidget {
  const YearStatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final p = s.profile.value;
    final year = s.selectedYear.value;
    if (p == null || year == null || year == p.currentYear) {
      return const SizedBox.shrink();
    }
    return FutureBuilder<_BannerData>(
      future: _BannerData.load(s, year),
      builder: (context, snap) {
        final d = snap.data;
        if (d == null) return const SizedBox.shrink();
        return _content(context, p, year, d);
      },
    );
  }

  Widget _content(
    BuildContext context,
    StudentProfile p,
    int year,
    _BannerData d,
  ) {
    final t = context.tokens;
    final past = year < p.currentYear;
    final (String title, String text, String action) = switch ((
      past,
      d.status,
    )) {
      (false, _) => (
        'Anno futuro',
        'Puoi già vedere gli insegnamenti e, se anticipi qualche esame, '
            'inserirne il voto.',
        'Inserisci voti',
      ),
      (true, PlanYearStatus.completato) => (
        'Anno completato',
        'Tutti gli esami di questo anno hanno un voto o un\'idoneità.',
        'Modifica voti',
      ),
      (true, PlanYearStatus.completatoParziale) => (
        'Completato in parte',
        d.completion.missingSummary,
        'Riprendi',
      ),
      (true, _) => (
        'Anno da completare',
        'Segna l\'anno come completato inserendo solo i voti degli esami.',
        'Segna come completato',
      ),
    };
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      // Azzurro: stato calcolato dall'app.
                      color: past && d.status == PlanYearStatus.completato
                          ? t.cyanSoft
                          : t.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    text,
                    style: TextStyle(fontSize: 13, color: t.textSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('year-banner-action'),
              onPressed: () => openYearGrades(context, year),
              child: Text(action),
            ),
          ],
        ),
      ),
    );
  }
}

class _BannerData {
  const _BannerData(this.status, this.completion);
  final PlanYearStatus status;
  final YearCompletion completion;

  static Future<_BannerData> load(AppServices s, int year) async {
    final py = await s.profiles.planYear(year);
    final courses = await yearCourses(s, year);
    final exams = await s.exams.all();
    return _BannerData(
      py?.status ?? PlanYearStatus.inCorso,
      YearCompletion.evaluate(courses, exams),
    );
  }
}
