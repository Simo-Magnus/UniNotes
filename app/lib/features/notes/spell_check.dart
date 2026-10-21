import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Controllo ortografico del sistema operativo nei campi di testo lunghi
/// (trascrizione dal vivo, note e appunti), come nel Blocco note: le parole
/// errate hanno la classica linea ondulata rossa e i suggerimenti sono nel
/// menu del tasto destro (PC e Mac) o al tocco sulla parola (telefono).
/// Nessun dizionario incluso nell'app: si usano quelli installati nel
/// sistema.
///
/// - **Android, iOS**: il servizio del sistema di Flutter
///   ([DefaultSpellCheckService]: correttore della tastiera su Android,
///   `UITextChecker` su iOS), nella lingua principale.
/// - **Windows**: `ISpellChecker` di Windows (spellcheck.h) nel runner
///   (`windows/runner/spell_check.cpp`), canale [channelName].
/// - **macOS**: `NSSpellChecker` (`macos/Runner/MainFlutterWindow.swift`),
///   stesso canale.
/// - **Linux**: nessun controllo.
///
/// Su PC e Mac si controllano italiano e inglese insieme: una parola è
/// errata solo se non è in nessuna delle due lingue installate (le citazioni
/// in inglese di una lezione in italiano non si sottolineano). Se una lingua
/// non è installata nel sistema quella lingua semplicemente non conta e le
/// Impostazioni lo dicono ([SpellCheckLanguagesNote]).
///
/// Le parole errate si segnano anche nel testo in sola lettura
/// ([ReadingSpellChecker] e [misspelledSpans]).
///
/// Le formule (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`) e gli indirizzi web non si
/// controllano. Il testo si controlla una riga alla volta, con i risultati
/// delle righe già viste in memoria: a ogni tasto si ricontrolla solo la
/// riga cambiata, anche in una trascrizione di un'ora.
class SystemSpellCheckService extends SpellCheckService {
  SystemSpellCheckService({
    this.primary = 'it',
    MethodChannel? channel,
    this._mobile,
    TargetPlatform? platform,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _platform = platform ?? defaultTargetPlatform;

  /// Canale nativo del controllo ortografico (PC e Mac):
  /// - `languages` → `{it: bool, en: bool}` lingue installate;
  /// - `check` `{texts: [String], languages: ['it', 'en']}` → per ogni
  ///   testo l'elenco degli errori `[inizio, fine, [suggerimenti]]` (indici
  ///   UTF-16, fine esclusa); la prima lingua dà i suggerimenti.
  static const channelName = 'io.github.simomagnus.universitynotes/spellcheck';

  /// Lingua principale ('it' o 'en'): quella della lezione.
  final String primary;
  final MethodChannel _channel;
  final SpellCheckService? _mobile;
  final TargetPlatform _platform;

  /// Risultati per riga (testo della riga → errori nella riga).
  final Map<String, List<SuggestionSpan>> _cache = {};
  static const _maxCache = 4000;
  int _generation = 0;

  bool get _native =>
      _platform == TargetPlatform.windows || _platform == TargetPlatform.macOS;

  List<String> get _languages => primary == 'en' ? ['en', 'it'] : ['it', 'en'];

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    final gen = ++_generation;
    if (!_native) {
      final service = _mobile ?? DefaultSpellCheckService();
      final spans = await service.fetchSpellCheckSuggestions(
        primary == 'en' ? const Locale('en', 'US') : const Locale('it', 'IT'),
        text,
      );
      return spans == null ? null : filterSpellCheckSpans(text, spans);
    }
    final lines = text.split('\n');
    final missing = <String>{
      for (final l in lines)
        if (l.trim().isNotEmpty && !_cache.containsKey(l)) l,
    }.toList();
    if (missing.isNotEmpty) {
      List<Object?>? raw;
      try {
        raw = await _channel.invokeListMethod<Object?>('check', {
          'texts': missing,
          'languages': _languages,
        });
      } on MissingPluginException {
        return const [];
      } catch (e) {
        debugPrint('Controllo ortografico: $e');
        return const [];
      }
      if (raw == null) return const [];
      if (_cache.length + missing.length > _maxCache) _cache.clear();
      for (var i = 0; i < missing.length && i < raw.length; i++) {
        _cache[missing[i]] = parseNativeSpellErrors(raw[i]);
      }
    }
    // un controllo più recente arriverà comunque: questo non serve più
    if (gen != _generation) return null;
    final out = <SuggestionSpan>[];
    var offset = 0;
    for (final l in lines) {
      for (final s in _cache[l] ?? const <SuggestionSpan>[]) {
        out.add(
          SuggestionSpan(
            TextRange(start: s.range.start + offset, end: s.range.end + offset),
            s.suggestions,
          ),
        );
      }
      offset += l.length + 1;
    }
    return filterSpellCheckSpans(text, out);
  }
}

/// Errori di una riga dal canale nativo (`[[inizio, fine, [suggerimenti]]]`).
List<SuggestionSpan> parseNativeSpellErrors(Object? raw) {
  if (raw is! List) return const [];
  final out = <SuggestionSpan>[];
  for (final e in raw) {
    if (e is! List || e.length < 2) continue;
    final start = e[0], end = e[1];
    if (start is! int || end is! int || end <= start) continue;
    final sug = e.length > 2 && e[2] is List
        ? [
            for (final x in e[2] as List)
              if (x is String) x,
          ]
        : const <String>[];
    out.add(SuggestionSpan(TextRange(start: start, end: end), sug));
  }
  out.sort((a, b) => a.range.start.compareTo(b.range.start));
  return out;
}

final _skipped = RegExp(
  r'\$\$[\s\S]*?\$\$|\$[^$\n]+\$|\\\([\s\S]*?\\\)|\\\[[\s\S]*?\\\]|'
  r'https?://\S+|www\.\S+',
);

/// [spans] senza gli errori dentro formule e indirizzi web, in ordine e
/// senza sovrapposizioni (come li vuole il campo di testo).
List<SuggestionSpan> filterSpellCheckSpans(
  String text,
  List<SuggestionSpan> spans,
) {
  final skip = [for (final m in _skipped.allMatches(text)) (m.start, m.end)];
  final out = <SuggestionSpan>[];
  var last = -1;
  for (final s in [
    ...spans,
  ]..sort((a, b) => a.range.start.compareTo(b.range.start))) {
    final r = s.range;
    if (r.start < 0 || r.end > text.length || r.start < last) continue;
    if (skip.any((k) => r.start < k.$2 && r.end > k.$1)) continue;
    out.add(s);
    last = r.end;
  }
  return out;
}

/// Il controllo ortografico c'è su questo sistema.
bool get spellCheckSupported =>
    !kIsWeb &&
    (Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isWindows ||
        Platform.isMacOS);

/// Configurazione del controllo ortografico per un campo di testo ('it' o
/// 'en' come lingua principale); disattivata dove il sistema non lo offre.
///
/// Il campo controlla il testo solo quando cambia: per sottolineare subito
/// il testo che c'è già, la configurazione va passata un fotogramma dopo
/// l'apertura (vedi [DeferredSpellCheck]).
SpellCheckConfiguration spellCheckFor(SpellCheckService? service) =>
    service == null
    ? const SpellCheckConfiguration.disabled()
    : SpellCheckConfiguration(
        spellCheckService: service,
        misspelledTextStyle: TextField.materialMisspelledTextStyle,
      );

/// Servizi già creati per lingua (i risultati restano in memoria fra un
/// campo e l'altro).
final _services = <String, SystemSpellCheckService>{};

/// Servizio del controllo ortografico per la lingua [primary] (null dove
/// non c'è).
SystemSpellCheckService? spellCheckService([String primary = 'it']) {
  if (!spellCheckSupported) return null;
  return _services[primary] ??= SystemSpellCheckService(primary: primary);
}

/// Lingua principale del controllo ('it' o 'en') da un codice di lingua
/// («en-US», «it», null → 'it').
String spellLanguageOf(String? locale) =>
    (locale ?? '').toLowerCase().startsWith('en') ? 'en' : 'it';

/// Mescola nel campo di testo il controllo ortografico un fotogramma dopo
/// l'apertura: così il testo già presente viene controllato subito (il
/// campo lo fa solo quando la configurazione o il testo cambiano).
mixin DeferredSpellCheck<T extends StatefulWidget> on State<T> {
  SpellCheckConfiguration _spell = const SpellCheckConfiguration.disabled();

  /// Configurazione da passare a `TextField.spellCheckConfiguration`.
  SpellCheckConfiguration get spellCheck => _spell;

  /// Lingua principale del controllo ('it' o 'en').
  String get spellLanguage => 'it';

  /// Attiva il controllo (da chiamare quando il testo è pronto).
  void enableSpellCheck() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final next = spellCheckFor(spellCheckService(spellLanguage));
      if (next != _spell) setState(() => _spell = next);
    });
  }
}

/// [text] da [start] a [end] (di tutto il testo se non indicati) come
/// `TextSpan` con le parole errate di [spans] sottolineate dalla stessa linea
/// ondulata rossa dei campi di testo ([TextField.materialMisspelledTextStyle]),
/// per mostrare gli errori anche nel testo in sola lettura.
///
/// Gli intervalli di [spans] sono nelle posizioni di un testo più grande di
/// cui [text] comincia alla posizione [offset] (il carattere `i` di [text] è
/// la posizione `offset + i`): così un tratto di testo (una frase, un pezzo
/// di riga) si disegna con gli errori calcolati sul testo intero. Il testo
/// non cambia (solo lo stile e la divisione in tratti): i lettori di schermo
/// leggono le stesse parole e le posizioni dei caratteri restano quelle.
/// [style] è lo stile del testo corretto; quello delle parole errate lo
/// completa con la linea. Senza errori nel tratto restituisce un solo
/// `TextSpan`; con un tratto vuoto, nessuno.
List<TextSpan> misspelledSpans(
  String text,
  List<SuggestionSpan> spans, {
  TextStyle? style,
  int start = 0,
  int? end,
  int offset = 0,
}) {
  final to = (end ?? text.length).clamp(0, text.length);
  final from = start.clamp(0, to);
  if (from >= to) return const [];
  final bad = style == null
      ? TextField.materialMisspelledTextStyle
      : style.merge(TextField.materialMisspelledTextStyle);
  final out = <TextSpan>[];
  var at = from;
  final sorted = [...spans]
    ..sort((a, b) => a.range.start.compareTo(b.range.start));
  for (final s in sorted) {
    // l'errore si limita al tratto e a quello che non è già stato disegnato
    final a = math.max(s.range.start - offset, at);
    final b = math.min(s.range.end - offset, to);
    if (b <= a) continue;
    if (a > at) out.add(TextSpan(text: text.substring(at, a), style: style));
    out.add(TextSpan(text: text.substring(a, b), style: bad));
    at = b;
  }
  if (at < to) out.add(TextSpan(text: text.substring(at, to), style: style));
  return out;
}

/// Controllo ortografico del testo in sola lettura (trascrizione dal vivo
/// fuori dalla modifica, trascrizioni, riassunti e note aperti): chiede gli
/// errori al servizio del sistema ([spellCheckService]) senza che serva
/// entrare nel campo di modifica, e li dà a [misspelledSpans].
///
/// - Si controlla un testo alla volta (una frase, un blocco di Markdown) e il
///   risultato resta in memoria per testo: lo stesso testo non si richiede
///   due volte, durante la registrazione si controllano solo le frasi nuove
///   o cambiate.
/// - I controlli partono in modo asincrono, un testo dopo l'altro, dopo un
///   breve ritardo ([delay]) dall'ultimo testo nuovo; quando ci sono novità
///   chi ascolta ([addListener]) ridisegna il testo. Finché il risultato non
///   c'è, [errorsOf] dà nessun errore e il testo si vede com'è.
/// - Dove il correttore non c'è ([enabled] falso) o se fallisce, nessun
///   errore e nessun avviso.
/// - Le formule e gli indirizzi web non si controllano (lo fa il servizio).
///
/// [errorsOf] si chiama dal `build`: non cambia nulla di visibile, mette il
/// testo in coda. Il testo provvisorio (ancora in corso) non va passato.
class ReadingSpellChecker extends ChangeNotifier {
  ReadingSpellChecker({
    this._language = 'it',
    SpellCheckService? service,
    this.delay = const Duration(milliseconds: 500),
  }) : _injected = service;

  /// Attesa dall'ultimo testo nuovo prima di chiedere gli errori.
  final Duration delay;
  final SpellCheckService? _injected;
  String _language;

  final Map<String, List<SuggestionSpan>> _cache = {};
  final Set<String> _queue = {};
  final Map<String, int> _failures = {};
  String? _busy;
  Timer? _timer;
  bool _running = false;
  bool _disposed = false;
  static const _maxCache = 4000;
  static const _maxFailures = 2;

  SpellCheckService? get _service => _injected ?? spellCheckService(_language);

  /// C'è un correttore su questo sistema.
  bool get enabled => _service != null;

  /// Lingua principale ('it' o 'en'); cambiandola si ricomincia da capo.
  String get language => _language;
  set language(String value) {
    if (value == _language) return;
    _language = value;
    _cache.clear();
    _queue.clear();
    _failures.clear();
  }

  /// Errori già noti di [text] (nelle posizioni di [text]); se non ci sono
  /// ancora li chiede e intanto dà nessun errore.
  /// Errori di [text] se già controllato (null altrimenti), senza metterlo
  /// in coda.
  List<SuggestionSpan>? known(String text) => _cache[text];

  List<SuggestionSpan> errorsOf(String text) {
    final known = _cache[text];
    if (known != null) return known;
    if (_disposed || text.trim().isEmpty || !enabled) return const [];
    if (text != _busy && _queue.add(text)) _schedule();
    return const [];
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_flush()));
  }

  Future<void> _flush() async {
    if (_running || _disposed) return;
    _running = true;
    final service = _service;
    final locale = _language == 'en'
        ? const Locale('en', 'US')
        : const Locale('it', 'IT');
    final retry = <String>[];
    var done = 0;
    try {
      while (service != null && _queue.isNotEmpty && !_disposed) {
        final text = _queue.first;
        _queue.remove(text);
        _busy = text;
        List<SuggestionSpan>? found;
        var failed = false;
        try {
          found = await service.fetchSpellCheckSuggestions(locale, text);
        } catch (e) {
          debugPrint('Controllo ortografico: $e');
          failed = true;
        }
        _busy = null;
        if (_disposed) return;
        if (found == null && !failed) {
          // un controllo più recente ha preso il posto di questo: un altro
          // tentativo, poi si lascia il testo com'è
          final n = (_failures[text] ?? 0) + 1;
          _failures[text] = n;
          if (n < _maxFailures) {
            retry.add(text);
            continue;
          }
        }
        if (_cache.length >= _maxCache) _cache.clear();
        _cache[text] = found == null
            ? const []
            : filterSpellCheckSpans(text, found);
        // ogni tanto ridisegna: un testo lungo si sottolinea a pezzi
        if (++done % 25 == 0) notifyListeners();
      }
    } finally {
      _running = false;
      _busy = null;
    }
    if (_disposed) return;
    _queue.addAll(retry);
    if (_queue.isNotEmpty) _schedule();
    if (done > 0) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}

/// Controllo ortografico di un campo con un testo lungo che cresce (la
/// trascrizione dal vivo in modifica): il testo si divide in frasi e si
/// chiedono a [inner] solo quelle mai viste. Gli errori già noti vengono da
/// [known] (es. [ReadingSpellChecker.known], quelli della lettura) o da
/// [cache], che resta fra un controllo e l'altro: a ogni tasto o frase nuova
/// si controlla solo la frase cambiata, anche dopo un'ora di lezione.
///
/// Un'istanza nuova con la stessa [cache] fa ripartire il controllo del
/// campo (la configurazione cambia) senza ricontrollare nulla.
class SentenceSpellCheck extends SpellCheckService {
  SentenceSpellCheck(this.inner, {this.known, required this.cache});

  final SpellCheckService inner;
  final List<SuggestionSpan>? Function(String sentence)? known;
  final Map<String, List<SuggestionSpan>> cache;
  static const _maxCache = 4000;

  /// Frasi di [text] con la loro posizione: si divide dopo `.`, `!`, `?`,
  /// `…` seguiti da uno spazio e agli a capo, mai dentro una formula `$…$`.
  static List<(int, String)> sentences(String text) {
    final out = <(int, String)>[];
    var start = 0;
    var dollars = 0;
    void cut(int end) {
      final s = text.substring(start, end);
      if (s.trim().isNotEmpty) out.add((start, s));
    }

    for (var i = 0; i < text.length; i++) {
      final c = text.codeUnitAt(i);
      if (c == 0x24) dollars++; // $
      final boundary =
          dollars.isEven &&
          (c == 0x0A ||
              (c == 0x20 && i > start && '.!?…'.contains(text[i - 1])));
      if (boundary) {
        cut(i);
        start = i + 1;
        dollars = 0;
      }
    }
    if (start < text.length) cut(text.length);
    return out;
  }

  @override
  Future<List<SuggestionSpan>?> fetchSpellCheckSuggestions(
    Locale locale,
    String text,
  ) async {
    final out = <SuggestionSpan>[];
    for (final (at, s) in sentences(text)) {
      var spans = known?.call(s) ?? cache[s];
      if (spans == null) {
        final found = await inner.fetchSpellCheckSuggestions(locale, s);
        // un controllo più recente ha preso il posto di questo
        if (found == null) return null;
        spans = filterSpellCheckSpans(s, found);
        if (cache.length >= _maxCache) cache.clear();
        cache[s] = spans;
      }
      for (final x in spans) {
        out.add(
          SuggestionSpan(
            TextRange(start: x.range.start + at, end: x.range.end + at),
            x.suggestions,
          ),
        );
      }
    }
    return out;
  }
}

/// Menu contestuale dei campi con il controllo ortografico: sul PC e sul
/// Mac (tasto destro su una parola sottolineata) prima i suggerimenti,
/// poi Taglia, Copia, Incolla, Seleziona tutto. Sul telefono i suggerimenti
/// compaiono già al tocco sulla parola.
Widget spellCheckContextMenu(BuildContext context, EditableTextState state) {
  final items = <ContextMenuButtonItem>[];
  final desktop =
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      defaultTargetPlatform == TargetPlatform.linux;
  final value = state.textEditingValue;
  final sel = value.selection;
  if (desktop && sel.isValid) {
    final span = state.findSuggestionSpanAtCursorIndex(sel.baseOffset);
    if (span != null && span.range.end <= value.text.length) {
      for (final s in span.suggestions.take(5)) {
        items.add(
          ContextMenuButtonItem(
            label: s,
            onPressed: () {
              state.userUpdateTextEditingValue(
                TextEditingValue(
                  text: value.text.replaceRange(
                    span.range.start,
                    span.range.end,
                    s,
                  ),
                  selection: TextSelection.collapsed(
                    offset: span.range.start + s.length,
                  ),
                ),
                SelectionChangedCause.toolbar,
              );
              state.hideToolbar();
            },
          ),
        );
      }
      if (span.suggestions.isEmpty) {
        items.add(
          const ContextMenuButtonItem(
            label: 'Nessun suggerimento',
            onPressed: null,
          ),
        );
      }
    }
  }
  items.addAll(state.contextMenuButtonItems);
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: state.contextMenuAnchors,
    buttonItems: items,
  );
}

/// Lingue del controllo ortografico installate nel sistema (PC e Mac);
/// null se non si sa (telefono, Linux, canale assente).
Future<({bool it, bool en})?> spellCheckLanguages({
  MethodChannel channel = const MethodChannel(
    SystemSpellCheckService.channelName,
  ),
}) async {
  if (kIsWeb || !(Platform.isWindows || Platform.isMacOS)) return null;
  try {
    final m = await channel.invokeMapMethod<String, Object?>('languages');
    if (m == null) return null;
    return (it: m['it'] == true, en: m['en'] == true);
  } catch (_) {
    return null;
  }
}

/// Testo dell'avviso sulle lingue mancanti (null se ci sono entrambe).
String? spellCheckLanguagesText(({bool it, bool en}) l, {required bool mac}) {
  final system = mac ? 'macOS' : 'Windows';
  final where = mac
      ? 'Impostazioni di Sistema → Generali → Lingua e Zona'
      : 'Impostazioni → Ora e lingua → Lingua e area geografica';
  if (!l.it && !l.en) {
    return 'Per il controllo ortografico installa la lingua italiana (e '
        'l\'inglese) in $system: $where.';
  }
  if (!l.it) {
    return 'Per il controllo ortografico in italiano installa la lingua '
        'italiana in $system: $where.';
  }
  if (!l.en) {
    return 'Le parole inglesi vengono sottolineate: per riconoscerle '
        'installa l\'inglese in $system ($where).';
  }
  return null;
}

/// Avviso discreto nelle Impostazioni quando nel sistema manca una lingua
/// del controllo ortografico (niente se ci sono italiano e inglese).
class SpellCheckLanguagesNote extends StatefulWidget {
  const SpellCheckLanguagesNote({super.key});

  @override
  State<SpellCheckLanguagesNote> createState() =>
      _SpellCheckLanguagesNoteState();
}

class _SpellCheckLanguagesNoteState extends State<SpellCheckLanguagesNote> {
  String? _text;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final l = await spellCheckLanguages();
    if (l == null || !mounted) return;
    setState(() => _text = spellCheckLanguagesText(l, mac: Platform.isMacOS));
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    if (text == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.spellcheck, size: 18, color: muted),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
