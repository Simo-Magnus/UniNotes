import 'package:flutter/material.dart';

import '../../core/constants/enums.dart';
import '../../core/feedback/app_modals.dart';
import '../../models/study.dart';
import 'course_catalog.dart';
import 'study_stats.dart';
import 'study_widgets.dart';
import 'topic_dropdown.dart';
import '../../utils/dates.dart';
import '../../core/constants/text_limits.dart';
import '../../widgets/date_pick.dart';

/// Inserimento/modifica manuale di una sessione di studio.
Future<StudySession?> showSessionDialog(
  BuildContext context, {
  required CourseCatalog catalog,
  StudySession? session,
}) => showAppDialog<StudySession>(
  context: context,
  builder: (_) => _SessionDialog(catalog: catalog, session: session),
);

/// Fine della sessione: se l'orario di fine è prima dell'inizio si
/// intende il giorno dopo (sessione a cavallo della mezzanotte).
DateTime sessionEnd(DateTime day, TimeOfDay start, TimeOfDay end) {
  final s = DateTime(day.year, day.month, day.day, start.hour, start.minute);
  var e = DateTime(day.year, day.month, day.day, end.hour, end.minute);
  if (e.isBefore(s)) e = DateTime(e.year, e.month, e.day + 1, e.hour, e.minute);
  return e;
}

class _SessionDialog extends StatefulWidget {
  const _SessionDialog({required this.catalog, this.session});
  final CourseCatalog catalog;
  final StudySession? session;

  @override
  State<_SessionDialog> createState() => _SessionDialogState();
}

class _SessionDialogState extends State<_SessionDialog> {
  late int? _courseId = widget.session?.courseId;
  late int? _topicId = widget.session?.topicId;
  late ActivityType _activity =
      widget.session?.activityType ?? ActivityType.theory;
  late DateTime _day;
  late TimeOfDay _start;
  late TimeOfDay _end;
  late final _notes = TextEditingController(text: widget.session?.notes ?? '');

  @override
  void initState() {
    super.initState();
    final s = widget.session;
    final now = DateTime.now();
    final start = s?.start ?? now.subtract(const Duration(hours: 1));
    final end =
        s?.end ?? start.add(Duration(minutes: s?.durationMinutes ?? 60));
    _day = dayStart(start);
    _start = TimeOfDay.fromDateTime(start);
    _end = TimeOfDay.fromDateTime(end);
  }

  @override
  void dispose() {
    _notes.dispose();
    super.dispose();
  }

  DateTime get _startAt =>
      DateTime(_day.year, _day.month, _day.day, _start.hour, _start.minute);
  DateTime get _endAt => sessionEnd(_day, _start, _end);

  /// Se gli orari non vengono toccati si mantiene la durata salvata
  /// (le sessioni del cronometro escludono le pause).
  bool _timesChanged = false;
  int get _minutes {
    final s = widget.session;
    if (s != null && !_timesChanged) return s.durationMinutes;
    return minutesBetween(_startAt, _endAt);
  }

  Future<void> _pickDay() async {
    final d = await showSafeDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null && mounted) setState(() => _day = d);
  }

  Future<void> _pickTime(bool start) async {
    final t = await showSafeTimePicker(
      context: context,
      initialTime: start ? _start : _end,
    );
    if (t == null || !mounted) return;
    setState(() {
      start ? _start = t : _end = t;
      _timesChanged = true;
    });
  }

  void _save() {
    if (_minutes < 1) return;
    final notes = _notes.text.trim();
    Navigator.pop(
      context,
      StudySession(
        id: widget.session?.id,
        courseId: _courseId,
        topicId: _topicId,
        start: _startAt,
        end: _endAt,
        durationMinutes: _minutes,
        activityType: _activity,
        notes: notes.isEmpty ? null : notes,
        // modificando una sessione Focus restano modulo e durata scelta
        moduleId: _courseId == widget.session?.courseId
            ? widget.session?.moduleId
            : null,
        focus: widget.session?.focus ?? false,
        plannedMinutes: widget.session?.plannedMinutes,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = MaterialLocalizations.of(context);
    return AlertDialog(
      title: Text(
        widget.session == null ? 'Nuova sessione' : 'Modifica sessione',
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              CourseDropdown(
                catalog: widget.catalog,
                value: _courseId,
                noneLabel: 'Nessuna materia',
                onChanged: (v) => setState(() {
                  _courseId = v;
                  _topicId = null;
                }),
              ),
              const SizedBox(height: 12),
              TopicDropdown(
                courseId: _courseId,
                value: _topicId,
                onChanged: (v) => setState(() => _topicId = v),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<ActivityType>(
                // a tutta larghezza: con la finestra stretta o i caratteri
                // grandi la scritta si accorcia invece di uscire dal riquadro
                isExpanded: true,
                style: Theme.of(context).textTheme.bodyLarge,
                initialValue: _activity,
                decoration: const InputDecoration(
                  labelText: 'Attività',
                  isDense: true,
                ),
                items: [
                  for (final a in ActivityType.values)
                    DropdownMenuItem(
                      value: a,
                      child: Row(
                        children: [
                          Icon(a.icon, size: 18),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              a.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                onChanged: (v) => setState(() => _activity = v ?? _activity),
              ),
              const SizedBox(height: 8),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: Text(formatWeekdayDmy(_day)),
                onTap: _pickDay,
              ),
              Row(
                children: [
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.schedule),
                      title: Text('Inizio ${loc.formatTimeOfDay(_start)}'),
                      onTap: () => _pickTime(true),
                    ),
                  ),
                  Expanded(
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('Fine ${loc.formatTimeOfDay(_end)}'),
                      onTap: () => _pickTime(false),
                    ),
                  ),
                ],
              ),
              Text(
                _minutes < 1
                    ? 'Durata non valida'
                    : 'Durata: ${formatMinutes(_minutes)}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notes,
                minLines: 1,
                maxLines: 4,
                maxLength: TextLimits.shortNote,
                decoration: const InputDecoration(labelText: 'Note'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _minutes < 1 ? null : _save,
          child: const Text('Salva'),
        ),
      ],
    );
  }
}
