import 'dart:typed_data';

import '../reader_document.dart';
import 'text_formats.dart';

/// Rich Text Format (.rtf): testo, grassetto/corsivo/sottolineato, titoli
/// (livello di struttura), tabelle e immagini PNG/JPEG incorporate.

class _RtfState {
  bool bold = false;
  bool italic = false;
  bool underline = false;
  bool strike = false;

  /// Gruppo da ignorare (tabella dei caratteri, intestazioni, ...).
  bool skip = false;

  /// Dentro `\nonshppict` (copia di riserva delle immagini): ignorata.
  bool noPict = false;

  /// Caratteri da saltare dopo `\u`.
  int uc = 1;

  /// Gruppo `\pict`: tipo dell'immagine e cifre esadecimali.
  String? pict;
  StringBuffer? pictHex;

  _RtfState copy() => _RtfState()
    ..bold = bold
    ..italic = italic
    ..underline = underline
    ..strike = strike
    ..skip = skip
    ..noPict = noPict
    ..uc = uc
    ..pict = null
    ..pictHex = pictHex;
}

const _skipDestinations = {
  'fonttbl', 'colortbl', 'stylesheet', 'info', 'header', 'footer', //
  'headerl', 'headerr', 'headerf', 'footerl', 'footerr', 'footerf',
  'object', 'themedata', 'colorschememapping', 'latentstyles',
  'datastore', 'xmlnstbl', 'listtable', 'listoverridetable', 'rsidtbl',
  'generator', 'pgdsctbl', 'fldinst', 'revtbl', 'filetbl', 'bkmkstart',
  'bkmkend', 'nonshppict', 'xe', 'tc', 'private', 'userprops',
  'mmathPr', 'wgrffmtfilter', 'listtext', 'pnseclvl', 'shpinst', 'atnauthor',
};

RDoc parseRtf(Uint8List bytes) {
  final src = decodeCp1252(bytes);
  final blocks = <RBlock>[];
  final tables = <RTable>[];
  // parti non mostrate (per l'avviso all'apertura)
  final limits = <String>{};
  final para = RParaBuilder();
  var st = _RtfState();
  final stack = <_RtfState>[];
  var outline = -1;
  var inTable = false;
  var cells = <String>[];
  RTable? table;
  var tableId = -1;
  var pendingUnicodeSkip = 0;

  void emit(String t) {
    if (st.skip || t.isEmpty) return;
    if (pendingUnicodeSkip > 0) {
      final n = pendingUnicodeSkip < t.length ? pendingUnicodeSkip : t.length;
      pendingUnicodeSkip -= n;
      t = t.substring(n);
      if (t.isEmpty) return;
    }
    para.add(
      RSpan(
        t,
        bold: st.bold,
        italic: st.italic,
        underline: st.underline,
        strike: st.strike,
      ),
    );
  }

  void endPara() {
    if (inTable) return;
    if (para.isEmpty) {
      para.clear();
      return;
    }
    final style = switch (outline) {
      0 => RStyle.h1,
      1 => RStyle.h2,
      2 => RStyle.h3,
      >= 3 && <= 8 => RStyle.h4,
      _ => RStyle.body,
    };
    final text = para.text.trimLeft();
    if (text.startsWith('•') || text.startsWith('·')) {
      final p = para.build();
      final spans = [...p.spans];
      spans[0] = spans[0].withText(
        spans[0].text.replaceFirst(RegExp(r'^[•·]\s*'), ''),
      );
      blocks.add(RPara(spans, style: RStyle.list, marker: '•'));
    } else {
      blocks.add(para.build(style: style));
    }
  }

  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '{') {
      stack.add(st);
      st = st.copy();
      i++;
      continue;
    }
    if (c == '}') {
      final closing = st;
      st = stack.isEmpty ? _RtfState() : stack.removeLast();
      if (closing.pict != null &&
          closing.pictHex != null &&
          st.pictHex != closing.pictHex) {
        final hex = closing.pictHex.toString();
        if (closing.pict == 'png' || closing.pict == 'jpeg') {
          final data = Uint8List(hex.length ~/ 2);
          for (var k = 0; k + 1 < hex.length; k += 2) {
            data[k ~/ 2] =
                int.tryParse(hex.substring(k, k + 2), radix: 16) ?? 0;
          }
          endPara();
          blocks.add(RImage(data));
        } else {
          limits.add('immagini in formato WMF/EMF');
        }
      }
      i++;
      continue;
    }
    if (c == '\\') {
      if (i + 1 >= src.length) break;
      final n = src[i + 1];
      if (RegExp(r'[a-zA-Z]').hasMatch(n)) {
        var j = i + 1;
        while (j < src.length && _isAlpha(src.codeUnitAt(j))) {
          j++;
        }
        final word = src.substring(i + 1, j);
        var k = j;
        if (k < src.length && (src[k] == '-' || _isDigit(src.codeUnitAt(k)))) {
          k++;
          while (k < src.length && _isDigit(src.codeUnitAt(k))) {
            k++;
          }
        }
        final param = k > j ? int.tryParse(src.substring(j, k)) : null;
        if (k < src.length && src[k] == ' ') k++;
        i = k;
        if (_skipDestinations.contains(word)) {
          st.skip = true;
          if (word == 'nonshppict') st.noPict = true;
          continue;
        }
        switch (word) {
          case 'par' || 'sect' || 'page':
            endPara();
          case 'line':
            emit('\n');
          case 'tab':
            emit(inTable ? ' ' : '\t');
          case 'b':
            st.bold = param != 0;
          case 'i':
            st.italic = param != 0;
          case 'ul' || 'uld' || 'uldb' || 'ulw':
            st.underline = param != 0;
          case 'ulnone':
            st.underline = false;
          case 'strike' || 'striked':
            st.strike = param != 0;
          case 'plain':
            st
              ..bold = false
              ..italic = false
              ..underline = false
              ..strike = false;
          case 'pard':
            outline = -1;
            if (inTable && cells.isEmpty && para.isEmpty) inTable = false;
          case 'outlinelevel':
            outline = param ?? -1;
          case 'intbl':
            if (!inTable) {
              endPara();
              inTable = true;
              if (table == null) {
                tableId = tables.length;
                table = RTable([]);
                tables.add(table);
              }
            }
          case 'cell' || 'nestcell':
            cells.add(para.text.trim());
            para.clear();
          case 'row' || 'nestrow':
            if (cells.isNotEmpty && table != null) {
              table.fit(cells);
              blocks.add(RTableRow(cells, table: tableId));
            }
            cells = <String>[];
            inTable = false;
          case 'trowd':
            inTable = true;
            if (table == null) {
              tableId = tables.length;
              table = RTable([]);
              tables.add(table);
            }
          case 'uc':
            st.uc = param ?? 1;
          case 'u':
            var code = param ?? 0;
            if (code < 0) code += 65536;
            emit(String.fromCharCode(code));
            pendingUnicodeSkip = st.uc;
          case 'emdash':
            emit('—');
          case 'endash':
            emit('–');
          case 'bullet':
            emit('•');
          case 'lquote':
            emit('‘');
          case 'rquote':
            emit('’');
          case 'ldblquote':
            emit('“');
          case 'rdblquote':
            emit('”');
          case 'pict':
            if (st.noPict) continue;
            st.pict = 'other';
            st.pictHex = StringBuffer();
            st.skip = true;
          case 'pngblip':
            if (st.pict != null) st.pict = 'png';
          case 'jpegblip':
            if (st.pict != null) st.pict = 'jpeg';
          case 'bin':
            i += param ?? 0;
        }
        // Una tabella finisce al primo paragrafo fuori da \intbl.
        if (word == 'pard') table = inTable ? table : null;
        continue;
      }
      // Simboli di controllo.
      switch (n) {
        case '\'':
          if (i + 3 < src.length) {
            final v = int.tryParse(src.substring(i + 2, i + 4), radix: 16);
            if (v != null) emit(decodeCp1252([v]));
          }
          i += 4;
          continue;
        case '*':
          st.skip = true;
        case '~':
          emit(' ');
        case '_':
          emit('-');
        case '\\' || '{' || '}':
          emit(n);
        case '\n' || '\r':
          endPara();
      }
      i += 2;
      continue;
    }
    if (c == '\r' || c == '\n') {
      i++;
      continue;
    }
    if (st.pictHex != null && st.pict != null) {
      if (_isHex(c.codeUnitAt(0))) st.pictHex!.write(c);
      i++;
      continue;
    }
    // Testo normale fino al prossimo carattere speciale.
    var j = i;
    while (j < src.length && !'{}\\\r\n'.contains(src[j])) {
      j++;
    }
    emit(src.substring(i, j));
    i = j;
  }
  endPara();
  return RDoc(
    sections: [RSection('', blocks)],
    tables: tables,
    limits: limits.toList(),
  );
}

bool _isAlpha(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isHex(int c) =>
    _isDigit(c) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102);
