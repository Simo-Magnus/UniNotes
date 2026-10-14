import 'package:flutter/material.dart';

import '../../core/services/power.dart';
import '../../widgets/common.dart';
import '../cloud/cloud_drive_service.dart';
import 'links_widgets.dart';

class _CloudState {
  const _CloudState({
    required this.connected,
    required this.account,
    required this.folder,
    required this.last,
    required this.scopes,
    required this.interval,
    required this.wifiOnly,
  });
  final bool connected;
  final String? account;
  final String folder;
  final String? last;
  final Set<SyncScope> scopes;
  final int interval;
  final bool wifiOnly;
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
    return [
      StatusLine(
        d.connected ? (d.account ?? widget.connectedFallback) : 'Non collegato',
        ok: d.connected,
      ),
      if (d.connected) ...[
        const SizedBox(height: 6),
        StatusLine(
          _sv.syncing
              ? (_sv.progress ?? 'Sincronizzazione…')
              : (d.last == null ? 'Mai sincronizzato' : 'Ultima: ${d.last}'),
          ok: _sv.syncing || (d.last != null && !d.last!.startsWith('Errore')),
          error: d.last?.startsWith('Errore') ?? false,
        ),
        if (_sv.syncing) ...[
          const SizedBox(height: 6),
          const LinearProgressIndicator(),
        ],
      ],
      if (_sv.lastError != null) ...[
        const SizedBox(height: 6),
        StatusLine(_sv.lastError, error: true),
      ],
      const SizedBox(height: 8),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_outlined),
        title: Text('/${d.folder}'),
        subtitle: Text('Cartella dell\'app su $name'),
        trailing: d.connected
            ? TextButton(
                onPressed: () => _pickFolder(d.folder),
                child: const Text('Cambia…'),
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
                  : () async {
                      await _sv.signIn();
                      _reload();
                      await _sv.sync();
                      _sv.startAutoSync();
                    },
            )
          else ...[
            LinkButton(
              label: 'Sincronizza ora',
              icon: Icons.sync,
              primary: widget.primary,
              errorTitle: 'Sincronizzazione non riuscita',
              onPressed: () async {
                final r = await _sv.sync();
                if (context.mounted && r != null) {
                  showSnack(context, '$name: $r');
                }
              },
            ),
            LinkButton(
              label: 'Scollega',
              icon: Icons.logout,
              onPressed: () async {
                if (await confirmDialog(
                  context,
                  'Scollegare $name?',
                  'I file restano su questo dispositivo e su $name; smettono '
                      'solo di sincronizzarsi.',
                )) {
                  await _sv.signOut();
                  _reload();
                }
              },
            ),
          ],
        ],
      ),
      if (widget.note != null) ...[
        const SizedBox(height: 8),
        NoteText(widget.note!, icon: Icons.info_outline),
      ],
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
    ];
  }
}
