import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/database/app_database.dart';
import '../../core/services/app_services.dart';
import '../../core/services/app_uninstall.dart';
import '../../core/theme/app_theme.dart';
import '../../repositories/settings_repository.dart';
import 'erase_all.dart';
import 'logic/data_eraser.dart';

/// Argomento con cui il disinstallatore di Windows avvia l'app
/// (app/windows/installer/uninotes.iss, SchermataDisinstallazione in [Code]).
const String kUninstallArg = '--disinstalla';

/// Windows: il disinstallatore di Inno Setup, avviato da «App installate»,
/// lancia `uninotes.exe --disinstalla` e aspetta. L'app parte in modalità
/// minima (niente sincronizzazioni, promemoria o area di notifica) con la
/// schermata di disinstallazione dell'app ([runEraseFlow], modalità
/// [EraseFlowMode.windowsUninstaller]) e poi si chiude; il disinstallatore
/// toglie i file del programma. Solo per l'installatore del sito: nella build
/// del Microsoft Store l'argomento si ignora
/// ([AppUninstall.handlesUninstallArg]).
Future<void> runUninstallMode() async {
  AppDatabase db;
  try {
    db = await File(await AppDatabase.defaultPath()).exists()
        ? await AppDatabase.open()
        : await AppDatabase.openInMemory();
  } catch (_) {
    db = await AppDatabase.openInMemory();
  }
  final services = AppServices(db);
  var mode = ThemeMode.dark;
  try {
    mode = parseThemeMode(await services.settings.get(SettingKeys.themeMode));
  } catch (_) {}
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    try {
      await windowManager.ensureInitialized();
      await windowManager.setTitle('Disinstalla UniNotes');
      await windowManager.setSize(const Size(760, 560));
      await windowManager.center();
    } catch (_) {}
  }
  runApp(
    MaterialApp(
      title: 'Disinstalla UniNotes',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: mode,
      home: UninstallScreen(
        eraser: DataEraser(services),
        onDone: () => exit(0),
      ),
    ),
  );
}

/// Sfondo della modalità minima; il flusso parte al primo fotogramma.
class UninstallScreen extends StatefulWidget {
  const UninstallScreen({
    super.key,
    required this.eraser,
    required this.onDone,
  });
  final DataEraser eraser;

  /// Chiusura del programma.
  final VoidCallback onDone;

  @override
  State<UninstallScreen> createState() => _UninstallScreenState();
}

class _UninstallScreenState extends State<UninstallScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await runEraseFlow(
          context,
          mode: EraseFlowMode.windowsUninstaller,
          eraser: widget.eraser,
          quit: widget.onDone,
        );
      } catch (e) {
        debugPrint('Pulizia della disinstallazione non completa: $e');
        widget.onDone();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.delete_sweep_outlined,
                size: 48,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Disinstalla UniNotes',
                style: theme.textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
