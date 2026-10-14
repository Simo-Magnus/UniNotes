import 'package:path/path.dart' as p;

import '../utils/parse.dart';

/// Tipo di un file allegato in Studio: teoria, esercizi o ripasso (anche
/// più di uno). Le icone compaiono nella casella del file.
enum AttachmentKind {
  theory('teoria', 'Teoria'),
  exercises('esercizi', 'Esercizi'),
  review('ripasso', 'Ripasso');

  const AttachmentKind(this.key, this.label);
  final String key;
  final String label;

  /// "teoria,ripasso" → {theory, review} (chiavi sconosciute ignorate).
  static Set<AttachmentKind> parse(String? v) => {
    for (final k in (v ?? '').split(','))
      for (final x in AttachmentKind.values)
        if (x.key == k.trim()) x,
  };

  /// {theory, review} → "teoria,ripasso" (null se vuoto), in ordine fisso.
  static String? encode(Set<AttachmentKind> kinds) => kinds.isEmpty
      ? null
      : [
          for (final x in AttachmentKind.values)
            if (kinds.contains(x)) x.key,
        ].join(',');
}

/// File allegato a un modulo o a un argomento di Studio.
///
/// Un file scelto dal dispositivo viene copiato nella cartella `allegati`
/// dell'app ([storedFile]); un appunto del corso (registrazione,
/// trascrizione, riassunto…) resta dov'è e si salva il suo percorso ([path]).
class Attachment {
  const Attachment({
    this.id,
    this.moduleId,
    this.topicId,
    required this.title,
    this.storedFile,
    this.path,
    required this.createdAt,
    this.kinds = const {},
  }) : assert(moduleId != null || topicId != null);

  final int? id;
  final int? moduleId;
  final int? topicId;
  final String title;
  final String? storedFile;
  final String? path;
  final DateTime createdAt;

  /// Teoria, esercizi, ripasso (vuoto = non indicato).
  final Set<AttachmentKind> kinds;

  /// Estensione del file (minuscola, con il punto).
  String get extension =>
      p.extension(storedFile ?? path ?? title).toLowerCase();

  /// true se è un appunto del corso collegato (non una copia nell'app).
  bool get isLinkedNote => storedFile == null && path != null;

  factory Attachment.fromMap(Map<String, Object?> m) => Attachment(
    id: asInt(m['id']),
    moduleId: asInt(m['module_id']),
    topicId: asInt(m['topic_id']),
    title: m['title'] as String,
    storedFile: asString(m['stored_file']),
    path: asString(m['path']),
    createdAt: asDateTime(m['created_at']) ?? DateTime.now(),
    kinds: AttachmentKind.parse(asString(m['kinds'])),
  );

  Map<String, Object?> toMap() => {
    if (id != null) 'id': id,
    'module_id': moduleId,
    'topic_id': topicId,
    'title': title,
    'stored_file': storedFile,
    'path': path,
    'created_at': isoLocal(createdAt),
    'kinds': AttachmentKind.encode(kinds),
  };
}
