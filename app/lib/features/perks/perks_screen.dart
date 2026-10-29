import 'package:flutter/material.dart';

import '../../core/constants/text_limits.dart';
import '../../core/feedback/motion.dart' show motion;
import '../../core/services/external_launcher.dart';
import '../../core/theme/app_tokens.dart';
import '../../widgets/common.dart';
import '../../widgets/fit_segmented.dart';
import '../../widgets/glass.dart';
import '../../widgets/section_active.dart';
import '../../utils/dates.dart' show formatDmy;
import 'perks.dart';

/// Quali vantaggi si vedono: quelli per tutti gli studenti o quelli che
/// dipendono dall'ateneo.
enum PerksView { forAll, university }

/// «Vantaggi da studente»: offerte gratuite o scontate con l'email
/// universitaria. Due schede, «Per tutti gli studenti» (divisi per
/// categoria, senza una voce «Tutti»: con la ricerca si cerca in tutte) e
/// «Dal tuo ateneo» (solo dove l'ateneo ha un accordo). Toccando una card
/// si vedono condizioni, durata e il link alla pagina ufficiale.
class PerksScreen extends StatefulWidget {
  const PerksScreen({super.key, this.data, this.clock});

  /// Dati già pronti (prove); altrimenti si leggono dall'asset.
  final PerksData? data;

  /// Oggi (le prove lo fissano): le offerte scadute non si mostrano.
  final DateTime Function()? clock;

  @override
  State<PerksScreen> createState() => _PerksScreenState();
}

class _PerksScreenState extends State<PerksScreen>
    with SectionReturn<PerksScreen>, WidgetsBindingObserver {
  late final Future<PerksData> _data = widget.data != null
      ? Future.value(widget.data)
      : PerksData.load();
  final _search = TextEditingController();
  PerksView _view = PerksView.forAll;
  String? _category;
  String _query = '';

  /// Card aperte, per nome: lo stato segue il vantaggio (non la posizione
  /// nella lista) e resta anche scorrendo, cambiando categoria o cercando.
  final Set<String> _open = {};

  Widget _card(Perk p, IconData icon) => PerkCard(
    key: ValueKey(p.name),
    perk: p,
    icon: icon,
    open: _open.contains(p.name),
    onToggle: () => setState(() => _open.remove(p.name) || _open.add(p.name)),
  );

  /// Offerte da confermare: in fondo a ogni elenco, oppure nascoste.
  bool _showUnconfirmed = true;

  /// Prima le offerte confermate, poi quelle da confermare (nello stesso
  /// ordine di prima); senza [_showUnconfirmed] solo le confermate.
  PerksData _ordered(PerksData d) {
    List<Perk> order(List<Perk> l) => [
      for (final p in l)
        if (p.official) p,
      if (_showUnconfirmed)
        for (final p in l)
          if (!p.official) p,
    ];
    return PerksData(
      updated: d.updated,
      categories: d.categories,
      forAll: order(d.forAll),
      university: order(d.university),
    );
  }

  /// Ritorno nella sezione (resta viva nascosta anche per giorni, con l'app
  /// aperta): la ricostruzione rifà il filtro delle offerte scadute.
  @override
  void onSectionReturn() {}

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  /// App tornata in primo piano con la sezione già aperta: stesso filtro.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vantaggi da studente')),
      body: FutureBuilder<PerksData>(
        future: _data,
        builder: (context, snap) {
          if (snap.hasError) {
            return const EmptyState(
              icon: Icons.error_outline,
              message: 'Impossibile leggere l\'elenco dei vantaggi.',
            );
          }
          final d = snap.data;
          if (d == null) return const DelayedSpinner();
          return Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 900),
              child: ListView(
                padding: const EdgeInsets.only(bottom: 32),
                children: _content(context, d),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Widget> _content(BuildContext context, PerksData all) {
    final active = all.activeOn(
      DateUtils.dateOnly(widget.clock?.call() ?? DateTime.now()),
    );
    final unconfirmed = [
      ...active.forAll,
      ...active.university,
    ].where((p) => !p.official).length;
    final d = _ordered(active);
    final t = context.tokens;
    final category = _category ?? d.categories.first.id;
    final forAll = d.forAll.where((p) => p.matches(_query)).toList();
    final university = d.university.where((p) => p.matches(_query)).toList();
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Text(
          'Offerte gratuite o scontate per chi studia in un\'università '
          'italiana. Elenco aggiornato il ${d.updated}.',
          style: TextStyle(fontSize: 13, color: t.textSecondary),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: FitSegmentedButton<PerksView>(
          key: const Key('perks-view'),
          showSelectedIcon: false,
          segments: [
            FitSegment(value: PerksView.forAll, label: 'Per tutti'),
            FitSegment(value: PerksView.university, label: 'Dal tuo ateneo'),
          ],
          selected: {_view},
          onSelectionChanged: (s) => setState(() => _view = s.first),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: TextField(
          key: const Key('perks-search'),
          controller: _search,
          onChanged: (v) => setState(() => _query = v.trim()),
          inputFormatters: TextLimits.max(TextLimits.search),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search),
            hintText: 'Cerca un servizio',
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
        ),
      ),
      // offerte da confermare: in fondo a ogni elenco, si possono nascondere
      if (unconfirmed > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: FilterChip(
              key: const Key('perks-show-unconfirmed'),
              avatar: Icon(Icons.info_outline, size: 16, color: t.warning),
              label: Text('Anche da confermare ($unconfirmed)'),
              tooltip:
                  'Condizioni non lette tutte sulla pagina del fornitore o '
                  'da controllare con il tuo ateneo: compaiono in fondo',
              selected: _showUnconfirmed,
              onSelected: (v) => setState(() => _showUnconfirmed = v),
            ),
          ),
        ),
      if (_view == PerksView.forAll)
        ..._forAll(context, d, forAll, category)
      else
        ..._university(context, d, university),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Text(
          'UniNotes non è collegata a questi servizi: prezzi e condizioni li '
          'decidono i fornitori e possono cambiare. Prima di abbonarti leggi '
          'la pagina ufficiale.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: t.textMuted),
        ),
      ),
    ];
  }

  List<Widget> _forAll(
    BuildContext context,
    PerksData d,
    List<Perk> matching,
    String category,
  ) {
    // con la ricerca si cerca in tutte le categorie, divise per titolo
    if (_query.isNotEmpty) {
      if (matching.isEmpty) {
        return [
          _noResults(
            d.university.where((p) => p.matches(_query)).length,
            PerksView.university,
          ),
        ];
      }
      return [
        for (final c in d.categories)
          if (matching.any((p) => p.category == c.id)) ...[
            _GroupTitle(c.name),
            for (final p in matching.where((p) => p.category == c.id))
              _card(p, perkIcon(c.icon)),
          ],
        // es. «Adobe»: il prezzo per studenti qui, la licenza gratuita
        // dell'ateneo nell'altra scheda
        _alsoInOther(
          d.university.where((p) => p.matches(_query)).length,
          PerksView.university,
        ),
      ];
    }
    final cat = d.categories.firstWhere(
      (c) => c.id == category,
      orElse: () => d.categories.first,
    );
    return [
      SingleChildScrollView(
        // la riga delle categorie ricorda dove era (la lista la ricrea)
        key: const PageStorageKey('perks-chips'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        child: Row(
          children: [
            for (final c in d.categories)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: FilterChip(
                  key: Key('perks-cat-${c.id}'),
                  showCheckmark: false,
                  avatar: Icon(perkIcon(c.icon), size: 16),
                  label: Text(
                    '${c.name} '
                    '${d.forAll.where((p) => p.category == c.id).length}',
                  ),
                  selected: c.id == cat.id,
                  onSelected: (_) => setState(() => _category = c.id),
                ),
              ),
          ],
        ),
      ),
      for (final p in d.forAll.where((p) => p.category == cat.id))
        _card(p, perkIcon(cat.icon)),
    ];
  }

  List<Widget> _university(
    BuildContext context,
    PerksData d,
    List<Perk> matching,
  ) {
    final t = context.tokens;
    return [
      GlassCard(
        inner: true,
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 6),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: DefaultTextStyle.merge(
            style: TextStyle(fontSize: 13, color: t.textSecondary),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Questi vantaggi li dà il tuo ateneo, solo se ha un accordo '
                  'con il fornitore. Per sapere se ce li hai:',
                  style: TextStyle(color: t.textPrimary),
                ),
                const SizedBox(height: 6),
                const Text(
                  '1. cerca nel sito dell\'ateneo «Servizi informatici», '
                  '«Software per gli studenti», «Convenzioni» o «Biblioteca '
                  'digitale»;',
                ),
                const Text(
                  '2. prova ad accedere con l\'email dell\'ateneo sulla pagina '
                  'del servizio;',
                ),
                const Text(
                  '3. chiedi al servizio informatico (help desk) del tuo '
                  'ateneo.',
                ),
              ],
            ),
          ),
        ),
      ),
      if (matching.isEmpty)
        _noResults(
          d.forAll.where((p) => p.matches(_query)).length,
          PerksView.forAll,
        ),
      for (final p in matching) _card(p, Icons.account_balance_outlined),
      if (_query.isNotEmpty && matching.isNotEmpty)
        _alsoInOther(
          d.forAll.where((p) => p.matches(_query)).length,
          PerksView.forAll,
        ),
    ];
  }

  /// Ricerca senza risultati in questa scheda: se ce ne sono nell'altra lo
  /// dice, con il pulsante per passarci (es. «Canva» è solo tramite l'ateneo).
  Widget _noResults(int inOther, PerksView other) {
    if (inOther == 0) return _empty('Nessun servizio trovato.');
    final name = other == PerksView.university ? 'Dal tuo ateneo' : 'Per tutti';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 16),
      child: Column(
        children: [
          Text(
            'Nessun servizio in questa scheda.',
            textAlign: TextAlign.center,
            style: TextStyle(color: context.tokens.textMuted),
          ),
          const SizedBox(height: 8),
          TextButton(
            key: const Key('perks-other-tab'),
            onPressed: () => setState(() => _view = other),
            child: Text(
              inOther == 1
                  ? '1 risultato in «$name»'
                  : '$inOther risultati in «$name»',
            ),
          ),
        ],
      ),
    );
  }

  /// Sotto i risultati di una ricerca: quanti altri ce ne sono nell'altra
  /// scheda, con il pulsante per passarci (niente se non ce ne sono).
  Widget _alsoInOther(int inOther, PerksView other) {
    if (inOther == 0) return const SizedBox.shrink();
    final name = other == PerksView.university ? 'Dal tuo ateneo' : 'Per tutti';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Center(
        child: TextButton(
          key: const Key('perks-also-other-tab'),
          onPressed: () => setState(() => _view = other),
          child: Text(
            inOther == 1
                ? 'Anche 1 risultato in «$name»'
                : 'Anche $inOther risultati in «$name»',
          ),
        ),
      ),
    );
  }

  Widget _empty(String message) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
    child: Text(
      message,
      textAlign: TextAlign.center,
      style: TextStyle(color: context.tokens.textMuted),
    ),
  );
}

/// Testo del pulsante sotto un'offerta: dice dove porta. Le piattaforme
/// che verificano lo status di studente non sono la pagina del fornitore.
String perkLinkLabel(String url) {
  final host = Uri.tryParse(url)?.host ?? '';
  bool on(String domain) => host == domain || host.endsWith('.$domain');
  if (on('myunidays.com')) return 'Apri su UNiDAYS';
  if (on('studentbeans.com')) return 'Apri su Student Beans';
  if (on('sheerid.com')) return 'Apri su SheerID';
  if (on('isic.it')) return 'Apri su ISIC';
  return "Pagina dell'offerta";
}

/// Icona di una categoria (nome dell'asset dei vantaggi).
IconData perkIcon(String name) => switch (name) {
  'code' => Icons.code,
  'spark' => Icons.auto_awesome_outlined,
  'doc' => Icons.description_outlined,
  'music' => Icons.headphones_outlined,
  'bag' => Icons.shopping_bag_outlined,
  'plane' => Icons.flight_outlined,
  _ => Icons.local_offer_outlined,
};

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Card di un vantaggio: nome, prezzo in breve e descrizione; toccandola si
/// aprono condizioni, durata, per chi è (o dove c'è) e il link alla pagina
/// ufficiale.
class PerkCard extends StatefulWidget {
  const PerkCard({
    super.key,
    required this.perk,
    required this.icon,
    required this.open,
    required this.onToggle,
  });
  final Perk perk;
  final IconData icon;

  /// Aperta: si vedono i dettagli (lo stato lo tiene la schermata).
  final bool open;
  final VoidCallback onToggle;

  @override
  State<PerkCard> createState() => _PerkCardState();
}

class _PerkCardState extends State<PerkCard> {
  Perk get p => widget.perk;

  Future<void> _openPage() async {
    final r = await ExternalLauncher.openUrl(p.url);
    if (mounted) showLaunchResult(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // solo l'intestazione: i dettagli aperti restano nodi a parte (non
          // finiscono nell'etichetta del pulsante «apri/chiudi»)
          Semantics(
            container: true,
            button: true,
            expanded: widget.open,
            child: InkWell(
              onTap: widget.onToggle,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: t.innerCard,
                        border: Border.all(color: t.innerBorder),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(widget.icon, size: 18, color: t.cyan),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            p.name,
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: t.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text.rich(
                            TextSpan(
                              text: p.shortPrice,
                              children: [
                                // condizioni non lette tutte sulla pagina
                                // del fornitore: si vede anche a card chiusa
                                if (!p.official)
                                  TextSpan(
                                    text: ' · da confermare',
                                    style: TextStyle(color: t.warning),
                                  ),
                              ],
                            ),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: t.cyan,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            p.what,
                            maxLines: widget.open ? null : 2,
                            overflow: widget.open
                                ? null
                                : TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: t.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: widget.open ? 0.5 : 0,
                      duration: motion(
                        context,
                        const Duration(milliseconds: 200),
                      ),
                      child: Icon(Icons.expand_more, color: t.textMuted),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (widget.open) _details(context),
        ],
      ),
    );
  }

  Widget _details(BuildContext context) {
    final t = context.tokens;
    final rows = <(String, String)>[
      ('Prezzo', p.price),
      if (p.coverage != null) ('Dove c\'è', p.coverage!),
      ('Come si ottiene', p.howTo),
      if (p.duration != null) ('Durata', p.duration!),
      if (p.who != null) ('Per chi', p.who!),
      if (p.expires != null)
        ('Offerta disponibile fino al', formatDmy(p.expires!)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassCard(
            inner: true,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final (i, (label, value)) in rows.indexed) ...[
                    if (i > 0) const SizedBox(height: 8),
                    Text(
                      label.toUpperCase(),
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.4,
                        color: t.textMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value,
                      style: TextStyle(fontSize: 13, color: t.textPrimary),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            alignment: WrapAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    p.official ? Icons.verified_outlined : Icons.info_outline,
                    size: 16,
                    color: p.official ? t.success : t.warning,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      p.official
                          ? 'Condizioni controllate il ${p.checked}'
                          : p.coverage != null
                          ? 'Da confermare con il tuo ateneo (controllo del '
                                '${p.checked})'
                          : 'Da confermare: non tutte le condizioni sono '
                                'scritte sulla pagina del fornitore (controllo '
                                'del ${p.checked})',
                      style: TextStyle(fontSize: 12, color: t.textSecondary),
                    ),
                  ),
                ],
              ),
              if (p.url.isNotEmpty)
                OutlinedButton.icon(
                  onPressed: _openPage,
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(p.linkLabel ?? perkLinkLabel(p.url)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
