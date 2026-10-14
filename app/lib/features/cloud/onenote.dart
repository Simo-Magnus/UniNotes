import '../../utils/html_text.dart';
import 'graph_client.dart';

/// Elemento di OneNote (blocco appunti, sezione o pagina).
class OneNoteItem {
  const OneNoteItem({
    required this.id,
    required this.title,
    this.modified,
    this.webUrl,
    this.clientUrl,
    this.parent,
  });

  final String id;
  final String title;
  final DateTime? modified;

  /// Apertura in OneNote per il web / nell'app OneNote.
  final String? webUrl;
  final String? clientUrl;

  /// Blocco appunti (per le sezioni) o sezione (per le pagine).
  final String? parent;

  static OneNoteItem from(
    Map<String, Object?> m, {
    String titleKey = 'displayName',
  }) {
    final links = (m['links'] as Map?)?.cast<String, Object?>() ?? const {};
    String? href(String k) => ((links[k] as Map?)?['href']) as String?;
    final parent =
        ((m['parentNotebook'] as Map?)?['displayName'] ??
                (m['parentSection'] as Map?)?['displayName'])
            as String?;
    return OneNoteItem(
      id: m['id'] as String,
      title: (m[titleKey] as String?)?.trim().isNotEmpty == true
          ? (m[titleKey] as String).trim()
          : '(senza titolo)',
      modified: DateTime.tryParse(m['lastModifiedDateTime'] as String? ?? '')
          ?.toLocal(),
      webUrl: href('oneNoteWebUrl'),
      clientUrl: href('oneNoteClientUrl'),
      parent: parent,
    );
  }
}

/// Lettura dei blocchi appunti OneNote dell'utente (sola lettura).
class OneNoteReader {
  OneNoteReader(this.graph);
  final GraphClient graph;

  Future<List<OneNoteItem>> notebooks() async => (await graph.list(
    'me/onenote/notebooks',
    {r'$orderby': 'displayName'},
  )).map(OneNoteItem.from).toList();

  Future<List<OneNoteItem>> sections(String notebookId) async =>
      (await graph.list('me/onenote/notebooks/$notebookId/sections', {
        r'$orderby': 'displayName',
      })).map(OneNoteItem.from).toList();

  Future<List<OneNoteItem>> pages(String sectionId) async =>
      (await graph.list('me/onenote/sections/$sectionId/pages', {
        r'$select': 'id,title,lastModifiedDateTime,links',
        r'$orderby': 'order',
        r'$top': '100',
      })).map((m) => OneNoteItem.from(m, titleKey: 'title')).toList();

  /// Pagine modificate di recente in tutti i blocchi appunti.
  Future<List<OneNoteItem>> recentPages({int top = 30}) async {
    final page = await graph.getJson('me/onenote/pages', {
      r'$select': 'id,title,lastModifiedDateTime,links',
      r'$expand': r'parentSection($select=displayName)',
      r'$orderby': 'lastModifiedDateTime desc',
      r'$top': '$top',
    });
    return [
      for (final m in (page?['value'] as List? ?? const []).whereType<Map>())
        OneNoteItem.from(m.cast<String, Object?>(), titleKey: 'title'),
    ];
  }

  /// Testo della pagina (l'HTML di OneNote convertito in testo).
  Future<String> pageText(String pageId) async {
    final r = await graph.request('GET', 'me/onenote/pages/$pageId/content');
    if (!r.ok) return '';
    return htmlToText(r.text);
  }
}
