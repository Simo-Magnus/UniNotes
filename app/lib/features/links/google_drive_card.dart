import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../cloud/google_drive_service.dart';
import '../cloud/google_oauth.dart' show GoogleOAuth;
import '../cloud/incoming_files_host.dart' show importFromDrive;
import 'cloud_drive_card.dart';
import 'links_widgets.dart';
import 'onedrive_card.dart' show showOneDriveFolderPicker;

/// Google Drive: le stesse funzioni di OneDrive, con l'accesso ai soli file
/// dell'app (`drive.file`) e «Importa da Drive» per quelli caricati a mano.
class GoogleDriveCard extends StatelessWidget {
  const GoogleDriveCard({super.key, this.onChanged});
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) {
    final gd = context.read<AppServices>().googleDrive;
    return CloudDriveCard(
      service: gd,
      icon: Icons.add_to_drive_outlined,
      subtitle:
          'Collegando Google Drive tutto quello che crei o salvi nell\'app '
          'finisce nella cartella UniNotes del tuo Drive e arriva sugli altri '
          'dispositivi.',
      signInLabel: 'Accedi con Google',
      connectedFallback: 'Account Google collegato',
      missingId: gd.available
          ? null
          : 'Google Drive non è ancora disponibile in questa versione '
                'dell\'app.',
      pickFolder: (context, current) =>
          showOneDriveFolderPicker(context, gd.folders(), initialPath: current),
      note:
          'L\'app vede solo i file che salva lei e quelli che importi: un file '
          'caricato dal sito o dall\'app di Drive arriva con «Importa da '
          'Drive», con «Condividi → UniNotes» sul telefono o trascinandolo '
          'sulla finestra sul computer.',
      extra: (context, connected) =>
          _DriveExtras(service: gd, connected: connected),
      // alla disconnessione l'accesso si revoca presso Google; se non
      // riesce, la pagina dell'account dove toglierlo
      revokeHelpUrl: GoogleOAuth.permissionsPage,
      onChanged: onChanged,
    );
  }
}

/// Avviso una tantum (cartella nuova, accesso da rifare) e «Importa da
/// Drive».
class _DriveExtras extends StatefulWidget {
  const _DriveExtras({required this.service, required this.connected});
  final GoogleDriveService service;
  final bool connected;

  @override
  State<_DriveExtras> createState() => _DriveExtrasState();
}

class _DriveExtrasState extends State<_DriveExtras> {
  late Future<DriveNotice?> _notice = widget.service.notice();

  @override
  void didUpdateWidget(covariant _DriveExtras old) {
    super.didUpdateWidget(old);
    _notice = widget.service.notice();
  }

  static String _text(DriveNotice n) => switch (n) {
    DriveNotice.newFolder =>
      'Ho creato la cartella UniNotes nel tuo Drive. Se ne avevi una creata '
          'da una versione precedente dell\'app, i suoi file restano lì: '
          'recuperali con «Importa da Drive». Quelli che hai anche su questo '
          'dispositivo si ricaricano da soli.',
    DriveNotice.reconnect =>
      'Questa versione accede a Google Drive in un modo nuovo, più limitato: '
          'ricollega l\'account una volta con «Accedi con Google». I tuoi file '
          'restano su Drive e sul dispositivo.',
  };

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<DriveNotice?>(
      future: _notice,
      builder: (context, snap) {
        final n = snap.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (n != null) ...[
              const SizedBox(height: 8),
              NoteText(_text(n), icon: Icons.info_outline),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () async {
                    await widget.service.dismissNotice();
                    if (mounted) {
                      setState(() {
                        _notice = widget.service.notice();
                      });
                    }
                  },
                  child: const Text('Ho capito'),
                ),
              ),
            ],
            if (widget.connected) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: LinkButton(
                  label: 'Importa da Drive',
                  icon: Icons.drive_folder_upload_outlined,
                  errorTitle: 'Importazione non riuscita',
                  onPressed: () => importFromDrive(context, widget.service),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}
