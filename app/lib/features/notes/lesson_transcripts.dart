import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../core/theme/app_tokens.dart';
import 'notes_store.dart';

/// Le trascrizioni di una lezione e come si riconoscono.
///
/// - `Trascrizioni/<lezione>.md`: Whisper (intera registrazione o dal vivo a
///   pezzi) oppure il testo dal vivo del riconoscimento vocale del sistema;
/// - `Trascrizioni/<lezione> (Gemini).md`: Gemini.
///
/// Nella card «Registrazioni delle lezioni» le due caselle «Trascrivi con
/// Whisper» e «Trascrivi con Gemini» diventano «Vedi trascrizione» quando la
/// trascrizione c'è, ognuna con il suo colore (Whisper azzurro, Gemini
/// viola): così si riconosce subito chi l'ha fatta.
enum TranscriptKind {
  whisper('Whisper'),
  gemini('Gemini');

  const TranscriptKind(this.label);
  final String label;
}

/// Nome del file (senza estensione) della trascrizione [kind] di [lesson].
String transcriptName(String lesson, TranscriptKind kind) =>
    kind == TranscriptKind.gemini
    ? '$lesson${NotesStore.geminiSuffix}'
    : lesson;

/// La lezione di una trascrizione (toglie « (Gemini)»).
String lessonOfTranscript(String name) => name.endsWith(NotesStore.geminiSuffix)
    ? name.substring(0, name.length - NotesStore.geminiSuffix.length)
    : name;

/// Chi ha fatto la trascrizione con questo nome.
TranscriptKind transcriptKindOf(String name) =>
    name.endsWith(NotesStore.geminiSuffix)
    ? TranscriptKind.gemini
    : TranscriptKind.whisper;

/// La trascrizione Markdown è il testo dal vivo del riconoscimento vocale
/// del sistema (l'intestazione indica la fonte), non quella di Whisper.
bool isSystemLiveTranscript(String head) =>
    head.contains('riconoscimento vocale del sistema');

class LessonTranscripts {
  const LessonTranscripts({this.whisper, this.systemLive, this.gemini});

  /// Trascrizione di Whisper (null se manca).
  final File? whisper;

  /// Testo dal vivo del riconoscimento del sistema (null se manca o se c'è
  /// già quella di Whisper, che lo sostituisce).
  final File? systemLive;
  final File? gemini;

  static const none = LessonTranscripts();

  File? of(TranscriptKind k) => k == TranscriptKind.gemini ? gemini : whisper;

  /// La trascrizione da mostrare per prima: Whisper, Gemini, dal vivo.
  File? get best => whisper ?? gemini ?? systemLive;
}

/// Trascrizioni della lezione [lesson] nella cartella [dir]
/// (`<corso>/Trascrizioni`).
Future<LessonTranscripts> loadLessonTranscripts(
  Directory dir,
  String lesson,
) async {
  final main = File(p.join(dir.path, '$lesson.md'));
  final gemini = File(
    p.join(dir.path, '${transcriptName(lesson, TranscriptKind.gemini)}.md'),
  );
  File? whisper, live;
  if (await main.exists()) {
    if (isSystemLiveTranscript(await readHead(main))) {
      live = main;
    } else {
      whisper = main;
    }
  }
  return LessonTranscripts(
    whisper: whisper,
    systemLive: live,
    gemini: await gemini.exists() ? gemini : null,
  );
}

/// Primi byte di [f] come testo (intestazione della trascrizione).
Future<String> readHead(File f, [int bytes = 600]) async {
  try {
    final raf = await f.open();
    try {
      final data = await raf.read(bytes);
      return utf8.decode(data, allowMalformed: true);
    } finally {
      await raf.close();
    }
  } on FileSystemException {
    return '';
  }
}

/// Colore delle caselle della trascrizione [kind] (contrasto AA su card
/// chiare e scure).
Color transcriptColor(BuildContext context, TranscriptKind kind) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return switch (kind) {
    TranscriptKind.whisper =>
      dark ? context.tokens.cyanSoft : const Color(0xFF0B5FA8),
    TranscriptKind.gemini =>
      dark ? const Color(0xFFC4B1FF) : const Color(0xFF6A3FD0),
  };
}

/// «Impossibile trascrivere con Whisper, …»: causa e cosa provare, dal
/// messaggio d'errore di Whisper.
String whisperFailureMessage(String error) {
  final e = error.toLowerCase();
  final String hint;
  if (e.contains('nessun modello') ||
      e.contains('non è installato') ||
      e.contains('non installato') ||
      e.contains('whisper-cli') && e.contains('non trovato')) {
    hint =
        'scarica un modello in Collegamenti → Whisper e riprova, oppure '
        'trascrivi con Gemini.';
  } else if (e.contains('nessun parlato')) {
    hint =
        'nell\'audio non c\'è parlato riconoscibile: controlla la '
        'registrazione o prova con Gemini.';
  } else if (e.contains('file audio non trovato') ||
      e.contains('non trovato') && e.contains('audio')) {
    hint = 'il file della registrazione non si trova più: è stato spostato?';
  } else if (e.contains('memoria') || e.contains('memory')) {
    hint =
        'memoria insufficiente: chiudi le altre app o scegli un modello più '
        'piccolo in Collegamenti → Whisper.';
  } else if (e.contains('ffmpeg') ||
      e.contains('conversione') ||
      e.contains('non leggibile') ||
      e.contains('vuoto')) {
    hint =
        'l\'audio non si riesce a leggere: prova a riprodurlo e, se è '
        'rovinato, trascrivi con Gemini.';
  } else if (e.contains('spazio')) {
    hint = 'spazio esaurito sul dispositivo: libera spazio e riprova.';
  } else {
    hint =
        'riprova; se non funziona scegli un modello più piccolo in '
        'Collegamenti → Whisper o trascrivi con Gemini.';
  }
  return 'Impossibile trascrivere con Whisper: $hint';
}
