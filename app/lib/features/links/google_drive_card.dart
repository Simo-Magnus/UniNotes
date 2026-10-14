import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import 'cloud_drive_card.dart';
import 'onedrive_card.dart' show showOneDriveFolderPicker;

/// Google Drive: le stesse funzioni di OneDrive.
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
          'Collegando Google Drive tutto quello che crei nell\'app finisce in '
          'una cartella del tuo Drive e viceversa.',
      signInLabel: 'Accedi con Google',
      connectedFallback: 'Account Google collegato',
      missingId: gd.available
          ? null
          : 'Google Drive non è ancora disponibile in questa versione '
                'dell\'app.',
      pickFolder: (context, current) =>
          showOneDriveFolderPicker(context, gd.folders(), initialPath: current),
      onChanged: onChanged,
    );
  }
}
