import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../widgets/common.dart';
import '../cloud/microsoft_admin_consent.dart';
import '../cloud/onedrive_folders.dart';
import '../study/study_widgets.dart' show promptText;
import 'cloud_drive_card.dart';
import 'microsoft_consent_sheet.dart';

/// OneDrive: accesso, cartella dell'app, cosa sincronizzare e stato.
class OneDriveCard extends StatelessWidget {
  const OneDriveCard({super.key, this.primary = false, this.onChanged});
  final bool primary;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final od = context.read<AppServices>().onedrive;
    return CloudDriveCard(
      service: od,
      icon: Icons.cloud_outlined,
      subtitle:
          'Collegando OneDrive tutto quello che crei nell\'app finisce in '
          'una cartella del tuo OneDrive e viceversa.',
      signInLabel: 'Accedi con Microsoft',
      connectedFallback: 'Account Microsoft collegato',
      missingId: od.hasBuiltInClientId
          ? null
          : 'Questa versione dell\'app non include l\'ID applicazione '
                'Microsoft (vedi docs/onedrive_setup.md).',
      pickFolder: (context, current) =>
          showOneDriveFolderPicker(context, od.folders(), initialPath: current),
      // account universitario bloccato dall'ateneo (consenso
      // dell'amministratore): scheda dedicata, ricordata per le volte dopo
      signInHelp: SignInHelp(
        label: kUniversityAccountHelp,
        matches: MicrosoftAdminConsent.isAdminConsentError,
        show: (context, {error, required connected}) async {
          if (error != null) await od.setAdminConsentNeeded(true);
          final id = await od.clientId();
          if (!context.mounted) return false;
          return showUniversityBlockedSheet(
            context,
            clientId: id,
            declined: MicrosoftAdminConsent.isDeclined(error),
            allowPersonal: !connected,
          );
        },
        retry: od.signInPersonal,
        remembered: od.adminConsentNeeded,
      ),
      primary: primary,
      onChanged: onChanged,
    );
  }
}

/// Selettore della cartella (OneDrive, Google Drive): naviga, crea cartelle
/// e scegli quella in cui l'app salva tutto. Restituisce il percorso (vuoto
/// = radice).
Future<String?> showOneDriveFolderPicker(
  BuildContext context,
  FolderBrowser browser, {
  String initialPath = '',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      OneDriveFolderDialog(browser: browser, initialPath: initialPath),
);

class OneDriveFolderDialog extends StatefulWidget {
  const OneDriveFolderDialog({
    super.key,
    required this.browser,
    this.initialPath = '',
  });
  final FolderBrowser browser;
  final String initialPath;

  @override
  State<OneDriveFolderDialog> createState() => _OneDriveFolderDialogState();
}

class _OneDriveFolderDialogState extends State<OneDriveFolderDialog> {
  late final List<DriveFolder> _stack = [widget.browser.root];
  late Future<List<DriveFolder>> _children = _list();

  DriveFolder get _current => _stack.last;

  Future<List<DriveFolder>> _list() => widget.browser.children(_current);

  void _open(DriveFolder f) => setState(() {
    _stack.add(f);
    _children = _list();
  });

  void _up() => setState(() {
    if (_stack.length > 1) _stack.removeLast();
    _children = _list();
  });

  Future<void> _create() async {
    final name = await promptText(
      context,
      title: 'Nuova cartella',
      label: 'Nome',
      initial: 'UniNotes',
    );
    if (name == null) return;
    final err = widget.browser.validate(name);
    if (err != null) {
      if (mounted) showSnack(context, err);
      return;
    }
    try {
      final f = await widget.browser.createFolder(_current, name);
      _open(f);
    } catch (e) {
      if (mounted) showSnack(context, '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Cartella su ${widget.browser.serviceName}'),
      content: SizedBox(
        width: 520,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Su',
                  onPressed: _stack.length > 1 ? _up : null,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: Text(
                    _current.isRoot
                        ? widget.browser.serviceName
                        : '${widget.browser.serviceName}/${_current.path}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton.icon(
                  onPressed: _create,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                  label: const Text('Nuova'),
                ),
              ],
            ),
            if (widget.initialPath.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  'Attuale: /${widget.initialPath}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<List<DriveFolder>>(
                future: _children,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return Center(child: Text('Errore: ${snap.error}'));
                  }
                  final list = snap.data;
                  if (list == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (list.isEmpty) {
                    return const Center(child: Text('Nessuna sottocartella.'));
                  }
                  return ListView(
                    children: [
                      for (final f in list)
                        ListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(f.name),
                          subtitle: f.childCount == null
                              ? null
                              : Text('${f.childCount} elementi'),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _open(f),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Annulla'),
        ),
        FilledButton(
          onPressed: _current.isRoot
              ? null
              : () => Navigator.pop(context, _current.path),
          child: const Text('Usa questa cartella'),
        ),
      ],
    );
  }
}
