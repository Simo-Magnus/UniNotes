import 'package:flutter/material.dart';

import '../../../core/router/app_shell.dart';
import '../../../core/theme/app_tokens.dart';
import '../../notes/course_notes_screen.dart' show openRecording;
import '../../notes/lesson_transcripts.dart';
import '../dashboard_data.dart';
import 'dashboard_card.dart';

/// Ultime lezioni registrate, con le trascrizioni fatte (dal vivo, Whisper,
/// Gemini, ognuna con il suo colore). Toccando una lezione si apre
/// l'ascolto con la trascrizione.
class RecordingsCard extends StatelessWidget {
  const RecordingsCard({super.key, required this.data});

  final DashboardData data;

  @override
  Widget build(BuildContext context) {
    final items = data.recordings;
    return DashboardCard(
      icon: Icons.graphic_eq,
      title: 'Ultime registrazioni',
      actionLabel: 'Registra',
      onAction: () => AppShell.goTo(context, 'Registra'),
      child: items.isEmpty
          ? const CardEmptyMessage(
              icon: Icons.mic_none_outlined,
              message:
                  'Registra una lezione da «Inizia»: la trascrizione appare '
                  'mentre il docente parla.',
            )
          : Column(
              children: [
                for (var i = 0; i < items.length; i++) ...[
                  if (i > 0)
                    const Divider(height: 1, indent: 16, endIndent: 16),
                  _RecordingRow(item: items[i]),
                ],
              ],
            ),
    );
  }
}

class _RecordingRow extends StatelessWidget {
  const _RecordingRow({required this.item});
  final RecentRecording item;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final theme = Theme.of(context);
    final tr = item.transcripts;
    final labels = <(String, Color)>[
      if (tr.systemLive != null) ('Dal vivo', t.cyanSoft),
      if (tr.whisper != null)
        ('Whisper', transcriptColor(context, TranscriptKind.whisper)),
      if (tr.gemini != null)
        ('Gemini', transcriptColor(context, TranscriptKind.gemini)),
    ];
    return ListTile(
      leading: Icon(Icons.play_circle_outline, color: t.tintNotes),
      title: Text(item.file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // solo il nome dell'insegnamento
          Text(item.course.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              if (labels.isEmpty)
                Text(
                  'Da trascrivere',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: t.textMuted,
                  ),
                ),
              for (final (label, color) in labels)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: color.withValues(alpha: 0.55)),
                  ),
                  child: Text(
                    label,
                    style: theme.textTheme.labelSmall?.copyWith(color: color),
                  ),
                ),
            ],
          ),
        ],
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => openRecording(context, item.course, item.file),
    );
  }
}
