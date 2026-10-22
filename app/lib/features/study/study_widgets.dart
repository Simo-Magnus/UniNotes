import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/theme/app_tokens.dart';
import 'course_catalog.dart';
import '../../core/constants/text_limits.dart';

/// Menu a tendina dei corsi, con il solo nome dell'insegnamento.
class CourseDropdown extends StatelessWidget {
  const CourseDropdown({
    super.key,
    required this.catalog,
    required this.value,
    required this.onChanged,
    this.label = 'Materia',
    this.noneLabel,
  });

  final CourseCatalog catalog;
  final int? value;
  final ValueChanged<int?>? onChanged;
  final String label;

  /// Se non null, aggiunge una voce "nessun corso" con questa etichetta.
  final String? noneLabel;

  @override
  Widget build(BuildContext context) {
    final valid = value != null && catalog.byId.containsKey(value);
    return DropdownButtonFormField<int?>(
      key: ValueKey('course-$value'),
      style: Theme.of(context).textTheme.bodyLarge,
      initialValue: valid ? value : null,
      isExpanded: true,
      decoration: InputDecoration(labelText: label, isDense: true),
      items: [
        if (noneLabel != null)
          DropdownMenuItem<int?>(value: null, child: Text(noneLabel!)),
        for (final c in catalog.courses)
          DropdownMenuItem<int?>(
            value: c.id,
            // solo il nome dell'insegnamento: niente pallino né sigla
            // dell'ateneo
            child: Text(c.label, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }
}

/// Barra di avanzamento (con la percentuale, salvo [showPercent] false).
/// Il colore dice a che punto sei, non di che materia si tratta (quello lo
/// dice il pallino della materia): arancione all'inizio
/// (sotto il 34%), blu a metà strada, verde solo a lavoro completato.
/// Con [color] la barra è una quota (es. tempo per materia) e usa quel colore.
class ProgressRow extends StatelessWidget {
  const ProgressRow({
    super.key,
    required this.value,
    this.label,
    this.color,
    this.showPercent = true,
  });

  final double value;
  final String? label;
  final Color? color;

  /// false: solo la barra, senza la percentuale a destra (es. le card
  /// «Per materia» e «Per argomento» delle Statistiche).
  final bool showPercent;

  static Color colorFor(double v) => v >= 1
      ? const Color(0xFF2E7D32)
      : (v < 0.34 ? const Color(0xFFF57C00) : const Color(0xFF1E88E5));

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    // barra visibile anche sul bianco del tema chiaro (3:1, elemento grafico)
    final color = readableOn(
      this.color ?? colorFor(value),
      Theme.of(context).brightness,
      minRatio: 3,
    );
    return Row(
      children: [
        if (label != null) ...[
          Flexible(child: Text(label!)),
          const SizedBox(width: 8),
        ],
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value.clamp(0, 1),
              minHeight: 8,
              color: color,
              backgroundColor: color.withValues(alpha: 0.15),
            ),
          ),
        ),
        if (showPercent) ...[
          const SizedBox(width: 8),
          // la percentuale cresce con i caratteri grandi (niente testo
          // tagliato)
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 44),
            child: Text('$pct%', textAlign: TextAlign.end, maxLines: 1),
          ),
        ],
      ],
    );
  }
}

/// Colore e icona per lo stato di un argomento.
extension TopicStatusStyle on TopicStatus {
  /// Pallini e icone: almeno 3:1 sulle card in entrambi i temi.
  Color color(ColorScheme scheme) => readableOn(
    switch (this) {
      TopicStatus.notStarted => scheme.outline,
      TopicStatus.inProgress => Colors.blue,
      TopicStatus.partial => const Color(0xFF818CF8),
      TopicStatus.completed => Colors.green,
      TopicStatus.toReview => Colors.purple,
    },
    scheme.brightness,
    minRatio: 3,
  );

  IconData get icon => switch (this) {
    TopicStatus.notStarted => Icons.radio_button_unchecked,
    TopicStatus.inProgress => Icons.play_circle_outline,
    TopicStatus.partial => Icons.incomplete_circle,
    TopicStatus.completed => Icons.check_circle,
    TopicStatus.toReview => Icons.replay_circle_filled,
  };
}

/// Icona di ogni tipo di attività: stesso stile «outlined» delle icone dei
/// tipi di file (Teoria, Esercizi, Ripasso sono le stesse), così attività e
/// file si riconoscono a colpo d'occhio. Compare nel menu «Attività», nella
/// schermata Focus e nell'elenco delle sessioni.
extension ActivityTypeIcon on ActivityType {
  IconData get icon => switch (this) {
    ActivityType.theory => Icons.menu_book_outlined,
    ActivityType.exercises => Icons.edit_note_outlined,
    ActivityType.review => Icons.replay,
    ActivityType.reading => Icons.auto_stories_outlined,
    ActivityType.simulation => Icons.quiz_outlined,
    ActivityType.other => Icons.category_outlined,
  };
}

/// Casella con una scelta (es. l'intervallo delle sessioni, la materia
/// delle statistiche per argomento): la voce scelta e la freccia; il menu
/// elenca le voci con la spunta su quella scelta. Riquadro alto 36 px
/// dentro un'area di tocco di 44.
class ChoiceBox<T> extends StatelessWidget {
  const ChoiceBox({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    required this.tooltip,
  });

  final T value;

  /// Voci del menu: (valore, etichetta).
  final List<(T, String)> items;
  final ValueChanged<T> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.tokens;
    final selected = items.indexWhere((x) => x.$1 == value);
    final label = selected >= 0
        ? items[selected].$2
        : (items.firstOrNull?.$2 ?? '');
    // il menu lavora con la posizione della voce: un valore null (es.
    // «Tutte le materie») per il menu vorrebbe dire «chiuso senza scelta»
    return PopupMenuButton<int>(
      tooltip: tooltip,
      initialValue: selected >= 0 ? selected : null,
      position: PopupMenuPosition.under,
      borderRadius: BorderRadius.circular(10),
      onSelected: (i) => onChanged(items[i].$1),
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++)
          CheckedPopupMenuItem<int>(
            value: i,
            checked: i == selected,
            child: Text(items[i].$2, overflow: TextOverflow.ellipsis),
          ),
      ],
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Center(
          widthFactor: 1,
          child: Container(
            constraints: const BoxConstraints(minHeight: 36),
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: BoxDecoration(
              color: t.innerCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: theme.colorScheme.outline),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: t.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  Icons.expand_more_rounded,
                  size: 20,
                  color: t.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Dialogo con un solo campo di testo. Restituisce il testo (trim) o null.
Future<String?> promptText(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
}) async {
  final r = await showDialog<String>(
    context: context,
    builder: (_) => _TextPrompt(title: title, label: label, initial: initial),
  );
  final t = r?.trim();
  return (t == null || t.isEmpty) ? null : t;
}

class _TextPrompt extends StatefulWidget {
  const _TextPrompt({
    required this.title,
    required this.label,
    required this.initial,
  });

  final String title;
  final String label;
  final String initial;

  @override
  State<_TextPrompt> createState() => _TextPromptState();
}

class _TextPromptState extends State<_TextPrompt> {
  late final _ctrl = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        inputFormatters: TextLimits.max(TextLimits.moduleName),
        decoration: InputDecoration(labelText: widget.label),
        textCapitalization: TextCapitalization.sentences,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _ctrl.text),
          child: const Text('Salva'),
        ),
      ],
    );
  }
}
