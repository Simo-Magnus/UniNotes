import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/catalog/catalog_service.dart';
import '../core/catalog/path_setup.dart';
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

/// Messaggio quando si chiede di aggiornare il database senza connessione:
/// i dati già scaricati restano e l'app funziona come prima.
const String kServeConnessioneAggiornamento =
    'Serve una connessione a internet per aggiornare il database.';

/// Stato della rete secondo il sistema, per non far aspettare lo studente
/// un download che non può partire.
abstract final class Rete {
  /// Sostituibile nei test.
  static Future<bool> Function()? debugOffline;

  /// Il sistema non vede nessuna rete (né Wi‑Fi, né dati mobili, né cavo).
  /// Nel dubbio (sistema che non risponde, test) false: si prova comunque
  /// e gli errori di rete si riconoscono dopo.
  static Future<bool> offline() async {
    final debug = debugOffline;
    if (debug != null) return debug();
    // nei test il plugin non c'è (e su Linux userebbe D-Bus)
    if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
    try {
      final r = await Connectivity().checkConnectivity().timeout(
        const Duration(seconds: 3),
      );
      return r.isNotEmpty && r.every((c) => c == ConnectivityResult.none);
    } catch (_) {
      return false;
    }
  }
}

/// Esito di [aggiornaDatabase].
class AggiornamentoDatabase {
  const AggiornamentoDatabase(this.result, {this.offline = false});

  /// Esito dell'import (null se non si è nemmeno provato).
  final PlanImportResult? result;

  /// Il database non era raggiungibile: si mostra il messaggio che chiede
  /// la connessione, con «Riprova».
  final bool offline;

  /// Messaggio per lo studente quando [offline]: senza i dati del corso
  /// sul dispositivo [kServeConnessione], altrimenti
  /// [kServeConnessioneAggiornamento].
  String get messaggioOffline => (result?.senzaRete ?? false)
      ? kServeConnessione
      : kServeConnessioneAggiornamento;
}

/// «Aggiorna database» ([PathSetupService.refresh]) con lo stesso controllo
/// della connessione in tutta l'app (Impostazioni, nuovo anno accademico,
/// nuova versione del database, avvio con i dati del corso mancanti):
/// - il sistema non vede nessuna rete: non si prova (niente attese);
/// - dati del corso mancanti e non scaricabili
///   ([PlanImportResult.senzaRete]);
/// - piano reimportato dalla copia salvata perché il database non risponde
///   (i dati restano quelli di prima: non è un aggiornamento).
/// Gli errori che non sono di rete passano al chiamante.
Future<AggiornamentoDatabase> aggiornaDatabase(
  AppServices s, {
  DateTime? now,
}) async {
  if (await Rete.offline()) {
    return const AggiornamentoDatabase(null, offline: true);
  }
  final PlanImportResult r;
  try {
    r = await PathSetupService(s).refresh(now: now);
  } catch (e) {
    if (CatalogService.erroreDiRete(e)) {
      return const AggiornamentoDatabase(null, offline: true);
    }
    rethrow;
  }
  if (r.senzaRete) return AggiornamentoDatabase(r, offline: true);
  if (r.imported &&
      r.source != null &&
      r.source != CatalogSource.remote &&
      await s.catalog.remoteMeta() == null) {
    return AggiornamentoDatabase(r, offline: true);
  }
  return AggiornamentoDatabase(r);
}

/// Avviso uniforme «serve una connessione» in fondo allo schermo, con
/// «Riprova» se [onRetry] non è null (stesso testo e icona di
/// [CatalogOfflineNotice]).
void mostraServeConnessione(
  BuildContext context, {
  String message = kServeConnessione,
  VoidCallback? onRetry,
}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        key: const Key('serve-connessione'),
        duration: const Duration(seconds: 8),
        content: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 20,
              // stesso colore del testo della barra (chiaro su scuro)
              color: Theme.of(context).snackBarTheme.contentTextStyle?.color,
            ),
            const SizedBox(width: 12),
            Expanded(child: Text(message)),
          ],
        ),
        action: onRetry == null
            ? null
            : SnackBarAction(
                label: 'Riprova',
                // la barra resta anche cambiando pagina: «Riprova» non deve
                // usare il contesto di una pagina già chiusa
                onPressed: () {
                  if (context.mounted) onRetry();
                },
              ),
      ),
    );
}
