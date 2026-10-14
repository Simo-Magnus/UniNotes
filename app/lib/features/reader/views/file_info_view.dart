import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../../core/theme/app_tokens.dart';
import '../../../widgets/glass.dart';
import '../../notes/markdown_view.dart' show findActiveColor, findMatchColor;
import '../reader_controller.dart';
import '../reader_formats.dart';
import '../reader_loader.dart';
import '../reader_text.dart';

/// Dimensione leggibile ("1,2 MB").
String formatBytes(int b) {
  if (b < 1024) return '$b B';
  final units = ['KB', 'MB', 'GB'];
  var v = b / 1024;
  var u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u++;
  }
  return '${v.toStringAsFixed(v >= 10 ? 0 : 1).replaceAll('.', ',')} ${units[u]}';
}

/// Data e ora brevi ("05/10/2026 08:30"), senza dati di localizzazione.
String formatDateTime(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year} ${two(d.hour)}:${two(d.minute)}';
}

/// Icona della famiglia di formati.
IconData readerFamilyIcon(ReaderFamily f) => switch (f) {
  ReaderFamily.pdf => Icons.picture_as_pdf_outlined,
  ReaderFamily.word => Icons.description_outlined,
  ReaderFamily.presentation => Icons.slideshow_outlined,
  ReaderFamily.spreadsheet => Icons.table_chart_outlined,
  ReaderFamily.text => Icons.article_outlined,
  ReaderFamily.code => Icons.code,
  ReaderFamily.ebook => Icons.auto_stories_outlined,
  ReaderFamily.image => Icons.image_outlined,
  ReaderFamily.audio => Icons.graphic_eq,
  ReaderFamily.video => Icons.movie_outlined,
  ReaderFamily.handwriting => Icons.draw_outlined,
  ReaderFamily.notes => Icons.sticky_note_2_outlined,
  ReaderFamily.archive => Icons.folder_zip_outlined,
  ReaderFamily.other => Icons.insert_drive_file_outlined,
};

/// File che il lettore non mostra: informazioni, motivo, "Apri con…" e
/// "Condividi" (l'unica azione arancione è aprire con l'app predefinita).
class FileInfoView extends StatelessWidget {
  const FileInfoView({
    super.key,
    required this.path,
    required this.format,
    this.message,
    required this.onOpenExternal,
    required this.onShare,
    this.onOneNote,
  });

  final String path;
  final ReaderFormat format;
  final String? message;
  final VoidCallback onOpenExternal;
  final VoidCallback onShare;
  final VoidCallback? onOneNote;

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final f = File(path);
    final stat = f.existsSync() ? f.statSync() : null;
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: t.textMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(fontSize: 13, color: t.textPrimary),
            ),
          ),
        ],
      ),
    );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: GlassCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        readerFamilyIcon(format.family),
                        size: 36,
                        color: t.cyanSoft,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          p.basename(path),
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: t.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (message != null) ...[
                    const SizedBox(height: 14),
                    Text(
                      message!,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.45,
                        color: t.textSecondary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  row('Tipo', format.label),
                  row(
                    'Dimensione',
                    stat == null ? '- -' : formatBytes(stat.size),
                  ),
                  row(
                    'Modificato',
                    stat == null ? '- -' : formatDateTime(stat.modified),
                  ),
                  row('Percorso', path),
                  if (format.note != null) row('Nota', format.note!),
                  const SizedBox(height: 18),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: onOpenExternal,
                        icon: const Icon(Icons.open_in_new),
                        label: const Text('Apri con l\'app predefinita'),
                      ),
                      OutlinedButton.icon(
                        onPressed: onShare,
                        icon: const Icon(Icons.ios_share),
                        label: const Text('Condividi'),
                      ),
                      if (onOneNote != null)
                        TextButton.icon(
                          onPressed: onOneNote,
                          icon: const Icon(Icons.cloud_outlined),
                          label: const Text('OneNote nell\'app'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Contenuto di un archivio ZIP: tocca una voce per aprirla nel lettore.
class ArchiveView extends StatefulWidget {
  const ArchiveView({
    super.key,
    required this.entries,
    required this.controller,
    required this.onOpen,
  });
  final List<ArchiveEntry> entries;
  final ReaderPaneController controller;
  final ValueChanged<ArchiveEntry> onOpen;

  @override
  State<ArchiveView> createState() => _ArchiveViewState();
}

class _ArchiveViewState extends State<ArchiveView> {
  final _scroll = ScrollController();
  final _list = ListController();
  List<int> _matches = const [];
  int? _current;

  @override
  void initState() {
    super.initState();
    widget.controller.update(() {
      widget.controller
        ..onFind = _find
        ..onStep = _step;
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _list.dispose();
    super.dispose();
  }

  void _find(String q) {
    final out = <int>[
      for (var i = 0; i < widget.entries.length; i++)
        if (q.trim().isNotEmpty &&
            findFolded(widget.entries[i].name, q.trim()).isNotEmpty)
          i,
    ];
    setState(() {
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
    widget.controller.update(() {
      widget.controller
        ..matchCount = _matches.length
        ..matchIndex = _current;
    });
    final cur = _current;
    if (cur != null && _list.isAttached && _scroll.hasClients) {
      _list.jumpToItem(
        index: _matches[cur],
        scrollController: _scroll,
        alignment: 0.3,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.tokens;
    final b = Theme.of(context).brightness;
    final entries = widget.entries;
    if (entries.isEmpty) {
      return Center(
        child: Text(
          'L\'archivio è vuoto.',
          style: TextStyle(color: t.textMuted),
        ),
      );
    }
    final hits = _matches.toSet();
    final active = _current == null ? null : _matches[_current!];
    final total = entries.fold(0, (s, e) => s + e.size);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '${entries.length} file · ${formatBytes(total)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: t.cyanSoft,
              ),
            ),
          ),
        ),
        Expanded(
          child: SuperListView.builder(
            controller: _scroll,
            listController: _list,
            padding: const EdgeInsets.only(bottom: 32),
            itemCount: entries.length,
            itemBuilder: (context, i) {
              final e = entries[i];
              final f = detectFormat(e.name);
              return ListTile(
                leading: Icon(
                  readerFamilyIcon(f.family),
                  color: f.supported ? t.cyanSoft : t.textMuted,
                ),
                title: Text(
                  p.basename(e.name),
                  style: hits.contains(i)
                      ? TextStyle(
                          backgroundColor: i == active
                              ? findActiveColor(b)
                              : findMatchColor(b),
                        )
                      : null,
                ),
                subtitle: Text(
                  [
                    if (p.dirname(e.name) != '.') p.dirname(e.name),
                    formatBytes(e.size),
                    f.label,
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () => widget.onOpen(e),
              );
            },
          ),
        ),
      ],
    );
  }
}
