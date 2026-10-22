import 'dart:async';
import 'dart:io';

import '../../core/services/loopback_oauth.dart' show isExpiredGrant;
import '../cloud/folder_sync.dart' show isNetworkError;
import '../cloud/microsoft_admin_consent.dart';
import 'ai_assistants.dart';

/// Stati di un collegamento in Collegamenti (tabella completa con i
/// messaggi in `docs/collegamenti_stati.md`).
enum LinkPhase {
  /// La build non include l'ID del servizio: accesso impossibile.
  unavailable,

  /// Mai collegato o scollegato.
  notConnected,

  /// Accesso in corso nel browser.
  connecting,

  /// Collegato, nessuna sincronizzazione ancora fatta.
  connected,

  /// Sincronizzazione in corso.
  syncing,

  /// Ultima sincronizzazione riuscita.
  synced,

  /// Senza connessione: si riprova da soli quando torna la rete.
  offline,

  /// Accesso scaduto o revocato: va rifatto.
  expired,

  /// Account universitario bloccato dall'ateneo (consenso
  /// dell'amministratore Microsoft).
  adminConsent,

  /// Errore (accesso o sincronizzazione).
  error,
}

/// Stato mostrato nella card: cosa è successo e cosa fare.
class LinkStatus {
  const LinkStatus(this.phase, this.text, {this.action});
  final LinkPhase phase;

  /// Cosa è successo.
  final String text;

  /// Cosa fare (null = niente da fare).
  final String? action;

  bool get ok => phase == LinkPhase.synced || phase == LinkPhase.connected;

  bool get isError => switch (phase) {
    LinkPhase.error || LinkPhase.expired || LinkPhase.adminConsent => true,
    _ => false,
  };

  /// Testo completo (stato e azione).
  String get message => action == null ? text : '$text $action';
}

/// Stato della card di un servizio cloud (OneDrive, Google Drive).
LinkStatus cloudStatus({
  required String service,
  required bool available,
  required bool connected,
  bool connecting = false,
  bool syncing = false,
  String? progress,
  bool expired = false,
  bool adminConsent = false,
  String? account,
  String? lastLabel,
  String? lastError,
  String? offlineMessage,
}) {
  if (!available) {
    return LinkStatus(
      LinkPhase.unavailable,
      '$service non è disponibile in questa versione dell\'app.',
      action: 'Aggiorna UniNotes dal sito o dallo store.',
    );
  }
  if (connecting) {
    return LinkStatus(
      LinkPhase.connecting,
      'Accesso a $service in corso nel browser…',
      action: 'Completa l\'accesso: poi l\'app torna in primo piano da sola.',
    );
  }
  if (!connected) {
    if (adminConsent) {
      return const LinkStatus(
        LinkPhase.adminConsent,
        'Il tuo ateneo non permette di collegare l\'account universitario.',
        action:
            'Usa un account Microsoft personale o chiedi all\'ateneo di '
            'approvare UniNotes (link qui sotto).',
      );
    }
    return LinkStatus(
      LinkPhase.notConnected,
      'Non collegato.',
      action:
          'Accedi per avere file e dati dell\'app su tutti i tuoi dispositivi.',
    );
  }
  final who = account == null || account.isEmpty || account == 'collegato'
      ? ''
      : ' ($account)';
  if (expired) {
    return LinkStatus(
      LinkPhase.expired,
      'Collegamento interrotto: l\'accesso a $service$who è scaduto o è stato '
      'revocato.',
      action:
          'Premi «Accedi di nuovo»: file e dati restano sul dispositivo e '
          'riprendono a sincronizzarsi.',
    );
  }
  if (syncing) {
    return LinkStatus(
      LinkPhase.syncing,
      progress ?? 'Sincronizzazione con $service in corso…',
    );
  }
  if (lastError != null && lastError == offlineMessage) {
    return LinkStatus(
      LinkPhase.offline,
      'Senza connessione: $service non è raggiungibile.',
      action: lastLabel == null || lastLabel.startsWith('Errore')
          ? 'La sincronizzazione riparte da sola quando torna internet.'
          : 'Ultima riuscita: $lastLabel. Riparte da sola quando torna '
                'internet.',
    );
  }
  final failed = lastLabel != null && lastLabel.startsWith('Errore');
  if (lastError != null || failed) {
    final why = lastError ?? lastLabel!.replaceFirst(RegExp(r'^Errore:\s*'), '');
    return LinkStatus(
      LinkPhase.error,
      'Sincronizzazione non riuscita: $why',
      action: 'Riprova con «Sincronizza ora».',
    );
  }
  if (lastLabel == null) {
    return LinkStatus(
      LinkPhase.connected,
      'Collegato$who. Prima sincronizzazione in arrivo.',
    );
  }
  return LinkStatus(LinkPhase.synced, 'Collegato$who · ultima: $lastLabel');
}

/// Esito non riuscito di un accesso, già tradotto per lo studente.
class LinkFailure {
  const LinkFailure(this.phase, this.message, {this.retry = true});
  final LinkPhase phase;

  /// Causa e cosa fare.
  final String message;

  /// Ha senso proporre «Riprova».
  final bool retry;
}

/// Causa dell'errore di accesso a [service] e azione da proporre.
LinkFailure describeSignInError(Object e, String service) {
  final raw = '$e';
  final low = raw.toLowerCase();
  if (_offline(e, low)) {
    return LinkFailure(
      LinkPhase.offline,
      'Nessuna connessione a internet: $service non è raggiungibile. '
      'Collegati alla rete e riprova.',
    );
  }
  if (MicrosoftAdminConsent.isAdminConsentError(e)) {
    return const LinkFailure(
      LinkPhase.adminConsent,
      'Il tuo ateneo non permette agli studenti di collegare app esterne '
      'all\'account universitario. Usa un account Microsoft personale o '
      'chiedi all\'ateneo di approvare UniNotes.',
    );
  }
  if (low.contains('annullat') || low.contains('access_denied')) {
    return LinkFailure(
      LinkPhase.notConnected,
      'Accesso annullato: $service non è stato collegato. Riprova quando vuoi '
      'e accetta i permessi richiesti (solo i file di UniNotes).',
    );
  }
  if (low.contains('non completato') || e is TimeoutException) {
    return LinkFailure(
      LinkPhase.notConnected,
      'L\'accesso non è stato completato entro 5 minuti. Riprova e completa '
      'l\'accesso nella pagina che si apre nel browser.',
    );
  }
  if (low.contains('impossibile aprire il browser')) {
    return const LinkFailure(
      LinkPhase.error,
      'Non riesco ad aprire il browser per l\'accesso. Controlla di avere un '
      'browser predefinito e riprova.',
    );
  }
  if (low.contains('non include')) {
    return LinkFailure(LinkPhase.unavailable, raw, retry: false);
  }
  if (isExpiredGrant(low)) {
    return LinkFailure(
      LinkPhase.expired,
      'L\'accesso a $service è scaduto o è stato revocato: accedi di nuovo.',
    );
  }
  return LinkFailure(
    LinkPhase.error,
    'Collegamento a $service non riuscito: $raw\nRiprova; se l\'errore '
    'continua, scollega e ricollega l\'account.',
  );
}

bool _offline(Object e, String low) =>
    e is SocketException ||
    isNetworkError(e) ||
    low.contains('non raggiungibile') ||
    low.contains('non risponde') ||
    low.contains('failed host lookup');

/// Accesso riuscito.
String signInSuccessMessage(String service, String? account) {
  final who = account == null || account.isEmpty || account == 'collegato'
      ? ''
      : ' come $account';
  return '$service collegato$who: i tuoi dati si sincronizzano su questo '
      'dispositivo e su tutti quelli collegati allo stesso account.';
}

/// «Sincronizza ora» non riuscito.
String syncFailureMessage(String service, String? error, {bool offline = false}) =>
    offline
    ? 'Senza connessione: $service non è raggiungibile. La sincronizzazione '
          'riparte da sola quando torna internet.'
    : 'Sincronizzazione con $service non riuscita'
          '${error == null ? '' : ': $error'}. Riprova tra poco.';

/// AI di riferimento scelta.
String aiChosenMessage(ReferenceAi a) =>
    'AI di riferimento: ${a.label}. In Studio e Registra l\'app aprirà '
    '${a.label} con il prompt pronto.';

/// Download di un modello Whisper finito.
String whisperDownloadDone(String model) =>
    'Modello $model scaricato: le prossime trascrizioni possono usarlo.';

/// Download di un modello Whisper non riuscito: causa e cosa fare.
String whisperDownloadFailed(String model, String? error) {
  final e = (error ?? '').trim();
  final low = e.toLowerCase();
  if (e == 'Annullato.' || low.contains('annullat')) {
    return 'Download di $model annullato. Quando vuoi premi «Riprendi»: '
        'riparte da dove si era fermato.';
  }
  if (low.contains('spazio')) {
    return 'Download di $model non riuscito: $e';
  }
  if (low.contains('interrotto') ||
      low.contains('connessione') ||
      low.contains('raggiungibile') ||
      low.contains('socket')) {
    return 'Download di $model interrotto: controlla la connessione e premi '
        '«Riprendi» (riparte da dove si era fermato).';
  }
  return 'Download di $model non riuscito${e.isEmpty ? '' : ': $e'}. Riprova.';
}
