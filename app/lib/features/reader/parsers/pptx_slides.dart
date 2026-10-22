import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'zip_util.dart';

/// Diapositive di PowerPoint (.pptx, .ppsx, .potx) disegnate come
/// nell'originale ([RSlide]): sfondo, immagini e forme dello schema e del
/// layout, segnaposto con le posizioni e gli stili ereditati, caselle di
/// testo (dimensioni, colori, allineamento, elenchi), immagini (anche
/// ritagliate), forme semplici e a mano libera, tabelle, gruppi e SmartArt
/// (dal disegno salvato da PowerPoint).
///
/// Non disegnati (finiscono in [PptxSlides.limits], così l'app propone
/// l'app di riferimento): grafici, immagini EMF/WMF, oggetti incorporati,
/// formule senza immagine di ripiego, video. Effetti, ombre, sfumature
/// (si usa il primo colore) e caratteri del tema sono approssimati.

/// EMU per punto.
const double _emu = 12700;

typedef _Rels = Map<String, ({String target, String type, bool external})>;

class _Part {
  _Part(this.name, this.xml, this.rels);
  final String name;
  final XmlDocument xml;
  final _Rels rels;

  XmlElement get root => xml.rootElement;
  XmlElement? get spTree => root.kid('cSld')?.kid('spTree');

  String? relOfType(String suffix) {
    for (final r in rels.values) {
      if (r.type.endsWith(suffix)) return r.target;
    }
    return null;
  }
}

/// Riempimento: [none] = nessuno; altrimenti colore o immagine.
class _Fill {
  const _Fill({this.none = false, this.color, this.image});
  final bool none;
  final int? color;
  final Uint8List? image;
}

/// Trasformazione dei gruppi (in EMU): x' = x·sx + dx.
class _Tx {
  const _Tx([this.sx = 1, this.sy = 1, this.dx = 0, this.dy = 0]);
  final double sx;
  final double sy;
  final double dx;
  final double dy;

  _Tx then(_Tx inner) => _Tx(
    sx * inner.sx,
    sy * inner.sy,
    dx + inner.dx * sx,
    dy + inner.dy * sy,
  );
}

/// Posizione di una forma (EMU) con rotazione e ribaltamenti.
class _Xfrm {
  const _Xfrm(this.x, this.y, this.w, this.h, this.rot, this.flipH, this.flipV);
  final double x;
  final double y;
  final double w;
  final double h;
  final double rot;
  final bool flipH;
  final bool flipV;

  static _Xfrm? of(XmlElement? xfrm) {
    if (xfrm == null) return null;
    final off = xfrm.kid('off');
    final ext = xfrm.kid('ext');
    if (off == null || ext == null) return null;
    double n(XmlElement e, String a) => double.tryParse(e.attr(a) ?? '') ?? 0;
    return _Xfrm(
      n(off, 'x'),
      n(off, 'y'),
      n(ext, 'cx'),
      n(ext, 'cy'),
      (double.tryParse(xfrm.attr('rot') ?? '') ?? 0) / 60000,
      xfrm.attr('flipH') == '1',
      xfrm.attr('flipV') == '1',
    );
  }
}

/// Fonti delle proprietà di un paragrafo, dalla più specifica.
typedef _Levels = List<XmlElement?> Function(int level);

/// Lettore delle diapositive di una presentazione.
class PptxSlides {
  PptxSlides(this.zip, String presentationPart) {
    final pres = zip.xml(presentationPart);
    final sz = pres?.rootElement.kid('sldSz');
    width = (double.tryParse(sz?.attr('cx') ?? '') ?? 9144000) / _emu;
    height = (double.tryParse(sz?.attr('cy') ?? '') ?? 6858000) / _emu;
    _defaultText = pres?.rootElement.kid('defaultTextStyle');
  }

  final Zip zip;
  late final double width;
  late final double height;
  XmlElement? _defaultText;

  /// Parti del file non disegnate (per l'avviso all'apertura).
  final limits = <String>{};

  final _parts = <String, _Part?>{};
  final _images = <String, Uint8List?>{};
  final _themes = <String, Map<String, int>>{};
  final _layerShapes = <String, List<RShape>>{};

  // Contesto della diapositiva in corso.
  late _Part _slide;

  /// Una forma della diapositiva non ha una posizione (né sua né del
  /// layout): la diapositiva non si disegna.
  bool _unplaced = false;
  _Part? _layout;
  _Part? _master;
  Map<String, int> _scheme = const {};
  Map<String, String> _clrMap = const {};

  _Part? _part(String? name) {
    if (name == null) return null;
    return _parts.putIfAbsent(name, () {
      final x = zip.xml(name);
      return x == null ? null : _Part(name, x, readRels(zip, name));
    });
  }

  /// La diapositiva [name] (es. "ppt/slides/slide1.xml"), o null.
  RSlide? slide(String name) {
    final s = _part(name);
    if (s == null) return null;
    _slide = s;
    _unplaced = false;
    _layout = _part(s.relOfType('/slideLayout'));
    _master = _part(_layout?.relOfType('/slideMaster'));
    _scheme = _theme(_master);
    _clrMap = {
      for (final a in _master?.root.kid('clrMap')?.attributes ?? <XmlAttribute>[])
        a.name.local: a.value,
    };
    final ovr = s.root.kid('clrMapOvr')?.kid('overrideClrMapping');
    if (ovr != null) {
      _clrMap = {for (final a in ovr.attributes) a.name.local: a.value};
    }
    final shapes = <RShape>[];
    final showMaster = s.root.attr('showMasterSp') != '0';
    if (showMaster) {
      final layoutShowsMaster = _layout?.root.attr('showMasterSp') != '0';
      if (layoutShowsMaster) shapes.addAll(_layer(_master));
      shapes.addAll(_layer(_layout));
    }
    final tree = s.spTree;
    if (tree != null) _tree(tree, s, const _Tx(), shapes, layer: false);
    // testo o immagini senza posizione (file incompleti): meglio il testo
    // in sequenza che una diapositiva a cui manca qualcosa
    if (_unplaced) return null;
    final (bg, bgImage) = _background();
    return RSlide(
      width: width,
      height: height,
      shapes: shapes,
      background: bg,
      backgroundImage: bgImage,
    );
  }

  /// Forme (non segnaposto) dello schema o del layout, una volta sola.
  List<RShape> _layer(_Part? part) {
    if (part == null) return const [];
    return _layerShapes.putIfAbsent(part.name, () {
      final out = <RShape>[];
      final tree = part.spTree;
      if (tree != null) _tree(tree, part, const _Tx(), out, layer: true);
      return out;
    });
  }

  Map<String, int> _theme(_Part? master) {
    final name = master?.relOfType('/theme');
    if (name == null) return const {};
    return _themes.putIfAbsent(name, () {
      final out = <String, int>{};
      final x = zip.xml(name);
      final scheme = x?.rootElement.firstDesc('clrScheme');
      for (final c in scheme?.childElements ?? const <XmlElement>[]) {
        final v = c.kid('srgbClr')?.attr('val') ??
            c.kid('sysClr')?.attr('lastClr');
        final rgb = int.tryParse(v ?? '', radix: 16);
        if (rgb != null) out[c.local] = 0xFF000000 | rgb;
      }
      return out;
    });
  }

  // ------------------------------------------------------------ Colori

  /// Colore del primo elemento di colore dentro [holder] (ARGB), con le
  /// modifiche (luminosità, tinta, ombra, trasparenza).
  int? color(XmlElement? holder, {int? phClr}) {
    if (holder == null) return null;
    for (final c in holder.childElements) {
      int? base;
      switch (c.local) {
        case 'srgbClr':
          final v = int.tryParse(c.attr('val') ?? '', radix: 16);
          if (v != null) base = 0xFF000000 | v;
        case 'sysClr':
          final v = int.tryParse(
            c.attr('lastClr') ?? (c.attr('val') == 'window' ? 'FFFFFF' : '000000'),
            radix: 16,
          );
          if (v != null) base = 0xFF000000 | v;
        case 'schemeClr':
          final v = c.attr('val') ?? '';
          base = v == 'phClr' ? phClr : _schemeColor(v);
        case 'prstClr':
          base = _preset[c.attr('val')];
        case 'scrgbClr':
          int ch(String a) =>
              ((double.tryParse(c.attr(a) ?? '') ?? 0) / 100000 * 255)
                  .round()
                  .clamp(0, 255);
          base = 0xFF000000 | (ch('r') << 16) | (ch('g') << 8) | ch('b');
        default:
          continue;
      }
      if (base == null) return null;
      return _modify(base, c);
    }
    return null;
  }

  int? _schemeColor(String name) {
    final mapped = _clrMap[name] ??
        const {
          'bg1': 'lt1',
          'tx1': 'dk1',
          'bg2': 'lt2',
          'tx2': 'dk2',
        }[name] ??
        name;
    return _scheme[mapped] ??
        const {
          'dk1': 0xFF000000,
          'lt1': 0xFFFFFFFF,
          'dk2': 0xFF44546A,
          'lt2': 0xFFE7E6E6,
          'accent1': 0xFF4472C4,
          'accent2': 0xFFED7D31,
          'accent3': 0xFFA5A5A5,
          'accent4': 0xFFFFC000,
          'accent5': 0xFF5B9BD5,
          'accent6': 0xFF70AD47,
          'hlink': 0xFF0563C1,
          'folHlink': 0xFF954F72,
        }[mapped];
  }

  static const _preset = {
    'black': 0xFF000000,
    'white': 0xFFFFFFFF,
    'red': 0xFFFF0000,
    'green': 0xFF008000,
    'blue': 0xFF0000FF,
    'yellow': 0xFFFFFF00,
    'gray': 0xFF808080,
    'orange': 0xFFFFA500,
  };

  static int _modify(int argb, XmlElement c) {
    var r = (argb >> 16) & 0xFF;
    var g = (argb >> 8) & 0xFF;
    var b = argb & 0xFF;
    var a = (argb >> 24) & 0xFF;
    double? lumMod;
    double? lumOff;
    for (final m in c.childElements) {
      final v = (double.tryParse(m.attr('val') ?? '') ?? 100000) / 100000;
      switch (m.local) {
        case 'lumMod':
          lumMod = v;
        case 'lumOff':
          lumOff = v;
        case 'tint':
          r = (255 - (255 - r) * v).round();
          g = (255 - (255 - g) * v).round();
          b = (255 - (255 - b) * v).round();
        case 'shade':
          r = (r * v).round();
          g = (g * v).round();
          b = (b * v).round();
        case 'alpha':
          a = (255 * v).round().clamp(0, 255);
      }
    }
    if (lumMod != null || lumOff != null) {
      final hsl = _toHsl(r, g, b);
      final l = (hsl[2] * (lumMod ?? 1) + (lumOff ?? 0)).clamp(0.0, 1.0);
      final rgb = _fromHsl(hsl[0], hsl[1], l);
      r = rgb[0];
      g = rgb[1];
      b = rgb[2];
    }
    return (a << 24) |
        (r.clamp(0, 255) << 16) |
        (g.clamp(0, 255) << 8) |
        b.clamp(0, 255);
  }

  static List<double> _toHsl(int r8, int g8, int b8) {
    final r = r8 / 255, g = g8 / 255, b = b8 / 255;
    final mx = math.max(r, math.max(g, b));
    final mn = math.min(r, math.min(g, b));
    final l = (mx + mn) / 2;
    if (mx == mn) return [0, 0, l];
    final d = mx - mn;
    final s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
    double h;
    if (mx == r) {
      h = (g - b) / d + (g < b ? 6 : 0);
    } else if (mx == g) {
      h = (b - r) / d + 2;
    } else {
      h = (r - g) / d + 4;
    }
    return [h / 6, s, l];
  }

  static List<int> _fromHsl(double h, double s, double l) {
    if (s == 0) {
      final v = (l * 255).round();
      return [v, v, v];
    }
    double hue(double p, double q, double t) {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    }

    final q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    final p = 2 * l - q;
    return [
      (hue(p, q, h + 1 / 3) * 255).round(),
      (hue(p, q, h) * 255).round(),
      (hue(p, q, h - 1 / 3) * 255).round(),
    ];
  }

  // -------------------------------------------------------- Immagini

  /// Immagine [id] delle relazioni di [part], pronta per Flutter (TIFF
  /// convertite in PNG); null (con il limite segnato) per EMF e WMF.
  Uint8List? _image(_Part part, String? id) {
    if (id == null) return null;
    final rel = part.rels[id];
    if (rel == null || rel.external) return null;
    return _images.putIfAbsent(rel.target, () {
      final data = zip.bytes(rel.target);
      if (data == null || data.length < 8) return null;
      if (isMetafile(data)) {
        limits.add('immagini EMF/WMF');
        return null;
      }
      final tiff = (data[0] == 0x49 && data[1] == 0x49 && data[2] == 0x2A) ||
          (data[0] == 0x4D && data[1] == 0x4D && data[3] == 0x2A);
      if (tiff) {
        final decoded = img.decodeTiff(data);
        return decoded == null ? null : img.encodePng(decoded);
      }
      return data;
    });
  }

  /// Metafile di Windows (EMF o WMF), che Flutter non disegna.
  static bool isMetafile(Uint8List d) {
    if (d.length < 44) return false;
    final emf = d[0] == 1 &&
        d[1] == 0 &&
        d[2] == 0 &&
        d[3] == 0 &&
        d[40] == 0x20 &&
        d[41] == 0x45 &&
        d[42] == 0x4D &&
        d[43] == 0x46;
    final wmf = (d[0] == 0xD7 && d[1] == 0xCD && d[2] == 0xC6 && d[3] == 0x9A) ||
        (d[0] == 1 && d[1] == 0 && d[2] == 9 && d[3] == 0) ||
        (d[0] == 2 && d[1] == 0 && d[2] == 9 && d[3] == 0);
    return emf || wmf;
  }

  // ------------------------------------------------------- Riempimenti

  _Fill? _fill(XmlElement? props, _Part part, {int? phClr}) {
    if (props == null) return null;
    for (final c in props.childElements) {
      switch (c.local) {
        case 'noFill':
          return const _Fill(none: true);
        case 'solidFill':
          return _Fill(color: color(c, phClr: phClr));
        case 'gradFill':
          final stops = c.kid('gsLst')?.kids('gs').toList() ?? const [];
          if (stops.isEmpty) return null;
          // colore di mezzo della sfumatura
          return _Fill(color: color(stops[stops.length ~/ 2], phClr: phClr));
        case 'pattFill':
          return _Fill(color: color(c.kid('fgClr'), phClr: phClr));
        case 'blipFill':
          final data = _image(part, c.kid('blip')?.attr('embed'));
          return data == null ? const _Fill(none: true) : _Fill(image: data);
      }
    }
    return null;
  }

  /// Sfondo: della diapositiva, del layout o dello schema.
  (int, Uint8List?) _background() {
    for (final part in [_slide, _layout, _master]) {
      final bg = part?.root.kid('cSld')?.kid('bg');
      if (bg == null) continue;
      final pr = bg.kid('bgPr');
      if (pr != null) {
        final f = _fill(pr, part!);
        if (f == null || f.none) continue;
        return (f.color ?? 0xFFFFFFFF, f.image);
      }
      final ref = bg.kid('bgRef');
      if (ref != null) return (color(ref) ?? 0xFFFFFFFF, null);
    }
    return (0xFFFFFFFF, null);
  }

  // ------------------------------------------------------ Segnaposto

  static XmlElement? _ph(XmlElement shape) {
    for (final nv in shape.childElements) {
      if (nv.local.startsWith('nv')) return nv.kid('nvPr')?.kid('ph');
    }
    return null;
  }

  /// "title" per i titoli, "body" per testo e oggetti, altrimenti il tipo.
  static String _phClass(XmlElement ph) {
    final t = ph.attr('type') ?? 'obj';
    return switch (t) {
      'title' || 'ctrTitle' => 'title',
      'body' || 'subTitle' || 'obj' || 'tbl' || 'chart' || 'pic' ||
      'clipArt' || 'dgm' || 'media' => 'body',
      _ => t,
    };
  }

  /// Segnaposto corrispondente nel layout o nello schema.
  static XmlElement? _matchPh(_Part? part, XmlElement ph) {
    final tree = part?.spTree;
    if (tree == null) return null;
    final idx = ph.attr('idx');
    final cls = _phClass(ph);
    final type = ph.attr('type');
    XmlElement? byClass;
    for (final e in tree.childElements) {
      final p = _ph(e);
      if (p == null) continue;
      if (idx != null && p.attr('idx') == idx && cls != 'title') return e;
      if (byClass == null) {
        if (type != null && p.attr('type') == type) {
          byClass = e;
        } else if (_phClass(p) == cls &&
            (cls == 'title' || cls == 'body')) {
          byClass = e;
        }
      }
    }
    return byClass;
  }

  /// Forme ereditate da un segnaposto [ph] di [part]: layout e schema.
  List<XmlElement> _inherited(_Part part, XmlElement? ph) {
    if (ph == null) return const [];
    final out = <XmlElement>[];
    if (part == _slide) {
      final l = _matchPh(_layout, ph);
      if (l != null) out.add(l);
      final lph = l == null ? null : _ph(l);
      final m = _matchPh(_master, lph ?? ph);
      if (m != null) out.add(m);
    } else if (part == _layout) {
      final m = _matchPh(_master, ph);
      if (m != null) out.add(m);
    }
    return out;
  }

  // ----------------------------------------------------------- Forme

  void _tree(
    XmlElement tree,
    _Part part,
    _Tx tx,
    List<RShape> out, {
    required bool layer,
  }) {
    for (final e in tree.childElements) {
      // nello schema e nel layout i segnaposto sono solo modelli
      if (layer && _ph(e) != null) continue;
      try {
        switch (e.local) {
          case 'sp' || 'cxnSp':
            final s = _shape(e, part, tx);
            if (s != null) out.add(s);
          case 'pic':
            final s = _picture(e, part, tx);
            if (s != null) out.add(s);
          case 'grpSp':
            _group(e, part, tx, out, layer: layer);
          case 'graphicFrame':
            _frame(e, part, tx, out);
          case 'AlternateContent':
            final choice = e.kid('Choice');
            final fallback = e.kid('Fallback');
            final math = choice != null &&
                (choice.firstDesc('oMath') != null ||
                    choice.firstDesc('oMathPara') != null);
            final pick = (math && fallback != null)
                ? fallback
                : (choice ?? fallback);
            if (pick != null) _tree(pick, part, tx, out, layer: layer);
          case 'contentPart':
            limits.add('disegni a penna');
        }
      } catch (_) {
        // una forma illeggibile non ferma la diapositiva
      }
    }
  }

  void _group(
    XmlElement g,
    _Part part,
    _Tx tx,
    List<RShape> out, {
    required bool layer,
  }) {
    final xfrm = g.kid('grpSpPr')?.kid('xfrm');
    var inner = tx;
    if (xfrm != null) {
      double n(String k, String a) =>
          double.tryParse(xfrm.kid(k)?.attr(a) ?? '') ?? 0;
      final cx = n('ext', 'cx'), cy = n('ext', 'cy');
      final chx = n('chExt', 'cx'), chy = n('chExt', 'cy');
      final sx = chx == 0 ? 1.0 : cx / chx;
      final sy = chy == 0 ? 1.0 : cy / chy;
      inner = tx.then(
        _Tx(
          sx,
          sy,
          n('off', 'x') - n('chOff', 'x') * sx,
          n('off', 'y') - n('chOff', 'y') * sy,
        ),
      );
    }
    _tree(g, part, inner, out, layer: layer);
  }

  /// Riquadro in punti di [x] trasformato da [tx].
  ({double x, double y, double w, double h}) _box(_Xfrm x, _Tx tx) => (
    x: (x.x * tx.sx + tx.dx) / _emu,
    y: (x.y * tx.sy + tx.dy) / _emu,
    w: x.w * tx.sx / _emu,
    h: x.h * tx.sy / _emu,
  );

  _Xfrm? _xfrmOf(XmlElement e, List<XmlElement> inherited) {
    final own = _Xfrm.of(e.kid('spPr')?.kid('xfrm') ?? e.kid('xfrm'));
    if (own != null) return own;
    for (final i in inherited) {
      final x = _Xfrm.of(i.kid('spPr')?.kid('xfrm') ?? i.kid('xfrm'));
      if (x != null) return x;
    }
    return null;
  }

  RShape? _shape(XmlElement sp, _Part part, _Tx tx) {
    final ph = _ph(sp);
    final inh = _inherited(part, ph);
    final xfrm = _xfrmOf(sp, inh);
    if (xfrm == null) {
      if (part == _slide &&
          (sp.kid('txBody')?.desc('t').any((t) => t.innerText.isNotEmpty) ??
              false)) {
        _unplaced = true;
      }
      return null;
    }
    final box = _box(xfrm, tx);
    final spPr = sp.kid('spPr');
    final style = sp.kid('style');
    // forma
    var geometry = spPr?.kid('prstGeom')?.attr('prst');
    var adjust = _adjust(spPr?.kid('prstGeom'));
    List<List<RPathCmd>>? path;
    final cust = spPr?.kid('custGeom');
    if (cust != null) {
      path = _customPath(cust, xfrm);
      geometry = 'custom';
    }
    for (final i in inh) {
      if (geometry != null) break;
      geometry = i.kid('spPr')?.kid('prstGeom')?.attr('prst');
      adjust = _adjust(i.kid('spPr')?.kid('prstGeom'));
    }
    if (sp.local == 'cxnSp') geometry = 'line';
    // riempimento: proprio, ereditato, poi dallo stile della forma
    _Fill? fill = _fill(spPr, part);
    for (final i in inh) {
      fill ??= _fill(i.kid('spPr'), part);
    }
    final fillRef = style?.kid('fillRef');
    if (fill == null &&
        fillRef != null &&
        (int.tryParse(fillRef.attr('idx') ?? '') ?? 0) > 0) {
      fill = _Fill(color: color(fillRef));
    }
    // contorno
    int? line;
    var lineWidth = 0.75;
    final ln = spPr?.kid('ln');
    final lnFill = _fill(ln, part);
    final lnRef = style?.kid('lnRef');
    if (lnFill != null) {
      line = lnFill.none ? null : lnFill.color;
    } else if (lnRef != null &&
        (int.tryParse(lnRef.attr('idx') ?? '') ?? 0) > 0) {
      line = color(lnRef);
    }
    final w = double.tryParse(ln?.attr('w') ?? '');
    if (w != null) lineWidth = math.max(w / _emu, 0.25);
    if (geometry == 'line' && line == null && lnFill?.none != true) {
      line = color(lnRef) ?? 0xFF000000;
    }
    // testo
    final txBody = sp.kid('txBody');
    final fontColor = color(style?.kid('fontRef'));
    var paras = const <RSlidePara>[];
    var anchor = RAnchor.top;
    var insets = const [7.2, 3.6, 7.2, 3.6];
    if (txBody != null) {
      final bodies = [
        txBody.kid('bodyPr'),
        for (final i in inh) i.kid('txBody')?.kid('bodyPr'),
      ];
      anchor = _anchor(bodies);
      insets = _insets(bodies);
      final cls = ph == null ? null : _phClass(ph);
      paras = _paras(
        txBody,
        part,
        _levelsFor(txBody, inh, cls),
        defaultColor: fontColor ?? _schemeColor('tx1') ?? 0xFF000000,
        bodyPr: txBody.kid('bodyPr'),
      );
    }
    final hasFill = fill != null && !fill.none;
    if (!hasFill && line == null && paras.every((p) => p.text.isEmpty)) {
      return null;
    }
    return RShape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      rotation: xfrm.rot,
      flipH: xfrm.flipH,
      flipV: xfrm.flipV,
      geometry: geometry ?? 'rect',
      adjust: adjust,
      path: path,
      fill: hasFill ? fill.color : null,
      image: hasFill ? fill.image : null,
      line: line,
      lineWidth: lineWidth,
      paras: paras,
      anchor: anchor,
      insets: insets,
    );
  }

  /// Prima regolazione ("adj" o "adj1") di una forma predefinita, in
  /// frazione.
  static double? _adjust(XmlElement? prstGeom) {
    for (final gd in prstGeom?.kid('avLst')?.kids('gd') ?? <XmlElement>[]) {
      final name = gd.attr('name');
      if (name != 'adj' && name != 'adj1') continue;
      final m = RegExp(r'^val\s+(-?\d+)').firstMatch(gd.attr('fmla') ?? '');
      if (m != null) return int.parse(m.group(1)!) / 100000;
    }
    return null;
  }

  List<List<RPathCmd>>? _customPath(XmlElement cust, _Xfrm xfrm) {
    final out = <List<RPathCmd>>[];
    for (final path in cust.kid('pathLst')?.kids('path') ?? <XmlElement>[]) {
      final pw = double.tryParse(path.attr('w') ?? '') ?? xfrm.w;
      final ph = double.tryParse(path.attr('h') ?? '') ?? xfrm.h;
      if (pw <= 0 || ph <= 0) continue;
      final cmds = <RPathCmd>[];
      List<double>? pts(XmlElement e) {
        final out = <double>[];
        for (final pt in e.kids('pt')) {
          final x = double.tryParse(pt.attr('x') ?? '');
          final y = double.tryParse(pt.attr('y') ?? '');
          if (x == null || y == null) return null;
          out
            ..add(x / pw)
            ..add(y / ph);
        }
        return out;
      }

      for (final c in path.childElements) {
        switch (c.local) {
          case 'moveTo':
            final p = pts(c);
            if (p == null || p.length < 2) return null;
            cmds.add(RPathCmd(0, p));
          case 'lnTo':
            final p = pts(c);
            if (p == null || p.length < 2) return null;
            cmds.add(RPathCmd(1, p));
          case 'cubicBezTo':
            final p = pts(c);
            if (p == null || p.length < 6) return null;
            cmds.add(RPathCmd(2, p));
          case 'quadBezTo':
            final p = pts(c);
            if (p == null || p.length < 4) return null;
            cmds.add(RPathCmd(2, [p[0], p[1], ...p]));
          case 'close':
            cmds.add(const RPathCmd(3));
        }
      }
      if (cmds.isNotEmpty) out.add(cmds);
    }
    return out.isEmpty ? null : out;
  }

  RAnchor _anchor(List<XmlElement?> bodies) {
    for (final b in bodies) {
      final a = b?.attr('anchor');
      if (a != null) {
        return switch (a) {
          'ctr' => RAnchor.middle,
          'b' => RAnchor.bottom,
          _ => RAnchor.top,
        };
      }
    }
    return RAnchor.top;
  }

  List<double> _insets(List<XmlElement?> bodies) {
    double pick(String a, double def) {
      for (final b in bodies) {
        final v = double.tryParse(b?.attr(a) ?? '');
        if (v != null) return v / _emu;
      }
      return def;
    }

    return [
      pick('lIns', 7.2),
      pick('tIns', 3.6),
      pick('rIns', 7.2),
      pick('bIns', 3.6),
    ];
  }

  /// Fonti degli stili dei paragrafi per livello: stile della casella,
  /// segnaposto del layout e dello schema, stili del testo dello schema
  /// e predefiniti della presentazione.
  _Levels _levelsFor(
    XmlElement txBody,
    List<XmlElement> inherited,
    String? cls,
  ) {
    final txStyles = _master?.root.kid('txStyles');
    final masterStyle = switch (cls) {
      'title' => txStyles?.kid('titleStyle'),
      'body' => txStyles?.kid('bodyStyle'),
      null => null,
      _ => txStyles?.kid('otherStyle'),
    };
    return (level) {
      final name = 'lvl${level + 1}pPr';
      return [
        txBody.kid('lstStyle')?.kid(name),
        for (final i in inherited) i.kid('txBody')?.kid('lstStyle')?.kid(name),
        masterStyle?.kid(name),
        if (cls == null) _defaultText?.kid(name),
        if (cls == null) txStyles?.kid('otherStyle')?.kid(name),
      ];
    };
  }

  List<RSlidePara> _paras(
    XmlElement txBody,
    _Part part,
    _Levels levels, {
    required int defaultColor,
    XmlElement? bodyPr,
    bool bold = false,
    int? styleColor,
  }) {
    final autofit = bodyPr?.kid('normAutofit');
    final fontScale =
        (double.tryParse(autofit?.attr('fontScale') ?? '') ?? 100000) / 100000;
    final lnReduction =
        (double.tryParse(autofit?.attr('lnSpcReduction') ?? '') ?? 0) / 100000;
    final out = <RSlidePara>[];
    final counters = List.filled(10, 0);
    for (final p in txBody.kids('p')) {
      final pPr = p.kid('pPr');
      final level = (int.tryParse(pPr?.attr('lvl') ?? '') ?? 0).clamp(0, 8);
      final sources = [pPr, ...levels(level)];
      String? attr(String a) {
        for (final s in sources) {
          final v = s?.attr(a);
          if (v != null) return v;
        }
        return null;
      }

      XmlElement? child(String k) {
        for (final s in sources) {
          final v = s?.kid(k);
          if (v != null) return v;
        }
        return null;
      }

      // dimensione e colore predefiniti del paragrafo
      double? defSize;
      int? defColor;
      for (final s in sources) {
        final d = s?.kid('defRPr');
        defSize ??= double.tryParse(d?.attr('sz') ?? '');
        defColor ??= color(d?.kid('solidFill'));
      }
      final baseSize = (defSize ?? 1800) / 100;
      final baseColor = styleColor ?? defColor ?? defaultColor;
      final runs = <RRun>[];
      void addRun(XmlElement r, String text, {bool italic = false}) {
        final rpr = r.kid('rPr');
        final size =
            (double.tryParse(rpr?.attr('sz') ?? '') ?? baseSize * 100) / 100;
        final u = rpr?.attr('u');
        final b = rpr?.attr('b');
        final i = rpr?.attr('i');
        String? link;
        final click = rpr?.kid('hlinkClick')?.attr('id');
        if (click != null) {
          final rel = part.rels[click];
          if (rel != null && rel.external) link = rel.target;
        }
        runs.add(
          RRun(
            RSpan(
              text,
              bold: b == null ? bold : (b == '1' || b == 'true'),
              italic: italic || i == '1' || i == 'true',
              underline: u != null && u != 'none',
              strike: (rpr?.attr('strike') ?? 'noStrike') != 'noStrike',
              link: link,
            ),
            size: size * fontScale,
            color: color(rpr?.kid('solidFill')) ?? baseColor,
          ),
        );
      }

      for (final c in p.childElements) {
        switch (c.local) {
          case 'r' || 'fld':
            final t = c.kid('t')?.innerText ?? '';
            if (t.isNotEmpty) addRun(c, t);
          case 'br':
            addRun(c, '\n');
          case 'm':
            // formula (Office 2010+): solo il testo
            final t = c.desc('t').map((e) => e.innerText).join();
            if (t.isNotEmpty) {
              limits.add('formule');
              addRun(c, t, italic: true);
            }
        }
      }
      final text = runs.map((r) => r.span.text).join();
      // elenco
      String? bullet;
      int? bulletColor;
      for (final s in sources) {
        if (s == null) continue;
        if (s.kid('buNone') != null) break;
        final ch = s.kid('buChar')?.attr('char');
        if (ch != null) {
          bullet = _bulletChar(ch, s.kid('buFont')?.attr('typeface'));
          break;
        }
        final auto = s.kid('buAutoNum');
        if (auto != null) {
          final start = int.tryParse(auto.attr('startAt') ?? '') ?? 1;
          counters[level] = counters[level] == 0 ? start : counters[level] + 1;
          for (var k = level + 1; k < counters.length; k++) {
            counters[k] = 0;
          }
          bullet = _autoNumber(auto.attr('type') ?? '', counters[level]);
          break;
        }
      }
      if (text.trim().isEmpty) bullet = null;
      if (bullet != null) {
        bulletColor = color(child('buClr')) ??
            (runs.isEmpty ? baseColor : runs.first.color);
      }
      final marL = (double.tryParse(attr('marL') ?? '') ?? 0) / _emu;
      final indent = (double.tryParse(attr('indent') ?? '') ?? 0) / _emu;
      final spcBef = child('spcBef');
      var before = 0.0;
      final pts = double.tryParse(spcBef?.kid('spcPts')?.attr('val') ?? '');
      final pct = double.tryParse(spcBef?.kid('spcPct')?.attr('val') ?? '');
      if (pts != null) before = pts / 100;
      if (pct != null) before = pct / 100000 * baseSize;
      final lnSpc = child('lnSpc');
      var spacing = 1.0;
      final lp = double.tryParse(lnSpc?.kid('spcPct')?.attr('val') ?? '');
      final lpts = double.tryParse(lnSpc?.kid('spcPts')?.attr('val') ?? '');
      if (lp != null) spacing = lp / 100000;
      if (lpts != null) spacing = lpts / 100 / (baseSize * 1.2);
      spacing = math.max(0.5, spacing - lnReduction);
      out.add(
        RSlidePara(
          runs,
          align: switch (attr('algn')) {
            'ctr' => RAlign.center,
            'r' => RAlign.right,
            'just' || 'dist' => RAlign.justify,
            _ => RAlign.left,
          },
          indent: math.max(0, marL),
          hanging: bullet == null ? 0 : math.max(0, -indent),
          bullet: bullet,
          bulletColor: bulletColor,
          spaceBefore: before * fontScale,
          lineSpacing: spacing,
          size: baseSize * fontScale,
        ),
      );
    }
    return out;
  }

  /// Segni dei caratteri simbolo (Wingdings, Symbol) come caratteri Unicode.
  static String _bulletChar(String ch, String? font) {
    final f = (font ?? '').toLowerCase();
    if (f == 'wingdings 3') {
      return const {'Ø': '▸', '}': '▸', 'u': '▸', 'Æ': '▸'}[ch] ?? '▸';
    }
    if (f.startsWith('wingdings')) {
      return const {
            'Ø': '➢',
            'ü': '✓',
            '§': '▪',
            'v': '❖',
            'q': '❑',
            'n': '■',
            'l': '●',
            'à': '➔',
          }[ch] ??
          '•';
    }
    if (f == 'symbol') return '•';
    final code = ch.isEmpty ? 0 : ch.codeUnitAt(0);
    // caratteri della zona privata o di controllo: un pallino
    if (code < 0x20 || (code >= 0xE000 && code <= 0xF8FF)) return '•';
    return ch;
  }

  static String _autoNumber(String type, int n) {
    String letter(int k) => String.fromCharCode(96 + ((k - 1) % 26) + 1);
    String roman(int k) {
      const v = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
      const s = ['m', 'cm', 'd', 'cd', 'c', 'xc', 'l', 'xl', 'x', 'ix', 'v', 'iv', 'i'];
      final b = StringBuffer();
      for (var i = 0; i < v.length; i++) {
        while (k >= v[i]) {
          b.write(s[i]);
          k -= v[i];
        }
      }
      return b.toString();
    }

    final body = type.startsWith('alphaLc')
        ? letter(n)
        : type.startsWith('alphaUc')
        ? letter(n).toUpperCase()
        : type.startsWith('romanLc')
        ? roman(n)
        : type.startsWith('romanUc')
        ? roman(n).toUpperCase()
        : '$n';
    if (type.endsWith('ParenBoth')) return '($body)';
    if (type.endsWith('ParenR')) return '$body)';
    return '$body.';
  }

  RShape? _picture(XmlElement pic, _Part part, _Tx tx) {
    final ph = _ph(pic);
    final xfrm = _xfrmOf(pic, _inherited(part, ph));
    if (xfrm == null) {
      if (part == _slide) _unplaced = true;
      return null;
    }
    final box = _box(xfrm, tx);
    final blipFill = pic.kid('blipFill');
    final data = _image(part, blipFill?.kid('blip')?.attr('embed'));
    if (pic.kid('nvPicPr')?.kid('nvPr')?.firstDesc('videoFile') != null ||
        pic.kid('nvPicPr')?.kid('nvPr')?.firstDesc('audioFile') != null) {
      limits.add('video e audio');
    }
    final src = blipFill?.kid('srcRect');
    double c(String a) =>
        ((double.tryParse(src?.attr(a) ?? '') ?? 0) / 100000).clamp(-1.0, 0.95);
    final spPr = pic.kid('spPr');
    final lnFill = _fill(spPr?.kid('ln'), part);
    return RShape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      rotation: xfrm.rot,
      flipH: xfrm.flipH,
      flipV: xfrm.flipV,
      geometry: spPr?.kid('prstGeom')?.attr('prst') ?? 'rect',
      image: data,
      crop: [c('l'), c('t'), c('r'), c('b')],
      line: lnFill == null || lnFill.none ? null : lnFill.color,
      lineWidth: math.max(
        (double.tryParse(spPr?.kid('ln')?.attr('w') ?? '') ?? 9525) / _emu,
        0.25,
      ),
      label: data == null ? 'Immagine' : null,
    );
  }

  void _frame(XmlElement frame, _Part part, _Tx tx, List<RShape> out) {
    final xfrm = _xfrmOf(frame, _inherited(part, _ph(frame)));
    if (xfrm == null) return;
    final box = _box(xfrm, tx);
    final data = frame.kid('graphic')?.kid('graphicData');
    final uri = data?.attr('uri') ?? '';
    RShape labelled(String label) =>
        RShape(x: box.x, y: box.y, w: box.w, h: box.h, label: label);
    if (uri.endsWith('/table')) {
      final tbl = data?.kid('tbl');
      if (tbl != null) out.add(_table(tbl, part, box));
      return;
    }
    if (uri.endsWith('/chart') || uri.contains('chartex')) {
      limits.add('grafici');
      out.add(labelled(_chartTitle(part, data) ?? 'Grafico'));
      return;
    }
    if (uri.endsWith('/diagram')) {
      if (!_smartArt(part, data, xfrm, tx, out)) {
        limits.add('SmartArt');
        out.add(labelled('SmartArt'));
      }
      return;
    }
    // oggetti incorporati: l'immagine di anteprima, se c'è
    final pic = data?.firstDesc('pic');
    final preview = _image(part, pic?.firstDesc('blip')?.attr('embed'));
    if (preview != null) {
      out.add(
        RShape(x: box.x, y: box.y, w: box.w, h: box.h, image: preview),
      );
    } else {
      limits.add('oggetti incorporati');
      out.add(labelled('Oggetto incorporato'));
    }
  }

  String? _chartTitle(_Part part, XmlElement? data) {
    final id = data?.firstDesc('chart')?.attr('id');
    final rel = id == null ? null : part.rels[id];
    if (rel == null) return null;
    final title = zip.xml(rel.target)?.rootElement.firstDesc('title');
    final t = title?.desc('t').map((e) => e.innerText).join().trim();
    return t == null || t.isEmpty ? null : 'Grafico: $t';
  }

  /// SmartArt dal disegno salvato da PowerPoint (diagrams/drawingN.xml):
  /// le forme sono relative al riquadro dell'oggetto.
  bool _smartArt(
    _Part part,
    XmlElement? data,
    _Xfrm xfrm,
    _Tx tx,
    List<RShape> out,
  ) {
    final dm = data?.kid('relIds')?.attr('dm');
    final dataRel = dm == null ? null : part.rels[dm];
    String? drawing;
    if (dataRel != null) {
      final model = zip.xml(dataRel.target);
      final ext = model?.rootElement.firstDesc('dataModelExt')?.attr('relId');
      if (ext != null) drawing = part.rels[ext]?.target;
    }
    final x = drawing == null ? null : zip.xml(drawing);
    final tree = x?.rootElement.firstDesc('spTree');
    if (tree == null || drawing == null) return false;
    final dPart = _part(drawing)!;
    _tree(tree, dPart, tx.then(_Tx(1, 1, xfrm.x, xfrm.y)), out, layer: false);
    return true;
  }

  RShape _table(
    XmlElement tbl,
    _Part part,
    ({double x, double y, double w, double h}) box,
  ) {
    final cols = [
      for (final c in tbl.kid('tblGrid')?.kids('gridCol') ?? <XmlElement>[])
        (double.tryParse(c.attr('w') ?? '') ?? 0) / _emu,
    ];
    final pr = tbl.kid('tblPr');
    final styled = pr?.kid('tableStyleId') != null;
    final firstRow = pr?.attr('firstRow') == '1';
    final bandRow = pr?.attr('bandRow') == '1';
    final accent = _schemeColor('accent1') ?? 0xFF4472C4;
    int tint(int c, double t) {
      final r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
      int m(int v) => (255 - (255 - v) * t).round();
      return 0xFF000000 | (m(r) << 16) | (m(g) << 8) | m(b);
    }

    final rows = <double>[];
    final cells = <List<RSlideCell>>[];
    final text = _schemeColor('tx1') ?? 0xFF000000;
    var r = 0;
    for (final tr in tbl.kids('tr')) {
      rows.add((double.tryParse(tr.attr('h') ?? '') ?? 0) / _emu);
      final header = styled && firstRow && r == 0;
      final band = styled && bandRow && !(firstRow && r == 0);
      final dataRow = firstRow ? r - 1 : r;
      int? styleFill;
      if (header) {
        styleFill = accent;
      } else if (band) {
        styleFill = tint(accent, dataRow.isEven ? 0.4 : 0.2);
      } else if (styled) {
        styleFill = tint(accent, 0.2);
      }
      final row = <RSlideCell>[];
      for (final tc in tr.kids('tc')) {
        if (tc.attr('hMerge') == '1' || tc.attr('vMerge') == '1') continue;
        final body = tc.kid('txBody');
        final f = _fill(tc.kid('tcPr'), part);
        row.add(
          RSlideCell(
            body == null
                ? const []
                : _paras(
                    body,
                    part,
                    (level) => [
                      body.kid('lstStyle')?.kid('lvl${level + 1}pPr'),
                      _defaultText?.kid('lvl${level + 1}pPr'),
                    ],
                    defaultColor: header ? 0xFFFFFFFF : text,
                    bold: header,
                    styleColor: header ? 0xFFFFFFFF : null,
                  ),
            fill: f == null ? styleFill : (f.none ? null : f.color),
            span: int.tryParse(tc.attr('gridSpan') ?? '') ?? 1,
          ),
        );
      }
      cells.add(row);
      r++;
    }
    return RShape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      table: RSlideTable(cols, rows, cells),
      line: styled ? 0xFFFFFFFF : 0xFF000000,
    );
  }
}
