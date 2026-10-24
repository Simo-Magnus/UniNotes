import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../core/services/book_library.dart';
import '../../core/services/external_launcher.dart';
import '../../models/book.dart';
import '../../widgets/common.dart';
import '../books/pdf_reader_screen.dart';
import '../reader/reader_screen.dart';
import '../notes/safe_files.dart';

/// Il materiale ha un file (nell'app o in un percorso locale).
bool materialHasFile(StudyMaterial m) =>
    (m.storedFile ?? '').isNotEmpty || (m.localPath ?? '').trim().isNotEmpty;

/// Apre un materiale nel lettore interno: PDF all'ultima pagina letta
/// (salvata nel catalogo), gli altri formati con la posizione del lettore
/// ("Apri con…" resta nel menu). Un file con solo percorso esterno viene
/// prima copiato nell'app.
Future<void> openMaterial(BuildContext context, StudyMaterial material) async {
  final s = context.read<AppServices>();
  var m = material;
  var file = await s.materialsLibrary.fileNamed(m.storedFile);
  final path = m.localPath?.trim();
  if (file == null && path != null && path.isNotEmpty) {
    if (await fileExistsQuick(path)) {
      try {
        final name = await s.materialsLibrary.store(path);
        m = m.withFile(storedFile: () => name);
        await s.books.updateMaterial(m);
        s.revision.bump();
        file = await s.materialsLibrary.fileNamed(name);
      } catch (e) {
        if (context.mounted) {
          showSnack(context, 'Copia nell\'app non riuscita: $e');
        }
        return;
      }
    } else {
      final r = await ExternalLauncher.openPath(path);
      if (context.mounted) showLaunchResult(context, r);
      return;
    }
  }
  if (!context.mounted) return;
  if (file == null) {
    showSnack(
      context,
      'Il file di "${m.title}" non è disponibile su questo dispositivo.',
    );
    return;
  }
  if (BookLibrary.isPdf(file.path) && m.id != null) {
    final id = m.id!;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfReaderScreen(
          title: m.title,
          file: file!,
          lastPage: m.lastPage,
          pageCount: m.pageCount,
          savePosition: (page, count) =>
              s.books.saveMaterialPosition(id, page: page, pageCount: count),
        ),
      ),
    );
    s.revision.bump();
    return;
  }
  await openInReader(context, file.path, title: m.title);
}

/// Sceglie uno o più file e li aggiunge al materiale del corso, copiandoli
/// dentro l'app.
Future<void> addMaterialFiles(BuildContext context, int courseId) async {
  final s = context.read<AppServices>();
  final List<PlatformFile> files;
  try {
    files = await FilePicker.pickFiles(dialogTitle: 'Aggiungi materiale');
  } catch (e) {
    if (context.mounted) showSnack(context, 'Selezione non riuscita: $e');
    return;
  }
  var added = 0;
  for (final f in files) {
    final path = f.path;
    if (path == null) continue;
    try {
      final name = await s.materialsLibrary.store(path);
      await s.books.insertMaterial(
        StudyMaterial(
          courseId: courseId,
          title: p.basenameWithoutExtension(f.name),
          kind: MaterialKind.other,
          storedFile: name,
          source: 'aggiunto dall\'utente',
        ),
      );
      added++;
    } catch (e) {
      if (context.mounted) showSnack(context, '${f.name}: $e');
    }
  }
  s.revision.bump();
  if (context.mounted && added > 0) {
    showSnack(
      context,
      added == 1 ? 'Materiale aggiunto' : '$added materiali aggiunti',
    );
  }
}
