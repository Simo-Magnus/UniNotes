import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/install_check.dart';
import '../../core/services/local_data.dart';
import '../../core/theme/app_theme.dart';
import '../settings/erase_all.dart';

/// Domande del primo avvio dopo una reinstallazione (vedi [InstallCheck]),
/// due pulsanti per dialogo; senza risposta (Esc) la domanda si ripete.
///
/// - Dati rimasti nelle cartelle dell'app: «Usa» li tiene, «Elimina» chiama
///   [eraseLeftover] (la stessa pulizia di «Elimina tutti i dati») e poi
///   [recheck] (che può trovare ancora appunti in Documenti).
/// - Appunti in una cartella condivisa (PC): «Usa» li rilegge, «Ignora» li
///   mette da parte con [setAside] (`Corsi (installazione precedente)`):
///   restano all'utente e l'app parte vuota.
Future<void> askInstallQuestions(
  BuildContext context,
  InstallStatus status, {
  required Future<void> Function() eraseLeftover,
  required Future<InstallStatus> Function() recheck,
  Future<List<Directory>> Function(List<Directory> dirs) setAside =
      LocalData.setAside,
  Future<void> Function(String key) answered = InstallCheck.answered,
}) async {
  var st = status;
  if (st.leftover) {
    final use = await _askUntilAnswered(
      context,
      body:
          'Ho trovato dati di una installazione precedente: li usi o li '
          'elimini?\n\n'
          'Se li usi ritrovi percorso, esami, appunti e impostazioni come '
          'prima. Se li elimini l\'app riparte da zero (i dati nel cloud e '
          'nel calendario non si toccano).',
      no: 'Elimina',
      yes: 'Usa',
    );
    if (use == null) return;
    if (!use) {
      await eraseLeftover();
      st = await recheck();
    }
    await answered(InstallCheck.pendingLeftoverKey);
  }
  if (st.sharedNotes.isEmpty || !context.mounted) return;
  final paths = st.sharedNotes.map((d) => d.path).join('\n');
  final use = await _askUntilAnswered(
    context,
    body:
        'Ho trovato dati di una installazione precedente: li usi o li '
        'ignori?\n\n$paths\n\n'
        'Se li usi, appunti e registrazioni ricompaiono nei corsi con lo '
        'stesso nome. Se li ignori l\'app parte da zero e la cartella resta '
        'sul PC con il nome «Corsi${LocalData.ignoredSuffix}».',
    no: 'Ignora',
    yes: 'Usa',
  );
  if (use == null) return;
  if (!use && (await setAside(st.sharedNotes)).isNotEmpty) {
    if (!context.mounted) return;
    await showAppDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: const Text('Cartella in uso'),
        content: const Text(
          'La cartella è aperta in un altro programma e non si è potuta '
          'mettere da parte. Chiudilo: la domanda torna al prossimo avvio.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return;
  }
  await answered(InstallCheck.pendingSharedKey);
}

Future<bool?> _askUntilAnswered(
  BuildContext context, {
  required String body,
  required String no,
  required String yes,
}) async {
  bool? answer;
  while (answer == null && context.mounted) {
    answer = await askTwoChoices(
      context,
      title: 'Dati di un\'installazione precedente',
      body: body,
      no: no,
      yes: yes,
    );
  }
  return answer;
}

/// Mostra le domande prima di avviare l'app vera (il database non è ancora
/// aperto): una piccola app con il solo dialogo, poi si torna a main().
Future<void> runInstallQuestions(
  InstallStatus status, {
  required Future<void> Function() eraseLeftover,
  required Future<InstallStatus> Function() recheck,
}) async {
  if (!status.needsAnswer) return;
  final done = Completer<void>();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: _QuestionsHost(
        run: (context) => askInstallQuestions(
          context,
          status,
          eraseLeftover: eraseLeftover,
          recheck: recheck,
        ),
        done: done,
      ),
    ),
  );
  await done.future;
}

class _QuestionsHost extends StatefulWidget {
  const _QuestionsHost({required this.run, required this.done});
  final Future<void> Function(BuildContext context) run;
  final Completer<void> done;

  @override
  State<_QuestionsHost> createState() => _QuestionsHostState();
}

class _QuestionsHostState extends State<_QuestionsHost> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await widget.run(context);
      } catch (e) {
        debugPrint('Domande sull\'installazione precedente: $e');
      }
      if (!widget.done.isCompleted) widget.done.complete();
    });
  }

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}
