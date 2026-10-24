import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/app_services.dart';
import '../../models/course.dart';
import '../../models/study.dart';
import '../notes/ai_files.dart';
import '../notes/ai_prompts.dart';
import '../notes/ai_request_dialog.dart';
import '../links/link_settings.dart';

/// «Revisiona con AI» da Studio: si sceglie la parte del corso (tutto
/// l'insegnamento, un modulo e, dentro il modulo, un argomento) e che cosa
/// chiedere; poi prompt e file da allegare (appunti, allegati del
/// modulo/argomento, libri obbligatori). [module] e [topic] sono la scelta
/// iniziale (dal menu di un modulo o di un argomento).
Future<void> askAiStudy(
  BuildContext context,
  Course course, {
  StudyModule? module,
  Topic? topic,
}) async {
  final s = context.read<AppServices>();
  final modules = course.id == null
      ? const <StudyModule>[]
      : await s.study.modules(course.id!);
  final topics = course.id == null
      ? const <Topic>[]
      : await s.study.topicsOfCourse(course.id!);
  if (!context.mounted) return;
  final choice = await showAppDialog<_AiChoice>(
    context: context,
    builder: (_) => _AiScopeDialog(
      modules: modules,
      topics: topics,
      moduleId: module?.id ?? topic?.moduleId,
      topicId: topic?.id,
    ),
  );
  if (choice == null || !context.mounted) return;
  final m = modules.where((x) => x.id == choice.moduleId).firstOrNull;
  final t = topics.where((x) => x.id == choice.topicId).firstOrNull;
  final ai = await s.settings.referenceAi();
  final files = await collectAiFiles(s, course, module: m, topic: t);
  final exam = await _nextExamDate(s, course);
  if (!context.mounted) return;
  await showAiRequestDialog(
    context,
    title: 'Revisiona con AI',
    ai: ai,
    intro:
        'Copia e incolla il seguente messaggio nella chat della tua AI di '
        'riferimento.\nNel caso in cui essa non abbia la possibilità di accedere '
        'ai file presenti sul tuo '
        '${Platform.isAndroid || Platform.isIOS ? 'telefono' : 'computer'}, '
        'allega i seguenti file.',
    prompt: choice.task.prompt(
      course,
      ai,
      files: [for (final f in files) p.basename(f.path)],
      scope: aiScope(topics, module: m, topic: t),
      examDate: exam,
      today: DateTime.now(),
    ),
    files: files,
  );
}

/// Parte del corso e richiesta scelte nel dialogo.
typedef _AiChoice = ({int? moduleId, int? topicId, AiTask task});

/// Modulo («Tutto l'insegnamento» o un modulo), argomento («Tutto il
/// modulo» o un argomento, solo dopo aver scelto il modulo) e richiesta.
/// Due soli pulsanti: Annulla e Continua.
class _AiScopeDialog extends StatefulWidget {
  const _AiScopeDialog({
    required this.modules,
    required this.topics,
    this.moduleId,
    this.topicId,
  });

  final List<StudyModule> modules;
  final List<Topic> topics;
  final int? moduleId;
  final int? topicId;

  @override
  State<_AiScopeDialog> createState() => _AiScopeDialogState();
}

class _AiScopeDialogState extends State<_AiScopeDialog> {
  late int? _module = widget.modules.any((m) => m.id == widget.moduleId)
      ? widget.moduleId
      : null;
  late int? _topic = _topics.any((t) => t.id == widget.topicId)
      ? widget.topicId
      : null;
  AiTask _task = AiTask.summary;

  List<Topic> get _topics => [
    for (final t in widget.topics)
      if (_module != null && t.moduleId == _module) t,
  ];

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyLarge;
    final topics = _topics;
    return AlertDialog(
      title: const Text('Revisiona con AI'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<int?>(
                key: const Key('ai-module'),
                style: style,
                initialValue: _module,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Modulo'),
                items: [
                  const DropdownMenuItem<int?>(
                    value: null,
                    child: Text('Tutto l\'insegnamento'),
                  ),
                  for (final m in widget.modules)
                    DropdownMenuItem<int?>(
                      value: m.id,
                      child: Text(m.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() {
                  _module = v;
                  _topic = null;
                }),
              ),
              if (_module != null && topics.isNotEmpty) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<int?>(
                  key: ValueKey('ai-topic-$_module'),
                  style: style,
                  initialValue: _topic,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Argomento'),
                  items: [
                    const DropdownMenuItem<int?>(
                      value: null,
                      child: Text('Tutto il modulo'),
                    ),
                    for (final t in topics)
                      DropdownMenuItem<int?>(
                        value: t.id,
                        child: Text(t.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _topic = v),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<AiTask>(
                key: const Key('ai-task'),
                style: style,
                initialValue: _task,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: 'Che cosa chiedere',
                  helperText: _task.description,
                  helperMaxLines: 3,
                ),
                items: [
                  for (final t in AiTask.values)
                    DropdownMenuItem(value: t, child: Text(t.label)),
                ],
                onChanged: (v) => setState(() => _task = v ?? _task),
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
          onPressed: () => Navigator.pop<_AiChoice>(context, (
            moduleId: _module,
            topicId: _topic,
            task: _task,
          )),
          child: const Text('Continua'),
        ),
      ],
    );
  }
}

/// Data del prossimo esame del corso (per il piano di ripasso), se nota.
Future<DateTime?> _nextExamDate(AppServices s, Course course) async {
  if (course.id == null) return null;
  final today = DateTime.now();
  final dates = [
    for (final e in await s.exams.byCourse(course.id!))
      if (e.date != null &&
          !e.date!.isBefore(DateTime(today.year, today.month, today.day)))
        e.date!,
  ]..sort();
  return dates.isEmpty ? null : dates.first;
}
