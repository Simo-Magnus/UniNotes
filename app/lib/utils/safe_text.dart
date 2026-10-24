/// Testo sicuro da disegnare: niente metà di una coppia surrogata.
///
/// Flutter rifiuta ogni stringa con una unità UTF-16 spaiata (la prima o la
/// seconda metà di un carattere fuori dal piano base: emoji, ideogrammi
/// rari, simboli matematici) con `ArgumentError: string is not
/// well-formed UTF-16` appena la disegna, e la schermata diventa rossa. Una
/// unità spaiata nasce da:
/// - un taglio con `substring` o `[i]` in mezzo a una coppia (nomi accorciati
///   a N caratteri, frammenti attorno a una parola cercata, paragrafi divisi
///   a metà);
/// - dati letti da fuori: un numero scritto come `&#xD800;` in un XML, un
///   `\ud800` in un JSON, un file UTF-16 troncato, un RTF con `\u-10179`.
///
/// Qui ci sono i due rimedi: tagliare senza spezzare ([cutBefore],
/// [safePrefix], [safeSlice]) e ripulire ciò che arriva da fuori
/// ([wellFormed], [wellFormedJson]).
library;

bool _isHigh(int u) => u >= 0xD800 && u <= 0xDBFF;
bool _isLow(int u) => u >= 0xDC00 && u <= 0xDFFF;

/// Il testo ha almeno una unità UTF-16 spaiata.
bool hasLoneSurrogate(String s) {
  final n = s.length;
  for (var i = 0; i < n; i++) {
    final u = s.codeUnitAt(i);
    if (u < 0xD800 || u > 0xDFFF) continue;
    if (_isHigh(u) && i + 1 < n && _isLow(s.codeUnitAt(i + 1))) {
      i++;
      continue;
    }
    return true;
  }
  return false;
}

/// [s] con ogni unità spaiata sostituita da U+FFFD (il carattere che Flutter
/// e i file UTF-8 usano già per i dati non validi). Senza unità spaiate
/// restituisce lo stesso oggetto, senza copie.
String wellFormed(String s) {
  if (!hasLoneSurrogate(s)) return s;
  final b = StringBuffer();
  final n = s.length;
  for (var i = 0; i < n; i++) {
    final u = s.codeUnitAt(i);
    if (_isHigh(u) && i + 1 < n && _isLow(s.codeUnitAt(i + 1))) {
      b
        ..writeCharCode(u)
        ..writeCharCode(s.codeUnitAt(i + 1));
      i++;
    } else if (_isHigh(u) || _isLow(u)) {
      b.writeCharCode(0xFFFD);
    } else {
      b.writeCharCode(u);
    }
  }
  return b.toString();
}

/// Valore JSON (liste, mappe, stringhe) con ogni stringa e ogni chiave
/// passata da [wellFormed]; il resto resta uguale. Le liste e le mappe
/// senza stringhe da correggere non si copiano.
Object? wellFormedJson(Object? v) {
  if (v is String) return wellFormed(v);
  if (v is List) {
    List<Object?>? copy;
    for (var i = 0; i < v.length; i++) {
      final c = wellFormedJson(v[i]);
      if (!identical(c, v[i])) {
        copy ??= List<Object?>.of(v);
        copy[i] = c;
      }
    }
    return copy ?? v;
  }
  if (v is Map<String, dynamic>) {
    // come lo dà `jsonDecode`: il tipo resta Map<String, dynamic>
    Map<String, dynamic>? copy;
    for (final e in v.entries) {
      final k = wellFormed(e.key);
      final c = wellFormedJson(e.value);
      if (!identical(k, e.key) || !identical(c, e.value)) {
        copy ??= Map<String, dynamic>.of(v);
        if (!identical(k, e.key)) copy.remove(e.key);
        copy[k] = c;
      }
    }
    return copy ?? v;
  }
  if (v is Map) {
    Map<Object?, Object?>? copy;
    for (final e in v.entries) {
      final k = e.key is String ? wellFormed(e.key as String) : e.key;
      final c = wellFormedJson(e.value);
      if (!identical(k, e.key) || !identical(c, e.value)) {
        copy ??= Map<Object?, Object?>.of(v);
        if (!identical(k, e.key)) copy.remove(e.key);
        copy[k] = c;
      }
    }
    return copy ?? v;
  }
  return v;
}

/// Il primo indice `<= end` (limitato a 0 e alla lunghezza) in cui si può
/// tagliare [s] senza spezzare una coppia surrogata.
int cutBefore(String s, int end) {
  if (end <= 0) return 0;
  if (end >= s.length) return s.length;
  if (_isLow(s.codeUnitAt(end)) && _isHigh(s.codeUnitAt(end - 1))) {
    return end - 1;
  }
  return end;
}

/// Il primo indice `>= start` (limitato a 0 e alla lunghezza) da cui si può
/// cominciare un frammento di [s] senza spezzare una coppia surrogata.
int cutAfter(String s, int start) {
  if (start <= 0) return 0;
  if (start >= s.length) return s.length;
  if (_isLow(s.codeUnitAt(start)) && _isHigh(s.codeUnitAt(start - 1))) {
    return start + 1;
  }
  return start;
}

/// Al massimo [max] unità UTF-16 iniziali di [s], senza spezzare una coppia.
String safePrefix(String s, int max) =>
    s.length <= max ? s : s.substring(0, cutBefore(s, max));

/// `s.substring(start, end)` con gli estremi limitati al testo e portati
/// fuori da una coppia surrogata (il frammento perde al massimo i due
/// mezzi caratteri ai bordi).
String safeSlice(String s, int start, [int? end]) {
  final to = cutBefore(s, end ?? s.length);
  final from = cutAfter(s, start);
  return from >= to ? '' : s.substring(from, to);
}

/// Il primo carattere di [s] in maiuscolo e il resto uguale (coppie
/// surrogate intere; `s[0].toUpperCase()` ne avrebbe preso metà).
String capitalizeFirst(String s) {
  if (s.isEmpty) return s;
  final n = s.length > 1 && _isHigh(s.codeUnitAt(0)) && _isLow(s.codeUnitAt(1))
      ? 2
      : 1;
  return s.substring(0, n).toUpperCase() + s.substring(n);
}
