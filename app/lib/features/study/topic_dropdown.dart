import 'package:flutter/material.dart';

import '../../models/study.dart';
import '../../widgets/common.dart';

/// Argomenti del corso selezionato (vuoto/disabilitato senza corso).
class TopicDropdown extends StatelessWidget {
  const TopicDropdown({
    super.key,
    required this.courseId,
    required this.value,
    required this.onChanged,
  });

  final int? courseId;
  final int? value;
  final ValueChanged<int?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final id = courseId;
    if (id == null) return _field(context, const [], enabled: false);
    return RevisionBuilder<List<Topic>>(
      deps: [id],
      load: (s) => s.study.topicsOfCourse(id),
      builder: (context, topics) =>
          _field(context, topics, enabled: onChanged != null),
    );
  }

  Widget _field(
    BuildContext context,
    List<Topic> topics, {
    required bool enabled,
  }) {
    final valid = topics.any((t) => t.id == value);
    return DropdownButtonFormField<int?>(
      key: ValueKey('topic-$courseId-$value-${topics.length}'),
      style: Theme.of(context).textTheme.bodyLarge,
      initialValue: valid ? value : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Argomento', isDense: true),
      items: [
        const DropdownMenuItem<int?>(value: null, child: Text('Nessuno')),
        for (final t in topics)
          DropdownMenuItem<int?>(
            value: t.id,
            child: Text(t.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: enabled ? onChanged : null,
    );
  }
}
