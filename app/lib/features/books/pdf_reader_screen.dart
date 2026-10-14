import 'dart:io';

import 'package:flutter/material.dart';

import '../reader/reader_screen.dart';
import 'reading_position.dart';

/// Lettore PDF di libri e materiali: il lettore universale dell'app che si
/// apre all'ultima pagina letta e salva la pagina corrente nel database
/// (non nelle impostazioni del lettore) mentre si sfoglia.
class PdfReaderScreen extends StatelessWidget {
  const PdfReaderScreen({
    super.key,
    required this.title,
    required this.file,
    required this.savePosition,
    this.lastPage,
    this.pageCount,
  });

  final String title;
  final File file;
  final int? lastPage;
  final int? pageCount;

  /// Salva la pagina corrente (libro o materiale).
  final Future<void> Function(int page, int? pageCount) savePosition;

  @override
  Widget build(BuildContext context) => ReaderScreen(
    path: file.path,
    title: title,
    initialPosition: resumePage(lastPage, pageCount),
    onPosition: savePosition,
  );
}
