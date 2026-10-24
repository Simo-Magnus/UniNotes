import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/study.dart';
import '../../widgets/common.dart';
import '../../widgets/undo_snack_bar.dart';
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

/// Intervallo dello storico delle sessioni (casella accanto a «Sessioni»).
enum SessionRange {
  today('Oggi', 'oggi'),
  week('Ultimi 7 giorni', 'negli ultimi 7 giorni'),
  days15('Ultimi 15 giorni', 'negli ultimi 15 giorni'),
  days30('Ultimi 30 giorni', 'negli ultimi 30 giorni'),
  days60('Ultimi 60 giorni', 'negli ultimi 60 giorni'),
  months6('Ultimi 6 mesi', 'negli ultimi 6 mesi'),
  year('Ultimo anno', 'nell\'ultimo anno');

  const SessionRange(this.label, this.phrase);
  final String label;

  /// Per le frasi: «Nessuna sessione negli ultimi 7 giorni».
  final String phrase;

  /// Primo istante dell'intervallo (mezzanotte), oggi compreso: «Ultimi 7
  /// giorni» sono oggi e i 6 giorni prima, come nelle Statistiche.
  DateTime from(DateTime now) {
    final d = dayStart(now);
    return switch (this) {
      today => d,
      week => DateTime(d.year, d.month, d.day - 6),
      days15 => DateTime(d.year, d.month, d.day - 14),
      days30 => DateTime(d.year, d.month, d.day - 29),
      days60 => DateTime(d.year, d.month, d.day - 59),
      months6 => DateTime(d.year, d.month - 6, d.day + 1),
      year => DateTime(d.year - 1, d.month, d.day + 1),
    };
  }
}

/// Storico delle sessioni di studio (in fondo a Sessioni Studio),
/// raggruppate per materia (con il colore della materia), dalla più
/// recente. Accanto al titolo «Sessioni» la casella dell'intervallo (da
/// «Oggi» a «Ultimo anno»; si apre su «Ultimi 7 giorni»); «Aggiungi»
/// inserisce una sessione a mano.
class SessionHistory extends StatefulWidget {
  const SessionHistory({super.key, required this.catalog});
  final CourseCatalog catalog;

  /// Intervallo scelto: resta finché l'app è aperta (cambiando scheda o
  /// sezione), a ogni avvio si riparte da «Ultimi 7 giorni».
  static SessionRange range = SessionRange.week;

  @override
  State<SessionHistory> createState() => _SessionHistoryState();
}

class _SessionHistoryState extends State<SessionHistory> {
  SessionRange get _range => SessionHistory.range;

  Future<_SessionsData> _load(AppServices s) async {
    final sessions = await s.study.sessions(from: _range.from(DateTime.now()));
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
    if (!mounted) return;
    // «Annulla»: la sessione torna con lo stesso id
    showUndoSnackBar(
      context,
      'Sessione eliminata.',
      undoneMessage: 'Sessione ripristinata.',
      onUndo: () async {
        await s.database.db.insert('study_sessions', session.toMap());
        s.revision.bump();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return RevisionBuilder<_SessionsData>(
      deps: [_range],
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
    return [
      // Titolo, casella dell'intervallo e «Aggiungi» sulla stessa riga,
      // centrati in verticale e alti 44 px (area di tocco); il titolo parte
      // dal margine delle intestazioni delle materie (16 px).
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
        // il titolo si accorcia (puntini) se con i caratteri grandi non c'è
        // posto per tutti e tre
        child: Row(
          key: const Key('sessions-title-row'),
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Flexible(
              child: Text(
                'Sessioni',
                key: const Key('sessions-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: SessionRangeBox(
                  value: _range,
                  onChanged: (r) {
                    if (r == _range) return;
                    AppFeedback.of(context).toggle();
                    setState(() => SessionHistory.range = r);
                  },
                ),
              ),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              key: const Key('session-add'),
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () => _edit(),
              icon: const Icon(Icons.add),
              label: const Text('Aggiungi'),
            ),
          ],
        ),
      ),
      if (bySubject.isEmpty)
        EmptyState(
          icon: Icons.timer_outlined,
          message:
              'Nessuna sessione ${_range.phrase}. Avvia il cronometro o il '
              'timer, oppure aggiungi una sessione a mano.',
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

/// Casella dell'intervallo dello storico accanto a «Sessioni».
class SessionRangeBox extends StatelessWidget {
  const SessionRangeBox({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SessionRange value;
  final ValueChanged<SessionRange> onChanged;

  @override
  Widget build(BuildContext context) => ChoiceBox<SessionRange>(
    key: const Key('session-range'),
    tooltip: 'Intervallo delle sessioni',
    value: value,
    items: [for (final r in SessionRange.values) (r, r.label)],
    onChanged: onChanged,
  );
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
      child: LayoutBuilder(
        // il riepilogo a destra non supera metà riga: oltre va a capo
        builder: (context, c) => Row(
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
            ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: c.hasBoundedWidth ? c.maxWidth * 0.5 : 400,
              ),
              child: Text(
                '${count == 1 ? '1 sessione' : '$count sessioni'} · ${formatMinutes(minutes)}',
                textAlign: TextAlign.end,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Icona di una sessione nello storico: l'icona dell'attività (Teoria,
/// Esercizi, Ripasso, Lettura, Simulazione, Altro) nel cerchio del colore
/// della materia; le sessioni Focus hanno in più un piccolo bollino con
/// l'icona Focus in basso a destra (e «Focus» nella riga sotto).
class SessionActivityIcon extends StatelessWidget {
  const SessionActivityIcon({
    super.key,
    required this.activity,
    required this.focus,
    required this.color,
  });

  final ActivityType activity;
  final bool focus;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink = readableOn(color, theme.brightness, minRatio: 3);
    final label = focus ? 'Sessione Focus, ${activity.label}' : activity.label;
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: 40,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            CircleAvatar(
              radius: 20,
              backgroundColor: color.withValues(alpha: 0.2),
              foregroundColor: ink,
              child: Icon(activity.icon, size: 20),
            ),
            if (focus)
              Positioned(
                right: -3,
                bottom: -3,
                child: Container(
                  key: const Key('session-focus-badge'),
                  padding: const EdgeInsets.all(2),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    shape: BoxShape.circle,
                    border: Border.all(color: ink, width: 1.2),
                  ),
                  child: Icon(
                    Icons.center_focus_strong_outlined,
                    size: 12,
                    color: ink,
                  ),
                ),
              ),
          ],
        ),
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
      leading: SessionActivityIcon(
        activity: session.activityType,
        focus: session.focus,
        color: catalog.colorOf(session.courseId),
      ),
      title: Text(
        '${capitalize(formatShortWeekdayDmy(session.start))} · $range',
      ),
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
