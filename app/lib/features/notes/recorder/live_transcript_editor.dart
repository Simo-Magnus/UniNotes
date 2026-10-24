import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../../widgets/math_text.dart';
import '../markdown_lite.dart' show parseMathOnly;
import '../spell_check.dart';
import 'recording_meta.dart';

/// Una frase della trascrizione nel testo del campo di modifica: chiave
/// (inizio del segmento in millisecondi) e posizione nel testo.
class TranscriptPiece {
  TranscriptPiece(this.key, this.start, this.end);
  final int key;
  int start;
  int end;

  @override
  String toString() => 'TranscriptPiece($key, $start, $end)';
}

/// Modifica da applicare ai segmenti: le frasi [keys] (in ordine) diventano
/// una sola con il testo [text] (vuoto = tolte).
class TranscriptEdit {
  const TranscriptEdit(this.keys, this.text);
  final List<int> keys;
  final String text;

  @override
  bool operator ==(Object other) =>
      other is TranscriptEdit &&
      other.text == text &&
      other.keys.length == keys.length &&
      [for (var i = 0; i < keys.length; i++) other.keys[i] == keys[i]]
          .every((x) => x);

  @override
  int get hashCode => Object.hash(text, Object.hashAll(keys));

  @override
  String toString() => 'TranscriptEdit($keys, «$text»)';
}

/// Un cambiamento del testo fatto da [TranscriptEditBuffer.sync]: da [at]
/// [removed] caratteri sostituiti da [inserted] caratteri. [map] porta una
/// posizione del testo di prima (cursore, selezione, parola in composizione
/// della tastiera) in quello di dopo.
class TranscriptChange {
  const TranscriptChange(
    this.at,
    this.removed,
    this.inserted, {
    this.end = false,
  });
  final int at;
  final int removed;
  final int inserted;

  /// Inserimento in fondo al testo: il cursore che era in fondo resta prima
  /// del testo nuovo (si sta scrivendo lì); a metà invece lo segue.
  final bool end;

  int map(int offset) {
    if (offset < at) return offset;
    if (removed == 0) {
      return offset > at || !end ? offset + inserted : offset;
    }
    if (offset >= at + removed) return offset + inserted - removed;
    // dentro il tratto cambiato: alla stessa distanza dall'inizio, se c'è
    return at + math.min(offset - at, inserted);
  }

  @override
  bool operator ==(Object other) =>
      other is TranscriptChange &&
      other.at == at &&
      other.removed == removed &&
      other.inserted == inserted &&
      other.end == end;

  @override
  int get hashCode => Object.hash(at, removed, inserted, end);

  @override
  String toString() =>
      'TranscriptChange($at, -$removed, +$inserted'
      '${end ? ', in fondo' : ''})';
}

/// Il testo della trascrizione come in un editor (Blocco note): le frasi una
/// dopo l'altra separate da uno spazio, con la posizione di ognuna. Una
/// modifica qualsiasi (scrivere, cancellare, incollare, sostituire una
/// selezione) si riporta sulle frasi toccate ([apply]): se tocca più frasi
/// diventano una sola (con l'inizio della prima e la fine dell'ultima),
/// quelle non toccate tengono i loro tempi.
///
/// Mentre si scrive la trascrizione va avanti ([sync]): le frasi nuove si
/// inseriscono al loro posto e quelle cambiate dal programma (seconda
/// passata con un modello migliore, «Formule» attivate o tolte) si
/// aggiornano o spariscono nel testo; le frasi modificate qui ([owned])
/// restano come le ha scritte lo studente.
class TranscriptEditBuffer {
  TranscriptEditBuffer(List<TranscriptSegment> segments) {
    final b = StringBuffer();
    for (final s in segments) {
      if (s.text.isEmpty) continue;
      if (b.isNotEmpty) b.write(' ');
      final start = b.length;
      b.write(s.text);
      pieces.add(TranscriptPiece(s.start.inMilliseconds, start, b.length));
    }
    text = b.toString();
  }

  String text = '';
  final List<TranscriptPiece> pieces = [];

  /// Frasi (chiavi) modificate in questo campo: il loro testo è quello
  /// scritto qui, anche negli spazi in fondo che la trascrizione toglie.
  final Set<int> owned = {};

  /// Testo nuovo [next] scritto dall'utente: aggiorna le posizioni e
  /// restituisce la modifica da fare ai segmenti (null se niente cambia).
  TranscriptEdit? apply(String next) {
    final old = text;
    if (next == old) return null;
    final max = math.min(old.length, next.length);
    var p = 0;
    while (p < max && old.codeUnitAt(p) == next.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < max - p &&
        old.codeUnitAt(old.length - 1 - s) ==
            next.codeUnitAt(next.length - 1 - s)) {
      s++;
    }
    final a = p, b = old.length - s, delta = next.length - old.length;
    text = next;
    if (pieces.isEmpty) return null;
    // frasi toccate dalla modifica [a, b) (anche solo ai bordi)
    var first = -1, last = -1;
    for (var i = 0; i < pieces.length; i++) {
      final x = pieces[i];
      if (x.start <= b && x.end >= a) {
        if (first < 0) first = i;
        last = i;
      }
    }
    if (first < 0) {
      // modifica fra due frasi lontane: va alla frase prima (o alla prima)
      var k = 0;
      for (var i = 0; i < pieces.length; i++) {
        if (pieces[i].start <= a) k = i;
      }
      first = last = k;
    }
    final head = pieces[first];
    final newStart = math.min(head.start, a);
    final newEnd = math.max(pieces[last].end, b) + delta;
    final keys = [for (var i = first; i <= last; i++) pieces[i].key];
    final merged = next.substring(newStart, newEnd);
    head
      ..start = newStart
      ..end = newEnd;
    pieces.removeRange(first + 1, last + 1);
    for (var i = first + 1; i < pieces.length; i++) {
      pieces[i]
        ..start += delta
        ..end += delta;
    }
    owned
      ..removeAll(keys)
      ..add(head.key);
    if (merged.trim().isEmpty) {
      pieces.removeAt(first);
      owned.remove(head.key);
    }
    return TranscriptEdit(keys, merged);
  }

  /// Sostituisce [start, end) con [insert] e sposta le frasi che seguono.
  TranscriptChange _replace(
    int start,
    int end,
    String insert, {
    bool atEnd = false,
  }) {
    text = text.replaceRange(start, end, insert);
    final delta = insert.length - (end - start);
    for (final x in pieces) {
      if (x.start >= end && !(x.start == end && start == end && atEnd)) {
        x
          ..start += delta
          ..end += delta;
      }
    }
    return TranscriptChange(start, end - start, insert.length, end: atEnd);
  }

  /// Allinea il testo alle frasi attuali [segments] (arrivate o cambiate
  /// mentre si scrive) e restituisce i cambiamenti, nell'ordine, per
  /// spostare cursore e selezione ([TranscriptChange.map]).
  List<TranscriptChange> sync(List<TranscriptSegment> segments) {
    final out = <TranscriptChange>[];
    final now = <int, String>{
      for (final s in segments) s.start.inMilliseconds: s.text,
    };
    // frasi tolte o riscritte dal programma (dal fondo: le posizioni delle
    // frasi prima non cambiano)
    for (var i = pieces.length - 1; i >= 0; i--) {
      final x = pieces[i];
      if (owned.contains(x.key)) continue;
      final t = now[x.key];
      if (t != null && t.isNotEmpty) {
        final old = text.substring(x.start, x.end);
        if (t != old) {
          final start = x.start, end = x.end;
          // la frase stessa non si sposta: cambia la sua fine
          pieces.removeAt(i);
          // parole confermate in fondo alla frase in corso: si aggiungono
          // dopo (il cursore che era alla fine della frase resta lì)
          out.add(
            t.startsWith(old)
                ? _replace(end, end, t.substring(old.length), atEnd: true)
                : _replace(start, end, t),
          );
          pieces.insert(i, TranscriptPiece(x.key, start, start + t.length));
        }
        continue;
      }
      // tolta: con uno spazio vicino
      var start = x.start, end = x.end;
      if (start > 0 && text.codeUnitAt(start - 1) == 0x20) {
        start--;
      } else if (end < text.length && text.codeUnitAt(end) == 0x20) {
        end++;
      }
      pieces.removeAt(i);
      out.add(_replace(start, end, ''));
    }
    // frasi nuove, al loro posto
    final known = {for (final x in pieces) x.key};
    for (final seg in segments) {
      final key = seg.start.inMilliseconds;
      if (known.contains(key) || seg.text.isEmpty) continue;
      known.add(key);
      final j = pieces.indexWhere((x) => x.key > key);
      final TranscriptChange change;
      final int pieceStart;
      if (j < 0) {
        final at = text.length;
        final insert = text.isEmpty ? seg.text : ' ${seg.text}';
        pieceStart = at + insert.length - seg.text.length;
        change = _replace(at, at, insert, atEnd: true);
      } else {
        final at = pieces[j].start;
        pieceStart = at;
        change = _replace(at, at, '${seg.text} ');
      }
      final piece = TranscriptPiece(
        key,
        pieceStart,
        pieceStart + seg.text.length,
      );
      if (j < 0) {
        pieces.add(piece);
      } else {
        pieces.insert(j, piece);
      }
      out.add(change);
    }
    return out;
  }
}

/// Posizione nel testo disegnato (le formule contano un carattere) e nel
/// testo da modificare.
class _Anchor {
  const _Anchor(this.shown, this.shownLength, this.raw, this.rawLength);
  final int shown;
  final int shownLength;
  final int raw;
  final int rawLength;
}

/// Frasi per blocco del testo in lettura ([EditableLiveTranscript]).
const kLiveReadingBlock = 40;

/// Un blocco di frasi del testo in lettura: testi ed errori con cui è stato
/// costruito (per riusarlo se non cambiano), tratti, posizioni (del blocco)
/// e chiave del suo paragrafo.
class _ReadingBlock {
  _ReadingBlock(
    this.keys,
    this.texts,
    this.errors,
    this.span,
    this.anchors,
    this.raw,
  );

  /// Chiavi delle frasi (inizio in millisecondi).
  final List<int> keys;
  final List<String> texts;
  final List<List<SuggestionSpan>> errors;
  final InlineSpan span;
  final List<_Anchor> anchors;

  /// Lunghezza del testo da modificare del blocco (frasi e spazi fra loro).
  final int raw;
  final GlobalKey key = GlobalKey();

  /// Paragrafo già costruito (blocchi senza il testo provvisorio).
  Widget? widget;

  bool sameAs(List<int> k, List<String> t, List<List<SuggestionSpan>> e) {
    if (t.length != texts.length) return false;
    for (var i = 0; i < t.length; i++) {
      if (k[i] != keys[i] || t[i] != texts[i] || !identical(e[i], errors[i])) {
        return false;
      }
    }
    return true;
  }
}

/// Testo dal vivo modificabile come in un normale editor di testo (Blocco
/// note, Google Docs): un tocco (o un clic) in un punto qualsiasi del testo
/// mette lì il cursore e si scrive, cancella, seleziona, copia e incolla
/// direttamente nel testo, mentre la registrazione e la trascrizione
/// continuano. Le modifiche si salvano da sole a ogni tasto ([onEdit]).
/// Stesso comportamento su telefono, PC e Mac.
///
/// Due modalità con passaggio immediato e senza cambi di aspetto: nessun
/// riquadro, solo il cursore (e sul telefono la tastiera) nel punto
/// toccato:
/// - **lettura**: le formule (`$…$`) disegnate;
/// - **modifica** (il campo ha il fuoco): le formule in LaTeX, da
///   correggere come il resto. Esc, un tocco fuori o la perdita del fuoco
///   tornano alla lettura (formule di nuovo disegnate). Senza formule le
///   due modalità hanno lo stesso aspetto.
///
/// Durante la modifica la trascrizione va avanti nello stesso campo
/// ([TranscriptEditBuffer.sync]): le frasi confermate arrivano in fondo (o
/// al loro posto) e sono subito modificabili, quelle riscritte dal
/// programma (seconda passata, «Formule») si aggiornano; cursore,
/// selezione e parola in composizione della tastiera restano dove sono e
/// le frasi già corrette dallo studente non vengono mai sovrascritte. Il
/// testo provvisorio (ancora in corso) resta sotto, più chiaro, e diventa
/// modificabile appena confermato.
///
/// Controllo ortografico del sistema ([spellCheckService]): parole errate
/// con la linea ondulata rossa e suggerimenti nel menu (tasto destro sul
/// PC, tocco sulla parola sul telefono), sempre visibile. In lettura
/// ([ReadingSpellChecker]) le frasi stabilizzate si controllano in modo
/// asincrono, un attimo dopo l'ultima novità e una sola volta per testo;
/// in modifica ([SentenceSpellCheck]) si riusano quei risultati e si
/// controllano solo le frasi nuove o cambiate. Il testo provvisorio e le
/// formule non si controllano.
class EditableLiveTranscript extends StatefulWidget {
  const EditableLiveTranscript({
    super.key,
    required this.segments,
    required this.partial,
    required this.onEdit,
    this.style,
    this.onEditing,
    this.language = 'it',
    this.spellService,
  });

  final List<TranscriptSegment> segments;
  final String partial;
  final TextStyle? style;

  /// Lingua principale del controllo ortografico ('it' o 'en').
  final String language;

  /// Servizio del controllo ortografico in lettura al posto di quello del
  /// sistema (per i test).
  final SpellCheckService? spellService;

  /// Modifica delle frasi (vedi [TranscriptEdit]).
  final void Function(TranscriptEdit edit) onEdit;

  /// Inizio (true) e fine (false) della modifica.
  final ValueChanged<bool>? onEditing;

  @override
  State<EditableLiveTranscript> createState() => _EditableLiveTranscriptState();
}

class _EditableLiveTranscriptState extends State<EditableLiveTranscript> {
  final _controller = TextEditingController();
  final _focus = FocusNode(debugLabel: 'trascrizione dal vivo');
  TranscriptEditBuffer? _buffer;

  /// Il testo in lettura a blocchi di [kLiveReadingBlock] frasi: dopo ore di
  /// lezione (migliaia di frasi) un paragrafo unico si reimpaginava tutto a
  /// ogni parola nuova (2600 frasi: ~115 ms sul PC, molto di più sul
  /// telefono, più volte al secondo: interfaccia ferma). Si ricostruisce e
  /// si reimpagina solo il blocco che cambia (di solito l'ultimo).
  List<_ReadingBlock> _blocks = const [];
  TextStyle? _blocksStyle;

  /// Modifica di un testo di più blocchi: nel campo c'è solo il blocco
  /// toccato (frasi da [_editFrom] incluso a [_editTo] escluso, chiavi in
  /// millisecondi; null = tutto il testo, o fino in fondo); quelli prima
  /// ([_before]) e dopo ([_after]) restano paragrafi in lettura. Un campo
  /// con ore di testo si reimpaginava tutto a ogni tasto e a ogni parola
  /// confermata (2600 frasi: ~140 ms sul PC, molto di più sul telefono).
  int? _editFrom;
  int? _editTo;
  List<_ReadingBlock> _before = const [];
  List<_ReadingBlock> _after = const [];

  bool _inWindow(TranscriptSegment s) {
    final from = _editFrom;
    if (from == null) return true;
    final k = s.start.inMilliseconds;
    final to = _editTo;
    return k >= from && (to == null || k < to);
  }

  /// Le frasi del campo di modifica.
  List<TranscriptSegment> get _windowSegments => [
    for (final s in widget.segments)
      if (_inWindow(s)) s,
  ];
  SpellCheckConfiguration _spell = const SpellCheckConfiguration.disabled();

  /// Errori delle frasi per la linea rossa in lettura.
  late final ReadingSpellChecker _checker = ReadingSpellChecker(
    language: widget.language,
    service: widget.spellService,
  )..addListener(_spellChanged);

  bool get _editing => _buffer != null;

  void _spellChanged() {
    if (mounted && !_editing) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _stop();
    });
  }

  @override
  void didUpdateWidget(EditableLiveTranscript old) {
    super.didUpdateWidget(old);
    _checker.language = widget.language;
    final buffer = _buffer;
    if (buffer == null) return;
    // frasi nuove o cambiate mentre si scrive: al loro posto, nello stesso
    // campo; cursore, selezione e parola in composizione della tastiera
    // restano dove sono (la tastiera del telefono non perde la parola)
    final changes = buffer.sync(_windowSegments);
    if (changes.isEmpty) return;
    int map(int o) {
      for (final c in changes) {
        o = c.map(o);
      }
      return o.clamp(0, buffer.text.length);
    }

    final before = _controller.value;
    final sel = before.selection;
    final comp = before.composing;
    final composing = comp.isValid && !comp.isCollapsed
        ? TextRange(start: map(comp.start), end: map(comp.end))
        : TextRange.empty;
    _controller.value = TextEditingValue(
      text: buffer.text,
      selection: sel.isValid
          ? sel.copyWith(
              baseOffset: map(sel.baseOffset),
              extentOffset: map(sel.extentOffset),
            )
          : TextSelection.collapsed(offset: buffer.text.length),
      composing: composing.isCollapsed ? TextRange.empty : composing,
    );
    _refreshSpellSoon();
  }

  /// Il campo controlla l'ortografia solo quando scrive l'utente: dopo le
  /// frasi arrivate dalla trascrizione si chiede di nuovo il controllo
  /// (configurazione nuova, stesso correttore e stessa memoria: si
  /// controllano solo le frasi nuove), poco dopo l'ultima novità.
  Timer? _spellRefresh;
  void _refreshSpellSoon() {
    if (_spellService == null) return;
    _spellRefresh?.cancel();
    _spellRefresh = Timer(const Duration(milliseconds: 600), () {
      if (mounted && _editing) setState(() => _spell = _editSpell());
    });
  }

  SpellCheckService? get _spellService =>
      widget.spellService ?? spellCheckService(widget.language);

  /// Errori già trovati per frase nel campo di modifica (oltre a quelli
  /// della lettura, che si riusano: entrando nella modifica la linea rossa
  /// resta dov'era).
  final Map<String, List<SuggestionSpan>> _editErrors = {};

  SpellCheckConfiguration _editSpell() {
    final service = _spellService;
    return spellCheckFor(
      service == null
          ? null
          : SentenceSpellCheck(
              service,
              known: _checker.known,
              cache: _editErrors,
            ),
    );
  }

  @override
  void dispose() {
    _spellRefresh?.cancel();
    _checker.dispose();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Dal tocco nel testo disegnato alla modifica, con il cursore lì.
  void _startAt(Offset global, {bool word = false}) {
    if (widget.segments.isEmpty) return;
    // il blocco toccato (il primo che arriva sotto il punto, o l'ultimo)
    var at = -1;
    var hit = _blocks.length - 1;
    for (var i = 0; i < _blocks.length; i++) {
      final b = _blocks[i];
      final box = b.key.currentContext?.findRenderObject();
      if (box is RenderParagraph && box.hasSize) {
        final local = box.globalToLocal(global);
        if (local.dy < box.size.height || i == _blocks.length - 1) {
          at = _rawOffset(b, box.getPositionForOffset(local).offset);
          hit = i;
          break;
        }
      }
    }
    if (_blocks.length > 1 && hit >= 0) {
      // testo lungo: nel campo solo il blocco toccato
      _editFrom = _blocks[hit].keys.first;
      _editTo = hit + 1 < _blocks.length ? _blocks[hit + 1].keys.first : null;
      _before = _blocks.sublist(0, hit);
      _after = _blocks.sublist(hit + 1);
    } else {
      _editFrom = null;
      _editTo = null;
      _before = const [];
      _after = const [];
    }
    final buffer = TranscriptEditBuffer(_windowSegments);
    final raw = (at < 0 ? buffer.text.length : at).clamp(0, buffer.text.length);
    var selection = TextSelection.collapsed(offset: raw);
    if (word) selection = _wordAt(buffer.text, raw);
    setState(() {
      _buffer = buffer;
      _controller.value = TextEditingValue(
        text: buffer.text,
        selection: selection,
      );
    });
    widget.onEditing?.call(true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_editing) return;
      _focus.requestFocus();
      // controllo ortografico dopo l'apertura: il testo che c'è già si
      // sottolinea subito
      setState(() => _spell = _editSpell());
    });
  }

  static TextSelection _wordAt(String text, int at) {
    bool isWord(int i) =>
        i >= 0 &&
        i < text.length &&
        RegExp(r'[\p{L}\p{N}_]', unicode: true).hasMatch(text[i]);
    var a = at, b = at;
    while (isWord(a - 1)) {
      a--;
    }
    while (isWord(b)) {
      b++;
    }
    return a == b
        ? TextSelection.collapsed(offset: at)
        : TextSelection(baseOffset: a, extentOffset: b);
  }

  /// Dalla posizione [shown] nel paragrafo del blocco [b] a quella nel suo
  /// testo da modificare.
  static int _rawOffset(_ReadingBlock b, int shown) {
    for (final a in b.anchors) {
      if (shown > a.shown + a.shownLength) continue;
      if (a.shownLength == a.rawLength) {
        return a.raw + (shown - a.shown).clamp(0, a.rawLength);
      }
      // formula: prima o dopo
      return shown <= a.shown ? a.raw : a.raw + a.rawLength;
    }
    return b.raw;
  }

  void _changed(String text) {
    final edit = _buffer?.apply(text);
    if (edit != null) widget.onEdit(edit);
  }

  void _stop() {
    if (!_editing) return;
    _spellRefresh?.cancel();
    setState(() {
      _buffer = null;
      _spell = const SpellCheckConfiguration.disabled();
      _editFrom = null;
      _editTo = null;
      _before = const [];
      _after = const [];
    });
    widget.onEditing?.call(false);
  }

  /// Le frasi [texts] di un blocco come testo disegnato (formule comprese),
  /// con le posizioni per portare il cursore nel punto toccato.
  _ReadingBlock _readingBlock(
    List<int> keys,
    List<String> texts,
    List<List<SuggestionSpan>> errorsOf,
  ) {
    final children = <InlineSpan>[];
    final anchors = <_Anchor>[];
    var shown = 0, raw = 0;
    for (var i = 0; i < texts.length; i++) {
      final text = texts[i];
      if (i > 0) {
        children.add(const TextSpan(text: ' '));
        anchors.add(_Anchor(shown, 1, raw, 1));
        shown++;
        raw++;
      }
      // errori della frase (nelle posizioni del suo testo); le parti con le
      // formule li usano a tratti. Il testo disegnato è lo stesso, solo
      // diviso in tratti: le posizioni restano quelle.
      final errors = errorsOf[i];
      if (!mayContainMath(text)) {
        children.addAll(misspelledSpans(text, errors));
        anchors.add(_Anchor(shown, text.length, raw, text.length));
        shown += text.length;
        raw += text.length;
        continue;
      }
      final parts = parseMathOnly(text);
      var q = 0;
      for (var k = 0; k < parts.length; k++) {
        final part = parts[k];
        if (!part.math) {
          final found = text.indexOf(part.text, q);
          final at = found < 0 ? q : found;
          children.addAll(
            found < 0
                ? [TextSpan(text: part.text)]
                : misspelledSpans(
                    text,
                    errors,
                    start: at,
                    end: at + part.text.length,
                  ),
          );
          anchors.add(
            _Anchor(shown, part.text.length, raw + at, part.text.length),
          );
          shown += part.text.length;
          q = at + part.text.length;
          continue;
        }
        // la formula arriva fino al tratto di testo dopo
        var end = text.length;
        for (var j = k + 1; j < parts.length; j++) {
          if (parts[j].math) continue;
          final at = text.indexOf(parts[j].text, q);
          if (at >= 0) end = at;
          break;
        }
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: MathFormula(
              part.text,
              display: part.display,
              style: widget.style,
              source: part.source,
            ),
          ),
        );
        anchors.add(_Anchor(shown, 1, raw + q, math.max(0, end - q)));
        shown++;
        q = math.max(q, end);
      }
      raw += text.length;
    }
    return _ReadingBlock(
      keys,
      texts,
      errorsOf,
      TextSpan(children: children),
      anchors,
      raw,
    );
  }

  /// [segs] a blocchi di [kLiveReadingBlock] frasi (quelle vuote saltate,
  /// come nel campo di modifica): i blocchi di [previous] con le stesse
  /// frasi e gli stessi errori si riusano (stesso paragrafo, niente
  /// impaginazione).
  List<_ReadingBlock> _chunk(
    Iterable<TranscriptSegment> segs,
    List<_ReadingBlock> previous,
  ) {
    final list = [
      for (final s in segs)
        if (s.text.isNotEmpty) s,
    ];
    final out = <_ReadingBlock>[];
    for (var from = 0; from < list.length; from += kLiveReadingBlock) {
      final part = list.sublist(
        from,
        math.min(list.length, from + kLiveReadingBlock),
      );
      final k = [for (final s in part) s.start.inMilliseconds];
      final t = [for (final s in part) s.text];
      final e = [for (final x in t) _checker.errorsOf(x)];
      final i = out.length;
      final old = i < previous.length ? previous[i] : null;
      out.add(
        old != null && old.sameAs(k, t, e) ? old : _readingBlock(k, t, e),
      );
    }
    return out;
  }

  /// Paragrafo di un blocco senza il testo provvisorio, costruito una volta
  /// e ridisegnato a parte (il blocco che cambia non ridipinge gli altri).
  Widget _paragraph(_ReadingBlock b) => b.widget ??= RepaintBoundary(
    child: Text.rich(
      TextSpan(style: widget.style, children: [b.span]),
      key: b.key,
    ),
  );

  /// Il testo in lettura: un paragrafo per blocco, il testo provvisorio in
  /// fondo all'ultimo.
  Widget _readingView(InlineSpan? partial) {
    final blocks = _blocks = _chunk(widget.segments, _blocks);
    if (blocks.isEmpty) {
      return Text.rich(TextSpan(style: widget.style, children: [?partial]));
    }
    final last = blocks.length - 1;
    final paragraphs = [
      for (var i = 0; i < last; i++) _paragraph(blocks[i]),
      Text.rich(
        TextSpan(style: widget.style, children: [blocks[last].span, ?partial]),
        key: blocks[last].key,
      ),
    ];
    if (paragraphs.length == 1) return paragraphs.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: paragraphs,
    );
  }

  static const _noFrame = InputDecoration(
    isCollapsed: true,
    contentPadding: EdgeInsets.zero,
    filled: false,
    border: InputBorder.none,
    enabledBorder: InputBorder.none,
    focusedBorder: InputBorder.none,
    disabledBorder: InputBorder.none,
    errorBorder: InputBorder.none,
    focusedErrorBorder: InputBorder.none,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segs = widget.segments;
    final partialText = widget.partial;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
    if (_blocksStyle != widget.style) {
      // paragrafi già costruiti con lo stile di prima
      _blocks = const [];
      _before = const [];
      _after = const [];
      _blocksStyle = widget.style;
    }
    if (!_editing) {
      final partial = partialText.isEmpty
          ? null
          : TextSpan(
              text: '${segs.isEmpty ? '' : ' '}$partialText',
              style: muted,
            );
      return Semantics(
        hint: segs.isEmpty ? null : 'Tocca il testo per modificarlo',
        child: MouseRegion(
          cursor: segs.isEmpty ? MouseCursor.defer : SystemMouseCursors.text,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _startAt(d.globalPosition),
            onLongPressStart: (d) => _startAt(d.globalPosition, word: true),
            child: _readingView(partial),
          ),
        ),
      );
    }
    // i blocchi prima e dopo quello in modifica, in lettura
    final from = _editFrom, to = _editTo;
    final before = _before = from == null
        ? const <_ReadingBlock>[]
        : _chunk(segs.where((s) => s.start.inMilliseconds < from), _before);
    final after = _after = to == null
        ? const <_ReadingBlock>[]
        : _chunk(segs.where((s) => s.start.inMilliseconds >= to), _after);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in before) _paragraph(b),
        CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _focus.unfocus,
          },
          child: TextField(
            key: const Key('live-edit'),
            controller: _controller,
            focusNode: _focus,
            style: widget.style,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            // nessun riquadro: il tema dei campi ha bordo e fondo (anche
            // con la decorazione «collapsed» il bordo del tema compariva
            // attorno al testo), qui il testo resta com'era in lettura
            decoration: _noFrame,
            spellCheckConfiguration: _spell,
            contextMenuBuilder: spellCheckContextMenu,
            onChanged: _changed,
            onTapOutside: (_) => _focus.unfocus(),
          ),
        ),
        for (final b in after) _paragraph(b),
        if (partialText.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              partialText,
              style: widget.style?.merge(muted) ?? muted,
            ),
          ),
      ],
    );
  }
}
