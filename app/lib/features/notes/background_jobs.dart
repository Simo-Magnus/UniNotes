import 'package:flutter/foundation.dart';

enum JobState { running, done, failed }

/// Tipo di operazione: le trascrizioni di Whisper non riuscite non hanno
/// una card propria, l'errore compare sulla card della registrazione.
enum JobKind { other, whisper }

/// Operazione lunga (trascrizione, riassunto, download) che continua anche
/// se si lascia la schermata.
class BackgroundJob {
  BackgroundJob(
    this.id,
    this.title, {
    this.courseId,
    this.target,
    this.onCancel,
    this.kind = JobKind.other,
  });
  final int id;
  final JobKind kind;
  final String title;
  final int? courseId;

  /// File su cui lavora (per mostrare l'avanzamento accanto al file).
  final String? target;
  JobState state = JobState.running;
  String phase = 'In corso…';
  double? fraction;
  String? error;
  String? result;

  /// Annulla l'operazione (null = non annullabile).
  final void Function()? onCancel;
  bool cancelled = false;

  void cancel() {
    if (state != JobState.running || onCancel == null) return;
    cancelled = true;
    phase = 'Annullamento…';
    onCancel!();
  }
}

class BackgroundJobs extends ChangeNotifier {
  final List<BackgroundJob> _jobs = [];
  int _next = 1;

  List<BackgroundJob> get all => List.unmodifiable(_jobs);
  List<BackgroundJob> forCourse(int? courseId) =>
      _jobs.where((j) => j.courseId == courseId).toList();

  /// Operazioni finite con un errore su [target] (di tipo [kind]).
  List<BackgroundJob> failedOn(String target, {JobKind? kind}) => [
    for (final j in _jobs)
      if (j.target == target &&
          j.state == JobState.failed &&
          (kind == null || j.kind == kind))
        j,
  ];

  BackgroundJob? runningOn(String target) {
    for (final j in _jobs) {
      if (j.target == target && j.state == JobState.running) return j;
    }
    return null;
  }

  /// Avvia [body]; `report(fase, frazione)` aggiorna l'avanzamento. Il
  /// valore restituito da [body] diventa `result` (es. percorso creato).
  BackgroundJob start(
    String title,
    Future<String?> Function(
      void Function(String phase, double? fraction) report,
    )
    body, {
    int? courseId,
    String? target,
    JobKind kind = JobKind.other,
    void Function(BackgroundJob job)? onFinished,
    void Function()? onCancel,
  }) {
    final job = BackgroundJob(
      _next++,
      title,
      courseId: courseId,
      target: target,
      onCancel: onCancel,
      kind: kind,
    );
    _jobs.add(job);
    notifyListeners();
    () async {
      try {
        job.result = await body((phase, fraction) {
          job
            ..phase = phase
            ..fraction = fraction;
          notifyListeners();
        });
        job
          ..state = JobState.done
          ..phase = 'Completato'
          ..fraction = 1;
      } catch (e) {
        job
          ..state = JobState.failed
          ..error = job.cancelled ? 'Annullato.' : e.toString();
      }
      notifyListeners();
      onFinished?.call(job);
    }();
    return job;
  }

  /// Operazione in corso con questo titolo (es. download di un modello).
  BackgroundJob? runningTitled(String title) {
    for (final j in _jobs) {
      if (j.title == title && j.state == JobState.running) return j;
    }
    return null;
  }

  void cancel(BackgroundJob job) {
    job.cancel();
    notifyListeners();
  }

  void dismiss(BackgroundJob job) {
    _jobs.remove(job);
    notifyListeners();
  }
}
