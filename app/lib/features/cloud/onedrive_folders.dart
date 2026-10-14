import 'graph_client.dart';

/// Cartella di OneDrive mostrata nel selettore.
class DriveFolder {
  const DriveFolder({
    required this.id,
    required this.name,
    required this.path,
    this.childCount,
  });

  /// La radice di OneDrive («I miei file»).
  static const root = DriveFolder(id: 'root', name: 'OneDrive', path: '');

  final String id;
  final String name;

  /// Percorso dalla radice, con «/» (vuoto = radice).
  final String path;
  final int? childCount;

  bool get isRoot => path.isEmpty;

  /// Percorso per Graph (`root` o `items/<id>`).
  String get _graphPath => isRoot ? 'me/drive/root' : 'me/drive/items/$id';

  String childPath(String child) => isRoot ? child : '$path/$child';
}

/// Navigazione delle cartelle di un servizio cloud (OneDrive, Google Drive)
/// e creazione di nuove cartelle, per scegliere dove l'app salva tutto.
abstract class FolderBrowser {
  /// Nome del servizio («OneDrive», «Google Drive»).
  String get serviceName;

  /// Radice del servizio.
  DriveFolder get root;

  /// Sottocartelle di [parent], in ordine alfabetico.
  Future<List<DriveFolder>> children(DriveFolder parent);

  /// Crea la cartella [name] dentro [parent].
  Future<DriveFolder> createFolder(DriveFolder parent, String name);

  /// Messaggio d'errore per un nome non valido (null = valido).
  String? validate(String name) => OneDriveFolderBrowser.validateName(name);
}

/// Cartelle di OneDrive (Microsoft Graph `/me/drive/root/children`,
/// `/me/drive/items/{id}/children`).
class OneDriveFolderBrowser extends FolderBrowser {
  OneDriveFolderBrowser(this.graph);
  final GraphClient graph;

  @override
  String get serviceName => 'OneDrive';

  @override
  DriveFolder get root => DriveFolder.root;

  @override
  Future<List<DriveFolder>> children(DriveFolder parent) async {
    final items = await graph.list('${parent._graphPath}/children', {
      r'$select': 'id,name,folder',
      r'$top': '200',
    });
    final out = [
      for (final it in items)
        if (it['folder'] != null)
          DriveFolder(
            id: '${it['id']}',
            name: '${it['name']}',
            path: parent.childPath('${it['name']}'),
            childCount: ((it['folder'] as Map?)?['childCount'] as num?)
                ?.toInt(),
          ),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// Nomi non ammessi da OneDrive.
  static final invalidName = RegExp(r'["*:<>?/\\|]');

  static String? validateName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Scrivi un nome.';
    if (invalidName.hasMatch(n)) {
      return 'Il nome non può contenere " * : < > ? / \\ |';
    }
    if (n.endsWith('.')) return 'Il nome non può finire con un punto.';
    return null;
  }

  @override
  Future<DriveFolder> createFolder(DriveFolder parent, String name) async {
    final n = name.trim();
    final err = validateName(n);
    if (err != null) throw GraphException(400, err);
    try {
      final r = await graph.sendJson('POST', '${parent._graphPath}/children', {
        'name': n,
        'folder': <String, Object?>{},
        '@microsoft.graph.conflictBehavior': 'fail',
      });
      return DriveFolder(
        id: '${r['id']}',
        name: '${r['name'] ?? n}',
        path: parent.childPath('${r['name'] ?? n}'),
      );
    } on GraphException catch (e) {
      if (e.status == 409) {
        throw GraphException(409, 'Esiste già una cartella «$n» qui.');
      }
      rethrow;
    }
  }
}
