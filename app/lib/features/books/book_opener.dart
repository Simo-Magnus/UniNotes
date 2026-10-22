import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/services/book_library.dart';
import '../../core/services/external_launcher.dart';
import '../../models/book.dart';
import '../../widgets/common.dart';
import '../reader/reader_screen.dart';
import 'pdf_reader_screen.dart';

/// «Aggiungi» su un libro senza file: l'utente sceglie il file (l'app non
/// può verificare che sia davvero quel libro), che viene copiato nell'app;
/// il libro diventa «Scaricato». true se è stato associato un file.
Future<bool> attachBookFile(BuildContext context, Book book) async {
  final s = context.read<AppServices>();
  final PlatformFile? picked;
  try {
    picked = await FilePicker.pickFile(
      dialogTitle: 'Scegli il file di «${book.title}»',
    );
  } catch (e) {
    if (context.mounted) showSnack(context, 'Selezione non riuscita: $e');
    return false;
  }
  final path = picked?.path;
  if (path == null) return false;
  try {
    final name = await s.library.store(path);
    await s.books.update(book.withFile(storedFile: () => name));
    s.revision.bump();
    if (context.mounted) showSnack(context, '«${book.title}»: scaricato.');
    return true;
  } catch (e) {
    if (context.mounted) showSnack(context, 'Copia nell\'app non riuscita: $e');
    return false;
  }
}

/// Apre un libro:
/// - file nell'app: nel lettore interno (PDF all'ultima pagina letta salvata
///   nel catalogo; EPUB, MOBI, DOCX, ... con la posizione del lettore);
///   "Apri con…" resta nel menu del lettore;
/// - solo percorso esterno a un file esistente: lo copia prima nell'app;
/// - cartella o percorso mancante: lo apre con il sistema (o lo segnala).
Future<void> openBook(BuildContext context, Book book) async {
  try {
    await _openBook(context, book);
  } on FileSystemException catch (e) {
    // cartella dei libri non accessibile, file sparito durante la copia
    if (context.mounted) {
      showSnack(
        context,
        'Impossibile aprire "${book.title}": ${e.osError?.message ?? e.message}.',
      );
    }
  }
}

Future<void> _openBook(BuildContext context, Book book) async {
  final s = context.read<AppServices>();
  var b = book;
  var file = await s.library.fileOf(b);
  final path = b.filePath?.trim();
  if (file == null && path != null && path.isNotEmpty) {
    if (await File(path).exists()) {
      if (context.mounted) {
        showSnack(context, 'Copio "${b.title}" nell\'app…');
      }
      try {
        final name = await s.library.store(path);
        b = b.withFile(storedFile: () => name);
        await s.books.update(b);
        s.revision.bump();
        file = await s.library.fileOf(b);
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
      b.storedFile != null
          ? 'Il file di "${b.title}" non è più nell\'app su questo dispositivo. '
                'Modifica il libro per sceglierlo di nuovo.'
          : 'Nessun file associato a "${b.title}". '
                'Modifica il libro per aggiungerlo all\'app.',
    );
    return;
  }
  if (BookLibrary.isPdf(file.path) && b.id != null) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PdfReaderScreen(
          title: b.title,
          file: file!,
          lastPage: b.lastPage,
          pageCount: b.pageCount,
          savePosition: (page, count) =>
              s.books.saveReadingPosition(b.id!, page: page, pageCount: count),
        ),
      ),
    );
    s.revision.bump();
    return;
  }
  await openInReader(context, file.path, title: b.title);
}
