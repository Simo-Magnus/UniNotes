import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/exam.dart';
import '../../widgets/common.dart';
import '../academic/year_widgets.dart';
import 'exam_stats.dart';
import 'exam_tile.dart';
import 'exam_ui.dart';
import 'previous_years_screen.dart';

/// Filtro per tipo di prova comune alle liste. Nessun filtro scelto (null)
/// = tutte le prove: non c'è l'opzione «Tutti».
enum KindFilter { finals, midterms }

extension KindFilterX on KindFilter? {
  bool matches(Exam e) => switch (this) {
    null => true,
    KindFilter.finals => e.kind == ExamKind.finalExam,
    KindFilter.midterms => e.kind == ExamKind.midterm,
  };
}

/// «Esami» / «Itinere/esoneri»: toccando il segmento scelto lo si toglie e
/// si torna a vedere tutto.
class KindFilterBar extends StatelessWidget {
  const KindFilterBar({
    super.key,
    required this.value,
    required this.onChanged,
    this.narrow = false,
  });
  final KindFilter? value;
  final ValueChanged<KindFilter?> onChanged;

  /// Telefono: «Itinere/esoneri» al posto di «In itinere/esoneri» (sta su una riga).
  final bool narrow;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<KindFilter>(
      showSelectedIcon: false,
      emptySelectionAllowed: true,
      segments: [
        const ButtonSegment(value: KindFilter.finals, label: Text('Esami')),
        ButtonSegment(
          value: KindFilter.midterms,
          label: Text(narrow ? 'Itinere/esoneri' : 'In itinere/esoneri'),
        ),
      ],
      selected: {?value},
      onSelectionChanged: (s) => onChanged(s.firstOrNull),
    );
  }
}

/// Tab "Da sostenere": prove da prenotare o prenotate divise per semestre
/// dell'insegnamento, in ordine cronologico (a scelta per ultimi), con gli
/// esami finali non superati (stato «Non superato», si riprenotano
/// dall'icona). Gli esami «Da completare» degli anni prima dell'anno di
/// partenza non ci sono: il riquadro «Anni precedenti» in cima porta alla
/// pagina dove si compilano. Niente card delle sessioni d'esame né «Segnala date
/// d'esame»: data e appelli dipendono dal canale e dal docente, si indicano
/// su ogni prova.
class PendingExamsTab extends StatefulWidget {
  const PendingExamsTab({
    super.key,
    required this.data,
    required this.selectedId,
    required this.onSelect,
  });

  final ExamsData data;
  final int? selectedId;
  final ValueChanged<Exam> onSelect;

  @override
  State<PendingExamsTab> createState() => _PendingExamsTabState();
}

class _PendingExamsTabState extends State<PendingExamsTab> {
  KindFilter? _filter;

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final pending = sortByDate(
      toTakeExams(data.scopedExams, all: data.exams).where(_filter.matches),
      data.courses,
    );
    final booked = pending.where((e) => e.status == ExamStatus.booked).length;
    final today = DateTime.now();

    final children = <Widget>[
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: LayoutBuilder(
          builder: (context, c) => Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              KindFilterBar(
                value: _filter,
                onChanged: (f) => setState(() => _filter = f),
                narrow: c.maxWidth < kNarrowFilters,
              ),
              _CountChip(
                key: const Key('count-to-take'),
                count: pending.length,
                label: 'da sostenere',
                icon: Icons.pending_actions_outlined,
                color: const Color(0xFFF57C00),
              ),
              _CountChip(
                key: const Key('count-booked'),
                count: booked,
                label: booked == 1 ? 'prenotato' : 'prenotati',
                icon: Icons.event_available_outlined,
                color: const Color(0xFF1E88E5),
              ),
            ],
          ),
        ),
      ),
      const YearStatusBanner(),
      // esami degli anni prima dell'anno di partenza da completare
      PreviousYearsBanner(data: data.previous),
    ];

    if (pending.isEmpty) {
      children.add(
        const SizedBox(
          height: 320,
          child: EmptyState(
            icon: Icons.event_available_outlined,
            message: 'Nessuna prova da sostenere.\nAggiungi un esame o una prova in itinere con il pulsante +.',
          ),
        ),
      );
    } else {
      for (final g in groupBySemester(
        pending,
        (e) => data.courses[e.courseId],
      )) {
        children.add(SectionHeader(g.label));
        for (final e in g.items) {
          final course = data.courses[e.courseId];
          children.add(
            ExamTile(
              exam: e,
              course: course,
              selected: e.id == widget.selectedId,
              onTap: () => widget.onSelect(e),
              dateHint: _hint(e, today),
            ),
          );
        }
      }
    }
    children.add(const SizedBox(height: 96));
    return ListView(children: children);
  }

  /// Esame finale senza data: prossimo appello noto oppure "Data da
  /// aggiungere".
  String? _hint(Exam e, DateTime today) {
    if (e.kind != ExamKind.finalExam || e.date != null) return null;
    final w = widget.data.nextWindow(e.courseId, today);
    if (w == null) return null;
    return 'Prossimo appello: ${formatDate(w.start)}';
  }
}

/// Contatore con icona e colore propri (da sostenere, prenotati).
class _CountChip extends StatelessWidget {
  const _CountChip({
    super.key,
    required this.count,
    required this.label,
    required this.icon,
    required this.color,
  });

  final int count;
  final String label;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // tema chiaro: tinta scurita quanto basta per il contrasto AA
    final fg = dark
        ? Color.lerp(color, Colors.white, 0.45)!
        : readableOn(color, Brightness.light);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: dark ? 0.25 : 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: fg),
          const SizedBox(width: 6),
          // caratteri grandi: il testo va a capo dentro la pillola
          Flexible(
            child: Text(
              '$count $label',
              style: TextStyle(color: fg, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
