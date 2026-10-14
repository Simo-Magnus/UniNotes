import '../../models/study.dart';

/// Lista con l'elemento in [from] spostato in posizione [to] (indici di
/// `ReorderableListView.onReorderItem`). null se non cambia nulla.
List<T>? reorderList<T>(List<T> items, int from, int to) {
  if (from < 0 || from >= items.length) return null;
  final target = to.clamp(0, items.length - 1);
  if (target == from) return null;
  final copy = [...items];
  final v = copy.removeAt(from);
  copy.insert(target, v);
  return copy;
}

/// Argomento con nome e nota cambiati (nota vuota = nessuna nota).
Topic withNameNote(Topic t, String name, String note) => Topic(
  id: t.id,
  moduleId: t.moduleId,
  name: name,
  status: t.status,
  theoryDone: t.theoryDone,
  exercisesDone: t.exercisesDone,
  reviewDone: t.reviewDone,
  notes: note.trim().isEmpty ? null : note.trim(),
  sort: t.sort,
);
