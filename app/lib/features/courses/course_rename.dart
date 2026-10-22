import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/text_limits.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../widgets/undo_snack_bar.dart';

/// Dà all'insegnamento il nome [name] scelto dallo studente (vuoto o uguale a
/// quello ufficiale = torna il nome ufficiale). Il nome è un dato solo
/// dell'insegnamento (`courses.custom_name`): Esami, Insegnamenti, Studio,
/// Registra, Libri, Home e promemoria lo leggono da lì. Le cartelle di
/// registrazioni e appunti seguono il nome nuovo. Restituisce l'insegnamento
/// aggiornato (null se non è cambiato nulla).
Future<Course?> applyCourseName(
  AppServices s,
  Course course,
  String? name,
) async {
  final id = course.id;
  if (id == null) return null;
  final clean = cleanCourseName(name);
  final Course next;
  if (!hasOfficialName(course)) {
    // insegnamento aggiunto a mano: nessun nome ufficiale da conservare
    if (clean == null || clean == course.name) return null;
    next = course.copyWith(name: clean, clearCustomName: true);
    await s.courses.update(next);
  } else {
    next = (clean == null || clean == course.officialName)
        ? course.copyWith(clearCustomName: true)
        : course.copyWith(customName: clean);
    if (next.name == course.name && next.customName == course.customName) {
      return null;
    }
    await s.courses.setCustomName(id, next.hasCustomName ? next.name : null);
  }
  if (next.name != course.name) {
    try {
      await s.notes.renameCourse(course, next);
    } catch (_) {
      // cartella non raggiungibile: il nome nel database è già cambiato
    }
  }
  s.revision.bump();
  return next;
}

/// L'insegnamento viene dal database dei corsi (ha un nome ufficiale che
/// «Aggiorna database» può cambiare); quelli aggiunti a mano no.
bool hasOfficialName(Course c) => c.externalId != null;

/// «Nome dell'insegnamento»: campo con il nome mostrato, il nome ufficiale
/// sotto e, se è stato cambiato, l'icona per rimettere quello ufficiale.
/// Due soli pulsanti, «Annulla» e «Salva». Restituisce true se salvato.
Future<bool> renameCourseDialog(BuildContext context, Course course) async {
  final s = context.read<AppServices>();
  final name = await showDialog<String>(
    context: context,
    builder: (_) => CourseRenameDialog(course: course),
  );
  if (name == null || !context.mounted) return false;
  final next = await applyCourseName(s, course, name);
  if (next != null && context.mounted) {
    // «Annulla»: torna il nome di prima (anche nelle cartelle degli appunti)
    showUndoSnackBar(
      context,
      next.hasCustomName
          ? 'Nome cambiato in tutta l\'app: «${next.name}»'
          : 'Ripristinato il nome originale: «${next.name}»',
      undoneMessage: 'Nome di nuovo «${course.name}».',
      onUndo: () => applyCourseName(s, next, course.name),
    );
  }
  return next != null;
}

class CourseRenameDialog extends StatefulWidget {
  const CourseRenameDialog({super.key, required this.course});
  final Course course;

  @override
  State<CourseRenameDialog> createState() => _CourseRenameDialogState();
}

class _CourseRenameDialogState extends State<CourseRenameDialog> {
  late final _ctrl = TextEditingController(text: widget.course.name);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _ok() => Navigator.pop(context, _ctrl.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Nome dell\'insegnamento'),
      content: CourseNameField(
        controller: _ctrl,
        officialName: hasOfficialName(widget.course)
            ? widget.course.officialName
            : null,
        autofocus: true,
        onSubmitted: (_) => _ok(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          key: const Key('course-rename-save'),
          onPressed: _ok,
          child: const Text('Salva'),
        ),
      ],
    );
  }
}

/// Campo del nome dell'insegnamento (dialogo «Nome dell'insegnamento» e
/// modulo dell'insegnamento): con un nome diverso da quello ufficiale mostra
/// il nome originale e l'icona «Ripristina il nome originale».
class CourseNameField extends StatefulWidget {
  const CourseNameField({
    super.key,
    required this.controller,
    required this.officialName,
    this.autofocus = false,
    this.onSubmitted,
    this.label = 'Nome',
    this.validator,
  });

  final TextEditingController controller;

  /// Nome dal database dei corsi (null per un insegnamento nuovo).
  final String? officialName;
  final bool autofocus;
  final ValueChanged<String>? onSubmitted;
  final String label;
  final FormFieldValidator<String>? validator;

  @override
  State<CourseNameField> createState() => _CourseNameFieldState();
}

class _CourseNameFieldState extends State<CourseNameField> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final official = widget.officialName;
    final custom =
        official != null &&
        cleanCourseName(widget.controller.text) != official;
    return TextFormField(
      key: const Key('course-name-field'),
      controller: widget.controller,
      autofocus: widget.autofocus,
      inputFormatters: TextLimits.max(TextLimits.courseName),
      textCapitalization: TextCapitalization.sentences,
      onFieldSubmitted: widget.onSubmitted,
      validator: widget.validator,
      decoration: InputDecoration(
        labelText: widget.label,
        helperText: custom ? 'Nome originale: $official' : null,
        helperMaxLines: 3,
        suffixIcon: custom
            ? IconButton(
                key: const Key('course-name-restore'),
                tooltip: 'Ripristina il nome originale',
                icon: const Icon(Icons.restart_alt),
                onPressed: () => widget.controller.text = official,
              )
            : null,
      ),
    );
  }
}
