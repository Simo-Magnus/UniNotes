import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

/// Archivio ZIP (OOXML, ODF, EPUB, XPS, contenitori Apple, ...) con ricerca
/// dei file senza distinzione di maiuscole e percorsi relativi risolti.
class Zip {
  Zip(Uint8List bytes) : archive = ZipDecoder().decodeBytes(bytes) {
    for (final f in archive.files) {
      if (f.isFile) _byLower[_norm(f.name).toLowerCase()] = f;
    }
  }

  /// Archivio o null se i byte non sono uno ZIP valido.
  static Zip? tryOpen(Uint8List bytes) {
    try {
      return Zip(bytes);
    } catch (_) {
      return null;
    }
  }

  final Archive archive;
  final _byLower = <String, ArchiveFile>{};

  static String _norm(String name) {
    var n = name.replaceAll('\\', '/');
    while (n.startsWith('/')) {
      n = n.substring(1);
    }
    return p.posix.normalize(n);
  }

  /// Nomi dei file (non cartelle), come nell'archivio.
  List<String> get names => [
    for (final f in archive.files)
      if (f.isFile) f.name,
  ];

  bool has(String name) => _byLower.containsKey(_norm(name).toLowerCase());

  Uint8List? bytes(String name) {
    final f =
        _byLower[_norm(Uri.decodeFull(name)).toLowerCase()] ??
        _byLower[_norm(name).toLowerCase()];
    return f?.readBytes();
  }

  String? text(String name) {
    final b = bytes(name);
    return b == null ? null : utf8.decode(b, allowMalformed: true);
  }

  XmlDocument? xml(String name) {
    final t = text(name);
    if (t == null) return null;
    try {
      return XmlDocument.parse(t);
    } catch (_) {
      return null;
    }
  }

  /// Percorso di [target] relativo al file [from] (es. relazioni OOXML).
  static String resolve(String from, String target) {
    if (target.startsWith('/')) return _norm(target);
    final dir = p.posix.dirname(_norm(from));
    return _norm(p.posix.join(dir == '.' ? '' : dir, target));
  }
}

/// Elementi XML per nome locale, qualunque sia il prefisso.
extension XmlLocal on XmlElement {
  String get local => name.local;

  Iterable<XmlElement> kids(String local) =>
      childElements.where((e) => e.name.local == local);

  XmlElement? kid(String local) {
    for (final e in childElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  Iterable<XmlElement> desc(String local) =>
      descendantElements.where((e) => e.name.local == local);

  XmlElement? firstDesc(String local) {
    for (final e in descendantElements) {
      if (e.name.local == local) return e;
    }
    return null;
  }

  /// Attributo per nome locale (preferendo quello senza prefisso se
  /// [prefixed] è false, con prefisso se è true).
  String? attr(String local, {bool? prefixed}) {
    String? any;
    for (final a in attributes) {
      if (a.name.local != local) continue;
      final hasPrefix = a.name.prefix != null;
      if (prefixed == null || prefixed == hasPrefix) return a.value;
      any ??= a.value;
    }
    return prefixed == null ? any : null;
  }
}

/// Relazioni di una parte OOXML (`_rels/xxx.rels`): id → (target, tipo).
Map<String, ({String target, String type, bool external})> readRels(
  Zip zip,
  String part,
) {
  final dir = p.posix.dirname(part);
  final rels = zip.xml(
    '${dir == '.' ? '' : '$dir/'}_rels/${p.posix.basename(part)}.rels',
  );
  final out = <String, ({String target, String type, bool external})>{};
  if (rels == null) return out;
  for (final r in rels.rootElement.kids('Relationship')) {
    final id = r.attr('Id');
    final target = r.attr('Target');
    if (id == null || target == null) continue;
    final external = r.attr('TargetMode') == 'External';
    out[id] = (
      target: external ? target : Zip.resolve(part, target),
      type: r.attr('Type') ?? '',
      external: external,
    );
  }
  return out;
}
