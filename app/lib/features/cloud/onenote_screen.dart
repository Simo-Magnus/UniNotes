import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/external_launcher.dart';
import '../../widgets/common.dart';
import '../../widgets/glass.dart';
import 'onenote.dart';
import '../../utils/dates.dart';

/// Elenco generico di OneNote (blocchi, sezioni, pagine) con caricamento.
class _OneNoteList extends StatefulWidget {
  const _OneNoteList({
    required this.title,
    required this.load,
    required this.onTap,
    this.icon = Icons.book_outlined,
    this.header,
  });

  final String title;
  final Future<List<OneNoteItem>> Function(OneNoteReader r) load;
  final void Function(BuildContext context, OneNoteItem item) onTap;
  final IconData icon;
  final Widget? header;

  @override
  State<_OneNoteList> createState() => _OneNoteListState();
}

class _OneNoteListState extends State<_OneNoteList> {
  late final OneNoteReader _reader = context
      .read<AppServices>()
      .onedrive
      .oneNote();
  late Future<List<OneNoteItem>> _future = widget.load(_reader);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Aggiorna',
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _future = widget.load(_reader)),
          ),
        ],
      ),
      body: FutureBuilder<List<OneNoteItem>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return EmptyState(icon: Icons.cloud_off, message: '${snap.error}');
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final items = snap.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              ?widget.header,
              if (items.isEmpty)
                const EmptyState(
                  icon: Icons.inbox_outlined,
                  message: 'Niente da mostrare.',
                )
              else
                GlassCard(
                  child: Column(
                    children: [
                      for (final it in items)
                        ListTile(
                          leading: Icon(widget.icon),
                          title: Text(it.title),
                          subtitle: Text(
                            [
                              ?it.parent,
                              if (it.modified != null)
                                'modificato ${formatDmyHm(it.modified!)}',
                            ].join(' · '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => widget.onTap(context, it),
                        ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// Blocchi appunti OneNote dell'utente (più le pagine recenti).
class OneNoteScreen extends StatelessWidget {
  const OneNoteScreen({super.key});

  @override
  Widget build(BuildContext context) => _OneNoteList(
    title: 'OneNote',
    load: (r) => r.notebooks(),
    header: GlassCard(
      child: ListTile(
        leading: const Icon(Icons.history),
        title: const Text('Pagine modificate di recente'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _push(
          context,
          _OneNoteList(
            title: 'Pagine recenti',
            icon: Icons.description_outlined,
            load: (r) => r.recentPages(),
            onTap: _openPage,
          ),
        ),
      ),
    ),
    onTap: (context, nb) => _push(
      context,
      _OneNoteList(
        title: nb.title,
        icon: Icons.folder_outlined,
        load: (r) => r.sections(nb.id),
        onTap: (context, sec) => _push(
          context,
          _OneNoteList(
            title: sec.title,
            icon: Icons.description_outlined,
            load: (r) => r.pages(sec.id),
            onTap: _openPage,
          ),
        ),
      ),
    ),
  );

  static void _push(BuildContext context, Widget w) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));

  static void _openPage(BuildContext context, OneNoteItem page) =>
      _push(context, OneNotePageScreen(page: page));
}

/// Testo di una pagina OneNote, con apertura nell'app o nel web.
class OneNotePageScreen extends StatefulWidget {
  const OneNotePageScreen({super.key, required this.page});
  final OneNoteItem page;

  @override
  State<OneNotePageScreen> createState() => _OneNotePageScreenState();
}

class _OneNotePageScreenState extends State<OneNotePageScreen> {
  late final Future<String> _text = context
      .read<AppServices>()
      .onedrive
      .oneNote()
      .pageText(widget.page.id);

  Future<void> _open(String? url) async {
    if (url == null) return;
    final r = await ExternalLauncher.openUrl(url);
    if (mounted) showLaunchResult(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.page;
    return Scaffold(
      appBar: AppBar(title: Text(p.title)),
      body: FutureBuilder<String>(
        future: _text,
        builder: (context, snap) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (p.clientUrl != null)
                    OutlinedButton.icon(
                      onPressed: () => _open(p.clientUrl),
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Apri in OneNote'),
                    ),
                  if (p.webUrl != null)
                    OutlinedButton.icon(
                      onPressed: () => _open(p.webUrl),
                      icon: const Icon(Icons.public),
                      label: const Text('Apri nel browser'),
                    ),
                ],
              ),
              const Divider(height: 28),
              if (snap.hasError)
                Text('${snap.error}')
              else if (!snap.hasData)
                const Center(child: CircularProgressIndicator())
              else
                SelectableText(
                  snap.data!.isEmpty
                      ? '(pagina senza testo: immagini o disegni si vedono in OneNote)'
                      : snap.data!,
                  style: Theme.of(context).textTheme.bodyMedium
                      ?.copyWith(height: 1.45),
                ),
            ],
          );
        },
      ),
    );
  }
}
