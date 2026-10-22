import 'dart:math' as math;
import 'dart:typed_data';

import 'package:xml/xml.dart';

import '../reader_document.dart';
import 'pptx_slides.dart';
import 'zip_util.dart';

/// Diapositive OpenDocument (.odp, .otp: LibreOffice Impress, PowerPoint
/// salvato in ODF) disegnate come nell'originale ([RSlide]): sfondo della
/// pagina, forme dello schema (non i segnaposto), riquadri di testo con
/// dimensioni, colori, allineamento ed elenchi, immagini, forme (rettangoli,
/// ellissi, forme predefinite e tracciati semplici), linee, gruppi e tabelle.
///
/// Non disegnati (in [limits]): formule e grafici (oggetti incorporati, si
/// usa l'anteprima se è un'immagine normale), immagini vettoriali (SVM, WMF,
/// EMF). Sfumature: il colore iniziale; caratteri: quello dell'app.
class OdpSlides {
  OdpSlides(this.zip) {
    content = zip.xml('content.xml');
    styles = zip.xml('styles.xml');
    for (final doc in [styles, content]) {
      final root = doc?.rootElement;
      if (root == null) continue;
      for (final s in root.desc('style')) {
        final name = s.attr('name');
        if (name != null && s.parentElement?.local != 'master-page') {
          _styles[name] = s;
        }
      }
      for (final s in root.desc('default-style')) {
        final family = s.attr('family');
        if (family != null) _defaults[family] = s;
      }
      for (final l in root.desc('list-style')) {
        final name = l.attr('name');
        if (name != null) _lists[name] = l;
      }
      for (final m in root.desc('master-page')) {
        final name = m.attr('name');
        if (name != null) _masters[name] = m;
      }
      for (final l in root.desc('page-layout')) {
        final name = l.attr('name');
        if (name != null) _layouts[name] = l;
      }
      for (final i in root.desc('fill-image')) {
        final name = i.attr('name');
        if (name != null) _fillImages[name] = i.attr('href');
      }
    }
  }

  final Zip zip;
  XmlDocument? content;
  XmlDocument? styles;

  /// Parti del file non disegnate (per l'avviso all'apertura).
  final limits = <String>{};

  final _styles = <String, XmlElement>{};
  final _defaults = <String, XmlElement>{};
  final _lists = <String, XmlElement>{};
  final _masters = <String, XmlElement>{};
  final _layouts = <String, XmlElement>{};
  final _fillImages = <String, String?>{};
  final _images = <String, Uint8List?>{};
  final _masterShapes = <String, List<RShape>>{};

  /// Pagine della presentazione.
  List<XmlElement> get pages =>
      content?.rootElement
          .kid('body')
          ?.kid('presentation')
          ?.kids('page')
          .toList() ??
      const [];

  // --------------------------------------------------------------- Misure

  /// Lunghezza ODF ("2.5cm", "1in", "12pt") in punti.
  static double? length(String? v) {
    if (v == null) return null;
    final m = RegExp(r'^\s*(-?[\d.]+)\s*([a-z%]*)').firstMatch(v);
    if (m == null) return null;
    final n = parseFinite(m.group(1)!);
    if (n == null) return null;
    return switch (m.group(2)) {
      'in' => n * 72,
      'cm' => n * 72 / 2.54,
      'mm' => n * 72 / 25.4,
      'pc' => n * 12,
      'px' => n * 0.75,
      _ => n,
    };
  }

  static int? _color(String? hex, {String? opacity}) {
    if (hex == null || !hex.startsWith('#') || hex.length != 7) return null;
    final rgb = int.tryParse(hex.substring(1), radix: 16);
    if (rgb == null) return null;
    var a = 255;
    final o = RegExp(r'([\d.]+)%').firstMatch(opacity ?? '');
    if (o != null) a = ((parseFinite(o.group(1)) ?? 100) / 100 * 255).round().clamp(0, 255);
    return (a << 24) | rgb;
  }

  // ---------------------------------------------------------------- Stili

  /// Attributo [attr] di [props] (es. "graphic-properties") nella catena di
  /// stili che parte da [names] (il primo che lo ha), poi nello stile
  /// predefinito della famiglia.
  String? _prop(
    List<String?> names,
    String props,
    String attr, {
    String? family,
  }) {
    for (final start in names) {
      var name = start;
      var guard = 0;
      while (name != null && guard++ < 20) {
        final s = _styles[name];
        if (s == null) break;
        final v = s.kid(props)?.attr(attr);
        if (v != null) return v;
        name = s.attr('parent-style-name');
      }
    }
    if (family != null) return _defaults[family]?.kid(props)?.attr(attr);
    return null;
  }

  Uint8List? _image(String? href) {
    if (href == null || href.isEmpty) return null;
    return _images.putIfAbsent(href, () {
      final data = zip.bytes(href);
      if (data == null) return null;
      if (PptxSlides.isMetafile(data) ||
          (data.length > 6 && String.fromCharCodes(data.sublist(0, 6)) == 'VCLMTF')) {
        limits.add('immagini vettoriali');
        return null;
      }
      return data;
    });
  }

  // ------------------------------------------------------------- Pagine

  /// La pagina [page] disegnata.
  RSlide slide(XmlElement page) {
    final master = _masters[page.attr('master-page-name')];
    final layout = _layouts[master?.attr('page-layout-name')]
        ?.kid('page-layout-properties');
    final w = length(layout?.attr('page-width')) ?? 28 * 72 / 2.54;
    final h = length(layout?.attr('page-height')) ?? 21 * 72 / 2.54;
    // sfondo: della pagina, altrimenti dello schema
    var bg = 0xFFFFFFFF;
    Uint8List? bgImage;
    for (final styleName in [page.attr('style-name'), master?.attr('style-name')]) {
      final s = _styles[styleName]?.kid('drawing-page-properties');
      final fill = s?.attr('fill');
      if (s == null || fill == null || fill == 'none') continue;
      if (fill == 'bitmap') {
        bgImage = _image(_fillImages[s.attr('fill-image-name')]);
        if (bgImage == null) continue;
      } else if (fill == 'gradient') {
        final g = _styles[s.attr('fill-gradient-name')];
        bg = _color(g?.attr('start-color')) ?? bg;
      } else {
        bg = _color(s.attr('fill-color')) ?? bg;
      }
      break;
    }
    final shapes = <RShape>[];
    final showMaster = _styles[page.attr('style-name')]
            ?.kid('drawing-page-properties')
            ?.attr('background-objects-visible') !=
        'false';
    if (master != null && showMaster) {
      shapes.addAll(
        _masterShapes.putIfAbsent(master.attr('name') ?? '', () {
          final out = <RShape>[];
          _shapes(master, out, master: true);
          return out;
        }),
      );
    }
    _shapes(page, shapes, master: false);
    return RSlide(
      width: w,
      height: h,
      shapes: shapes,
      background: bg,
      backgroundImage: bgImage,
    );
  }

  void _shapes(XmlElement parent, List<RShape> out, {required bool master}) {
    for (final e in parent.childElements) {
      final cls = e.attr('class');
      // nello schema i segnaposto sono solo modelli
      if (master && cls != null) continue;
      try {
        switch (e.local) {
          case 'frame':
            _frame(e, out);
          case 'custom-shape' || 'rect' || 'ellipse' || 'circle' ||
              'polygon' || 'path':
            final s = _shape(e);
            if (s != null) out.add(s);
          case 'line' || 'connector':
            final s = _line(e);
            if (s != null) out.add(s);
          case 'g':
            _shapes(e, out, master: master);
          case 'notes':
            break;
        }
      } catch (_) {
        // una forma illeggibile non ferma la pagina
      }
    }
  }

  ({double x, double y, double w, double h, double rot})? _box(XmlElement e) {
    var x = length(e.attr('x'));
    var y = length(e.attr('y'));
    final w = length(e.attr('width'));
    final h = length(e.attr('height'));
    if (w == null || h == null) return null;
    var rot = 0.0;
    // draw:transform="rotate (0.35) translate (2cm 3cm)": l'angolo è in
    // radianti in senso antiorario, la traslazione porta l'angolo in alto
    // a sinistra già ruotato
    final t = e.attr('transform');
    if (t != null) {
      final r = RegExp(r'rotate\s*\(\s*(-?[\d.eE+-]+)\s*\)').firstMatch(t);
      final tr = RegExp(r'translate\s*\(\s*([^\s)]+)\s+([^\s)]+)\s*\)').firstMatch(t);
      final a = r == null ? 0.0 : parseFinite(r.group(1)!) ?? 0;
      if (tr != null) {
        final tx = length(tr.group(1)) ?? 0, ty = length(tr.group(2)) ?? 0;
        // centro della forma ruotata, poi angolo della forma non ruotata
        final cx = tx + (w / 2) * math.cos(a) + (h / 2) * math.sin(a);
        final cy = ty - (w / 2) * math.sin(a) + (h / 2) * math.cos(a);
        x = cx - w / 2;
        y = cy - h / 2;
      }
      rot = -a * 180 / math.pi;
    }
    if (x == null || y == null) return null;
    return (x: x, y: y, w: w, h: h, rot: rot);
  }

  List<String?> _graphicStyles(XmlElement e) => [
    e.attr('style-name'),
    // presentation:style-name e draw:style-name hanno lo stesso nome locale
    for (final a in e.attributes)
      if (a.name.local == 'style-name') a.value,
  ];

  ({int? fill, Uint8List? image, int? line, double lineWidth}) _paint(
    XmlElement e, {
    required bool frame,
  }) {
    final names = _graphicStyles(e);
    String? p(String attr) => _prop(
      names,
      'graphic-properties',
      attr,
      family: frame ? null : 'graphic',
    );
    int? fill;
    Uint8List? image;
    switch (p('fill')) {
      case 'solid':
        fill = _color(p('fill-color'), opacity: p('opacity'));
      case 'gradient':
        final g = _styles[p('fill-gradient-name')];
        fill = _color(g?.attr('start-color'));
      case 'bitmap':
        image = _image(_fillImages[p('fill-image-name')]);
      case 'hatch':
        fill = _color(p('fill-color'));
      case null:
        // forme senza stile: il colore predefinito di LibreOffice
        if (!frame) fill = _color(p('fill-color')) ?? 0xFF729FCF;
    }
    int? line;
    final stroke = p('stroke');
    if (stroke != null && stroke != 'none') {
      line = _color(p('stroke-color')) ?? 0xFF3465A4;
    } else if (stroke == null && !frame) {
      line = _color(p('stroke-color')) ?? 0xFF3465A4;
    }
    final lw = math.max(length(p('stroke-width')) ?? 0.75, 0.25);
    return (fill: fill, image: image, line: line, lineWidth: lw);
  }

  void _frame(XmlElement f, List<RShape> out) {
    final box = _box(f);
    if (box == null) return;
    final paint = _paint(f, frame: true);
    final textBox = f.kid('text-box');
    final img = f.kid('image');
    final table = f.kid('table');
    final object = f.kid('object') ?? f.kid('object-ole');
    String? label;
    Uint8List? image = paint.image;
    if (object != null) {
      limits.add('formule o grafici');
      final preview = img == null ? null : _image(img.attr('href'));
      if (preview == null) label = 'Oggetto incorporato (formula o grafico)';
      image = preview;
    } else if (img != null) {
      image = _image(img.attr('href'));
      if (image == null) label = 'Immagine';
    }
    var paras = const <RSlidePara>[];
    var anchor = RAnchor.top;
    var insets = const [7.2, 3.6, 7.2, 3.6];
    if (textBox != null) {
      paras = _paras(textBox, f);
      anchor = _anchor(f);
      insets = _insets(f);
    }
    if (table != null) {
      out.add(_table(table, box));
      return;
    }
    if (paras.every((p) => p.text.isEmpty) &&
        image == null &&
        label == null &&
        paint.fill == null &&
        paint.line == null) {
      return;
    }
    out.add(
      RShape(
        x: box.x,
        y: box.y,
        w: box.w,
        h: box.h,
        rotation: box.rot,
        fill: paint.fill,
        line: paint.line,
        lineWidth: paint.lineWidth,
        image: image,
        label: label,
        paras: paras,
        anchor: anchor,
        insets: insets,
      ),
    );
  }

  RAnchor _anchor(XmlElement e) => switch (_prop(
    _graphicStyles(e),
    'graphic-properties',
    'textarea-vertical-align',
  )) {
    'middle' => RAnchor.middle,
    'bottom' => RAnchor.bottom,
    _ => RAnchor.top,
  };

  List<double> _insets(XmlElement e) {
    final names = _graphicStyles(e);
    double pick(String a, double def) =>
        length(_prop(names, 'graphic-properties', a)) ?? def;
    return [
      pick('padding-left', 7.2),
      pick('padding-top', 3.6),
      pick('padding-right', 7.2),
      pick('padding-bottom', 3.6),
    ];
  }

  static const _presets = {
    'rectangle': 'rect',
    'round-rectangle': 'roundRect',
    'ellipse': 'ellipse',
    'circle': 'ellipse',
    'isosceles-triangle': 'triangle',
    'right-triangle': 'rtTriangle',
    'diamond': 'diamond',
    'parallelogram': 'parallelogram',
    'trapezoid': 'trapezoid',
    'pentagon-right': 'homePlate',
    'pentagon': 'pentagon',
    'hexagon': 'hexagon',
    'octagon': 'octagon',
    'chevron': 'chevron',
    'right-arrow': 'rightArrow',
    'left-arrow': 'leftArrow',
    'up-arrow': 'upArrow',
    'down-arrow': 'downArrow',
    'star5': 'star5',
    'cross': 'plus',
    'flowchart-process': 'rect',
    'flowchart-decision': 'diamond',
    'flowchart-terminator': 'flowChartTerminator',
    'flowchart-connector': 'ellipse',
  };

  RShape? _shape(XmlElement e) {
    final box = _box(e);
    if (box == null) return null;
    var geometry = switch (e.local) {
      'ellipse' || 'circle' => 'ellipse',
      _ => 'rect',
    };
    final rx = length(e.attr('corner-radius'));
    if (e.local == 'rect' && (rx ?? 0) > 0) geometry = 'roundRect';
    List<List<RPathCmd>>? path;
    final geo = e.kid('enhanced-geometry');
    if (geo != null) {
      final type = geo.attr('type') ?? '';
      final preset = _presets[type];
      if (preset != null) {
        geometry = preset;
      } else {
        path = _enhancedPath(geo);
        if (path != null) geometry = 'custom';
      }
    }
    final paint = _paint(e, frame: false);
    final paras = _paras(e, e);
    return RShape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      rotation: box.rot,
      geometry: geometry,
      path: path,
      fill: paint.fill,
      image: paint.image,
      line: paint.line,
      lineWidth: paint.lineWidth,
      paras: paras,
      anchor: _anchor(e) == RAnchor.top && geo != null
          ? RAnchor.middle
          : _anchor(e),
      insets: _insets(e),
    );
  }

  /// Tracciato "M 0 0 L 21600 0 ... Z N" nel riquadro svg:viewBox (solo
  /// numeri: le formule delle forme si ignorano).
  List<List<RPathCmd>>? _enhancedPath(XmlElement geo) {
    final d = geo.attr('enhanced-path');
    final vb = (geo.attr('viewBox') ?? '0 0 21600 21600')
        .trim()
        .split(RegExp(r'\s+'))
        .map(parseFinite)
        .toList();
    if (d == null || vb.length != 4 || vb.contains(null)) return null;
    final vx = vb[0]!, vy = vb[1]!, vw = vb[2]!, vh = vb[3]!;
    if (vw <= 0 || vh <= 0) return null;
    final tokens = RegExp(r'[A-Za-z]|-?[\d.]+(?:[eE][+-]?\d+)?|\?\w+|\$\d+')
        .allMatches(d)
        .map((m) => m.group(0)!)
        .toList();
    final out = <List<RPathCmd>>[];
    var cur = <RPathCmd>[];
    String? cmd;
    final nums = <double>[];
    void flush() {
      if (cmd == null) return;
      final need = switch (cmd) {
        'M' || 'L' => 2,
        'C' => 6,
        _ => 0,
      };
      if (need == 0) return;
      for (var i = 0; i + need <= nums.length; i += need) {
        final pts = [
          for (var k = 0; k < need; k++)
            k.isEven ? (nums[i + k] - vx) / vw : (nums[i + k] - vy) / vh,
        ];
        final op = cmd == 'M' && i == 0 ? 0 : (cmd == 'C' ? 2 : 1);
        cur.add(RPathCmd(op, pts));
      }
      nums.clear();
    }

    for (final t in tokens) {
      if (RegExp(r'^[A-Za-z]$').hasMatch(t)) {
        flush();
        cmd = t;
        switch (t) {
          case 'Z':
            cur.add(const RPathCmd(3));
          case 'N':
            if (cur.isNotEmpty) out.add(cur);
            cur = <RPathCmd>[];
          case 'M' || 'L' || 'C' || 'F' || 'S':
            break;
          default:
            // archi e curve speciali: non gestiti
            return null;
        }
      } else if (t.startsWith('?') || t.startsWith(r'$')) {
        return null;
      } else {
        // numero non valido («1.2.3», «1e999»): percorso non disegnabile
        final v = parseFinite(t);
        if (v == null) return null;
        nums.add(v);
      }
    }
    flush();
    if (cur.isNotEmpty) out.add(cur);
    return out.isEmpty ? null : out;
  }

  RShape? _line(XmlElement e) {
    final x1 = length(e.attr('x1')), y1 = length(e.attr('y1'));
    final x2 = length(e.attr('x2')), y2 = length(e.attr('y2'));
    if (x1 == null || y1 == null || x2 == null || y2 == null) return null;
    final paint = _paint(e, frame: false);
    return RShape(
      x: math.min(x1, x2),
      y: math.min(y1, y2),
      w: math.max((x2 - x1).abs(), 0.5),
      h: math.max((y2 - y1).abs(), 0.5),
      flipH: x2 < x1,
      flipV: y2 < y1,
      geometry: 'line',
      line: paint.line ?? 0xFF000000,
      lineWidth: paint.lineWidth,
    );
  }

  // --------------------------------------------------------------- Testo

  /// Paragrafi (anche negli elenchi) di [parent]; [owner] è la forma con
  /// gli stili di base (presentation:style-name).
  List<RSlidePara> _paras(XmlElement parent, XmlElement owner) {
    final out = <RSlidePara>[];
    final ownerStyles = _graphicStyles(owner);
    void walk(XmlElement el, int level, String? listStyle) {
      for (final c in el.childElements) {
        switch (c.local) {
          case 'p' || 'h':
            out.add(_para(c, ownerStyles, level, listStyle));
          case 'list':
            walk(c, level + 1, c.attr('style-name') ?? listStyle);
          case 'list-item' || 'list-header':
            walk(c, level, listStyle);
        }
      }
    }

    walk(parent, 0, null);
    return out;
  }

  RSlidePara _para(
    XmlElement p,
    List<String?> ownerStyles,
    int level,
    String? listStyle,
  ) {
    final pStyles = [p.attr('style-name'), ...ownerStyles];
    String? pp(String attr) => _prop(pStyles, 'paragraph-properties', attr);
    String? tp(List<String?> names, String attr) =>
        _prop(names, 'text-properties', attr);
    double size(List<String?> names) {
      final v = tp(names, 'font-size');
      if (v == null || v.endsWith('%')) return 18;
      return length(v) ?? 18;
    }

    final runs = <RRun>[];
    void text(String t, List<String?> names) {
      if (t.isEmpty) return;
      final weight = tp(names, 'font-weight');
      final u = tp(names, 'text-underline-style');
      final st = tp(names, 'text-line-through-style');
      runs.add(
        RRun(
          RSpan(
            t,
            bold: weight == 'bold' || (int.tryParse(weight ?? '') ?? 0) >= 600,
            italic: tp(names, 'font-style') == 'italic',
            underline: u != null && u != 'none',
            strike: st != null && st != 'none',
          ),
          size: size(names),
          color: _color(tp(names, 'color')) ?? 0xFF000000,
        ),
      );
    }

    void inline(XmlNode n, List<String?> names) {
      if (n is XmlText) {
        text(n.value.replaceAll(RegExp(r'\s+'), ' '), names);
        return;
      }
      if (n is! XmlElement) return;
      switch (n.local) {
        case 'span' || 'a':
          final inner = [n.attr('style-name'), ...names];
          for (final c in n.children) {
            inline(c, inner);
          }
        case 's':
          text(' ' * (int.tryParse(n.attr('c') ?? '') ?? 1), names);
        case 'tab':
          text('\t', names);
        case 'line-break':
          text('\n', names);
        default:
          for (final c in n.children) {
            inline(c, names);
          }
      }
    }

    for (final c in p.children) {
      inline(c, pStyles);
    }
    final baseSize = size(pStyles);
    // elenco: segno e rientri del livello
    String? bullet;
    var indent = math.max(0.0, length(pp('margin-left')) ?? 0);
    var hanging = math.max(0.0, -(length(pp('text-indent')) ?? 0));
    if (level > 0 && runs.isNotEmpty) {
      final style = _lists[listStyle];
      XmlElement? lvl;
      for (final l in style?.childElements ?? const <XmlElement>[]) {
        if (l.attr('level') == '$level') lvl = l;
      }
      if (lvl?.local == 'list-level-style-bullet') {
        final ch = lvl!.attr('bullet-char') ?? '•';
        final code = ch.isEmpty ? 0 : ch.codeUnitAt(0);
        bullet = code >= 0xE000 && code <= 0xF8FF ? '•' : ch;
      } else if (lvl?.local == 'list-level-style-number') {
        bullet = '$level.';
      } else if (style == null) {
        bullet = '•';
      }
      final props = lvl?.kid('list-level-properties');
      final before = length(props?.attr('space-before'));
      final label = length(props?.attr('min-label-width'));
      if (indent == 0 && before != null) indent = before + (label ?? 0);
      if (hanging == 0) hanging = label ?? baseSize;
    }
    final lineHeight = pp('line-height');
    var spacing = 1.0;
    final pct = RegExp(r'([\d.]+)%').firstMatch(lineHeight ?? '');
    if (pct != null) spacing = (parseFinite(pct.group(1)) ?? 100) / 100;
    return RSlidePara(
      runs,
      align: switch (pp('text-align')) {
        'center' => RAlign.center,
        'end' || 'right' => RAlign.right,
        'justify' => RAlign.justify,
        _ => RAlign.left,
      },
      indent: indent,
      hanging: bullet == null ? 0 : hanging,
      bullet: bullet,
      bulletColor: runs.isEmpty ? null : runs.first.color,
      spaceBefore: length(pp('margin-top')) ?? 0,
      lineSpacing: spacing,
      size: baseSize,
    );
  }

  RShape _table(
    XmlElement table,
    ({double x, double y, double w, double h, double rot}) box,
  ) {
    final cols = <double>[];
    for (final c in table.desc('table-column')) {
      final w = length(
        _styles[c.attr('style-name')]
            ?.kid('table-column-properties')
            ?.attr('column-width'),
      );
      final rep = int.tryParse(c.attr('number-columns-repeated') ?? '') ?? 1;
      for (var i = 0; i < rep.clamp(1, 100); i++) {
        cols.add(w ?? 72);
      }
    }
    final rows = <double>[];
    final cells = <List<RSlideCell>>[];
    for (final tr in table.desc('table-row')) {
      rows.add(
        length(
              _styles[tr.attr('style-name')]
                  ?.kid('table-row-properties')
                  ?.attr('row-height'),
            ) ??
            0,
      );
      final row = <RSlideCell>[];
      for (final tc in tr.childElements) {
        if (tc.local != 'table-cell') continue;
        final fill = _prop(
          [tc.attr('style-name')],
          'graphic-properties',
          'fill-color',
        );
        row.add(
          RSlideCell(
            _paras(tc, tc),
            fill: _color(fill),
            span: int.tryParse(tc.attr('number-columns-spanned') ?? '') ?? 1,
          ),
        );
      }
      cells.add(row);
    }
    return RShape(
      x: box.x,
      y: box.y,
      w: box.w,
      h: box.h,
      table: RSlideTable(cols, rows, cells),
      line: 0xFF000000,
    );
  }
}
