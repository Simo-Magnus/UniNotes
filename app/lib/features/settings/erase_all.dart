import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/build_flags.dart';
import '../../core/services/app_services.dart';
import '../../core/services/app_uninstall.dart';
import 'logic/data_eraser.dart';

/// Da dove parte l'eliminazione dei dati.
enum EraseFlowMode {
  /// Impostazioni → «Elimina tutti i dati»: l'app resta installata.
  eraseOnly,

  /// Impostazioni → «Disinstalla UniNotes»: dopo la pulizia si avvia la
  /// disinstallazione dove il sistema lo permette (Microsoft Store: si apre
  /// «App installate» di Windows).
  uninstall,

  /// Windows, disinstallazione avviata da «App installate»: il
  /// disinstallatore lancia `uninotes.exe --disinstalla` e, alla chiusura
  /// dell'app, toglie i file del programma.
  windowsUninstaller,
}

/// Impostazioni → «Elimina tutti i dati».
Future<void> eraseAllData(BuildContext context) => runEraseFlow(
  context,
  mode: EraseFlowMode.eraseOnly,
  eraser: DataEraser(context.read<AppServices>()),
);

/// Impostazioni → «Disinstalla UniNotes».
Future<void> uninstallApp(BuildContext context) => runEraseFlow(
  context,
  mode: EraseFlowMode.uninstall,
  eraser: DataEraser(context.read<AppServices>()),
);

void _exitApp() => exit(0);

/// Il flusso unico di eliminazione e disinstallazione (due pulsanti per
/// dialogo):
/// 1. «Elimina tutto» oppure «Scegli cosa eliminare» (elenco con spunte e
///    dimensioni);
/// 2. conferma con il riepilogo;
/// 3. eliminazione ([DataEraser]);
/// 4. con una scelta parziale, domanda se disinstallare comunque o tenere
///    l'app;
/// 5. disinstallazione ([AppUninstall]) o chiusura dell'app.
///
/// Nella build del Microsoft Store ([windowsStore], predefinito: Windows con
/// `STORE=microsoft`) non c'è un disinstallatore da avviare: dopo la pulizia
/// si apre «App installate» di Windows ([AppUninstall.windowsStore]).
Future<void> runEraseFlow(
  BuildContext context, {
  required EraseFlowMode mode,
  required DataEraser eraser,
  Future<UninstallResult> Function() uninstall = AppUninstall.uninstall,
  VoidCallback quit = _exitApp,
  bool? windowsStore,
}) async {
  final store = windowsStore ?? (Platform.isWindows && kMicrosoftStoreBuild);
  final windows = mode == EraseFlowMode.windowsUninstaller;
  final options = await eraser.options();
  if (!context.mounted) return;
  final available = {
    for (final o in options)
      if (o.available) o.item,
  };
  final action = mode == EraseFlowMode.uninstall
      ? 'Elimina e disinstalla'
      : 'Elimina';
  final all = await askTwoChoices(
    context,
    title: mode == EraseFlowMode.eraseOnly
        ? 'Eliminare i dati?'
        : 'Disinstalla UniNotes',
    body: switch (mode) {
      EraseFlowMode.eraseOnly =>
        'Puoi eliminare tutti i dati dell\'app (anche quelli collegati nel '
            'cloud e nel calendario) oppure scegliere cosa eliminare.',
      EraseFlowMode.uninstall =>
        'Prima di disinstallare puoi eliminare tutti i dati dell\'app, '
            'anche quelli collegati nel cloud e nel calendario, così '
            'reinstallandola non ritrovi nulla. Oppure scegli cosa '
            'eliminare.',
      EraseFlowMode.windowsUninstaller =>
        'Il programma si sta disinstallando. Scegli quali dati eliminare: '
            'chiudendo questa finestra restano tutti sul PC.',
    },
    no: 'Scegli cosa eliminare',
    yes: 'Elimina tutto',
    danger: true,
  );
  if (all == null || !context.mounted) {
    if (windows) quit();
    return;
  }
  final items = all
      ? available
      : await showDialog<Set<EraseItem>>(
          context: context,
          builder: (_) => EraseChecklist(options: options, action: action),
        );
  if (items == null || items.isEmpty || !context.mounted) {
    if (windows) quit();
    return;
  }
  final everything = items.containsAll(available);
  final ok = await askTwoChoices(
    context,
    title: 'Confermi?',
    body: [
      'Si eliminano:',
      for (final o in options)
        if (items.contains(o.item))
          '• ${o.item.label}'
              '${o.bytes != null && o.bytes! > 0 ? ' (${formatBytes(o.bytes!)})' : ''}',
      if (mode == EraseFlowMode.uninstall && everything)
        store
            ? '\nPoi si apre «App installate» di Windows per togliere '
                  'UniNotes.'
            : '\nPoi UniNotes si disinstalla.',
      if (mode != EraseFlowMode.eraseOnly && !everything && !windows)
        '\nAlla fine potrai scegliere se disinstallare l\'app o tenerla.',
      '\nNon si può annullare.',
    ].join('\n'),
    no: 'Annulla',
    yes: action,
    danger: true,
  );
  if (ok != true || !context.mounted) {
    if (windows) quit();
    return;
  }
  final report = await runEraseWithProgress(context, eraser, items);
  if (!context.mounted) return;
  final problems = eraseProblems(report);

  if (windows) {
    if (problems.isNotEmpty) {
      await _info(context, 'Disinstallazione', problems.join('\n\n'));
    }
    quit();
    return;
  }
  var doUninstall = mode == EraseFlowMode.uninstall;
  if (doUninstall && !everything) {
    doUninstall =
        await askTwoChoices(
          context,
          title: 'Disinstallare UniNotes?',
          body:
              'Hai eliminato solo alcuni dati. Vuoi disinstallare comunque '
              'l\'app o tenerla?',
          no: 'Tieni l\'app',
          yes: 'Disinstalla',
        ) ==
        true;
    if (!context.mounted) return;
  }
  if (doUninstall) {
    final r = await uninstall();
    if (r.started) {
      quit();
      return;
    }
    if (!context.mounted) return;
    await _finalDialog(context, 'Dati eliminati', [
      ...problems,
      ?r.message,
    ], quit);
    return;
  }
  await _finalDialog(context, 'Dati eliminati', [
    ...problems,
    Platform.isIOS
        ? 'Chiudi l\'app e riaprila per ricominciare.'
        : 'L\'app ora si chiude: riaprila per ricominciare.',
  ], quit);
}

/// Ultimo messaggio: dopo l'eliminazione il database è chiuso e l'app va
/// chiusa (su iPhone e iPad la chiude l'utente).
Future<void> _finalDialog(
  BuildContext context,
  String title,
  List<String> lines,
  VoidCallback quit,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (c) => PopScope(
    canPop: false,
    child: AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(lines.join('\n\n'))),
      actions: [
        if (!Platform.isIOS)
          FilledButton(onPressed: quit, child: const Text('Chiudi')),
      ],
    ),
  ),
);

Future<void> _info(BuildContext context, String title, String text) =>
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(text)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('OK'),
          ),
        ],
      ),
    );

/// «Scegli cosa eliminare»: elenco con spunte e dimensioni; le voci senza
/// niente da eliminare sono spente con il motivo. Restituisce le voci
/// scelte (null = Annulla).
class EraseChecklist extends StatefulWidget {
  const EraseChecklist({
    super.key,
    required this.options,
    required this.action,
  });
  final List<EraseOption> options;

  /// Testo del pulsante di conferma.
  final String action;

  @override
  State<EraseChecklist> createState() => _EraseChecklistState();
}

class _EraseChecklistState extends State<EraseChecklist> {
  final Set<EraseItem> _chosen = {};

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Scegli cosa eliminare'),
      contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final o in widget.options)
                CheckboxListTile(
                  key: ValueKey('erase-${o.item.name}'),
                  value: o.available && _chosen.contains(o.item),
                  onChanged: o.available
                      ? (v) => setState(
                          () => v == true
                              ? _chosen.add(o.item)
                              : _chosen.remove(o.item),
                        )
                      : null,
                  title: Text(o.item.label),
                  subtitle: _subtitle(o),
                  controlAffinity: ListTileControlAffinity.leading,
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
          style: FilledButton.styleFrom(
            backgroundColor: scheme.error,
            foregroundColor: scheme.onError,
          ),
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, Set.of(_chosen)),
          child: Text(widget.action),
        ),
      ],
    );
  }

  Widget? _subtitle(EraseOption o) {
    final parts = [if (o.bytes != null) formatBytes(o.bytes!), ?o.detail];
    return parts.isEmpty ? null : Text(parts.join(' · '));
  }
}

/// Dimensione leggibile («0 KB», «12 KB», «3,4 MB», «1,2 GB»).
String formatBytes(int bytes) {
  String one(double v) => v.toStringAsFixed(1).replaceAll('.', ',');
  if (bytes < 1024 * 1024) return '${(bytes / 1024).ceil()} KB';
  final mb = bytes / (1024 * 1024);
  if (mb < 1024) return '${one(mb)} MB';
  return '${one(mb / 1024)} GB';
}

/// Dialogo con due soli pulsanti: true = [yes], false = [no], null = chiuso
/// senza scegliere (tasto Indietro, Esc).
Future<bool?> askTwoChoices(
  BuildContext context, {
  required String title,
  required String body,
  required String no,
  required String yes,
  bool danger = false,
}) => showDialog<bool>(
  context: context,
  builder: (c) {
    final scheme = Theme.of(c).colorScheme;
    return AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: Text(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: Text(no)),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                )
              : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(yes),
        ),
      ],
    );
  },
);

/// Esegue l'eliminazione con un dialogo di avanzamento che non si chiude.
Future<EraseReport> runEraseWithProgress(
  BuildContext context,
  DataEraser eraser,
  Set<EraseItem> items,
) async {
  final step = ValueNotifier('Elimino i dati…');
  final nav = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            const SizedBox.square(
              dimension: 28,
              child: CircularProgressIndicator(),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: step,
                builder: (_, v, _) => Text(v),
              ),
            ),
          ],
        ),
      ),
    ),
  );
  try {
    return await eraser.run(items, onStep: (v) => step.value = v);
  } finally {
    if (nav.mounted) nav.pop();
  }
}

/// Righe per le parti non riuscite (cloud, calendario).
List<String> eraseProblems(EraseReport r) => [
  if (r.problems.isNotEmpty)
    'Non tutto si è potuto eliminare:\n'
        '${r.problems.map((p) => '• $p').join('\n')}\n'
        'Puoi toglierlo a mano dal sito del servizio o dal calendario.',
];
