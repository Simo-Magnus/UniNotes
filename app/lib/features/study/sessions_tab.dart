import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../models/study.dart';
import '../../widgets/common.dart';
import 'course_catalog.dart';
import 'session_dialog.dart';
import 'study_stats.dart';
import 'study_widgets.dart';
import '../../utils/dates.dart';

class _SessionsData {
  const _SessionsData(this.sessions, this.topicNames);
  final List<StudySession> sessions;
  final Map<int, String> topicNames;
}

/// Storico delle sessioni di studio (in fondo a Sessioni Studio),
/// raggruppate per materia (con il colore della materia), dalla più
/// recente. Il titolo passa da «ultimi 60 giorni» a «tutte»; «Aggiungi»
/// inserisce una sessione a mano.
class SessionHistory extends StatefulWidget {
  const SessionHistory({super.key, required this.catalog});
  final CourseCatalog catalog;

  @override
  State<SessionHistory> createState() => _SessionHistoryState();
}

class _SessionHistoryState extends State<SessionHistory> {
  static const _recentDays = 60;
  bool _showAll = false;

  Future<_SessionsData> _load(AppServices s) async {
    final from = _showAll
        ? null
        : dayStart(DateTime.now()).subtract(const Duration(days: _recentDays));
    final sessions = await s.study.sessions(from: from);
    final topics = await s.study.allTopics();
    return _SessionsData(sessions, {for (final t in topics) t.id!: t.name});
  }

  Future<void> _edit([StudySession? session]) async {
    final r = await showSessionDialog(
      context,
      catalog: widget.catalog,
      session: session,
    );
    if (r == null || !mounted) return;
    final s = context.read<AppServices>();
    if (r.id == null) {
      await s.study.insertSession(r);
    } else {
      await s.study.updateSession(r);
    }
    s.revision.bump();
  }

  Future<void> _delete(StudySession session) async {
    final ok = await confirmDialog(
      context,
      'Eliminare la sessione?',
      '${formatMinutes(session.durationMinutes)} di '
          '${widget.catalog.nameOf(session.courseId)}.',
    );
    if (!ok || !mounted) return;
    final s = context.read<AppServices>();
    await s.study.deleteSession(session.id!);
    s.revision.bump();
  }

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<_SessionsData>(
      deps: [_showAll],
      load: _load,
      builder: (context, data) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _sessionWidgets(context, data),
      ),
    );
  }

  List<Widget> _sessionWidgets(BuildContext context, _SessionsData data) {
    final theme = Theme.of(context);
    final shown = [
      for (final x in data.sessions)
        if (widget.catalog.shows(x.courseId)) x,
    ]..sort((a, b) => b.start.compareTo(a.start));
    // per materia, nell'ordine dell'ultima sessione
    final bySubject = <int?, List<StudySession>>{};
    for (final x in shown) {
      bySubject.putIfAbsent(x.courseId, () => []).add(x);
    }
    final title = _showAll
        ? 'Tutte le sessioni'
        : 'Sessioni (ultimi $_recentDays giorni)';
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 8, 8),
        child: Row(
          children: [
            // Il titolo stesso cambia vista: recenti ↔ tutte.
            Flexible(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _showAll = !_showAll),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.swap_vert,
                        size: 18,
                        color: theme.colorScheme.onSurfaceVariant,
                        semanticLabel: _showAll
                            ? 'Mostra solo le sessioni recenti'
                            : 'Mostra tutte le sessioni',
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              key: const Key('session-add'),
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Aggiungi'),
            ),
          ],
        ),
      ),
      if (bySubject.isEmpty)
        const EmptyState(
          icon: Icons.timer_outlined,
          message:
              'Nessuna sessione registrata. Avvia il cronometro o il timer, '
              'oppure aggiungi una sessione a mano.',
        ),
      for (final g in bySubject.entries) ...[
        SubjectSessionsHeader(
          name: widget.catalog.nameOf(g.key),
          color: widget.catalog.colorOf(g.key),
          minutes: totalMinutes(g.value),
          count: g.value.length,
        ),
        for (final s in g.value)
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: _SessionTile(
              session: s,
              catalog: widget.catalog,
              topicName: s.topicId == null ? null : data.topicNames[s.topicId],
              onEdit: () => _edit(s),
              onDelete: () => _delete(s),
            ),
          ),
        const Divider(height: 1),
      ],
    ];
  }
}

/// Intestazione di una materia nelle sessioni: barra del colore della
/// materia, nome, numero di sessioni e tempo totale.
class SubjectSessionsHeader extends StatelessWidget {
  const SubjectSessionsHeader({
    super.key,
    required this.name,
    required this.color,
    required this.minutes,
    required this.count,
  });

  final String name;
  final Color color;
  final int minutes;
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 22,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${count == 1 ? '1 sessione' : '$count sessioni'} · ${formatMinutes(minutes)}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.session,
    required this.catalog,
    required this.topicName,
    required this.onEdit,
    required this.onDelete,
  });

  final StudySession session;
  final CourseCatalog catalog;
  final String? topicName;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final t = DateFormat.Hm('it_IT');
    final range = session.end == null
        ? t.format(session.start)
        : '${t.format(session.start)}–${t.format(session.end!)}';
    final subtitle = [
      if (session.focus) 'Focus',
      session.activityType.label,
      ?topicName,
      ?session.notes,
    ].join(' · ');
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: catalog
            .colorOf(session.courseId)
            .withValues(alpha: 0.2),
        foregroundColor: catalog.colorOf(session.courseId),
        child: Icon(
          session.focus
              ? Icons.center_focus_strong_outlined
              : session.activityType.icon,
          size: 20,
          semanticLabel: session.focus ? 'Sessione Focus' : null,
        ),
      ),
      title: Text('${capitalize(formatShortWeekdayDmy(session.start))} · $range'),
      subtitle: Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(formatMinutes(session.durationMinutes)),
          IconButton(
            tooltip: 'Elimina',
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
          ),
        ],
      ),
      onTap: onEdit,
    );
  }
}
