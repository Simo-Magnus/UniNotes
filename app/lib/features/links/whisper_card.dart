import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/power.dart';
import '../../core/services/whisper_service.dart';
import '../../core/theme/app_tokens.dart';
import '../../repositories/settings_repository.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart' show kMissing;
import '../notes/background_jobs.dart';
import 'links_widgets.dart';

/// Nome del lavoro in background che scarica [m].
String whisperDownloadTitle(WhisperModelInfo m) => 'Download Whisper · ${m.id}';

class _WhisperState {
  const _WhisperState(this.status, this.ffmpeg, this.partial, this.selected);
  final WhisperStatus status;
  final String? ffmpeg;
  final Map<String, int> partial;
  final WhisperModelInfo? selected;
}

/// Whisper in locale: tabella dei modelli con download, programma
/// whisper.cpp (PC) e modello usato per le trascrizioni.
class WhisperCard extends StatefulWidget {
  const WhisperCard({super.key});

  @override
  State<WhisperCard> createState() => _WhisperCardState();
}

class _WhisperCardState extends State<WhisperCard> {
  late final AppServices _s = context.read<AppServices>();
  WhisperService get _w => _s.whisper;
  late Future<_WhisperState> _future = _load();

  Future<_WhisperState> _load() async {
    final st = await _w.status();
    return _WhisperState(
      st,
      st.engine == WhisperEngineKind.cli ? await _w.ffmpeg() : null,
      {for (final m in kWhisperModels) m.id: await _w.partialBytes(m)},
      await _w.pickModel(st.models),
    );
  }

  void _reload() {
    if (mounted) {
      setState(() {
        _future = _load();
      });
    }
  }

  Future<void> _download(WhisperModelInfo m) async {
    if (!m.italianOk) {
      final ok = await confirmDialog(
        context,
        'Modello non adatto all\'italiano',
        '${m.id} è addestrato solo in inglese: le lezioni in italiano verrebbero '
            'trascritte male o tradotte. Scaricarlo comunque?',
      );
      if (!ok) return;
    }
    final cancel = CancelToken();
    _s.jobs.start(whisperDownloadTitle(m), onCancel: cancel.cancel, (
      report,
    ) async {
      await for (final p in _w.install(m, cancel: cancel)) {
        report(p.phase, p.fraction);
      }
      if (await _w.selectedModelId() == null) {
        await _w.setSelectedModel(m.id);
      }
      return null;
    }, onFinished: (_) => _reload());
  }

  void _installFfmpeg() {
    final cancel = CancelToken();
    _s.jobs.start('Download ffmpeg', onCancel: cancel.cancel, (report) async {
      await for (final p in _w.installFfmpeg(cancel: cancel)) {
        report(p.phase, p.fraction);
      }
      return null;
    }, onFinished: (_) => _reload());
  }

  Future<void> _delete(WhisperModelInfo m) async {
    if (!await confirmDialog(
      context,
      'Eliminare ${m.id}?',
      'Il file del modello (${m.disk}) viene cancellato. Potrai riscaricarlo.',
    )) {
      return;
    }
    await _w.deleteModel(m);
    if (await _w.selectedModelId() == m.id) await _w.setSelectedModel(null);
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _s.jobs,
      builder: (context, _) => FutureBuilder<_WhisperState>(
        future: _future,
        builder: (context, snap) {
          final d = snap.data;
          return LinksCard(
            title: 'Whisper',
            icon: Icons.graphic_eq,
            subtitle:
                'Trascrizione offline. Scarica il modello più adatto per il tuo '
                'dispositivo.',
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
      ),
    );
  }

  List<Widget> _content(BuildContext context, _WhisperState d) {
    final st = d.status;
    final rec = recommendedWhisperModel(phone: _w.isPhone);
    final models = whisperModelsFor(_w.platform);
    final installed = [
      for (final m in kWhisperModels)
        if (st.models.contains(m.id)) m,
    ];
    return [
      StatusLine(_engineText(st), ok: st.engineReady),
      const SizedBox(height: 6),
      StatusLine(
        installed.isEmpty
            ? 'Nessun modello scaricato. Consigliato: ${rec.id} (${rec.disk}).'
            : 'Modello usato: ${d.selected?.id ?? kMissing}',
        ok: installed.isNotEmpty,
      ),
      const NoteText(
        'Con un modello scaricato il registratore mostra anche la '
        'trascrizione dal vivo mentre registri.',
        icon: Icons.subtitles_outlined,
      ),
      if (_w.isPhone)
        const NoteText(
          'Sul telefono un\'ora di lezione può richiedere da 20 minuti a oltre '
          'un\'ora con «small» (molto di più con i modelli grandi): tieni l\'app '
          'aperta e il telefono in carica. Per lezioni lunghe Gemini è più rapido.',
          icon: Icons.battery_charging_full,
        ),
      if (installed.length > 1) ...[
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          style: Theme.of(context).textTheme.bodyLarge,
          isExpanded: true,
          initialValue: d.selected?.id,
          decoration: const InputDecoration(labelText: 'Modello da usare'),
          items: [
            for (final m in installed)
              DropdownMenuItem(value: m.id, child: Text(m.id)),
          ],
          onChanged: (v) async {
            await _w.setSelectedModel(v);
            _reload();
          },
        ),
      ],
      if (!st.engineReady && _w.canDownloadCli) ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            LinkButton(
              label: 'Scarica il programma whisper.cpp (≈ 8 MB)',
              icon: Icons.download_outlined,
              onPressed: () async {
                final cancel = CancelToken();
                _s.jobs.start('Download whisper.cpp', onCancel: cancel.cancel, (
                  report,
                ) async {
                  await for (final p in _w.installCli(cancel: cancel)) {
                    report(p.phase, p.fraction);
                  }
                  return null;
                }, onFinished: (_) => _reload());
              },
            ),
          ],
        ),
      ],
      for (final j in _s.jobs.all.where(
        (j) =>
            j.state != JobState.done &&
            (j.title == 'Download whisper.cpp' || j.title == 'Download ffmpeg'),
      ))
        _JobProgress(job: j),
      const SizedBox(height: 4),
      // Elenco dei modelli a tendina, chiuso: occuperebbe mezza pagina.
      AdvancedSection(
        key: const Key('whisper-models'),
        title: d.selected == null
            ? 'Modelli di trascrizione'
            : 'Modelli di trascrizione · in uso: ${d.selected!.id}',
        children: [
          Text(
            'Fonti: whisper.cpp e OpenAI',
            style: TextStyle(fontSize: 11, color: context.tokens.textMuted),
          ),
          const SizedBox(height: 4),
          LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 900
                ? _table(context, models, d, rec)
                : Column(
                    children: [
                      for (final m in models) _tile(context, m, d, rec),
                    ],
                  ),
          ),
        ],
      ),
      _ChargingOnlySwitch(settings: _s.settings, phone: _w.isPhone),
      // Sul telefono non c'è nulla di avanzato: niente sezione vuota.
      if (_advanced(context, d) case final adv when adv.isNotEmpty)
        AdvancedSection(children: adv),
    ];
  }

  String _engineText(WhisperStatus st) {
    if (_w.isPhone) {
      return 'whisper.cpp incluso nell\'app: basta scaricare un modello '
          '(consigliato $kRecommendedPhoneModel; $kLightPhoneModel sui telefoni meno recenti).';
    }
    if (st.engine == WhisperEngineKind.plugin) {
      return 'Mac: uso whisper.cpp incluso nell\'app. Per lezioni lunghe è più '
          'veloce whisper-cli di Homebrew («brew install whisper-cpp»): verrà '
          'trovato da solo.';
    }
    if (st.cli != null) {
      return 'Programma whisper.cpp pronto (${st.cli!.path}).';
    }
    if (_w.host == WhisperHost.macos) {
      return 'whisper-cli non trovato: installalo con Homebrew o indicalo in Avanzate.';
    }
    return 'Manca il programma whisper.cpp (≈ 8 MB): si scarica insieme al primo '
        'modello.';
  }

  List<Widget> _advanced(BuildContext context, _WhisperState d) => [
    if (!_w.isPhone)
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          LinkButton(
            label: 'Indica whisper-cli…',
            icon: Icons.folder_open_outlined,
            onPressed: () async {
              final f = await FilePicker.pickFile(
                dialogTitle: 'Seleziona whisper-cli',
              );
              if (f?.path == null) return;
              await _w.setCliPath(f!.path);
              _reload();
            },
          ),
          if (d.status.engine == WhisperEngineKind.cli && d.ffmpeg == null)
            LinkButton(
              label: _w.canDownloadCli
                  ? 'Scarica ffmpeg (riserva per i formati audio rari)'
                  : 'ffmpeg mancante: «brew install ffmpeg»',
              icon: Icons.transform,
              onPressed: _w.canDownloadCli
                  ? () async => _installFfmpeg()
                  : null,
            ),
        ],
      ),
    if (!_w.isPhone)
      const NoteText(
        '«Indica whisper-cli…» serve solo se hai già whisper.cpp (il programma '
        'whisper-cli) in un\'altra cartella: sceglilo e l\'app userà quello al '
        'posto del suo. Le registrazioni .m4a si convertono con gli strumenti '
        'del sistema (Windows, macOS); «Scarica ffmpeg» serve solo se la '
        'conversione non riesce (formati audio rari).',
      ),
    if (_w.host == WhisperHost.macos)
      const NoteText(
        'Mac: non serve installare nulla, l\'app usa il suo whisper.cpp. Per '
        'trascrivere più in fretta le lezioni lunghe apri il Terminale e scrivi '
        '«brew install whisper-cpp ffmpeg» (serve Homebrew, brew.sh): al '
        'riavvio l\'app trova e usa da sola quella versione.',
      ),
  ];

  Widget _actions(BuildContext context, WhisperModelInfo m, _WhisperState d) {
    final job = _s.jobs.runningTitled(whisperDownloadTitle(m));
    if (job != null) return _JobProgress(job: job, compact: true);
    final failed = _s.jobs.all
        .where(
          (j) =>
              j.title == whisperDownloadTitle(m) && j.state == JobState.failed,
        )
        .lastOrNull;
    final installed = d.status.models.contains(m.id);
    final partial = d.partial[m.id] ?? 0;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (installed)
          OutlinedButton.icon(
            onPressed: () => _delete(m),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Elimina'),
          )
        else
          OutlinedButton.icon(
            onPressed: () => _download(m),
            icon: const Icon(Icons.download_outlined, size: 18),
            label: Text(partial > 0 ? 'Riprendi' : 'Scarica'),
          ),
        LinkText('Pagina ufficiale del modello', '${m.officialPageUrl}'),
        if (failed != null && !installed)
          Tooltip(
            message: failed.error ?? '',
            child: Icon(
              Icons.error_outline,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  Widget _name(
    BuildContext context,
    WhisperModelInfo m,
    _WhisperState d,
    WhisperModelInfo rec,
  ) {
    final t = context.tokens;
    final installed = d.status.models.contains(m.id);
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(m.id, style: const TextStyle(fontWeight: FontWeight.w600)),
        if (m.id == rec.id)
          Text(
            'consigliato',
            style: TextStyle(fontSize: 11, color: t.cyanSoft),
          ),
        if (installed)
          Text('scaricato', style: TextStyle(fontSize: 11, color: t.cyanSoft)),
        if (!m.italianOk)
          Text(
            'non adatto all\'italiano',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
      ],
    );
  }

  Widget _table(
    BuildContext context,
    List<WhisperModelInfo> models,
    _WhisperState d,
    WhisperModelInfo rec,
  ) {
    const cols = [
      'Modello',
      'Parametri',
      'Peso su disco',
      'RAM',
      'GPU/VRAM',
      'Velocità',
      'Italiano',
      'Lingue',
      'Hardware minimo',
      'Piattaforme',
      '',
    ];
    Widget cell(String s, {double w = 110}) => SizedBox(
      width: w,
      child: Text(s, style: const TextStyle(fontSize: 12)),
    );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 14,
        dataRowMinHeight: 56,
        dataRowMaxHeight: 96,
        headingTextStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: context.tokens.textSecondary,
        ),
        columns: [for (final c in cols) DataColumn(label: Text(c))],
        rows: [
          for (final m in models)
            DataRow(
              cells: [
                DataCell(
                  SizedBox(width: 170, child: _name(context, m, d, rec)),
                ),
                DataCell(cell(m.params, w: 64)),
                DataCell(cell(m.disk, w: 80)),
                DataCell(cell(m.ram, w: 100)),
                DataCell(cell(m.gpu, w: 130)),
                DataCell(cell(m.speed, w: 90)),
                DataCell(cell(m.italian, w: 170)),
                DataCell(cell(m.languages, w: 100)),
                DataCell(cell(m.minHardware, w: 190)),
                DataCell(
                  cell(m.platforms.map((p) => p.label).join(', '), w: 90),
                ),
                DataCell(SizedBox(width: 200, child: _actions(context, m, d))),
              ],
            ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    WhisperModelInfo m,
    _WhisperState d,
    WhisperModelInfo rec,
  ) {
    final t = context.tokens;
    Widget row(String k, String v) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(k, style: TextStyle(fontSize: 12, color: t.textMuted)),
          ),
          Expanded(child: Text(v, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        title: _name(context, m, d, rec),
        subtitle: Text(
          '${m.disk} · RAM ${m.ram} · ${m.italian}',
          style: const TextStyle(fontSize: 12),
        ),
        expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          row('Parametri', m.params),
          row('GPU/VRAM', m.gpu),
          row('Velocità', m.speed),
          row('Lingue', m.languages),
          row('Hardware minimo', m.minHardware),
          row('Piattaforme', m.platforms.map((p) => p.label).join(', ')),
          if (m.note != null) row('Nota', m.note!),
          const SizedBox(height: 6),
          _actions(context, m, d),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

/// Avanzamento di un download con «Annulla».
class _JobProgress extends StatelessWidget {
  const _JobProgress({required this.job, this.compact = false});
  final BackgroundJob job;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final theme = Theme.of(context);
    final failed = job.state == JobState.failed;
    return Padding(
      padding: EdgeInsets.only(top: compact ? 0 : 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            failed ? (job.error ?? 'Non riuscito') : job.phase,
            maxLines: compact ? 2 : 4,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: failed ? theme.colorScheme.error : null,
            ),
          ),
          if (!failed) ...[
            const SizedBox(height: 4),
            LinearProgressIndicator(value: job.fraction),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: failed
                ? TextButton(
                    onPressed: () => s.jobs.dismiss(job),
                    child: const Text('Chiudi'),
                  )
                : TextButton(
                    onPressed: job.onCancel == null || job.cancelled
                        ? null
                        : () => s.jobs.cancel(job),
                    child: const Text('Annulla'),
                  ),
          ),
        ],
      ),
    );
  }
}

/// «Trascrivi solo quando il computer (o il telefono) si sta caricando»: le
/// trascrizioni avviate a batteria aspettano il caricabatterie (risparmio
/// energetico; Whisper usa molto il processore).
class _ChargingOnlySwitch extends StatefulWidget {
  const _ChargingOnlySwitch({required this.settings, required this.phone});
  final SettingsRepository settings;
  final bool phone;

  @override
  State<_ChargingOnlySwitch> createState() => _ChargingOnlySwitchState();
}

class _ChargingOnlySwitchState extends State<_ChargingOnlySwitch> {
  bool? _on;

  @override
  void initState() {
    super.initState();
    Power.whisperOnlyCharging(widget.settings).then((v) {
      if (mounted) setState(() => _on = v);
    });
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    title: Text(
      'Trascrivi solo quando il ${widget.phone ? 'telefono' : 'computer'} '
      'si sta caricando',
    ),
    subtitle: const Text(
      'Le trascrizioni avviate a batteria partono appena colleghi il '
      'caricabatterie.',
    ),
    value: _on ?? false,
    onChanged: _on == null
        ? null
        : (v) async {
            await Power.setWhisperOnlyCharging(widget.settings, v);
            if (mounted) setState(() => _on = v);
          },
  );
}
