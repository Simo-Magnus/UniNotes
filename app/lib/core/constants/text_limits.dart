import 'package:flutter/services.dart';

/// Lunghezza massima dei campi di testo (in caratteri).
///
/// Criteri: i nomi reali più lunghi del database con un margine (i corsi di
/// laurea arrivano a ~120 caratteri, i titoli dei libri a ~200); i campi
/// brevi (codici, anni, ISBN) seguono il loro formato; i testi lunghi (note,
/// descrizioni) hanno un tetto ampio con il contatore visibile. Il corpo
/// degli appunti in Markdown, le risposte incollate dall'AI, le ricerche
/// nel testo e le password dei PDF non hanno limite.
abstract final class TextLimits {
  static const courseName = 150;
  static const courseCode = 20;
  static const teacher = 150;
  static const classCode = 20;
  static const moduleName = 100;
  static const topicName = 120;
  static const examTitle = 100;
  static const location = 120;
  static const bookTitle = 250;
  static const bookAuthor = 200;
  static const publisher = 120;
  static const edition = 20;
  static const isbn = 17;
  static const language = 40;
  static const fileName = 255;
  static const materialLine = 200;
  static const noteTitle = 90;
  static const search = 100;
  static const shortNote = 500;
  static const notes = 2000;
  static const longText = 4000;
  static const url = 2048;
  static const hexColor = 7;

  /// Limite senza contatore (campi brevi).
  static List<TextInputFormatter> max(int n) => [
    LengthLimitingTextInputFormatter(n),
  ];
}
