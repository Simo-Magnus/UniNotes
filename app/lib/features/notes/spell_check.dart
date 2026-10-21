import 'dart:async';
import 'dart:io';

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
