/// Converte l'HTML di una email in testo leggibile (senza dipendenze).
///
/// Non è un parser completo: toglie stili e script, trasforma blocchi e
/// `<br>` in a capo, le voci di elenco in «• », i link in «testo (url)» e
/// decodifica le entità più comuni.
String htmlToText(String html) {
  var s = html;
  s = s.replaceAll(
    RegExp(
      r'<(script|style|head|title)[^>]*>.*?</\1\s*>',
      caseSensitive: false,
      dotAll: true,
    ),
    '',
  );
  s = s.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  // Link: «testo (url)» se il testo non è già l'indirizzo.
  s = s.replaceAllMapped(
    RegExp(
      r'''<a\s[^>]*href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a\s*>''',
      caseSensitive: false,
      dotAll: true,
    ),
    (m) {
      final url = m[1]!.trim();
      final label = m[2]!.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      if (url.startsWith('mailto:') || label.isEmpty || label == url) {
        return label.isEmpty ? url : label;
      }
      return '$label ($url)';
    },
  );
  s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
  s = s.replaceAll(RegExp(r'<li[^>]*>', caseSensitive: false), '\n• ');
  s = s.replaceAll(
    RegExp(
      r'</?(p|div|tr|table|h[1-6]|ul|ol|blockquote|section|article|header|footer)[^>]*>',
      caseSensitive: false,
    ),
    '\n',
  );
  s = s.replaceAll(RegExp(r'</t[dh]\s*>', caseSensitive: false), '\t');
  s = s.replaceAll(RegExp(r'<[^>]+>'), '');
  s = decodeHtmlEntities(s);
  s = s.replaceAll('\r', '');
  s = s.replaceAll(RegExp(r'[ \t ]+\n'), '\n');
  s = s.replaceAll(RegExp(r'\n[ \t ]+'), '\n');
  s = s.replaceAll(RegExp(r'[ \t]{2,}'), ' ');
  s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return s.trim();
}

const _entities = {
  'nbsp': ' ',
  'amp': '&',
  'lt': '<',
  'gt': '>',
  'quot': '"',
  'apos': "'",
  'egrave': 'è',
  'eacute': 'é',
  'agrave': 'à',
  'aacute': 'á',
  'igrave': 'ì',
  'ograve': 'ò',
  'ugrave': 'ù',
  'Egrave': 'È',
  'Eacute': 'É',
  'Agrave': 'À',
  'euro': '€',
  'copy': '©',
  'reg': '®',
  'hellip': '…',
  'ndash': '–',
  'mdash': '—',
  'laquo': '«',
  'raquo': '»',
  'rsquo': '’',
  'lsquo': '‘',
  'rdquo': '”',
  'ldquo': '“',
  'bull': '•',
  'deg': '°',
};

String decodeHtmlEntities(String s) =>
    s.replaceAllMapped(RegExp(r'&(#x?[0-9a-fA-F]+|[a-zA-Z]+);'), (m) {
      final e = m[1]!;
      if (e.startsWith('#')) {
        final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
        final code = int.tryParse(
          hex ? e.substring(2) : e.substring(1),
          radix: hex ? 16 : 10,
        );
        if (code == null || code > 0x10FFFF) return m[0]!;
        return String.fromCharCode(code);
      }
      return _entities[e] ?? m[0]!;
    });
