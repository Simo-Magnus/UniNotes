import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/academic/academic_year.dart';
import '../../../core/services/app_services.dart';
import '../../../core/theme/app_tokens.dart';
import '../../../widgets/glass.dart';
import '../../exams/previous_years.dart';
import '../../exams/previous_years_screen.dart';

/// Riquadro della Home «Completa gli esami degli anni precedenti»: compare
/// subito dopo l'onboarding o il cambio di corso con un anno di partenza
/// oltre il 1°, finché ci sono esami obbligatori «Da completare». Due
/// pulsanti: «Completa» (apre Esami → Anni precedenti) e «Più tardi» (lo
/// nasconde per 7 giorni, vedi [PreviousYearsPrompt]).
class PreviousYearsHomeCard extends StatefulWidget {
  const PreviousYearsHomeCard({super.key});

  @override
  State<PreviousYearsHomeCard> createState() => _PreviousYearsHomeCardState();
}

class _PreviousYearsHomeCardState extends State<PreviousYearsHomeCard> {
  late final AppServices _s = context.read<AppServices>();
  PreviousYearsData? _data;

  @override
  void initState() {
    super.initState();
    _s.revision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    _s.revision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    PreviousYearsData? d;
    try {
      d = await loadPreviousYears(_s);
      if (d != null &&
          (d.toComplete == 0 ||
              !await PreviousYearsPrompt.homeVisible(_s.settings))) {
        d = null;
      }
    } catch (_) {
      d = null;
    }
    if (mounted) setState(() => _data = d);
  }

  Future<void> _later() async {
    setState(() => _data = null);
    try {
      await PreviousYearsPrompt.later(_s.settings);
    } catch (_) {}
    _s.feedback.toggle();
  }

  @override
  Widget build(BuildContext context) {
    final d = _data;
    if (d == null) return const SizedBox.shrink();
    final t = context.tokens;
    final theme = Theme.of(context);
    final n = d.toComplete;
    return GlassCard(
      key: const Key('home-previous-years'),
      child: InkWell(
        onTap: () => openPreviousYears(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.history_edu_rounded, color: t.cyanSoft),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Completa gli esami degli anni precedenti',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'Hai iniziato a usare UniNotes al '
                '${planYearLabel(d.startYear)}: indica quali esami '
                '${d.yearsLabel} hai già sostenuto. Quelli ancora da '
                'sostenere diventano arretrati. '
                '${n == 1 ? 'Ne resta 1' : 'Ne restano $n'} da completare.',
                style: TextStyle(fontSize: 13, color: t.textSecondary),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                alignment: WrapAlignment.end,
                children: [
                  TextButton(
                    key: const Key('home-previous-later'),
                    onPressed: _later,
                    child: const Text('Più tardi'),
                  ),
                  FilledButton.tonal(
                    key: const Key('home-previous-open'),
                    onPressed: () => openPreviousYears(context),
                    child: const Text('Completa'),
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
