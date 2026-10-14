import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/constants/enums.dart';
import '../../core/services/app_services.dart';
import '../../models/attachment.dart';
import '../../models/book.dart';
import '../../models/study.dart';

/// Modulo di Studio che raccoglie i file allegati agli esami della materia.
const kExamMaterialsModule = 'Materiale d\'esame';

/// I file allegati in «Materiale da studiare» di un esame, una prova in
/// itinere o un esonero finiscono anche nel «Materiale didattico» del corso
/// (Corsi) e negli allegati di Studio della materia (modulo
/// [kExamMaterialsModule]). Le copie sono nell'app: restano anche se il file
/// originale viene spostato. Le righe di solo testo non si copiano.
Future<void> shareExamMaterials(
  AppServices s, {
  required int courseId,
  required List<String> added,
}) async {
  final files = [
    for (final path in added)
      if (await File(path).exists()) path,
  ];
  if (files.isEmpty) return;
  final modules = await s.study.modules(courseId);
  final existing = modules.where((m) => m.name == kExamMaterialsModule);
  final moduleId = existing.isNotEmpty
      ? existing.first.id!
      : await s.study.insertModule(
          StudyModule(
            courseId: courseId,
            name: kExamMaterialsModule,
            sort: modules.length,
          ),
        );
  for (final path in files) {
    final title = p.basenameWithoutExtension(path);
    await s.books.insertMaterial(
      StudyMaterial(
        courseId: courseId,
        title: title,
        kind: MaterialKind.other,
        storedFile: await s.materialsLibrary.store(path),
        source: 'materiale d\'esame',
      ),
    );
    await s.study.insertAttachment(
      Attachment(
        moduleId: moduleId,
        title: title,
        storedFile: await s.attachmentsLibrary.store(path),
        createdAt: DateTime.now(),
      ),
    );
  }
}
