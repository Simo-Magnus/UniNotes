import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/academic_year.dart';
import '../../core/catalog/catalog_models.dart';
import '../../core/catalog/catalog_search.dart';
import '../../core/catalog/catalog_service.dart';
import '../../core/catalog/curricula.dart';
import '../../core/catalog/path_setup.dart';
import '../../core/constants/build_flags.dart';
import '../../core/constants/text_limits.dart';
import '../../core/feedback/feedback_service.dart';
import '../../core/reminders/notification_prefs.dart';
import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import '../../core/theme/display_prefs.dart';
import '../../repositories/settings_repository.dart';
import '../../widgets/catalog_download.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import '../exams/exam_form.dart' show kCalendarOfferedKey;
import '../links/ai_assistants.dart';
import '../links/link_settings.dart';
import '../settings/logic/exclusion_cleanup.dart';
import '../settings/sections/appearance_section.dart';
import 'percorso_field.dart';

part 'onboarding_steps.dart';

/// Passi dell'onboarding (in ordine di percorso).
enum OnboardingStep {
  /// Contrasto e grandezza del testo, prima di tutto il resto.
  aspetto,
  tipo,
  regione,
  universita,
  tipoCorso,
  corso,
  manuale,
  anno,
  annoFuoriCorso,
  fine,

  /// Dopo l'import del piano (solo al primo avvio): AI di riferimento,
  /// avvisi (permesso delle notifiche), calendario del telefono, gruppi da
  /// nascondere.
  ai,
  notifiche,
  calendario,
  esclusioni,
}

extension on OnboardingStep {
  /// Passo «di riferimento» nella barra di avanzamento: inserimento a mano e
  /// fuori corso contano come il passo che sostituiscono.
  OnboardingStep get slot => switch (this) {
    OnboardingStep.manuale => OnboardingStep.corso,
    OnboardingStep.annoFuoriCorso => OnboardingStep.anno,
    _ => this,
  };

  /// Passi che non usano l'elenco delle università.
  bool get ownStep =>
      this == OnboardingStep.aspetto || index >= OnboardingStep.ai.index;
}

/// Onboarding: aspetto (contrasto e caratteri) → tipo di università (o
/// ricerca diretta) → regione → università → tipo di laurea → corso → anno
/// frequentato → riepilogo, download dei dati del corso e import del piano
/// → AI di riferimento → avvisi → calendario (telefono) → gruppi da
/// nascondere (OFA, lingua, facoltativi). Ogni passo ha al massimo due
/// pulsanti. Al primo avvio; da Impostazioni → «Cambia corso» si rifanno solo
/// i passi del percorso (aspetto, AI, avvisi ed esclusioni restano).
///
/// Apre la scelta del percorso per cambiare università, corso o anno
/// (Impostazioni → «Cambia corso»). Voti, note e libri scelti restano.
Future<void> showChangePath(BuildContext context) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (c) => OnboardingFlow(
          canCancel: true,
          onFinished: () => Navigator.of(c).pop(),
        ),
      ),
    );

class OnboardingFlow extends StatefulWidget {
  const OnboardingFlow({super.key, this.onFinished, this.canCancel = false});

  /// Chiamato dopo "Vai all'app" (profilo già salvato e caricato).
  final VoidCallback? onFinished;

  /// Dal primo passo si può tornare indietro (aperto dalle Impostazioni):
  /// cambio di corso, solo i passi del percorso.
  final bool canCancel;

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _CatalogData {
  const _CatalogData(this.universita, this.indice);
  final UniversitaCatalog universita;
  final IndiceCorsi indice;
}

class _OnboardingFlowState extends State<OnboardingFlow> {
  late final AppServices _s = context.read<AppServices>();
  late final Future<_CatalogData> _data = _loadData();

  /// Primo avvio: anche aspetto, AI, avvisi, calendario ed esclusioni.
  bool get _full => !widget.canCancel;

  late final List<OnboardingStep> _history = [
    _full ? OnboardingStep.aspetto : OnboardingStep.tipo,
  ];
  OnboardingStep get _step => _history.last;

  /// Passi dopo l'import (primo avvio): avvisi solo se il sistema li ha e
  /// non sono già stati chiesti, calendario solo sul telefono (su Windows
  /// Outlook si collega da Impostazioni o al primo esame con una data).
  List<OnboardingStep> _tail = const [
    OnboardingStep.ai,
    OnboardingStep.esclusioni,
  ];

  /// Passi nella barra di avanzamento.
  List<OnboardingStep> get _order => [
    if (_full) OnboardingStep.aspetto,
    OnboardingStep.tipo,
    OnboardingStep.regione,
    OnboardingStep.universita,
    OnboardingStep.tipoCorso,
    OnboardingStep.corso,
    OnboardingStep.anno,
    OnboardingStep.fine,
    if (_full) ..._tail,
  ];

  @override
  void initState() {
    super.initState();
    if (_full) _loadTail();
  }

  Future<void> _loadTail() async {
    final r = _s.reminders;
    final notif =
        r.notificationsSupported &&
        await _s.settings.get(NotificationKeys.consent) == null &&
        await _s.settings.get(NotificationKeys.asked) == null;
    final cal =
        r.calendar.backend?.id == 'device' &&
        !await r.calendar.enabled() &&
        await _s.settings.get(kCalendarOfferedKey) == null;
    if (!mounted) return;
    setState(() {
      _tail = [
        OnboardingStep.ai,
        if (notif) OnboardingStep.notifiche,
        if (cal) OnboardingStep.calendario,
        OnboardingStep.esclusioni,
      ];
    });
  }

  TipoAteneo? _tipo;
  String? _regione;
  Ateneo? _ateneo;
  TipoCorso? _tipoCorso;
  CorsoIndice? _corso;
  String? _manualName;
  String? _manualClass;
  int? _manualDuration;
  int? _year;
  bool _fuoriCorso = false;

  Future<_CatalogData> _loadData() async {
    final results = await Future.wait<Object>([
      _s.catalog.universita(),
      _s.catalog.indiceCorsi(),
    ]);
    return _CatalogData(
      results[0] as UniversitaCatalog,
      results[1] as IndiceCorsi,
    );
  }

  void _go(OnboardingStep next) => setState(() => _history.add(next));

  bool get _canGoBack => _history.length > 1;

  /// Import del piano in corso nel riepilogo: niente ritorno indietro.
  bool _busy = false;

  void _setBusy(bool v) {
    if (mounted && v != _busy) setState(() => _busy = v);
  }

  void _back() {
    if (_busy) return;
    if (_canGoBack) {
      setState(() => _history.removeLast());
    } else if (widget.canCancel) {
      Navigator.of(context).maybePop();
    }
  }

  /// Piano importato: al primo avvio i passi finali (senza ritorno al
  /// riepilogo, il piano è già importato), altrimenti si torna all'app.
  void _afterImport() {
    if (!_full) {
      _finish();
      return;
    }
    setState(
      () => _history
        ..clear()
        ..add(_tail.first),
    );
  }

  /// Passo successivo dopo l'import, o l'app.
  void _nextTail() {
    final i = _tail.indexOf(_step);
    if (i >= 0 && i + 1 < _tail.length) {
      _go(_tail[i + 1]);
    } else {
      _finish();
    }
  }

  Future<void> _finish() async {
    await _s.loadProfile();
    _s.revision.bump();
    widget.onFinished?.call();
  }

  int get _duration =>
      _corso?.durataAnni ?? _manualDuration ?? _tipoCorso?.durataTipica ?? 3;

  // -------------------------------------------------------------- scelte

  void _pickTipo(TipoAteneo t) {
    _tipo = t;
    _regione = null;
    _go(
      tipoSenzaRegione(t) ? OnboardingStep.universita : OnboardingStep.regione,
    );
  }

  void _pickRegione(String r) {
    _regione = r;
    _go(OnboardingStep.universita);
  }

  void _pickAteneo(Ateneo a, {bool fromSearch = false}) {
    _ateneo = a;
    if (fromSearch) {
      _tipo = a.tipo;
      _regione = null;
    }
    _go(OnboardingStep.tipoCorso);
  }

  void _pickTipoCorso(TipoCorso t) {
    _tipoCorso = t;
    _corso = null;
    _go(OnboardingStep.corso);
  }

  void _pickCorso(CorsoIndice c) {
    _corso = c;
    _manualName = null;
    _go(OnboardingStep.anno);
  }

  void _pickManual(String name, String? classe, int duration) {
    _corso = null;
    _manualName = name;
    _manualClass = classe;
    _manualDuration = duration;
    _go(OnboardingStep.anno);
  }

  void _pickYear(int? year) {
    if (year == null) {
      _fuoriCorso = true;
      _go(OnboardingStep.annoFuoriCorso);
      return;
    }
    if (_step == OnboardingStep.anno) _fuoriCorso = false;
    _year = year;
    _go(OnboardingStep.fine);
  }

  PathSelection get _selection => PathSelection(
    ateneo: _ateneo!,
    tipo: _tipoCorso ?? TipoCorso.altro,
    corso: _corso,
    manualName: _manualName,
    manualClass: _manualClass,
    manualDuration: _manualDuration,
    year: _year ?? 1,
    fuoriCorso: _fuoriCorso,
  );

  // ---------------------------------------------------------------- vista

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy && !_canGoBack && widget.canCancel,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _canGoBack) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leading: (_canGoBack || widget.canCancel)
              ? IconButton(
                  tooltip: 'Indietro',
                  icon: const Icon(Icons.arrow_back),
                  onPressed: _busy ? null : _back,
                )
              : null,
          title: const Text('Il tuo percorso'),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(22),
            child: _Progress(
              position: _order.indexOf(_step.slot) + 1,
              total: _order.length,
            ),
          ),
        ),
        body: _step.ownStep
            ? SafeArea(
                top: false,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 720),
                    child: KeyedSubtree(
                      key: ValueKey(_step),
                      child: _buildOwnStep(),
                    ),
                  ),
                ),
              )
            : FutureBuilder<_CatalogData>(
                future: _data,
                builder: (context, snap) {
                  if (snap.hasError) {
                    return EmptyState(
                      icon: Icons.error_outline,
                      message:
                          'Elenco delle università non disponibile: '
                          '${snap.error}',
                    );
                  }
                  if (!snap.hasData) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return SafeArea(
                    top: false,
                    child: Align(
                      alignment: Alignment.topCenter,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: _buildStep(snap.data!),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  /// Passi senza dati del catalogo.
  Widget _buildOwnStep() => switch (_step) {
    OnboardingStep.aspetto => _AppearanceStep(
      onNext: () => _go(OnboardingStep.tipo),
    ),
    OnboardingStep.ai => _AiStep(onNext: _nextTail),
    OnboardingStep.notifiche => _NotificationsStep(onNext: _nextTail),
    OnboardingStep.calendario => _CalendarStep(onNext: _nextTail),
    _ => _ExclusionsStep(onDone: _finish),
  };

  Widget _buildStep(_CatalogData d) => switch (_step) {
    OnboardingStep.tipo => _TipoStep(
      atenei: d.universita.universita,
      onTipo: _pickTipo,
      onAteneo: (a) => _pickAteneo(a, fromSearch: true),
    ),
    OnboardingStep.regione => _ListStep<String>(
      title: 'In quale regione?',
      subtitle: _tipo!.description,
      items: regioniPerTipo(d.universita.universita, _tipo!),
      label: (r) => r,
      detail: (r) {
        final n = ateneiPer(d.universita.universita, _tipo!, regione: r).length;
        return n == 1 ? '1 ateneo' : '$n atenei';
      },
      onTap: _pickRegione,
    ),
    OnboardingStep.universita => _ListStep<Ateneo>(
      title: 'Qual è la tua università?',
      subtitle: [_tipo!.description, ?_regione].join(' · '),
      items: ateneiPer(d.universita.universita, _tipo!, regione: _regione),
      label: (a) => a.nome,
      detail: (a) => a.cittaIn(_regione).join(', '),
      onTap: _pickAteneo,
    ),
    OnboardingStep.tipoCorso => _ListStep<TipoCorso>(
      title: 'Che tipo di corso frequenti?',
      subtitle: _ateneo!.nome,
      items: tipiCorsoDisponibili(d.indice, _ateneo!.id),
      label: (t) => t.label,
      detail: (t) {
        final n = corsiPer(d.indice, _ateneo!.id, t).length;
        return [
          t.description,
          if (n > 0) n == 1 ? '1 corso' : '$n corsi',
        ].join(' · ');
      },
      onTap: _pickTipoCorso,
    ),
    OnboardingStep.corso => _CorsoStep(
      ateneo: _ateneo!,
      tipo: _tipoCorso!,
      corsi: corsiPer(d.indice, _ateneo!.id, _tipoCorso!),
      indice: d.indice,
      onCorso: _pickCorso,
      onManual: () => _go(OnboardingStep.manuale),
    ),
    OnboardingStep.manuale => _ManualStep(
      tipo: _tipoCorso!,
      initialName: _manualName,
      onDone: _pickManual,
    ),
    OnboardingStep.anno => _YearStep(
      title: 'Che anno frequenti?',
      subtitle:
          '${_corso?.nome ?? _manualName} · anno accademico '
          '${AcademicYear.current().label}',
      duration: _duration,
      allowFuoriCorso: true,
      onYear: _pickYear,
    ),
    OnboardingStep.annoFuoriCorso => _YearStep(
      title: 'Quale anno del piano stai completando?',
      subtitle: 'Fuori corso: scegli l\'anno con gli esami che ti mancano.',
      duration: _duration,
      allowFuoriCorso: false,
      onYear: _pickYear,
    ),
    OnboardingStep.fine => _SummaryStep(
      selection: _selection,
      changing: widget.canCancel,
      onDone: _afterImport,
      onBusy: _setBusy,
    ),
    // passi senza catalogo: costruiti da [_buildOwnStep]
    _ => const SizedBox.shrink(),
  };
}

class _Progress extends StatelessWidget {
  const _Progress({required this.position, required this.total});
  final int position;
  final int total;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Row(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: position / total,
                minHeight: 4,
                color: t.cyan,
                backgroundColor: t.textPrimary.withValues(alpha: 0.09),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Passo $position di $total',
            style: TextStyle(fontSize: 11, color: t.textMuted),
          ),
        ],
      ),
    );
  }
}

class _StepHeader extends StatelessWidget {
  const _StepHeader(this.title, this.subtitle);
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          if (subtitle != null && subtitle!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: theme.textTheme.bodyMedium),
          ],
        ],
      ),
    );
  }
}

/// Voce di una lista di scelta: card di vetro tutta toccabile.
class _OptionTile extends StatelessWidget {
  const _OptionTile({
    required this.title,
    this.subtitle,
    this.icon,
    required this.onTap,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: ListTile(
        minVerticalPadding: 12,
        leading: icon == null ? null : Icon(icon),
        title: Text(title),
        subtitle: subtitle == null || subtitle!.isEmpty
            ? null
            : Text(subtitle!),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}

// ------------------------------------------------------------ passo 1

class _TipoStep extends StatefulWidget {
  const _TipoStep({
    required this.atenei,
    required this.onTipo,
    required this.onAteneo,
  });
  final List<Ateneo> atenei;
  final ValueChanged<TipoAteneo> onTipo;
  final ValueChanged<Ateneo> onAteneo;

  @override
  State<_TipoStep> createState() => _TipoStepState();
}

class _TipoStepState extends State<_TipoStep> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static IconData _icon(TipoAteneo t) => switch (t) {
    TipoAteneo.statale => Icons.account_balance_outlined,
    TipoAteneo.nonStatale => Icons.school_outlined,
    TipoAteneo.ordinamentoSpeciale => Icons.workspace_premium_outlined,
    TipoAteneo.telematica => Icons.laptop_chromebook_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final results = _query.trim().isEmpty
        ? const <Ateneo>[]
        : searchAtenei(widget.atenei, _query);
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StepHeader(
          'Che università frequenti?',
          'Cerca il nome, la sigla o la città, oppure scegli il tipo di '
              'università.',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            key: const Key('onboarding-search'),
            controller: _search,
            textInputAction: TextInputAction.search,
            inputFormatters: TextLimits.max(TextLimits.search),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Es. Politecnico di Torino, Bicocca, Napoli…',
              suffixIcon: _query.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Cancella',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                    ),
            ),
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        if (_query.trim().isNotEmpty) ...[
          if (results.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text(
                'Nessuna università trovata: prova con un\'altra parola o '
                'scegli il tipo qui sotto.',
              ),
            ),
          for (final a in results)
            _OptionTile(
              title: a.nome,
              subtitle: a.citta.join(', '),
              onTap: () => widget.onAteneo(a),
            ),
          const SizedBox(height: 12),
        ],
        if (_query.trim().isEmpty)
          for (final t in TipoAteneo.values)
            _OptionTile(
              icon: _icon(t),
              title: t.label,
              subtitle: '${ateneiDiTipo(widget.atenei, t).length} atenei',
              onTap: () => widget.onTipo(t),
            ),
      ],
    );
  }
}

// ------------------------------------------------------ liste semplici

class _ListStep<T> extends StatelessWidget {
  const _ListStep({
    required this.title,
    required this.subtitle,
    required this.items,
    required this.label,
    required this.detail,
    required this.onTap,
  });
  final String title;
  final String? subtitle;
  final List<T> items;
  final String Function(T) label;
  final String Function(T) detail;
  final ValueChanged<T> onTap;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == 0) return _StepHeader(title, subtitle);
        final item = items[i - 1];
        return _OptionTile(
          title: label(item),
          subtitle: detail(item),
          onTap: () => onTap(item),
        );
      },
    );
  }
}

// ------------------------------------------------------------ passo 5

class _CorsoStep extends StatefulWidget {
  const _CorsoStep({
    required this.ateneo,
    required this.tipo,
    required this.corsi,
    required this.indice,
    required this.onCorso,
    required this.onManual,
  });
  final Ateneo ateneo;
  final TipoCorso tipo;
  final List<CorsoIndice> corsi;
  final IndiceCorsi indice;
  final ValueChanged<CorsoIndice> onCorso;
  final VoidCallback onManual;

  @override
  State<_CorsoStep> createState() => _CorsoStepState();
}

class _CorsoStepState extends State<_CorsoStep> {
  String _query = '';

  static String _lingua(String? l) => switch (l) {
    'it' => 'italiano',
    'en' => 'inglese',
    'it/en' => 'italiano e inglese',
    _ => l ?? '',
  };

  @override
  Widget build(BuildContext context) {
    final list = _query.trim().isEmpty
        ? widget.corsi
        : corsiPer(widget.indice, widget.ateneo.id, widget.tipo, query: _query);
    final manual = Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: OutlinedButton.icon(
        onPressed: widget.onManual,
        icon: const Icon(Icons.edit_outlined),
        label: const Text('Aggiungi corso'),
      ),
    );
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 24),
      itemCount: list.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StepHeader(
                'Qual è il tuo corso di laurea?',
                '${widget.tipo.label} · ${widget.ateneo.nome}',
              ),
              if (widget.corsi.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
                  child: Text(
                    'Il database non ha ancora i corsi di questo tipo per il '
                    'tuo ateneo',
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    key: const Key('onboarding-course-search'),
                    inputFormatters: TextLimits.max(TextLimits.search),
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Cerca per nome, classe o sede',
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
              if (widget.corsi.isEmpty) manual,
            ],
          );
        }
        if (i == list.length + 1) {
          return widget.corsi.isEmpty ? const SizedBox.shrink() : manual;
        }
        final c = list[i - 1];
        return _OptionTile(
          title: c.nome,
          subtitle: [
            if (c.classe != null) 'Classe ${c.classe}',
            ?c.sede,
            if (c.lingua != null) _lingua(c.lingua),
            if (c.durataAnni != null) '${c.durataAnni} anni',
          ].join(' · '),
          onTap: () => widget.onCorso(c),
        );
      },
    );
  }
}

class _ManualStep extends StatefulWidget {
  const _ManualStep({
    required this.tipo,
    required this.onDone,
    this.initialName,
  });
  final TipoCorso tipo;
  final String? initialName;
  final void Function(String name, String? classe, int duration) onDone;

  @override
  State<_ManualStep> createState() => _ManualStepState();
}

class _ManualStepState extends State<_ManualStep> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.initialName);
  final _classe = TextEditingController();
  late int _duration = widget.tipo.durataTipica ?? 3;

  @override
  void dispose() {
    _name.dispose();
    _classe.dispose();
    super.dispose();
  }

  void _submit() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final c = _classe.text.trim();
    widget.onDone(_name.text.trim(), c.isEmpty ? null : c, _duration);
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          _StepHeader(
            'Inserisci il tuo corso',
            '${widget.tipo.label}: gli insegnamenti potrai aggiungerli tu.',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: TextFormField(
              key: const Key('manual-name'),
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              inputFormatters: TextLimits.max(TextLimits.courseName),
              decoration: const InputDecoration(
                labelText: 'Nome del corso',
                hintText: 'Es. Scienze biologiche',
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Scrivi il nome del corso'
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextFormField(
              controller: _classe,
              inputFormatters: TextLimits.max(TextLimits.classCode),
              decoration: const InputDecoration(
                labelText: 'Classe di laurea (facoltativa)',
                hintText: 'Es. L-13',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: DropdownButtonFormField<int>(
              style: Theme.of(context).textTheme.bodyLarge,
              initialValue: _duration,
              decoration: const InputDecoration(labelText: 'Durata'),
              items: [
                for (var y = 1; y <= 6; y++)
                  DropdownMenuItem(
                    value: y,
                    child: Text(y == 1 ? '1 anno' : '$y anni'),
                  ),
              ],
              onChanged: (v) => setState(() => _duration = v ?? _duration),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
            child: Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _submit,
                child: const Text('Continua'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------ passo 6

class _YearStep extends StatelessWidget {
  const _YearStep({
    required this.title,
    required this.subtitle,
    required this.duration,
    required this.allowFuoriCorso,
    required this.onYear,
  });
  final String title;
  final String subtitle;
  final int duration;
  final bool allowFuoriCorso;

  /// null = "Fuori corso".
  final ValueChanged<int?> onYear;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _StepHeader(title, subtitle),
        for (var y = 1; y <= duration; y++)
          _OptionTile(title: planYearLabel(y), onTap: () => onYear(y)),
        if (allowFuoriCorso)
          _OptionTile(
            title: 'Fuori corso',
            subtitle: 'Hai superato la durata normale del corso',
            onTap: () => onYear(null),
          ),
      ],
    );
  }
}

// ------------------------------------------------------------ riepilogo

/// Fasi del riepilogo. Nulla si scarica prima che lo studente prema il
/// pulsante.
enum _Fase {
  /// In attesa del tocco su «Scarica il piano di studi».
  pronto,

  /// Download dei soli corsi dell'ateneo (servono per la scelta del
  /// percorso).
  corsi,

  /// Il corso ha più percorsi: si sceglie prima dell'import.
  percorso,

  /// Download degli altri file dell'ateneo e import del piano.
  importo,

  /// Piano importato (o percorso salvato senza piano).
  fatto,
}

class _SummaryStep extends StatefulWidget {
  const _SummaryStep({
    required this.selection,
    required this.onDone,
    this.onBusy,
    this.changing = false,
  });
  final PathSelection selection;

  /// Dopo l'import: «Continua» (primo avvio) o «Vai all'app» (cambio corso).
  final VoidCallback onDone;

  /// Import in corso (true) o finito: durante l'import non si torna
  /// indietro, così non parte un secondo import.
  final ValueChanged<bool>? onBusy;

  /// Aperto da «Cambia corso»: spiega che i dati del corso precedente
  /// restano salvati ma non si vedono se il corso di laurea cambia.
  final bool changing;

  @override
  State<_SummaryStep> createState() => _SummaryStepState();
}

class _SummaryStepState extends State<_SummaryStep> {
  late final AppServices _s = context.read<AppServices>();
  _Fase _fase = _Fase.pronto;
  PlanImportResult? _result;
  Object? _error;

  /// Download dei corsi non riuscito (offline, disco pieno, file non
  /// valido): avviso con «Riprova» e conferma senza piano.
  Object? _erroreCorsi;

  /// Percorsi del corso scelto (curricula, orientamenti); si sceglie solo se
  /// sono più d'uno.
  PercorsiCorso? _percorsi;
  String? _percorso;

  bool get _busy => _fase == _Fase.corsi || _fase == _Fase.importo;

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  /// Tocco sul pulsante principale: prima i corsi (e il percorso, se ce
  /// n'è più d'uno), poi il resto dei dati e l'import. Durante
  /// l'operazione il pulsante è disattivato; un download già in corso
  /// dello stesso ateneo (per esempio dopo un ritorno al riepilogo) si
  /// aspetta invece di avviarne un altro ([CatalogService.scaricaCorso]).
  Future<void> _avvia({bool senzaPiano = false}) async {
    if (_busy) return;
    final sel = widget.selection;
    if (senzaPiano || sel.isManual || _fase == _Fase.percorso) {
      return _importa(remote: !senzaPiano);
    }
    _set(() {
      _fase = _Fase.corsi;
      _error = null;
      _erroreCorsi = null;
    });
    try {
      // i file del corso precedente si eliminano solo all'import
      final d = await _s.catalog.scaricaCorso(
        sel.ateneo.id,
        sel.degreeId,
        pulisci: false,
        soloCorso: true,
      );
      if (!mounted) return;
      if (d.senzaRete) {
        _set(() {
          _fase = _Fase.pronto;
          _erroreCorsi = d.errore;
        });
        return;
      }
      PercorsiCorso? p;
      if (d.corsi) {
        final file = await _s.catalog.corsiAteneo(
          sel.ateneo.id,
          remote: false,
          scarica: false,
          corso: sel.degreeId,
        );
        final corso = file?.data.corso(sel.degreeId);
        if (corso != null) p = PercorsiCorso.di(corso);
      }
      if (!mounted) return;
      if (p != null && p.daScegliere) {
        final current = _s.profile.value;
        final scelto = p.valido(
          current?.degreeId == sel.degreeId ? current?.curriculum : null,
        );
        _set(() {
          _percorsi = p;
          _percorso = scelto;
          _fase = _Fase.percorso;
        });
        return;
      }
    } catch (e) {
      // (scaricaCorso non lancia: qui solo la lettura del file)
      _set(() {
        _fase = _Fase.pronto;
        _erroreCorsi = e;
      });
      return;
    }
    await _importa(remote: true);
  }

  Future<void> _importa({required bool remote}) async {
    if (_fase == _Fase.importo) return;
    _set(() {
      _fase = _Fase.importo;
      _error = null;
      _erroreCorsi = null;
    });
    widget.onBusy?.call(true);
    try {
      final r = await PathSetupService(_s)
          .apply(widget.selection.withPercorso(_percorso), remote: remote);
      _set(() {
        _result = r;
        _fase = _Fase.fatto;
      });
    } catch (e) {
      _set(() {
        _error = e;
        _fase = _percorsi != null ? _Fase.percorso : _Fase.pronto;
      });
    } finally {
      if (mounted) widget.onBusy?.call(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sel = widget.selection;
    final t = context.tokens;
    final aa = AcademicYear.current().label;
    final result = _result;
    final erroreCorsi = _erroreCorsi;
    final percorsi = _percorsi;
    final stato = switch (_fase) {
      _Fase.corsi => 'Scarico i dati del tuo corso…',
      _Fase.importo =>
        sel.isManual
            ? 'Salvo il tuo percorso…'
            : 'Scarico le sessioni d\'esame e importo il piano di studi…',
      _Fase.percorso =>
        'Il tuo corso ha più percorsi: scegli il tuo, poi importa il piano.',
      _ => null,
    };
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        _StepHeader(
          result == null ? 'Tutto giusto?' : 'Pronto!',
          result == null
              ? [
                  sel.isManual
                      ? 'Con «Conferma» salvo il tuo percorso: gli '
                            'insegnamenti potrai aggiungerli tu.'
                      : 'Con «Scarica il piano di studi» scarico gli '
                            'insegnamenti, i libri e le date d\'esame del '
                            'tuo corso: potrai cambiare tutto più tardi.',
                  if (widget.changing)
                    'Se cambi corso di laurea, insegnamenti, esami, voti, '
                        'studio e libri del corso precedente restano salvati '
                        'ma l\'app mostra solo il nuovo corso; tornando a '
                        'quello precedente ricompaiono.',
                ].join('\n\n')
              : null,
        ),
        GlassCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const CardHeader(title: 'Il mio percorso', icon: Icons.school),
              _SummaryRow('Università', sel.ateneo.nome),
              _SummaryRow(
                'Corso',
                [
                  sel.degreeName,
                  if ((sel.corso?.classe ?? sel.manualClass) != null)
                    'classe ${sel.corso?.classe ?? sel.manualClass}',
                ].join(' · '),
              ),
              _SummaryRow('Tipo', sel.tipo.label),
              _SummaryRow(
                'Anno',
                sel.fuoriCorso
                    ? 'Fuori corso · completo il ${planYearLabel(sel.year)}'
                    : '${planYearLabel(sel.year)} di ${sel.duration}',
              ),
              _SummaryRow('Anno accademico', aa),
              if (percorsi != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: PercorsoField(
                    percorsi: percorsi,
                    value: _percorso,
                    onChanged: _fase != _Fase.percorso
                        ? null
                        : (v) => setState(() => _percorso = v),
                  ),
                ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        const CatalogDownloadProgress(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 0),
        ),
        if (stato != null)
          Padding(
            key: const Key('onboarding-status'),
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Row(
              children: [
                if (_busy) ...[
                  const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                ],
                Expanded(
                  child: Text(
                    stato,
                    style: TextStyle(fontSize: 13, color: t.textMuted),
                  ),
                ),
              ],
            ),
          ),
        if (erroreCorsi != null && !_busy)
          CatalogOfflineNotice(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            message: CatalogService.descriviErrore(erroreCorsi),
            detail:
                'Puoi anche confermare senza piano e scaricarlo più tardi; '
                'intanto l\'app funziona con i corsi aggiunti a mano, gli '
                'appunti e il registratore.',
            onRetry: _avvia,
          ),
        if (result != null && result.senzaRete && !_busy)
          CatalogOfflineNotice(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            detail:
                'Il percorso è salvato: puoi andare all\'app e scaricare '
                'il piano più tardi da Impostazioni → Il mio percorso '
                '→ Aggiorna database.',
            onRetry: () => _importa(remote: true),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Text(
              'Import non riuscito: $_error. Riprova.',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (result != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (result.imported)
                  Text(
                    'Importati ${result.courses} insegnamenti e '
                    '${result.books} libri.',
                    style: TextStyle(color: t.cyanSoft),
                  ),
                if (result.message != null && !result.senzaRete) ...[
                  const SizedBox(height: 6),
                  Text(
                    result.message!,
                    style: TextStyle(color: t.textMuted, fontSize: 13),
                  ),
                ],
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
          child: Align(
            alignment: Alignment.centerRight,
            child: result == null
                ? FilledButton.icon(
                    key: const Key('onboarding-confirm'),
                    onPressed: _busy
                        ? null
                        : erroreCorsi != null
                        ? () => _avvia(senzaPiano: true)
                        : _avvia,
                    icon: Icon(
                      erroreCorsi != null
                          ? Icons.check
                          : Icons.download_outlined,
                    ),
                    label: Text(switch (_fase) {
                      _ when erroreCorsi != null => 'Conferma senza piano',
                      _Fase.percorso => 'Importa il piano',
                      _ when sel.isManual => 'Conferma',
                      _ => 'Scarica il piano di studi',
                    }),
                  )
                : FilledButton.icon(
                    key: Key(
                      widget.changing ? 'onboarding-done' : 'onboarding-next',
                    ),
                    onPressed: _busy ? null : widget.onDone,
                    icon: const Icon(Icons.arrow_forward),
                    label: Text(widget.changing ? 'Vai all\'app' : 'Continua'),
                  ),
          ),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 13, color: t.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(fontSize: 15, color: t.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}
