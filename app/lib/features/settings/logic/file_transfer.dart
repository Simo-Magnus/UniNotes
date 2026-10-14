import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// File scelto dall'utente con il suo contenuto.
class PickedBytes {
  const PickedBytes(this.name, this.bytes);
  final String name;
  final Uint8List bytes;

  /// Contenuto come testo UTF-8 (BOM ignorato).
  String asText() {
    try {
      final s = utf8.decode(bytes);
      return s.startsWith('\uFEFF') ? s.substring(1) : s;
    } on FormatException {
      throw FileTransferException('$name non è un file di testo UTF-8 valido.');
    }
  }
}

class FileTransferException implements Exception {
  FileTransferException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Selezione/salvataggio file per Impostazioni (Android e Windows).
class FileTransfer {
  /// Su Android il filtro per estensione dipende dal tipo MIME, poco
  /// affidabile per .json/.pmtiles: si mostra tutto e si valida dopo.
  static bool get _filterByExtension => !Platform.isAndroid;

  /// Sceglie un file e ne legge il contenuto (null se annullato).
  static Future<PickedBytes?> pickBytes({
    required String dialogTitle,
    required List<String> extensions,
    int maxBytes = 20 * 1024 * 1024,
  }) async {
    final file = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: _filterByExtension ? FileType.custom : FileType.any,
      allowedExtensions: _filterByExtension ? extensions : null,
    );
    if (file == null) return null;
    final len = await file.length();
    if (len != null && len > maxBytes) {
      throw FileTransferException(
        'File troppo grande (limite ${maxBytes ~/ (1024 * 1024)} MB): ${file.name}',
      );
    }
    try {
      return PickedBytes(file.name, await file.readAsBytes());
    } catch (e) {
      throw FileTransferException('Impossibile leggere ${file.name}: $e');
    }
  }

  /// Sceglie un file e ne restituisce il riferimento senza leggerlo
  /// (per file grandi come le mappe PMTiles).
  static Future<PlatformFile?> pickFile({
    required String dialogTitle,
    required List<String> extensions,
  }) => FilePicker.pickFile(
    dialogTitle: dialogTitle,
    type: _filterByExtension ? FileType.custom : FileType.any,
    allowedExtensions: _filterByExtension ? extensions : null,
  );

  /// Finestra "Salva con nome" che scrive [bytes]. Restituisce una
  /// descrizione della destinazione, o null se annullato.
  static Future<String?> saveBytes({
    required String dialogTitle,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    List<String>? extensions,
  }) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: dialogTitle,
      fileName: fileName,
      bytes: bytes,
      mimeType: mimeType,
      type: extensions == null ? FileType.any : FileType.custom,
      allowedExtensions: extensions,
    );
    if (uri == null) return null;
    return uri.isScheme('file') ? uri.toFilePath() : fileName;
  }
}
