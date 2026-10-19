import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/catalog/catalog_service.dart';
import '../core/services/app_services.dart';
import '../core/theme/app_tokens.dart';
import '../features/settings/logic/formatting.dart';

/// Barra di avanzamento del download dei dati del corso
/// ([CatalogService.progresso]): file in corso e megabyte ricevuti. Non
/// occupa spazio quando non si scarica nulla.
class CatalogDownloadProgress extends StatelessWidget {
  const CatalogDownloadProgress({
    super.key,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final catalog = context.read<AppServices>().catalog;
    return ValueListenableBuilder<CatalogProgress?>(
      valueListenable: catalog.progresso,
      builder: (context, p, _) {
        if (p == null) return const SizedBox.shrink();
        final t = context.tokens;
        return Padding(
          key: const Key('catalog-download-progress'),
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LinearProgressIndicator(value: p.frazione),
              const SizedBox(height: 6),
              Text(
                'Scarico i dati del tuo corso: ${p.etichetta} '
                '(${p.indice} di ${p.totale}) · '
                '${formatBytes(p.ricevutiTotali)}',
                style: TextStyle(fontSize: 13, color: t.textMuted),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Avviso «Serve una connessione per scaricare i dati del tuo corso» (o
/// un altro [message], per esempio spazio insufficiente) con il pulsante
/// Riprova: il resto dell'app (corsi a mano, appunti, registratore…)
/// funziona comunque.
class CatalogOfflineNotice extends StatelessWidget {
  const CatalogOfflineNotice({
    super.key,
    required this.onRetry,
    this.detail,
    this.message = kServeConnessione,
    this.padding = const EdgeInsets.symmetric(vertical: 8),
  });

  /// Messaggio principale (vedi [CatalogService.descriviErrore]).
  final String message;

  /// null mentre si riprova.
  final VoidCallback? onRetry;

  /// Spiegazione aggiuntiva sotto il messaggio.
  final String? detail;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      key: const Key('catalog-offline'),
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            message == kServeConnessione
                ? Icons.cloud_off_outlined
                : Icons.error_outline,
            color: t.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: TextStyle(color: t.textPrimary)),
                if (detail != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    detail!,
                    style: TextStyle(fontSize: 13, color: t.textMuted),
                  ),
                ],
                const SizedBox(height: 4),
                TextButton.icon(
                  key: const Key('catalog-retry'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Riprova'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
