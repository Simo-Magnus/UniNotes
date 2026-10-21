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

/// Il testo della trascrizione come in un editor (Blocco note): le frasi una
/// dopo l'altra separate da uno spazio, con la posizione di ognuna. Una
/// modifica qualsiasi (scrivere, cancellare, incollare, sostituire una
/// selezione) si riporta sulle frasi toccate ([apply]): se tocca più frasi
/// diventano una sola (con l'inizio della prima e la fine dell'ultima),
/// quelle non toccate tengono i loro tempi. Le frasi nuove che arrivano
/// mentre si scrive si inseriscono al loro posto ([sync]).
class TranscriptEditBuffer {
  TranscriptEditBuffer(List<TranscriptSegment> segments) {
    final b = StringBuffer();
    for (final s in segments) {
      if (b.isNotEmpty) b.write(' ');
      final start = b.length;
      b.write(s.text);
      pieces.add(TranscriptPiece(s.start.inMilliseconds, start, b.length));
    }
    text = b.toString();
  }

  String text = '';
  final List<TranscriptPiece> pieces = [];

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
    if (merged.trim().isEmpty) pieces.removeAt(first);
    return TranscriptEdit(keys, merged);
  }

  /// Frasi di [segments] che il testo non ha ancora (arrivate mentre si
  /// scrive): si inseriscono al loro posto. Restituisce gli inserimenti
  /// (posizione, lunghezza, in fondo al testo) per spostare il cursore.
  List<(int, int, bool)> sync(List<TranscriptSegment> segments) {
    final known = {for (final x in pieces) x.key};
    final out = <(int, int, bool)>[];
    for (final seg in segments) {
      final key = seg.start.inMilliseconds;
      if (known.contains(key) || seg.text.isEmpty) continue;
      known.add(key);
      final j = pieces.indexWhere((x) => x.key > key);
      final int at;
      final String insert;
      final int pieceStart;
      if (j < 0) {
        at = text.length;
        insert = text.isEmpty ? seg.text : ' ${seg.text}';
        pieceStart = at + insert.length - seg.text.length;
      } else {
        at = pieces[j].start;
        insert = '${seg.text} ';
        pieceStart = at;
      }
      text = text.replaceRange(at, at, insert);
      for (var i = j < 0 ? pieces.length : j; i < pieces.length; i++) {
        pieces[i]
          ..start += insert.length
          ..end += insert.length;
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
      out.add((at, insert.length, j < 0));
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

/// Testo dal vivo modificabile come in un normale editor di testo (Blocco
/// note, Google Docs): un tocco (o un clic) in un punto qualsiasi del testo
/// mette lì il cursore e si scrive, cancella, seleziona, copia e incolla
/// direttamente nel testo, mentre la registrazione e la trascrizione
/// continuano (le frasi nuove arrivano in fondo, quella provvisoria sotto,
/// più chiara). Le modifiche si salvano da sole a ogni tasto ([onEdit]).
///
/// Due modalità con passaggio immediato: **lettura** con le formule
/// (`$…$`) disegnate e **modifica** con il testo semplice (le formule in
/// LaTeX). Il tocco passa alla modifica con il cursore nel punto toccato;
/// Esc o un tocco fuori tornano alla lettura. Senza formule le due modalità
/// hanno lo stesso aspetto.
///
/// Controllo ortografico del sistema ([spellCheckService]): parole errate
/// con la linea ondulata rossa e suggerimenti nel menu (tasto destro sul
/// PC, tocco sulla parola sul telefono).
class EditableLiveTranscript extends StatefulWidget {
  const EditableLiveTranscript({
    super.key,
    required this.segments,
    required this.partial,
    required this.onEdit,
    this.style,
    this.onEditing,
    this.language = 'it',
  });

  final List<TranscriptSegment> segments;
  final String partial;
  final TextStyle? style;

  /// Lingua principale del controllo ortografico ('it' o 'en').
  final String language;

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
  final _text = GlobalKey();
  TranscriptEditBuffer? _buffer;
  List<_Anchor> _anchors = const [];
  int _rawLength = 0;
  SpellCheckConfiguration _spell = const SpellCheckConfiguration.disabled();

  bool get _editing => _buffer != null;

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
    final buffer = _buffer;
    if (buffer == null) return;
    // frasi nuove mentre si scrive: al loro posto, il cursore resta dov'è
    final inserted = buffer.sync(widget.segments);
    if (inserted.isEmpty) return;
    var sel = _controller.selection;
    for (final (at, len, end) in inserted) {
      // in fondo il cursore resta prima del testo nuovo, in mezzo lo segue
      int move(int o) => o > at || (o == at && !end) ? o + len : o;
      if (sel.isValid) {
        sel = sel.copyWith(
          baseOffset: move(sel.baseOffset),
          extentOffset: move(sel.extentOffset),
        );
      }
    }
    _controller.value = TextEditingValue(
      text: buffer.text,
      selection: sel.isValid
          ? sel
          : TextSelection.collapsed(offset: buffer.text.length),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Dal tocco nel testo disegnato alla modifica, con il cursore lì.
  void _startAt(Offset global, {bool word = false}) {
    if (widget.segments.isEmpty) return;
    var shown = -1;
    final box = _text.currentContext?.findRenderObject();
    if (box is RenderParagraph && box.hasSize) {
      shown = box.getPositionForOffset(box.globalToLocal(global)).offset;
    }
    final buffer = TranscriptEditBuffer(widget.segments);
    final raw = (shown < 0 ? _rawLength : _rawOffset(shown)).clamp(
      0,
      buffer.text.length,
    );
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
      final next = spellCheckFor(spellCheckService(widget.language));
      if (next != _spell) setState(() => _spell = next);
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

  int _rawOffset(int shown) {
    for (final a in _anchors) {
      if (shown > a.shown + a.shownLength) continue;
      if (a.shownLength == a.rawLength) {
        return a.raw + (shown - a.shown).clamp(0, a.rawLength);
      }
      // formula: prima o dopo
      return shown <= a.shown ? a.raw : a.raw + a.rawLength;
    }
    return _rawLength;
  }

  void _changed(String text) {
    final edit = _buffer?.apply(text);
    if (edit != null) widget.onEdit(edit);
  }

  void _stop() {
    if (!_editing) return;
    setState(() {
      _buffer = null;
      _spell = const SpellCheckConfiguration.disabled();
    });
    widget.onEditing?.call(false);
  }

  /// Le frasi come testo disegnato (formule comprese), con le posizioni
  /// per portare il cursore nel punto toccato.
  InlineSpan _reading() {
    final children = <InlineSpan>[];
    final anchors = <_Anchor>[];
    var shown = 0, raw = 0;
    final segs = widget.segments;
    for (var i = 0; i < segs.length; i++) {
      final text = segs[i].text;
      if (i > 0) {
        children.add(const TextSpan(text: ' '));
        anchors.add(_Anchor(shown, 1, raw, 1));
        shown++;
        raw++;
      }
      if (!mayContainMath(text)) {
        children.add(TextSpan(text: text));
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
          var at = text.indexOf(part.text, q);
          if (at < 0) at = q;
          children.add(TextSpan(text: part.text));
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
    _anchors = anchors;
    _rawLength = raw;
    return TextSpan(children: children);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final segs = widget.segments;
    final partialText = widget.partial;
    final muted = TextStyle(color: theme.colorScheme.onSurfaceVariant);
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
            child: Text.rich(
              TextSpan(style: widget.style, children: [_reading(), ?partial]),
              key: _text,
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            decoration: const InputDecoration.collapsed(hintText: null),
            spellCheckConfiguration: _spell,
            contextMenuBuilder: spellCheckContextMenu,
            onChanged: _changed,
            onTapOutside: (_) => _focus.unfocus(),
          ),
        ),
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
