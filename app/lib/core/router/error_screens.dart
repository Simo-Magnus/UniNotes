import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/notes/recorder/recording_overlay.dart'
    show appNavigatorKey;
import '../services/error_log.dart';
import '../theme/app_theme.dart';

/// Gestione globale degli errori (da chiamare una volta, all'inizio di
/// main): gli errori dei widget e quelli asincroni non gestiti finiscono nel
/// registro locale ([ErrorLog]) invece di chiudere l'app, e un widget che non
/// si costruisce mostra [AppErrorWidget] invece della schermata rossa o
/// grigia. Non sostituisce la gestione degli errori dove nascono.
void installGlobalErrorHandlers() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    // in debug il riquadro dell'errore nella console resta come prima
    (previous ?? FlutterError.presentError)(details);
    unawaited(
      ErrorLog.record(
        details.exception,
        details.stack,
        context: details.context?.toDescription() ?? details.library,
      ),
    );
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('Errore non gestito: $error');
    unawaited(ErrorLog.record(error, stack, context: 'Errore non gestito'));
    // gestito: l'app continua
    return true;
  };
  ErrorWidget.builder = (details) => AppErrorWidget(details: details);
}

/// Al posto di un widget che non si è potuto costruire: messaggio
/// comprensibile e «Torna indietro» (se c'è una schermata a cui tornare).
/// Funziona in qualsiasi spazio (anche minuscolo o senza limiti) e senza
/// Material, tema o Directionality sopra di sé.
class AppErrorWidget extends StatelessWidget {
  const AppErrorWidget({super.key, this.details});
  final FlutterErrorDetails? details;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final nav = appNavigatorKey.currentState;
    final canPop = nav != null && nav.mounted && nav.canPop();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        type: MaterialType.transparency,
        child: ClipRect(
          child: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Container(
                width: 300,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: scheme.outlineVariant),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.error_outline, color: scheme.error, size: 32),
                    const SizedBox(height: 8),
                    Text(
                      'Qualcosa non ha funzionato',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurface,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      canPop
                          ? 'Questa parte dell\'app non si è potuta mostrare. '
                                'I tuoi dati non sono stati toccati.'
                          : 'Questa parte dell\'app non si è potuta mostrare. '
                                'I tuoi dati non sono stati toccati: prova '
                                'un\'altra sezione o riapri l\'app.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                    if (kDebugMode && details != null) ...[
                      const SizedBox(height: 6),
                      Text(
                        details!.exceptionAsString(),
                        maxLines: 6,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: scheme.error, fontSize: 11),
                      ),
                    ],
                    if (canPop) ...[
                      const SizedBox(height: 10),
                      TextButton.icon(
                        onPressed: () =>
                            appNavigatorKey.currentState?.maybePop(),
                        icon: const Icon(Icons.arrow_back),
                        label: const Text('Torna indietro'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Avvio non riuscito (database non apribile, disco pieno…): al posto di
/// una finestra vuota o di una chiusura, cosa è successo e «Riprova».
class StartupErrorApp extends StatelessWidget {
  const StartupErrorApp({
    super.key,
    required this.error,
    required this.onRetry,
  });
  final Object error;
  final Future<void> Function() onRetry;

  /// Spiegazione per lo studente.
  static String messageFor(Object error) => isDiskFullError(error)
      ? 'Lo spazio sul dispositivo è esaurito e UniNotes non riesce ad aprire '
            'i tuoi dati. Libera un po\' di spazio (foto, video, app che non '
            'usi) e tocca «Riprova». I tuoi dati non sono stati modificati.'
      : 'UniNotes non è riuscito ad aprire i tuoi dati. Non è stato '
            'modificato nulla. Tocca «Riprova»; se il problema resta, riavvia '
            'il dispositivo. I dettagli sono nel registro degli errori '
            'dell\'app (${ErrorLog.fileName}).';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.dark,
      home: _StartupErrorScreen(error: error, onRetry: onRetry),
    );
  }
}

class _StartupErrorScreen extends StatefulWidget {
  const _StartupErrorScreen({required this.error, required this.onRetry});
  final Object error;
  final Future<void> Function() onRetry;

  @override
  State<_StartupErrorScreen> createState() => _StartupErrorScreenState();
}

class _StartupErrorScreenState extends State<_StartupErrorScreen> {
  bool _busy = false;

  Future<void> _retry() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onRetry();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.error_outline,
                    size: 48,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'UniNotes non si è avviato',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    StartupErrorApp.messageFor(widget.error),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  SelectableText(
                    '${widget.error}',
                    textAlign: TextAlign.center,
                    maxLines: 6,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 20),
                  FilledButton.icon(
                    key: const Key('startup-retry'),
                    onPressed: _busy ? null : _retry,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: const Text('Riprova'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Dopo l'avvio con un database danneggiato messo da parte (vedi
/// `AppDatabase.open`): avviso una volta sola, con dove è rimasta la copia.
Future<void> showDatabaseRecoveredNotice(
  String asidePath, {
  int recoveredRows = 0,
}) async {
  final context = appNavigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Dati danneggiati'),
      content: SingleChildScrollView(
        child: Text(
          'Il file con i dati dell\'app era danneggiato e non si poteva '
          '${recoveredRows > 0 ? 'leggere tutto: UniNotes ha recuperato in un file nuovo i dati ancora leggibili ($recoveredRows elementi); quelli rovinati mancano.' : 'leggere: UniNotes è ripartito da zero.'} '
          'Il file danneggiato non è stato eliminato:\n\n$asidePath\n\n'
          'Se hai esportato i tuoi dati (Impostazioni → Esporta/importa dati) '
          'o usi la sincronizzazione con OneDrive o Google Drive, puoi '
          'recuperarli da lì.',
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(c),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
