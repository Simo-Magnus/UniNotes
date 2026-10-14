import 'package:flutter/material.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/theme/app_tokens.dart';
import '../../notes/markdown_view.dart' show findActiveColor, findMatchColor;
import '../parsers/notes_apps.dart';
import '../reader_controller.dart';
import '../reader_text.dart';
import 'reader_surface.dart';

/// Mappa mentale o scaletta come elenco pieghevole. La ricerca apre i rami
/// che contengono i risultati.
class OutlineView extends StatefulWidget {
  const OutlineView({
    super.key,
    required this.doc,
    required this.controller,
    this.initialPosition,
  });
  final OutlineDoc doc;
  final ReaderPaneController controller;
  final int? initialPosition;

  @override
  State<OutlineView> createState() => OutlineViewState();
}

class _Node {
  _Node(this.node, this.level, this.parent);
  final OutlineNode node;
  final int level;
  final int parent;
  bool get hasChildren => node.children.isNotEmpty;
}

class OutlineViewState extends State<OutlineView> {
  final _scroll = ScrollController();
  final _list = ListController();
  late final List<_Node> _nodes;
  final _collapsed = <int>{};
  List<int> _matches = const [];
  int? _current;
  String _query = '';

  ReaderPaneController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    final nodes = <_Node>[];
    void add(OutlineNode n, int level, int parent) {
      final i = nodes.length;
      nodes.add(_Node(n, level, parent));
      for (final c in n.children) {
        add(c, level + 1, i);
      }
    }

    for (final r in widget.doc.roots) {
      add(r, 0, -1);
    }
    _nodes = nodes;
    // Dalle mappe grandi si parte con i rami oltre il secondo livello chiusi.
    if (nodes.length > 60) {
      for (var i = 0; i < nodes.length; i++) {
        if (nodes[i].level >= 1 && nodes[i].hasChildren) _collapsed.add(i);
      }
    }
    _c.update(() {
      _c
        ..unitLabel = 'Nodo'
        ..onFind = _find
        ..onStep = _step
        ..onGoToPosition = _reveal
        ..describe = ((p) => p < _nodes.length ? _nodes[p].node.text : '')
        ..outline = [
          for (var i = 0; i < nodes.length; i++)
            if (nodes[i].level <= 1 && nodes[i].node.text.isNotEmpty)
              ReaderTocItem(nodes[i].node.text, i, level: nodes[i].level),
        ]
        ..plainText = (() =>
            [for (final n in _nodes) '${'  ' * n.level}${n.node.text}']
                .join('\n'));
    });
    final start = widget.initialPosition;
    if (start != null && start > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(start));
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  /// Nodi visibili (i figli dei rami chiusi sono nascosti).
  List<int> get _visible {
    final out = <int>[];
    var skipBelow = -1;
    for (var i = 0; i < _nodes.length; i++) {
      final n = _nodes[i];
      if (skipBelow >= 0 && n.level > skipBelow) continue;
      skipBelow = -1;
      out.add(i);
      if (_collapsed.contains(i)) skipBelow = n.level;
    }
    return out;
  }

  void expandAll(bool open) => setState(() {
    _collapsed.clear();
    if (!open) {
      for (var i = 0; i < _nodes.length; i++) {
        if (_nodes[i].hasChildren && _nodes[i].level >= 0) _collapsed.add(i);
      }
    }
  });

  void _reveal(int node) {
    if (node < 0 || node >= _nodes.length) return;
    setState(() {
      for (var p = _nodes[node].parent; p >= 0; p = _nodes[p].parent) {
        _collapsed.remove(p);
      }
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final idx = _visible.indexOf(node);
      if (idx >= 0 && _list.isAttached && _scroll.hasClients) {
        _list.jumpToItem(index: idx, scrollController: _scroll, alignment: 0.3);
      }
      _c.update(() => _c.position = node);
    });
  }

  void _find(String q) {
    final query = q.trim();
    final out = <int>[];
    if (query.isNotEmpty) {
      for (var i = 0; i < _nodes.length; i++) {
        final n = _nodes[i].node;
        if (findFolded('${n.text}\n${n.note ?? ''}', query).isNotEmpty) {
          out.add(i);
        }
      }
    }
    setState(() {
      _query = query;
      _matches = out;
      _current = out.isEmpty ? null : 0;
    });
    _report();
  }

  void _step(int d) {
    if (_matches.isEmpty) return;
    setState(() => _current = ((_current ?? 0) + d) % _matches.length);
    _report();
  }

  void _report() {
    _c.update(() {
      _c
        ..matchCount = _matches.length
        ..matchIndex = _current;
    });
    final cur = _current;
    if (cur != null) _reveal(_matches[cur]);
  }

  @override
  Widget build(BuildContext context) {
    final surface = ReaderSurface.of(context);
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    final visible = _visible;
    final hits = _matches.toSet();
    final active = _current == null ? null : _matches[_current!];
    return ColoredBox(
      color: surface.background,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${_nodes.length} nodi',
                    style: TextStyle(
                      fontSize: 12,
                      color: t.cyanSoft,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => expandAll(true),
                  icon: const Icon(Icons.unfold_more, size: 18),
                  label: const Text('Espandi tutto'),
                ),
                TextButton.icon(
                  onPressed: () => expandAll(false),
                  icon: const Icon(Icons.unfold_less, size: 18),
                  label: const Text('Comprimi'),
                ),
              ],
            ),
          ),
          Expanded(
            child: SelectionArea(
              child: SuperListView.builder(
                controller: _scroll,
                listController: _list,
                padding: const EdgeInsets.fromLTRB(8, 4, 16, 48),
                itemCount: visible.length,
                itemBuilder: (context, k) {
                  final i = visible[k];
                  final n = _nodes[i];
                  final open = !_collapsed.contains(i);
                  final hl = hits.contains(i);
                  return Padding(
                    padding: EdgeInsets.only(left: 22.0 * n.level),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 44,
                          height: 44,
                          child: n.hasChildren
                              ? IconButton(
                                  tooltip: open ? 'Comprimi' : 'Espandi',
                                  icon: Icon(
                                    open
                                        ? Icons.expand_more
                                        : Icons.chevron_right,
                                    color: t.cyan,
                                  ),
                                  onPressed: () => setState(
                                    () => open
                                        ? _collapsed.add(i)
                                        : _collapsed.remove(i),
                                  ),
                                )
                              : Icon(
                                  Icons.circle,
                                  size: 6,
                                  color: surface.muted,
                                ),
                        ),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  n.node.text.isEmpty ? '- -' : n.node.text,
                                  style: TextStyle(
                                    fontSize: n.level == 0 ? 18 : 15,
                                    fontWeight: n.level == 0
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                    color: surface.text,
                                    backgroundColor: hl
                                        ? (i == active
                                              ? findActiveColor(b)
                                              : findMatchColor(b))
                                        : null,
                                  ),
                                ),
                                if ((n.node.note ?? '').isNotEmpty)
                                  Text(
                                    n.node.note!,
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: surface.muted,
                                    ),
                                  ),
                                if (!open && n.hasChildren)
                                  Text(
                                    '${n.node.children.length} sotto-nodi',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: surface.muted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Testo cercato (per i test).
  String get query => _query;
}
