import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/services/loopback_oauth.dart';
import '../../core/theme/app_tokens.dart';
import '../../models/course.dart';
import '../../widgets/common.dart';
import 'drive_picker.dart' show DrivePicker;
import 'google_drive_service.dart';
import 'incoming_files.dart';

/// Chiede dove salvare [count] file: un insegnamento del corso di laurea o
/// «Da ordinare». Due pulsanti: Annulla e Salva.
Future<IncomingDestination?> showIncomingDestinationDialog(
  BuildContext context, {
  required int count,
  String? title,
}) async {
  final s = context.read<AppServices>();
  final scope = s.scope;
  final courses = [
    for (final c in await s.courses.all())
      if (scope.inDegree(c)) c,
  ]..sort(_byStatusThenName);
  if (!context.mounted) return null;
  return showDialog<IncomingDestination>(
    context: context,
    builder: (_) => _DestinationDialog(
      title:
          title ??
          (count == 1 ? 'Dove salvare il file?' : 'Dove salvare i $count file?'),
      courses: courses,
    ),
  );
}

int _byStatusThenName(Course a, Course b) {
  int rank(Course c) => c.status == CourseStatus.active ? 0 : 1;
  final r = rank(a).compareTo(rank(b));
  return r != 0 ? r : a.name.toLowerCase().compareTo(b.name.toLowerCase());
}

class _DestinationDialog extends StatefulWidget {
  const _DestinationDialog({required this.title, required this.courses});
  final String title;
  final List<Course> courses;

  @override
  State<_DestinationDialog> createState() => _DestinationDialogState();
}

class _DestinationDialogState extends State<_DestinationDialog> {
  IncomingDestination _dest = IncomingDestination.unsorted;

  @override
  Widget build(BuildContext context) {
    final options = [
      IncomingDestination.unsorted,
      for (final c in widget.courses) IncomingDestination.course(c),
    ];
    // nomi uguali (stesso insegnamento in due anni): una voce sola
    final unique = <IncomingDestination>[];
    for (final o in options) {
      if (!unique.contains(o)) unique.add(o);
    }
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Finiscono in File → Materiali e, se colleghi Google Drive o '
            'OneDrive, nella cartella UniNotes su tutti i dispositivi.',
            style: TextStyle(fontSize: 13, color: context.tokens.textSecondary),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<IncomingDestination>(
            isExpanded: true,
            initialValue: _dest,
            decoration: const InputDecoration(
              labelText: 'Insegnamento',
            ),
            items: [
              for (final o in unique)
                DropdownMenuItem(
                  value: o,
                  child: Text(o.label, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => setState(() => _dest = v ?? _dest),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _dest),
          child: const Text('Salva'),
        ),
      ],
    );
  }
}

/// Salva [files] dove sceglie lo studente e li manda ai servizi cloud
/// collegati. Restituisce false se ha annullato.
Future<bool> saveIncomingFiles(
  BuildContext context,
  List<IncomingFile> files,
) async {
  if (files.isEmpty) return false;
  final s = context.read<AppServices>();
  final dest = await showIncomingDestinationDialog(
    context,
    count: files.length,
  );
  if (dest == null) {
    await IncomingFiles.discard(files);
    return false;
  }
  final List<String> saved;
  try {
    saved = await IncomingFiles.store(
      files,
      await s.materialsLibrary.directory(),
      dest,
    );
  } catch (e) {
    if (context.mounted) showSnack(context, 'File non salvati: $e');
    return false;
  }
  final msg = await _uploadMessage(s, saved.length, dest);
  if (context.mounted) showSnack(context, msg);
  return true;
}

/// Messaggio dopo il salvataggio e sincronizzazione in background con i
/// servizi collegati (che caricano la cartella Materiali).
Future<String> _uploadMessage(
  AppServices s,
  int count,
  IncomingDestination dest,
) async {
  final what = count == 1 ? '1 file salvato' : '$count file salvati';
  final names = <String>[];
  var scopeOff = false;
  for (final c in s.clouds) {
    if (!await c.connected()) continue;
    names.add(c.serviceName);
    if (!(await c.scopes()).contains(SyncScope.books)) {
      scopeOff = true;
    } else {
      unawaited(c.sync(force: false));
    }
  }
  final where = 'in Materiali/${dest.label}';
  if (names.isEmpty) {
    return '$what $where. Collega Google Drive o OneDrive in Collegamenti '
        'per averli su tutti i dispositivi.';
  }
  if (scopeOff) {
    return '$what $where. Per caricarli su ${names.join(' e ')} attiva '
        '«Libri e materiali» in Collegamenti.';
  }
  return '$what $where: li carico su ${names.join(' e ')}.';
}

/// «Importa da Drive»: Google Picker, poi i file scelti fuori dalla cartella
/// dell'app si copiano nella cartella dell'insegnamento scelto; quelli già
/// dentro UniNotes da ora si sincronizzano. Senza chiave del Picker nella
/// build si usa il selettore di file del sistema (Drive per desktop sul PC,
/// l'app Drive sul telefono) e i file passano dall'app.
Future<void> importFromDrive(BuildContext context, GoogleDriveService gd) async {
  final picker = gd.picker();
  if (!picker.available) {
    // senza chiave API il selettore di Google non si apre: lo si spiega e
    // si propone la scelta dal dispositivo
    final local = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        icon: const Icon(Icons.vpn_key_off_outlined),
        title: const Text('Selettore di Google Drive non disponibile'),
        content: const Text(DrivePicker.missingKeyMessage),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Chiudi'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Scegli dal dispositivo'),
          ),
        ],
      ),
    );
    if (local != true || !context.mounted) return;
    final List<PlatformFile> picked;
    try {
      picked = await FilePicker.pickFiles(
        dialogTitle: 'Scegli i file da importare',
      );
    } catch (e) {
      if (context.mounted) showSnack(context, 'Selezione non riuscita: $e');
      return;
    }
    final files = [
      for (final f in picked)
        if (f.path != null)
          IncomingFile(
            f.path!,
            IncomingFiles.safeFileName(f.name),
            // sul telefono il selettore copia i file nella cache dell'app
            temporary: CloudDriveService.isMobile,
          ),
    ];
    if (files.isNotEmpty && context.mounted) {
      await saveIncomingFiles(context, files);
    }
    return;
  }
  final token = await gd.accessToken();
  if (!context.mounted) return;
  // attesa visibile con «Annulla»: ogni errore (chiave rifiutata, pagina
  // chiusa, nessuna risposta in 5 minuti) ferma l'attesa con il messaggio
  final cancel = Completer<void>();
  final waiting = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => AlertDialog(
      title: const Text('Scegli i file su Google Drive'),
      content: const Row(
        children: [
          SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
          SizedBox(width: 16),
          Expanded(
            child: Text(
              'Il selettore è aperto nel browser: scegli i file, poi torna '
              'qui.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            if (!cancel.isCompleted) cancel.complete();
            Navigator.pop(c);
          },
          child: const Text('Annulla'),
        ),
      ],
    ),
  );
  final PickerResult result;
  try {
    result = await picker.pick(token, cancel: cancel.future);
  } finally {
    if (!cancel.isCompleted) {
      cancel.complete();
      if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    await waiting;
  }
  if (result.error != null) {
    throw OAuthException(DrivePicker.explain(result.error!));
  }
  if (result.cancelled || !context.mounted) return;
  final plan = await gd.planImport(result.ids);
  var copied = 0;
  if (plan.outside.isNotEmpty && context.mounted) {
    final dest = await showIncomingDestinationDialog(
      context,
      count: plan.outside.length,
    );
    if (dest != null) copied = await gd.copyIntoApp(plan.outside, dest);
  }
  final parts = [
    if (copied > 0) copied == 1 ? '1 file copiato' : '$copied file copiati',
    if (plan.inside.isNotEmpty)
      plan.inside.length == 1
          ? '1 file della cartella UniNotes'
          : '${plan.inside.length} file della cartella UniNotes',
    if (plan.skipped.isNotEmpty)
      '${plan.skipped.length} documenti Google saltati (scaricali come PDF '
          'o Office)',
  ];
  if (parts.isEmpty) return;
  if (copied > 0 || plan.inside.isNotEmpty) unawaited(gd.sync());
  if (context.mounted) {
    showSnack(
      context,
      copied > 0 || plan.inside.isNotEmpty
          ? '${parts.join(', ')}: arrivano su tutti i dispositivi.'
          : parts.join(', '),
    );
  }
}

/// Accoglie i file che arrivano da fuori in qualsiasi schermata:
/// «Condividi → UniNotes» (Android), «Apri in UniNotes» (iPhone, iPad) e
/// trascinamento sulla finestra (PC, Mac; spento con [dropEnabled] false,
/// es. nella sezione File che apre il file trascinato). Avvisa anche, una
/// volta, se l'accesso a Google Drive della versione precedente va rifatto.
class IncomingFilesHost extends StatefulWidget {
  const IncomingFilesHost({
    super.key,
    required this.child,
    this.dropEnabled = true,
  });

  final Widget child;
  final bool dropEnabled;

  static bool get desktop =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  State<IncomingFilesHost> createState() => _IncomingFilesHostState();
}

class _IncomingFilesHostState extends State<IncomingFilesHost> {
  late final AppServices _s = context.read<AppServices>();
  final IncomingFiles _incoming = IncomingFiles();
  bool _dragging = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (CloudDriveService.isMobile) {
      _incoming.listen(_check);
      // app aperta proprio da «Condividi» / «Apri in»
      WidgetsBinding.instance.addPostFrameCallback((_) => _check());
    }
    _s.googleDrive.addListener(_onDrive);
  }

  @override
  void dispose() {
    _s.googleDrive.removeListener(_onDrive);
    if (CloudDriveService.isMobile) _incoming.dispose();
    super.dispose();
  }

  void _onDrive() {
    if (!mounted || !_s.googleDrive.takeReconnectAlert()) return;
    showSnack(
      context,
      'Google Drive va ricollegato una volta (Collegamenti → Google Drive): '
      'i tuoi file sono al sicuro.',
    );
  }

  Future<void> _check() async {
    if (_busy || !mounted) return;
    _busy = true;
    try {
      // più condivisioni di fila: si prendono tutte, una alla volta
      while (mounted) {
        final files = await _incoming.take();
        if (files.isEmpty || !mounted) break;
        await saveIncomingFiles(context, files);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _dropped(DropDoneDetails d) async {
    setState(() => _dragging = false);
    final files = IncomingFiles.parse([
      for (final f in d.files) {'path': f.path, 'name': f.name},
    ]).where((f) => FileSystemEntity.isFileSync(f.path)).toList();
    if (files.isEmpty || _busy) return;
    _busy = true;
    try {
      await saveIncomingFiles(context, files);
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!IncomingFilesHost.desktop) return widget.child;
    final t = context.tokens;
    return DropTarget(
      enable: widget.dropEnabled,
      onDragEntered: (_) => setState(() => _dragging = true),
      onDragExited: (_) => setState(() => _dragging = false),
      onDragDone: _dropped,
      child: Stack(
        children: [
          Positioned.fill(child: widget.child),
          if (_dragging && widget.dropEnabled)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: t.cyan.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppScale.radiusCard),
                    border: Border.all(color: t.cyan, width: 2),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'Rilascia i file per salvarli in UniNotes',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: t.textPrimary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
