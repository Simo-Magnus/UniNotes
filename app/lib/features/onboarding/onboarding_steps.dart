part of 'onboarding_flow.dart';

// Passi dell'onboarding fuori dalla scelta del percorso: aspetto (prima
// della ricerca dell'ateneo) e, dopo l'import del piano, AI di riferimento,
// avvisi, calendario e gruppi da nascondere. Ognuno ha al massimo due
// pulsanti.

/// Pulsanti in fondo a un passo: [secondary] (testo) a sinistra di
/// [primary] (pieno), allineati a destra.
class _StepButtons extends StatelessWidget {
  const _StepButtons({required this.primary, this.secondary});
  final Widget primary;
  final Widget? secondary;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Wrap(
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [?secondary, primary],
      ),
    );
  }
}

/// Riga con icona e testo dentro una card di spiegazione.
class _Point extends StatelessWidget {
  const _Point(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: t.cyanSoft),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------- aspetto

/// Contrasto e grandezza del testo, scelti prima di tutto il resto: le
/// schermate successive si leggono già come preferisce lo studente.
/// Si salvano subito (Impostazioni → Aspetto).
class _AppearanceStep extends StatelessWidget {
  const _AppearanceStep({required this.onNext});
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    final theme = Theme.of(context);
    return ValueListenableBuilder<DisplayPrefs>(
      valueListenable: s.display,
      builder: (context, p, _) => ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const _StepHeader(
            'Come preferisci leggere?',
            'Scegli il contrasto e la grandezza del testo. Potrai cambiarli '
                'in Impostazioni → Aspetto.',
          ),
          GlassCard(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Contrasto', style: theme.textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<ContrastMode>(
                    key: const Key('onboarding-contrast'),
                    segments: const [
                      ButtonSegment(
                        value: ContrastMode.standard,
                        label: Text('Standard'),
                      ),
                      ButtonSegment(
                        value: ContrastMode.high,
                        label: Text('Alto contrasto'),
                        icon: Icon(Icons.contrast),
                      ),
                    ],
                    selected: {p.contrast},
                    onSelectionChanged: (v) {
                      AppFeedback.of(context).toggle();
                      AppearanceSection.saveDisplay(
                        s,
                        p.copyWith(contrast: v.first),
                      );
                    },
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Alto contrasto: testi più chiari, bordi più marcati e '
                    'card meno trasparenti.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Grandezza del testo',
                    style: theme.textTheme.titleSmall,
                  ),
                  Slider(
                    key: const Key('onboarding-text-size'),
                    value: p.textStep.toDouble(),
                    min: 0,
                    max: (kTextSizeSteps.length - 1).toDouble(),
                    divisions: kTextSizeSteps.length - 1,
                    label: kTextSizeLabels[p.textStep],
                    semanticFormatterCallback: (v) =>
                        'Caratteri: ${kTextSizeLabels[v.round()]}',
                    onChanged: (v) {
                      if (v.round() == p.textStep) return;
                      AppFeedback.of(context).toggle();
                      AppearanceSection.saveDisplay(
                        s,
                        p.copyWith(textStep: v.round()),
                      );
                    },
                  ),
                  TextSizePreview(label: kTextSizeLabels[p.textStep]),
                ],
              ),
            ),
          ),
          _StepButtons(
            primary: FilledButton.icon(
              key: const Key('onboarding-appearance-next'),
              onPressed: onNext,
              icon: const Icon(Icons.arrow_forward),
              label: const Text('Continua'),
            ),
          ),
        ],
      ),
    );
  }
}

// ------------------------------------------------- AI di riferimento

/// «Con quale AI studi?»: la scelta diventa l'AI di riferimento
/// (Collegamenti → AI di riferimento la mostra già impostata).
class _AiStep extends StatelessWidget {
  const _AiStep({required this.onNext});
  final VoidCallback onNext;

  static String _detail(ReferenceAi a) => switch (a) {
    ReferenceAi.chatgpt => 'OpenAI',
    ReferenceAi.claude => 'Anthropic',
    ReferenceAi.copilot => 'Microsoft',
    ReferenceAi.perplexity => 'Risposte con le fonti',
    ReferenceAi.notebooklm => 'Google: taccuini dai tuoi file',
    ReferenceAi.gemini => 'Google',
  };

  @override
  Widget build(BuildContext context) {
    final s = context.read<AppServices>();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StepHeader(
          'Con quale AI studi?',
          'UniNotes prepara il prompt e i file da allegare (trascrizioni, '
              'appunti, argomenti) e apre la tua AI con il tuo account. Puoi '
              'cambiarla in Collegamenti.',
        ),
        for (final a in ReferenceAi.values)
          _OptionTile(
            icon: Icons.psychology_alt_outlined,
            title: a.label,
            subtitle: _detail(a),
            onTap: () async {
              try {
                await s.settings.setReferenceAi(a);
              } catch (e) {
                debugPrint('Onboarding: AI di riferimento: $e');
              }
              onNext();
            },
          ),
        _StepButtons(
          primary: TextButton(
            key: const Key('onboarding-ai-skip'),
            onPressed: onNext,
            child: const Text('Decido più tardi'),
          ),
        ),
      ],
    );
  }
}

// -------------------------------------------------------------- avvisi

/// Permesso delle notifiche al primo ingresso, spiegato prima del dialogo
/// del sistema: cosa arriva e perché. «Non ora» non chiede più nulla
/// (resta l'interruttore in Impostazioni → Notifiche).
class _NotificationsStep extends StatefulWidget {
  const _NotificationsStep({required this.onNext});
  final VoidCallback onNext;

  @override
  State<_NotificationsStep> createState() => _NotificationsStepState();
}

class _NotificationsStepState extends State<_NotificationsStep> {
  late final AppServices _s = context.read<AppServices>();
  bool _busy = false;

  Future<void> _enable() async {
    if (_busy) return;
    setState(() => _busy = true);
    var ok = false;
    try {
      ok = await _s.reminders.enableNotifications();
    } catch (e) {
      // senza questo i due pulsanti resterebbero spenti per sempre
      debugPrint('Onboarding: notifiche: $e');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    if (!ok) {
      showSnack(
        context,
        'Permesso non concesso: puoi attivare le notifiche dalle '
        'impostazioni del sistema.',
      );
    }
    widget.onNext();
  }

  Future<void> _later() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _s.settings.set(NotificationKeys.asked, '1');
    } catch (e) {
      debugPrint('Onboarding: notifiche: $e');
    }
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StepHeader(
          'Vuoi gli avvisi?',
          'UniNotes avvisa solo per lo studio. Toccando «Attiva gli avvisi» '
              'il sistema ti chiede il permesso.',
        ),
        GlassCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _Point(
                  Icons.event_outlined,
                  'Esami, prove in itinere ed esoneri: 7 giorni prima e il '
                  'giorno prima.',
                ),
                const _Point(
                  Icons.timer_outlined,
                  'Fine delle sessioni di studio con il timer e delle pause, '
                  'anche con il Non disturbare attivo.',
                ),
                const _Point(
                  Icons.mic_none_outlined,
                  'Registrazione delle lezioni in corso quando esci dall\'app.',
                ),
                _Point(
                  Icons.star_outline,
                  'Una sola volta la richiesta di una recensione'
                  '${kShowDonationLink ? ' e, al massimo ogni sei mesi, '
                            'l\'invito facoltativo a sostenere il progetto' : ''}.',
                ),
                const SizedBox(height: 4),
                Text(
                  'Puoi cambiare tutto in Impostazioni → Notifiche.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
        _StepButtons(
          secondary: TextButton(
            key: const Key('onboarding-notifications-later'),
            onPressed: _busy ? null : _later,
            child: const Text('Non ora'),
          ),
          primary: FilledButton.icon(
            key: const Key('onboarding-notifications-on'),
            onPressed: _busy ? null : _enable,
            icon: const Icon(Icons.notifications_active_outlined),
            label: const Text('Attiva gli avvisi'),
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- calendario

/// Calendario del telefono (Android, iOS): proposto una volta qui, così
/// il primo esame con una data non lo richiede di nuovo
/// ([kCalendarOfferedKey]). Su Windows e macOS resta in Impostazioni.
class _CalendarStep extends StatefulWidget {
  const _CalendarStep({required this.onNext});
  final VoidCallback onNext;

  @override
  State<_CalendarStep> createState() => _CalendarStepState();
}

class _CalendarStepState extends State<_CalendarStep> {
  late final AppServices _s = context.read<AppServices>();
  bool _busy = false;

  Future<void> _answer(bool yes) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _s.settings.set(kCalendarOfferedKey, '1');
    } catch (e) {
      // solo il «già chiesto»: si va avanti lo stesso
      debugPrint('Onboarding: calendario: $e');
    }
    if (yes) {
      try {
        await _s.reminders.enableCalendar();
      } catch (e) {
        if (mounted) showSnack(context, '$e');
      }
    }
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onNext();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StepHeader(
          'Vuoi le prove nel calendario?',
          'UniNotes scrive esami, prove in itinere ed esoneri nel calendario '
              '«UniNotes» del telefono e li aggiorna quando cambi data o '
              'stato. Le altre date le aggiungi tu, a mano, in Esami.',
        ),
        GlassCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Point(
                  Icons.lock_outline,
                  'Il sistema ti chiede il permesso del calendario: l\'app '
                  'tocca solo il calendario «UniNotes».',
                ),
                _Point(
                  Icons.settings_outlined,
                  'Puoi scollegarlo in Impostazioni → Calendario: le prove '
                  'si tolgono dal calendario.',
                ),
              ],
            ),
          ),
        ),
        _StepButtons(
          secondary: TextButton(
            key: const Key('onboarding-calendar-later'),
            onPressed: _busy ? null : () => _answer(false),
            child: const Text('Non ora'),
          ),
          primary: FilledButton.icon(
            key: const Key('onboarding-calendar-on'),
            onPressed: _busy ? null : () => _answer(true),
            icon: const Icon(Icons.event_available_outlined),
            label: const Text('Collega il calendario'),
          ),
        ),
      ],
    );
  }
}

// ----------------------------------------------------------- esclusioni

/// Ultimo passo: nascondere OFA, inglese e lingua straniera, corsi
/// facoltativi (le esclusioni di Impostazioni → Esclusioni). Il piano è già
/// importato: gli elementi di quei gruppi si tolgono subito.
class _ExclusionsStep extends StatefulWidget {
  const _ExclusionsStep({required this.onDone});
  final Future<void> Function() onDone;

  @override
  State<_ExclusionsStep> createState() => _ExclusionsStepState();
}

class _ExclusionsStepState extends State<_ExclusionsStep> {
  late final AppServices _s = context.read<AppServices>();
  final Set<String> _hidden = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _s.settings
        .exclusionPatterns()
        .then((patterns) {
          if (!mounted) return;
          setState(() {
            for (final g in kExclusionPresets) {
              if (g.patterns.every(patterns.contains)) _hidden.add(g.id);
            }
          });
        })
        .catchError((Object e) => debugPrint('Onboarding: esclusioni: $e'));
  }

  Future<void> _done() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await applyExclusionPresets(_s, _hidden);
    } catch (e) {
      if (mounted) showSnack(context, 'Esclusioni non applicate: $e');
    }
    await widget.onDone();
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _StepHeader(
          'Vuoi nascondere qualcosa?',
          'Lezioni, esami e libri di questi gruppi spariscono da Esami, '
              'Studio e Libri. Puoi cambiare idea in Impostazioni → '
              'Esclusioni.',
        ),
        GlassCard(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Column(
            children: [
              for (final g in kExclusionPresets)
                SwitchListTile(
                  key: Key('onboarding-exclude-${g.id}'),
                  title: Text('Nascondi: ${g.label}'),
                  subtitle: Text(g.description),
                  value: _hidden.contains(g.id),
                  onChanged: _busy
                      ? null
                      : (v) {
                          AppFeedback.of(context).toggle();
                          setState(
                            () => v ? _hidden.add(g.id) : _hidden.remove(g.id),
                          );
                        },
                ),
            ],
          ),
        ),
        _StepButtons(
          primary: FilledButton.icon(
            key: const Key('onboarding-done'),
            onPressed: _busy ? null : _done,
            icon: const Icon(Icons.arrow_forward),
            label: const Text('Vai all\'app'),
          ),
        ),
      ],
    );
  }
}

/// Salva le esclusioni pronte scelte ([ids] di [kExclusionPresets]; le
/// altre si tolgono) e cancella gli elementi già importati che vi
/// corrispondono. Restituisce quanti elementi sono stati tolti.
Future<int> applyExclusionPresets(AppServices s, Set<String> ids) async {
  final current = await s.settings.exclusionPatterns();
  final next = [
    for (final p in current)
      if (!kAllPresetPatterns.contains(p)) p,
    for (final g in kExclusionPresets)
      if (ids.contains(g.id)) ...g.patterns,
  ];
  await s.settings.setExclusionPatterns(next);
  var n = 0;
  if (ids.isNotEmpty) {
    final cleanup = ExclusionCleanup(s.database);
    final matches = await cleanup.find(next);
    if (!matches.isEmpty) n = await cleanup.apply(matches);
  }
  s.revision.bump();
  return n;
}
