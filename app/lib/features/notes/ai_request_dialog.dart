import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../../core/services/external_launcher.dart';
import '../../core/services/msix_paths.dart';
import '../../widgets/common.dart';
import '../../widgets/copyable_text.dart';
import '../../widgets/glass.dart';
import '../../widgets/share_files.dart';
import '../links/ai_assistants.dart';

bool get _mobile => Platform.isAndroid || Platform.isIOS;

/// Copia [files] negli appunti di sistema come file (non come testo), per
/// incollarli con Ctrl+V / ⌘V nella chat dell'AI. Windows (PowerShell),
/// macOS (NSPasteboard via osascript) e Linux (xclip, se installato).
/// false se la piattaforma non lo permette.
Future<bool> copyFilesToClipboard(List<File> files) async {
  if (files.isEmpty) return false;
  try {
    if (Platform.isWindows) {
      // I percorsi passano in una variabile d'ambiente, mai dentro il testo
      // del comando: nomi con apostrofi (’ ‘) non possono rompere il comando
      // né aggiungerne altri.
      final r = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          r'Set-Clipboard -LiteralPath ($env:UN_FILES -split [char]10)',
        ],
        // Microsoft Store: percorsi veri, visibili al browser (MsixPaths)
        environment: {
          'UN_FILES': files
              .map((f) => MsixPaths.forOtherApps(f.path))
              .join('\n'),
        },
      );
      return r.exitCode == 0;
    }
    if (Platform.isMacOS) {
      // elenco in JSON: un letterale JavaScript sempre valido
      final arr = jsonEncode([for (final f in files) f.path]);
      final script =
          "ObjC.import('AppKit');"
          'var pb = \$.NSPasteboard.generalPasteboard; pb.clearContents;'
          'var a = \$.NSMutableArray.alloc.init;'
          '$arr.forEach(function (x) { a.addObject(\$.NSURL.fileURLWithPath(x)); });'
          'pb.writeObjects(a);';
      final r = await Process.run('osascript', [
        '-l',
        'JavaScript',
        '-e',
        script,
      ]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) {
      final uris = files.map((f) => Uri.file(f.path).toString()).join('\n');
      final proc = await Process.start('xclip', [
        '-selection',
        'clipboard',
        '-t',
        'text/uri-list',
      ]);
      proc.stdin.write(uris);
      await proc.stdin.close();
      return await proc.exitCode == 0;
    }
  } on Exception {
    return false;
  }
  return false;
}

/// Mostra [path] selezionato nella cartella (Esplora file / Finder).
Future<void> revealInFolder(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', ['/select,', MsixPaths.forOtherApps(path)]);
      return;
    }
    if (Platform.isMacOS) {
      await Process.run('open', ['-R', path]);
      return;
    }
  } on Exception {
    // si apre la cartella sotto
  }
  final r = await ExternalLauncher.openPath(p.dirname(path));
  if (context.mounted) showLaunchResult(context, r);
}

/// Apre la chat dell'AI di riferimento: l'app sul telefono (o il sito se non
/// è installata), il sito sul PC.
Future<void> openReferenceAi(BuildContext context, ReferenceAi ai) async {
  var ok = false;
  if (_mobile) {
    try {
      ok = await launchUrl(
        ai.webUri,
        mode: LaunchMode.externalNonBrowserApplication,
      );
    } catch (_) {
      ok = false;
    }
  }
  if (!ok) {
    final r = await ExternalLauncher.openUrl(ai.web);
    if (context.mounted) showLaunchResult(context, r);
  }
}

/// Riquadro unico per lavorare con l'AI di riferimento: istruzioni, sezione
/// «Prompt» (da copiare) e sezione «File da allegare» (nome, percorso, tasto
/// Condividi e tasto che apre la cartella del file, da cui copiarlo e
/// incollarlo nella chat). Due soli pulsanti: Chiudi e «Apri» con il nome dell'AI.
///
/// Niente «Incolla risposta»: con [onCapture] (trascrizione e riassunto di
/// una lezione) la risposta copiata dall'app AI si salva da sola quando si
/// torna in UniNotes con il dialogo aperto: si legge il testo copiato e, se
/// è una risposta (non il prompt, almeno [minCapture] caratteri), si passa a
/// [onCapture] e il dialogo si chiude.
Future<void> showAiRequestDialog(
  BuildContext context, {
  required String title,
  required ReferenceAi ai,
  required String prompt,
  List<File> files = const [],
  String? intro,
  List<String> steps = const [],
  Future<void> Function(String text)? onCapture,
}) {
  return showDialog<void>(
    context: context,
    builder: (c) => _AiRequestDialog(
      title: title,
      ai: ai,
      prompt: prompt,
      files: files,
      intro: intro,
      steps: steps,
      onCapture: onCapture,
    ),
  );
}

/// Lunghezza minima di un testo copiato per considerarlo la risposta.
const minCapture = 200;

/// Il testo copiato [clip] è la risposta dell'AI da salvare: abbastanza
/// lungo e diverso dal prompt e da quanto c'era già negli appunti quando si
/// è aperta l'AI.
bool isCapturedResponse(
  String? clip, {
  required String prompt,
  String? before,
}) {
  final t = clip?.trim() ?? '';
  if (t.length < minCapture) return false;
  if (t == prompt.trim()) return false;
  if (before != null && t == before.trim()) return false;
  return true;
}

class _AiRequestDialog extends StatefulWidget {
  const _AiRequestDialog({
    required this.title,
    required this.ai,
    required this.prompt,
    required this.files,
    required this.intro,
    required this.steps,
    required this.onCapture,
  });

  final String title;
  final ReferenceAi ai;
  final String prompt;
  final List<File> files;
  final String? intro;
  final List<String> steps;
  final Future<void> Function(String text)? onCapture;

  @override
  State<_AiRequestDialog> createState() => _AiRequestDialogState();
}

class _AiRequestDialogState extends State<_AiRequestDialog> {
  AppLifecycleListener? _lifecycle;
  Timer? _poll;

  /// L'AI è stata aperta: al ritorno si cerca la risposta copiata.
  bool _waiting = false;
  String? _clipAtOpen;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    if (widget.onCapture != null) {
      _lifecycle = AppLifecycleListener(
        onResume: () => unawaited(_checkClipboard()),
      );
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _openAi() async {
    if (widget.onCapture != null) {
      try {
        _clipAtOpen = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
      } catch (_) {}
    }
    await Clipboard.setData(ClipboardData(text: widget.prompt));
    if (!mounted) return;
    await openReferenceAi(context, widget.ai);
    if (widget.onCapture == null || !mounted) return;
    setState(() => _waiting = true);
    // Sul PC il browser è un'altra finestra: il ritorno non sempre arriva
    // come «ripresa» dell'app, si controlla anche ogni 2 secondi (leggere
    // gli appunti sul PC non chiede conferme).
    if (!_mobile) {
      _poll?.cancel();
      _poll = Timer.periodic(
        const Duration(seconds: 2),
        (_) => unawaited(_checkClipboard()),
      );
    }
  }

  Future<void> _checkClipboard() async {
    final capture = widget.onCapture;
    if (!_waiting || _capturing || capture == null || !mounted) return;
    String? clip;
    try {
      clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
    } catch (_) {
      return;
    }
    if (!isCapturedResponse(clip, prompt: widget.prompt, before: _clipAtOpen)) {
      return;
    }
    // riquadro già in chiusura («Chiudi», Indietro: resta sullo schermo per
    // l'animazione): niente salvataggio e soprattutto niente seconda
    // chiusura, che toglierebbe la pagina sotto
    if (!mounted || !(ModalRoute.isCurrentOf(context) ?? false)) return;
    _capturing = true;
    _poll?.cancel();
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    try {
      await capture(clip!.trim());
    } catch (e) {
      // file non scrivibile: la risposta resta negli appunti del sistema,
      // lo si dice (il riquadro è già chiuso)
      messenger?.showSnackBar(
        SnackBar(
          content: Text(
            'Risposta non salvata: $e. È ancora negli appunti: incollala in '
            'una nota.',
          ),
        ),
      );
    }
  }

  static String _size(File f) {
    try {
      final b = f.lengthSync();
      final mb = b / (1024 * 1024);
      return mb >= 1
          ? '${mb.toStringAsFixed(1)} MB'
          : '${(b / 1024).ceil()} KB';
    } on FileSystemException {
      return '';
    }
  }

  /// Tasto della cartella: sul PC apre la cartella con il file selezionato
  /// (da copiare e incollare nella chat); sul telefono copia il percorso.
  Future<void> _reveal(File f) async {
    if (!_mobile) {
      await revealInFolder(context, f.path);
      return;
    }
    await Clipboard.setData(ClipboardData(text: f.path));
    if (mounted) showSnack(context, 'Percorso copiato: ${f.path}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget heading(String t) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Text(t, style: theme.textTheme.titleSmall),
    );
    final files = widget.files;
    return AlertDialog(
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 16, 0),
      title: Text(widget.title),
      content: SizedBox(
        width: 600,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.intro != null) Text(widget.intro!),
              for (final s in widget.steps)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(s),
                ),
              if (_waiting)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'In attesa della risposta: copiala in '
                          '${widget.ai.label} e torna qui.',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              heading('Prompt'),
              CopyableBlock(widget.prompt, maxHeight: 220),
              if (files.isNotEmpty) ...[
                heading('File da allegare'),
                GlassCard(
                  inner: true,
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final f in files)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              Icons.insert_drive_file_outlined,
                              color: theme.colorScheme.primary,
                            ),
                            title: Text(p.basename(f.path)),
                            subtitle: SelectableText(
                              '${f.parent.path}${_size(f).isEmpty ? '' : ' · ${_size(f)}'}',
                              style: theme.textTheme.bodySmall,
                            ),
                            trailing: Wrap(
                              children: [
                                Builder(
                                  builder: (c) => IconButton(
                                    tooltip: 'Condividi il file',
                                    icon: const Icon(Icons.ios_share),
                                    onPressed: () => shareFiles(c, [f]),
                                  ),
                                ),
                                IconButton(
                                  tooltip: _mobile
                                      ? 'Copia il percorso del file'
                                      : 'Apri la cartella del file',
                                  icon: const Icon(Icons.folder_open_outlined),
                                  onPressed: () => _reveal(f),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (files.length > 1)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Builder(
                      builder: (c) => TextButton.icon(
                        onPressed: () => shareFiles(c, files),
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Condividi tutti i file'),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Chiudi'),
        ),
        FilledButton.icon(
          onPressed: _openAi,
          icon: const Icon(Icons.open_in_new, size: 18),
          label: Text('Apri ${widget.ai.label}'),
        ),
      ],
    );
  }
}
