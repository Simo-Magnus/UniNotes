import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../models/calendar_entry.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../cloud/cloud_drive_service.dart';
import '../cloud/onenote_screen.dart';
import '../study/course_catalog.dart';
import 'course_notes_screen.dart';
import 'recently_deleted_screen.dart';
import 'recorder_screen.dart';
import 'transcript_search_screen.dart';

class _NotesData {
  _NotesData(
    this.catalog,
    this.counts,
    this.suggested,
    this.onedrive,
    this.deleted,
  );
  final CourseCatalog catalog;
  final Map<int, int> counts;

  /// Elementi in «Eliminati di recente».
  final int deleted;

  /// Account OneDrive collegato (sincronizzazione e OneNote).
  final bool onedrive;

  /// Corso della lezione in corso (o della prossima di oggi).
  final Course? suggested;
}

/// "Appunti": registrazioni, trascrizioni, riassunti e appunti per corso.
class NotesScreen extends StatelessWidget {
  const NotesScreen({super.key});

  static Future<_NotesData> _load(AppServices s) async {
    final catalog = await CourseCatalog.load(s);
    final counts = <int, int>{};
    for (final c in catalog.courses) {
      counts[c.id!] = await s.notes.count(c);
    }
    return _NotesData(
      catalog,
      counts,
      await suggestedCourse(s, catalog),
      await s.onedrive.connected(),
      (await s.trash.list()).length,
    );
  }

  /// Lezione in corso adesso, altrimenti la prossima di oggi.
  static Future<Course?> suggestedCourse(
    AppServices s,
    CourseCatalog catalog,
  ) async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final entries = await s.calendar.entriesBetween(
      day,
      day.add(const Duration(days: 1)),
    );
    final lectures =
        entries
            .where((e) => e.kind == CalendarEntryKind.lecture && !e.allDay)
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    CalendarEntry? pick;
    for (final e in lectures) {
      final inProgress =
          !now.isBefore(e.start.subtract(const Duration(minutes: 15))) &&
          now.isBefore(e.end);
      if (inProgress) {
        pick = e;
        break;
      }
      if (pick == null && e.start.isAfter(now)) pick = e;
    }
    return pick?.courseId == null ? null : catalog.byId[pick!.courseId];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Registra'),
        actions: [
          IconButton(
            tooltip: 'Cerca nelle trascrizioni',
            icon: const Icon(Icons.search),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const TranscriptSearchScreen(),
              ),
            ),
          ),
          const _CloudSyncButton(),
        ],
      ),
      floatingActionButton: GlowFab(
        heroTag: 'record',
        onPressed: () => openRecorder(context),
        icon: const Icon(Icons.mic),
        label: const Text('Registra lezione'),
      ),
      body: RevisionBuilder<_NotesData>(
        load: _load,
        builder: (context, d) {
          if (d.catalog.courses.isEmpty) {
            return const EmptyState(
              icon: Icons.mic_none,
              message: 'Nessun corso: aggiungili in Insegnamenti o aggiorna il database in Impostazioni.',
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
            children: [
              if (d.onedrive)
                GlassCard(
                  child: ListTile(
                    leading: const Icon(Icons.menu_book_outlined),
                    title: const Text('OneNote'),
                    subtitle: const Text('I tuoi blocchi appunti'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const OneNoteScreen(),
                      ),
                    ),
                  ),
                ),
              if (d.suggested != null)
                GlassCard(
                  child: ListTile(
                    leading: const Icon(Icons.radio_button_checked),
                    title: Text('Registra ${d.suggested!.label}'),
                    subtitle: const Text('Lezione di oggi in calendario'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => openRecorder(context, course: d.suggested),
                  ),
                ),
              // insegnamenti solo con il nome: niente gruppi per ateneo
              GlassCard(
                child: Column(
                  children: [
                    for (final c in d.catalog.courses)
                      ListTile(
                        // solo il nome dell'insegnamento (niente pallino)
                        title: Text(c.label),
                        subtitle: Text(_countLabel(d.counts[c.id] ?? 0)),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => CourseNotesScreen(course: c),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              if (d.deleted > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: GlassCard(
                    child: ListTile(
                      leading: const Icon(Icons.delete_outline),
                      title: const Text('Eliminati di recente'),
                      subtitle: Text(
                        d.deleted == 1 ? '1 elemento' : '${d.deleted} elementi',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const RecentlyDeletedScreen(),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static String _countLabel(int n) => switch (n) {
    0 => 'Nessun file',
    1 => '1 file',
    _ => '$n file',
  };
}

/// Apre il registratore (o lo riporta in primo piano se già attivo).
/// Registratore aperto (una sola pagina alla volta: premendo più volte
/// «Registra» non si impilano pagine uguali).
bool _recorderOpen = false;

/// Apre il registratore. Con [fromCourse] (dalla pagina di quel corso),
/// dopo «Salva» si torna alla pagina e il risultato è il percorso della
/// registrazione salvata.
Future<String?> openRecorder(
  BuildContext context, {
  Course? course,
  bool fromCourse = false,
}) async {
  if (_recorderOpen) return null;
  _recorderOpen = true;
  final s = context.read<AppServices>();
  String? saved;
  try {
    saved = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(
        builder: (_) => RecorderScreen(
          initialCourse: course,
          fromCourse: fromCourse ? course?.id : null,
        ),
      ),
    );
  } finally {
    _recorderOpen = false;
  }
  s.revision.bump();
  return saved;
}

/// Sincronizzazione con OneDrive e Google Drive dalla barra (se almeno un
/// account è collegato).
class _CloudSyncButton extends StatelessWidget {
  const _CloudSyncButton();

  static Future<List<CloudDriveService>> _connected(
    List<CloudDriveService> clouds,
  ) async => [
    for (final c in clouds)
      if (await c.connected()) c,
  ];

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final clouds = s.clouds;
    return ListenableBuilder(
      listenable: Listenable.merge(clouds),
      builder: (context, _) => FutureBuilder<List<CloudDriveService>>(
        future: _connected(clouds),
        builder: (context, snap) {
          final on = snap.data ?? const <CloudDriveService>[];
          if (on.isEmpty) return const SizedBox.shrink();
          final busy = on.where((c) => c.syncing).firstOrNull;
          final names = on.map((c) => c.serviceName).join(' e ');
          return IconButton(
            tooltip: busy != null
                ? (busy.progress ?? 'Sincronizzazione…')
                : 'Sincronizza con $names',
            onPressed: busy != null
                ? null
                : () async {
                    final lines = <String>[];
                    for (final c in on) {
                      final r = await c.sync();
                      lines.add(
                        '${c.serviceName}: '
                        '${r ?? c.lastError ?? 'non sincronizzato'}',
                      );
                    }
                    s.revision.bump();
                    if (context.mounted) showSnack(context, lines.join('\n'));
                  },
            icon: busy != null
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync_outlined),
          );
        },
      ),
    );
  }
}
