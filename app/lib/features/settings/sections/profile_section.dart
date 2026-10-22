import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/academic/student_profile.dart';
import '../../../core/catalog/catalog_models.dart';
import '../../../core/catalog/catalog_service.dart';
import '../../../core/catalog/curricula.dart';
import '../../../core/catalog/path_setup.dart';
import '../../../core/services/app_services.dart';
import '../../../core/services/calendar_export.dart';
import '../../../utils/dates.dart';
import '../../../widgets/catalog_download.dart';
import '../../../widgets/common.dart';
import '../../onboarding/onboarding_flow.dart' show showChangePath;
import '../../onboarding/percorso_field.dart';
import '../dialogs/text_edit_dialog.dart';
import '../logic/formatting.dart';
import '../widgets/async_action_button.dart';
import '../widgets/settings_card.dart';

class _ProfileData {
  const _ProfileData(
    this.profile,
    this.baseUrl,
    this.meta,
    this.ammissione,
    this.percorsi,
    this.dati,
  );
  final StudentProfile? profile;
  final String baseUrl;
  final DatabaseMeta? meta;
  final Ammissione? ammissione;

  /// Dati del corso del profilo salvati sul dispositivo.
  final AteneoSulDispositivo? dati;

  /// Percorsi del corso di laurea, se sono più d'uno.
  final PercorsiCorso? percorsi;
}

/// "Il mio percorso": ateneo, corso, anno e anno accademico con «Cambia
/// corso» accanto al titolo; aggiorna il database pubblico e indirizzo del
/// database (sulla stessa riga). Senza connessione l'aggiornamento mostra il
/// messaggio che la chiede, con «Riprova» ([aggiornaDatabase]).
class ProfileSection extends StatelessWidget {
  const ProfileSection({super.key});

  static Future<_ProfileData> _load(AppServices s) async {
    final p = await s.profiles.load();
    // requisiti di accesso dalla copia salvata del file del corso (niente
    // rete: se manca si scarica con «Riprova», non aprendo le Impostazioni)
    final file = p == null
        ? null
        : await s.catalog.corsiAteneo(
            p.universityId,
            remote: false,
            scarica: false,
            corso: p.degreeId,
          );
    final corso = p == null ? null : file?.data.corso(p.degreeId);
    final percorsi = corso == null ? null : PercorsiCorso.di(corso);
    return _ProfileData(
      p,
      await s.catalog.baseUrl(),
      await s.catalog.localMeta(),
      corso?.ammissione,
      percorsi != null && percorsi.daScegliere ? percorsi : null,
      p == null ? null : await s.catalog.datiCorso(p.universityId, p.degreeId),
    );
  }

  /// «Dati del corso»: spazio occupato e data dell'ultimo download.
  static String _datiLabel(AteneoSulDispositivo d) {
    if (!d.corsi) return 'non ancora scaricati';
    return [
      if (d.byte > 0) '${formatBytes(d.byte)} sul dispositivo',
      if (d.scaricatoIl != null) 'scaricati il ${formatDmy(d.scaricatoIl!)}',
    ].join(' · ').ifEmpty('inclusi nell\'app');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: 'Il mio percorso',
      icon: Icons.school_outlined,
      // cambio del corso di laurea (università, corso, anno) dentro la card
      trailing: TextButton.icon(
        key: const Key('change-path'),
        onPressed: () => showChangePath(context),
        icon: const Icon(Icons.swap_horiz),
        label: const Text('Cambia corso'),
      ),
      children: [
        RevisionBuilder<_ProfileData>(
          load: _load,
          builder: (context, d) {
            final p = d.profile;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (p == null)
                  const InfoRow('Percorso', 'non ancora scelto')
                else ...[
                  InfoRow('Università', p.universityName),
                  InfoRow(
                    'Corso',
                    [
                      p.degreeName,
                      if (p.classCode != null) 'classe ${p.classCode}',
                    ].join(' · '),
                  ),
                  InfoRow('Tipo', TipoCorso.fromKey(p.degreeType).label),
                  InfoRow(
                    'Anno',
                    p.fuoriCorso
                        ? 'Fuori corso · ${p.currentYear}° anno del piano'
                        : '${p.currentYear}° anno di ${p.durationYears}',
                  ),
                  InfoRow(
                    'Anno accademico',
                    p.academicYearOf(p.currentYear).label,
                  ),
                  if (d.percorsi case final ps?)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: PercorsoField(
                        percorsi: ps,
                        value: p.curriculum,
                        onChanged: (v) => _changeCurriculum(context, v),
                      ),
                    ),
                  if (d.ammissione case final a?) ..._ammissione(context, a),
                ],
                InfoRow(
                  'Database',
                  [
                    if (d.meta?.versione != null)
                      'versione ${formatDmyString(d.meta!.versione!)}',
                    if (p?.catalogVersion != null)
                      'importato ${formatDmyString(p!.catalogVersion!)}',
                  ].join(' · ').ifEmpty('non ancora scaricato'),
                ),
                if (d.dati case final dati?)
                  InfoRow('Dati del corso', _datiLabel(dati)),
                InfoRow('Indirizzo', d.baseUrl),
                // percorso dal catalogo ma dati del corso non scaricati
                // (es. primo avvio offline): avviso con «Riprova»
                if (p != null && !p.manual && d.dati?.corsi == false)
                  CatalogOfflineNotice(onRetry: () => _refresh(context)),
              ],
            );
          },
        ),
        // «Aggiorna database» e «Indirizzo del database» sulla stessa riga
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              Expanded(
                child: AsyncActionButton(
                  key: const Key('catalog-refresh'),
                  label: 'Aggiorna database',
                  icon: Icons.cloud_download_outlined,
                  filled: true,
                  errorTitle: 'Aggiornamento non riuscito',
                  onPressed: () => _refresh(context),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  key: const Key('catalog-url'),
                  onPressed: () => _editUrl(context),
                  icon: const Icon(Icons.link),
                  label: const Text('Indirizzo del database'),
                ),
              ),
            ],
          ),
        ),
        const CatalogDownloadProgress(),
      ],
    );
  }

  /// Accesso, test d'ingresso, OFA e inglese come li descrive l'ateneo; il
  /// testo completo («Accesso e OFA») si apre dalla riga «Accesso».
  List<Widget> _ammissione(BuildContext context, Ammissione a) {
    final dettagli = a.requisiti == null
        ? null
        : TextButton.icon(
            key: const Key('accesso-ofa'),
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            onPressed: () => _showRequisiti(context, a),
            icon: const Icon(Icons.rule_outlined, size: 18),
            label: const Text('Accesso e OFA'),
          );
    return [
      if (a.accesso != null)
        AccessoRow(value: a.accesso!, action: dettagli)
      else if (dettagli != null)
        Align(alignment: Alignment.centerLeft, child: dettagli),
      if (a.test.isNotEmpty) InfoRow("Test d'ingresso", a.test.join(', ')),
      if (a.ofa != null)
        InfoRow(
          'OFA',
          a.ofa!
              ? 'previsti se la verifica iniziale non è superata'
              : 'non previsti',
        ),
      if (a.livelloInglese != null)
        InfoRow('Inglese richiesto', 'livello ${a.livelloInglese}'),
    ];
  }

  /// Testo completo dei requisiti di accesso e degli OFA, con la fonte.
  Future<void> _showRequisiti(BuildContext context, Ammissione a) =>
      showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Accesso e OFA'),
          content: SingleChildScrollView(
            child: SelectableText(
              [
                a.requisiti!,
                if (a.fonte != null) 'Fonte: ${a.fonte}',
              ].join('\n\n'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Chiudi'),
            ),
          ],
        ),
      );

  Future<void> _changeCurriculum(BuildContext context, String? v) async {
    final s = context.read<AppServices>();
    try {
      final r = await PathSetupService(s).changeCurriculum(v);
      if (context.mounted) {
        showSnack(
          context,
          r.imported
              ? 'Percorso aggiornato: ${r.courses} insegnamenti nel piano.'
              : (r.message ?? 'Percorso aggiornato.'),
        );
      }
    } catch (e) {
      if (context.mounted) showSnack(context, 'Cambio non riuscito: $e');
    }
  }

  Future<void> _refresh(BuildContext context) async {
    final s = context.read<AppServices>();
    final cal = CalendarExport(s);
    // file .ics solo dove il calendario di sistema non si collega (macOS) e
    // se lo studente l'ha scelto; altrove le nuove prove ci vanno da sole
    final AggiornamentoDatabase agg;
    var ics = false;
    var before = <int?>{};
    try {
      ics = !s.reminders.calendar.supported && await cal.enabled();
      before = {
        if (ics)
          for (final e in await cal.pendingWithDate()) e.id,
      };
      agg = await aggiornaDatabase(s);
    } catch (e) {
      if (context.mounted) {
        showSnack(context, 'Aggiornamento non riuscito: $e');
      }
      return;
    }
    if (!context.mounted) return;
    // senza connessione: messaggio che la chiede, con «Riprova»
    if (agg.offline) {
      mostraServeConnessione(
        context,
        message: agg.messaggioOffline,
        onRetry: () => _refresh(context),
      );
      return;
    }
    final r = agg.result!;
    // Nuove prove con una data dal database: «Aggiungi al calendario»?
    final added = [
      if (ics)
        for (final e in await cal.pendingWithDate())
          if (!before.contains(e.id)) e,
    ];
    if (added.isNotEmpty && context.mounted) {
      final ok = await confirmDialog(
        context,
        'Nuove date d\'esame',
        'Il database ha aggiunto ${added.length} '
            '${added.length == 1 ? 'prova' : 'prove'} con una data. '
            'Aggiungerle al calendario?',
      );
      if (ok) {
        final opened = await cal.open(added, name: 'nuove prove');
        if (context.mounted) showLaunchResult(context, opened);
      }
    }
    if (!context.mounted) return;
    showSnack(
      context,
      r.imported
          ? 'Piano aggiornato: ${r.courses} insegnamenti, ${r.books} libri '
                '(${r.source?.label ?? ''}).'
          : (r.message ?? 'Nessun aggiornamento.'),
    );
  }

  Future<void> _editUrl(BuildContext context) async {
    final s = context.read<AppServices>();
    final current = await s.catalog.baseUrl();
    if (!context.mounted) return;
    final v = await showTextEditDialog(
      context,
      title: 'Indirizzo del database',
      initialValue: current,
      label: 'Cartella del database (URL)',
      hint: kDefaultCatalogBaseUrl,
      validator: (v) {
        if (v.isEmpty) return null;
        final uri = Uri.tryParse(v);
        return (uri == null ||
                !(uri.isScheme('https') || uri.isScheme('http')) ||
                uri.host.isEmpty)
            ? 'Usa un URL http(s)://…'
            : null;
      },
    );
    if (v == null) return;
    await s.catalog.setBaseUrl(v);
    s.revision.bump();
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}

/// Riga «Accesso» con, sulla stessa riga, «Accesso e OFA» (testo completo).
/// Su schermi stretti il pulsante va sotto il valore, sempre nella riga.
class AccessoRow extends StatelessWidget {
  const AccessoRow({super.key, required this.value, this.action});
  final String value;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    if (action == null) return InfoRow('Accesso', value);
    final theme = Theme.of(context);
    final label = SizedBox(
      width: 150,
      child: Text(
        'Accesso',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
    final text = SelectableText(value, style: theme.textTheme.bodyMedium);
    return Padding(
      key: const Key('accesso-row'),
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 480;
          return Row(
            crossAxisAlignment: wide
                ? CrossAxisAlignment.center
                : CrossAxisAlignment.start,
            children: [
              label,
              Expanded(
                child: wide
                    ? text
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [text, action],
                      ),
              ),
              if (wide) ...[const SizedBox(width: 8), action],
            ],
          );
        },
      ),
    );
  }
}
