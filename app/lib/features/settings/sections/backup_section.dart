import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/services/app_services.dart';
import '../../../core/services/backup_service.dart';
import '../../../widgets/common.dart';
import '../logic/file_transfer.dart';
import '../logic/formatting.dart';
import '../widgets/async_action_button.dart';
import '../widgets/settings_card.dart';

const _maxBackupBytes = 200 * 1024 * 1024;

BackupService _backupService(BuildContext context) =>
    BackupService(context.read<AppServices>().database);

/// Ripristina un backup (JSON) dopo aver mostrato data e numero di elementi.
Future<void> restoreBackupJson(BuildContext context, String json) async {
  final service = _backupService(context);
  final info = service.inspect(json);
  final created = info.createdAt == null
      ? 'data sconosciuta'
      : formatIsoDateTime(info.createdAt!.toIso8601String());
  final ok = await confirmDialog(
    context,
    'Ripristinare i dati?',
    'File del $created (${info.totalRows} elementi).\n\n'
        'Tutti i dati personali attuali (corsi, eventi, esami e voti, studio, '
        'libri, materiali, note, preferiti, impostazioni) verranno SOSTITUITI '
        'da quelli del file. I dati pubblici non cambiano.\n\n'
        'Consiglio: esporta prima i dati attuali.',
  );
  if (!ok || !context.mounted) return;
  final restored = await service.importJson(json);
  if (!context.mounted) return;
  context.read<AppServices>().revision.bump();
  final total = restored.values.fold(0, (a, b) => a + b);
  showSnack(context, 'Dati ripristinati ($total elementi).');
}

/// "Esporta/importa dati": i dati personali in un file JSON e il loro
/// ripristino. Due sole caselle.
class BackupSection extends StatelessWidget {
  const BackupSection({super.key});

  Future<void> _exportJson(BuildContext context) async {
    final json = await _backupService(context).exportJson();
    final saved = await FileTransfer.saveBytes(
      dialogTitle: 'Salva i dati',
      fileName: 'university_notes_backup_${fileStamp()}.json',
      bytes: Uint8List.fromList(utf8.encode(json)),
      mimeType: 'application/json',
      extensions: const ['json'],
    );
    if (saved != null && context.mounted) {
      showSnack(context, 'Dati salvati: $saved');
    }
  }

  Future<void> _import(BuildContext context) async {
    final picked = await FileTransfer.pickBytes(
      dialogTitle: 'Scegli i dati esportati (.json)',
      extensions: const ['json'],
      maxBytes: _maxBackupBytes,
    );
    if (picked == null || !context.mounted) return;
    final json = picked.asText();
    if (!BackupService.looksLikeBackup(json)) {
      throw BackupException('Il file non contiene dati esportati da UniNotes.');
    }
    await restoreBackupJson(context, json);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: 'Esporta/importa dati',
      icon: Icons.backup_outlined,
      subtitle:
          'Il file contiene i tuoi dati personali: corsi, eventi, esami e voti, '
          'sessioni di studio, libri, materiali, preferiti, note e impostazioni.',
      children: [
        ActionWrap(
          children: [
            AsyncActionButton(
              key: const Key('export-json'),
              label: 'Esporta dati (.json)',
              icon: Icons.file_download_outlined,
              filled: true,
              errorTitle: 'Esportazione non riuscita',
              onPressed: () => _exportJson(context),
            ),
            AsyncActionButton(
              key: const Key('import-json'),
              label: 'Importa dati (.json)',
              icon: Icons.file_upload_outlined,
              errorTitle: 'Importazione non riuscita',
              onPressed: () => _import(context),
            ),
          ],
        ),
      ],
    );
  }
}
