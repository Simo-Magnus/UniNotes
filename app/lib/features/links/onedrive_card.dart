import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/app_services.dart';
import '../cloud/microsoft_admin_consent.dart';
import '../cloud/onedrive_folders.dart';
import 'cloud_drive_card.dart';
import 'microsoft_consent_sheet.dart';

/// Nel dialogo di «Scollega»: dove togliere l'accesso di UniNotes
/// dall'account Microsoft.
const kOneDriveRevokeNote =
    'L\'accesso di UniNotes al tuo account Microsoft resta finché non lo '
    'togli tu: per un account personale su '
    'https://account.live.com/consent/Manage, per un account universitario '
    'su https://myapps.microsoft.com.';

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
      // Microsoft non permette a un'app pubblica di revocare il proprio
      // accesso: si toglie dall'account
      signOutNote: kOneDriveRevokeNote,
      primary: primary,
      onChanged: onChanged,
    );
  }
}

/// Selettore della cartella (OneDrive, Google Drive): naviga e scegli
/// quella in cui l'app salva tutto (niente cartelle nuove da qui: per
/// cambiare il nome di quella dell'app c'è «Rinomina» nella scheda).
/// Restituisce il percorso (vuoto = radice).
Future<String?> showOneDriveFolderPicker(
  BuildContext context,
  FolderBrowser browser, {
  String initialPath = '',
}) => showAppDialog<String>(
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

  Future<List<DriveFolder>> _list() {
    final f = widget.browser.children(_current);
    // l'errore lo mostra il FutureBuilder; un doppio tocco su una cartella (o
    // su «Su») sostituisce il futuro prima che il FutureBuilder lo ascolti e,
    // senza rete, l'errore del primo restava senza ascoltatori (eccezione non
    // gestita)
    unawaited(f.then<void>((_) {}, onError: (Object _) {}));
    return f;
  }

  void _open(DriveFolder f) => setState(() {
    _stack.add(f);
    _children = _list();
  });

  void _up() => setState(() {
    if (_stack.length > 1) _stack.removeLast();
    _children = _list();
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // scorre con la finestra bassa (320 px) o i caratteri grandi; l'elenco
      // delle cartelle è alto al massimo metà schermo
      scrollable: true,
      title: Text('Cartella su ${widget.browser.serviceName}'),
      content: SizedBox(
        width: 520,
        height: math.min(420, MediaQuery.sizeOf(context).height * 0.5),
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
