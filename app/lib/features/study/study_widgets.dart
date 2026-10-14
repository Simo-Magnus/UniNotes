import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
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

/// Barra di avanzamento con percentuale.
/// Barra di avanzamento. Il colore dice a che punto sei, non di che materia
/// si tratta (quello lo dice il pallino della materia): arancione all'inizio
/// (sotto il 34%), blu a metà strada, verde solo a lavoro completato.
/// Con [color] la barra è una quota (es. tempo per materia) e usa quel colore.
class ProgressRow extends StatelessWidget {
  const ProgressRow({super.key, required this.value, this.label, this.color});

  final double value;
  final String? label;
  final Color? color;

  static Color colorFor(double v) => v >= 1
      ? const Color(0xFF2E7D32)
      : (v < 0.34 ? const Color(0xFFF57C00) : const Color(0xFF1E88E5));

  @override
  Widget build(BuildContext context) {
    final pct = (value * 100).round();
    final color = this.color ?? colorFor(value);
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
        const SizedBox(width: 8),
        // la percentuale cresce con i caratteri grandi (niente testo tagliato)
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44),
          child: Text('$pct%', textAlign: TextAlign.end, maxLines: 1),
        ),
      ],
    );
  }
}

/// Colore e icona per lo stato di un argomento.
extension TopicStatusStyle on TopicStatus {
  Color color(ColorScheme scheme) => switch (this) {
    TopicStatus.notStarted => scheme.outline,
    TopicStatus.inProgress => Colors.blue,
    TopicStatus.partial => const Color(0xFF818CF8),
    TopicStatus.completed => Colors.green,
    TopicStatus.toReview => Colors.purple,
  };

  IconData get icon => switch (this) {
    TopicStatus.notStarted => Icons.radio_button_unchecked,
    TopicStatus.inProgress => Icons.play_circle_outline,
    TopicStatus.partial => Icons.incomplete_circle,
    TopicStatus.completed => Icons.check_circle,
    TopicStatus.toReview => Icons.replay_circle_filled,
  };
}

extension ActivityTypeIcon on ActivityType {
  IconData get icon => switch (this) {
    ActivityType.theory => Icons.menu_book,
    ActivityType.exercises => Icons.edit_note,
    ActivityType.review => Icons.replay,
    ActivityType.reading => Icons.chrome_reader_mode,
    ActivityType.simulation => Icons.quiz,
    ActivityType.other => Icons.more_horiz,
  };
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
