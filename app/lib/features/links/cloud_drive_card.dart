import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/feedback/app_modals.dart';
import '../../core/services/external_launcher.dart';
import '../../core/services/power.dart';
import '../../widgets/common.dart';
import '../cloud/cloud_drive_service.dart';
import '../study/study_widgets.dart' show promptText;
import 'link_status.dart';
import 'links_widgets.dart';

/// Aiuto quando l'accesso al servizio non riesce per un motivo che lo
/// studente non può risolvere dall'app (OneDrive: l'ateneo deve approvare
/// UniNotes). Al posto dell'errore generico si apre una scheda.
class SignInHelp {
  const SignInHelp({
    required this.label,
    required this.matches,
    required this.show,
    required this.retry,
    required this.remembered,
  });

  /// Testo del link che riapre la scheda.
  final String label;

  /// L'errore di accesso è di questo tipo.
  final bool Function(Object error) matches;

  /// Mostra la scheda ([error] null = aperta dal link); true = rifare
  /// l'accesso con [retry] (es. con un account personale).
  final Future<bool> Function(
    BuildContext context, {
    Object? error,
    required bool connected,
  })
  show;
  final Future<void> Function() retry;

  /// Il blocco è già capitato: il link resta anche ad account collegato.
  final Future<bool> Function() remembered;
}

class _CloudState {
  const _CloudState({
    required this.connected,
    required this.account,
    required this.folder,
    required this.last,
    required this.scopes,
    required this.interval,
    required this.wifiOnly,
    required this.helpRemembered,
  });
  final bool connected;
  final String? account;
  final String folder;
  final String? last;
  final Set<SyncScope> scopes;
  final int interval;
  final bool wifiOnly;
  final bool helpRemembered;
}

/// Scheda di un servizio cloud in Collegamenti (OneDrive, Google Drive):
/// accesso, cartella dell'app, cosa sincronizzare, ogni quanto e stato.
class CloudDriveCard extends StatefulWidget {
  const CloudDriveCard({
    super.key,
    required this.service,
    required this.icon,
    required this.subtitle,
    required this.signInLabel,
    required this.connectedFallback,
    required this.pickFolder,
    this.missingId,
    this.note,
    this.extra,
    this.signInHelp,
    this.signOutNote,
    this.revokeHelpUrl,
    this.primary = false,
    this.onChanged,
  });

  final CloudDriveService service;
  final IconData icon;
  final String subtitle;
  final String signInLabel;

  /// Stato quando il nome dell'account non è noto.
  final String connectedFallback;

  /// Scelta della cartella: percorso (vuoto = predefinita) o null.
  final Future<String?> Function(BuildContext context, String current)
  pickFolder;

  /// Avviso se la build non include l'ID del servizio (accesso impossibile).
  final String? missingId;

  /// Nota sotto i pulsanti (es. limiti del servizio).
  final String? note;

  /// Parti in più del servizio sotto i pulsanti (es. «Importa da Drive»).
  final Widget Function(BuildContext context, bool connected)? extra;

  /// Scheda al posto dell'errore per gli accessi bloccati (vedi [SignInHelp]).
  final SignInHelp? signInHelp;

  /// Riga in più nel dialogo di «Scollega» (OneDrive: dove togliere
  /// l'accesso dall'account, perché l'app non può revocarlo).
  final String? signOutNote;

  /// Pagina dell'account dove togliere l'accesso a mano, proposta solo se
  /// la revoca alla disconnessione non riesce (Google).
  final String? revokeHelpUrl;
  final bool primary;
  final VoidCallback? onChanged;

  @override
  State<CloudDriveCard> createState() => _CloudDriveCardState();
}

class _CloudDriveCardState extends State<CloudDriveCard> {
  CloudDriveService get _sv => widget.service;
  late Future<_CloudState> _future = _load();

  Future<_CloudState> _load() async => _CloudState(
    connected: await _sv.connected(),
    account: await _sv.account(),
    folder: await _sv.folder(),
    last: await _sv.lastSyncLabel(),
    scopes: await _sv.scopes(),
    interval: await _sv.intervalMinutes(),
    wifiOnly: await _sv.recordingsWifiOnly(),
    helpRemembered: await widget.signInHelp?.remembered() ?? false,
  );

  void _reload() {
    if (!mounted) return;
    setState(() {
      _future = _load();
    });
    widget.onChanged?.call();
  }

  @override
  void initState() {
    super.initState();
    _sv.addListener(_onService);
  }

  void _onService() {
    if (mounted) setState(() {});
    if (!_sv.syncing) _reload();
  }

  @override
  void dispose() {
    _sv.removeListener(_onService);
    super.dispose();
  }

  /// Accesso nel browser in corso (stato «collegamento in corso»).
  bool _connecting = false;

  /// Accesso. Riuscito: messaggio di successo, card aggiornata e prima
  /// sincronizzazione. Non riuscito: se l'errore ha una scheda dedicata
  /// ([SignInHelp], ateneo che blocca l'account) la mostra, altrimenti un
  /// dialogo con la causa e «Riprova» (vedi [describeSignInError]).
  Future<void> _signIn(Future<void> Function() attempt) async {
    setState(() => _connecting = true);
    try {
      await attempt();
    } catch (e) {
      if (mounted) setState(() => _connecting = false);
      _reload();
      if (!mounted) return;
      final help = widget.signInHelp;
      if (help != null && help.matches(e)) {
        final retry = await help.show(context, error: e, connected: false);
        _reload();
        if (retry && mounted) return _signIn(help.retry);
        return;
      }
      final failure = describeSignInError(e, _sv.serviceName);
      if (await _failureDialog(failure) && mounted) return _signIn(attempt);
      return;
    }
    if (mounted) setState(() => _connecting = false);
    _reload();
    final who = await _sv.account();
    if (mounted) showSnack(context, signInSuccessMessage(_sv.serviceName, who));
    // la scheda è già «collegata»: la prima sincronizzazione continua da
    // sola (con il suo stato nella card) e i controlli automatici partono
    _sv.startAutoSync();
    if (!mounted) {
      unawaited(_sv.sync());
      return;
    }
    final messenger = ScaffoldMessenger.maybeOf(context);
    final name = _sv.serviceName;
    unawaited(
      _sv.sync().then((r) {
        if (r != null && r.dataChanges > 0) {
          messenger?.showSnackBar(
            SnackBar(
              content: Text(
                '$name: ${r.dataChanges} dati arrivati dagli altri '
                'dispositivi.',
              ),
            ),
          );
        }
      }),
    );
  }

  /// Dialogo «Collegamento non riuscito» con causa e azione; true =
  /// «Riprova».
  Future<bool> _failureDialog(LinkFailure f) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        icon: Icon(
          f.phase == LinkPhase.offline ? Icons.wifi_off : Icons.error_outline,
        ),
        title: Text('Collegamento a ${_sv.serviceName} non riuscito'),
        content: SelectableText(f.message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Chiudi'),
          ),
          if (f.retry)
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Riprova'),
            ),
        ],
      ),
    );
    return r == true;
  }

  Future<void> _openHelp(bool connected) async {
    final help = widget.signInHelp!;
    final retry = await help.show(context, connected: connected);
    if (!retry || !mounted) return;
    await _signIn(help.retry);
  }

  /// «Sincronizza ora»: esito in un messaggio (riuscita, senza rete,
  /// errore con la causa).
  Future<void> _syncNow() async {
    final name = _sv.serviceName;
    final r = await _sv.sync();
    if (!mounted) return;
    if (r != null) {
      showSnack(context, '$name: $r');
    } else if (_sv.lastError != null) {
      showSnack(
        context,
        syncFailureMessage(
          name,
          _sv.lastError,
          offline: _sv.lastError == _sv.offlineMessage,
        ),
      );
    } else if (await _sv.connected() && mounted) {
      // un'altra sincronizzazione è in corso (anche quella in background
      // del telefono): questa non è partita
      showSnack(
        context,
        '$name: sincronizzazione già in corso, riprova tra '
        'poco.',
      );
    }
  }

  /// Scollegato sul dispositivo, ma la revoca presso il servizio non è
  /// riuscita (senza rete, errore): la pagina dove togliere l'accesso.
  Future<void> _revokeFailed(String url) async {
    final open = await showAppDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text('${_sv.serviceName} scollegato'),
        content: Text(
          'Su questo dispositivo l\'accesso è tolto, ma non è stato possibile '
          'revocarlo anche presso ${_sv.serviceName} (serve la connessione). '
          'Puoi toglierlo dal tuo account: $url',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Chiudi'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Apri la pagina'),
          ),
        ],
      ),
    );
    if (open != true) return;
    final r = await ExternalLauncher.openUrl(url);
    if (mounted) showLaunchResult(context, r);
  }

  Future<void> _pickFolder(String current) async {
    final picked = await widget.pickFolder(context, current);
    if (picked == null) return;
    await _sv.setFolder(
      picked.trim().isEmpty ? CloudDriveService.defaultFolder : picked,
    );
    final now = await _sv.folder();
    _reload();
    if (mounted) showSnack(context, 'Cartella ${_sv.serviceName}: /$now');
  }

  /// «Rinomina»: nuovo nome della cartella dell'app sul servizio (i file
  /// restano dove sono; gli altri dispositivi la ritrovano da soli).
  Future<void> _renameFolder(String current) async {
    final last = current.split('/').last;
    final name = await promptText(
      context,
      title: 'Rinomina la cartella su ${_sv.serviceName}',
      label: 'Nuovo nome',
      initial: last,
    );
    if (name == null || name == last || !mounted) return;
    final err = CloudDriveService.validateFolderName(name);
    if (err != null) {
      showSnack(context, err);
      return;
    }
    try {
      final now = await _sv.renameFolder(name);
      _reload();
      if (mounted) {
        showSnack(context, 'Cartella ${_sv.serviceName} rinominata: /$now');
      }
    } catch (e) {
      if (mounted) showSnack(context, 'Cartella non rinominata: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_CloudState>(
      future: _future,
      builder: (context, snap) {
        final d = snap.data;
        return LinksCard(
          title: _sv.serviceName,
          icon: widget.icon,
          subtitle: widget.subtitle,
          children: d == null
              ? const [
                  Padding(
                    padding: EdgeInsets.all(12),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ]
              : _content(context, d),
        );
      },
    );
  }

  List<Widget> _content(BuildContext context, _CloudState d) {
    final name = _sv.serviceName;
    final status = cloudStatus(
      service: name,
      available: widget.missingId == null,
      connected: d.connected,
      connecting: _connecting,
      syncing: _sv.syncing,
      progress: _sv.progress,
      expired: _sv.authExpired,
      adminConsent: d.helpRemembered,
      account: d.account ?? widget.connectedFallback,
      lastLabel: d.last,
      lastError: _sv.lastError,
      offlineMessage: _sv.offlineMessage,
    );
    return [
      StatusLine(
        key: const Key('cloud-status'),
        status.message,
        ok: status.ok || status.phase == LinkPhase.syncing,
        error: status.isError,
      ),
      if (_sv.syncing || _connecting) ...[
        const SizedBox(height: 6),
        const LinearProgressIndicator(),
      ],
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_outlined),
        title: Text('/${d.folder}'),
        subtitle: Text('Cartella dell\'app su $name'),
        trailing: d.connected
            ? Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    key: const Key('cloud-folder-rename'),
                    onPressed: () => _renameFolder(d.folder),
                    child: const Text('Rinomina'),
                  ),
                  TextButton(
                    onPressed: () => _pickFolder(d.folder),
                    child: const Text('Cambia…'),
                  ),
                ],
              )
            : null,
      ),
      if (widget.missingId != null)
        NoteText(widget.missingId!, icon: Icons.info_outline),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          if (!d.connected)
            LinkButton(
              label: widget.signInLabel,
              icon: Icons.login,
              primary: widget.primary,
              errorTitle: 'Accesso a $name non riuscito',
              onPressed: widget.missingId != null
                  ? null
                  : () => _signIn(_sv.signIn),
            )
          else ...[
            if (_sv.authExpired)
              // collegamento interrotto: sincronizzare non servirebbe
              LinkButton(
                label: 'Accedi di nuovo',
                icon: Icons.login,
                primary: true,
                errorTitle: 'Accesso a $name non riuscito',
                onPressed: () => _signIn(_sv.signIn),
              )
            else
              LinkButton(
                label: 'Sincronizza ora',
                icon: Icons.sync,
                primary: widget.primary,
                errorTitle: 'Sincronizzazione non riuscita',
                onPressed: _syncNow,
              ),
            LinkButton(
              label: 'Scollega',
              icon: Icons.logout,
              onPressed: () async {
                final note = widget.signOutNote;
                if (await confirmDialog(
                  context,
                  'Scollegare $name?',
                  'I file restano su questo dispositivo e su $name; smettono '
                      'solo di sincronizzarsi.${note == null ? '' : '\n\n$note'}',
                )) {
                  final revoked = await _sv.signOut();
                  _reload();
                  final url = widget.revokeHelpUrl;
                  if (!revoked && url != null && context.mounted) {
                    await _revokeFailed(url);
                  }
                }
              },
            ),
          ],
        ],
      ),
      if (widget.signInHelp != null && (!d.connected || d.helpRemembered))
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const Key('sign-in-help'),
            onPressed: () => _openHelp(d.connected),
            icon: const Icon(Icons.help_outline, size: 18),
            label: Text(widget.signInHelp!.label),
          ),
        ),
      if (widget.note != null) ...[
        const SizedBox(height: 8),
        NoteText(widget.note!, icon: Icons.info_outline),
      ],
      if (widget.extra != null) widget.extra!(context, d.connected),
      const SizedBox(height: 12),
      Text(
        'Cosa sincronizzare',
        style: Theme.of(context).textTheme.labelMedium,
      ),
      for (final sc in SyncScope.values)
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          controlAffinity: ListTileControlAffinity.leading,
          title: Text(sc.label),
          subtitle: Text('In /${d.folder}/${sc.remoteDir}'),
          value: d.scopes.contains(sc),
          onChanged: (v) async {
            final next = {...d.scopes};
            v == true ? next.add(sc) : next.remove(sc);
            await _sv.setScopes(next);
            _reload();
          },
        ),
      if (Power.isMobile) ...[
        Text(
          'Risparmio energetico',
          style: Theme.of(context).textTheme.labelMedium,
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('Registrazioni solo con Wi‑Fi'),
          subtitle: const Text(
            'Con i dati mobili le registrazioni aspettano il Wi‑Fi; il resto '
            'si sincronizza subito.',
          ),
          value: d.wifiOnly,
          onChanged: (v) async {
            await _sv.setRecordingsWifiOnly(v);
            _reload();
          },
        ),
      ],
      DropdownButtonFormField<int>(
        style: Theme.of(context).textTheme.bodyLarge,
        isExpanded: true,
        initialValue: CloudDriveService.intervals.contains(d.interval)
            ? d.interval
            : CloudDriveService.defaultInterval,
        decoration: const InputDecoration(
          labelText: 'Controlla le novità ogni',
        ),
        items: [
          for (final m in CloudDriveService.intervals)
            DropdownMenuItem(value: m, child: Text('$m minuti')),
        ],
        onChanged: (m) async {
          if (m == null) return;
          await _sv.setIntervalMinutes(m);
          _reload();
        },
      ),
      if (Power.isMobile)
        const Padding(
          padding: EdgeInsets.only(top: 6),
          child: NoteText(
            'Con l\'app aperta il controllo è a questo intervallo; con l\'app '
            'chiusa il telefono sincronizza in background quando può '
            '(al massimo ogni 15 minuti, decide il sistema).',
            icon: Icons.info_outline,
          ),
        ),
    ];
  }
}
