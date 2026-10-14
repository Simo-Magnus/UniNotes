import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/course.dart';
import '../../repositories/settings_repository.dart';

/// Sottocartelle degli appunti di un corso.
enum NoteFolder {
  recordings('Registrazioni', 'Registrazioni delle lezioni'),
  transcripts('Trascrizioni', 'Trascrizioni'),
  summaries('Riassunti', 'Riassunti delle lezioni'),
  notes('Appunti', 'Appunti personali'),
  ai('AI', 'Risposte della tua AI di riferimento');

  const NoteFolder(this.dirName, this.label);
  final String dirName;
  final String label;
}

/// Un file degli appunti (audio o Markdown).
class NoteFile {
  NoteFile(this.file, this.folder, this.modified, this.size);
  final File file;
  final NoteFolder folder;
  final DateTime modified;
  final int size;

  String get name => p.basenameWithoutExtension(file.path);
  String get extension => p.extension(file.path).toLowerCase();
  bool get isAudio => NotesStore.audioExtensions.contains(extension);
}

/// Appunti dei corsi come file normali, una cartella per corso:
///
///     <radice>/PoliTo - Analisi matematica I/Registrazioni/2026-10-05 08-30 Lezione.flac
///     <radice>/PoliTo - Analisi matematica I/Trascrizioni/2026-10-05 08-30 Lezione.md
///     <radice>/PoliTo - Analisi matematica I/Riassunti/2026-10-05 08-30 Lezione.md
///
/// Trascrizione e riassunto hanno lo stesso nome della registrazione (la
/// trascrizione di Gemini ha in più « (Gemini)», vedi [NotesStore.geminiSuffix]); i
/// dati della registrazione (segnalibri, testo con i tempi, forma d'onda)
/// sono in `Registrazioni/<nome>.json` (recorder/recording_meta.dart).
/// Radice: sul PC `<cartella Appunti>/Corsi` (predefinita Documenti\UniNotes),
/// altrove la cartella documenti dell'app.
class NotesStore {
  NotesStore(this._settings, {Future<Directory> Function()? root})
    : _rootOverride = root;

  final SettingsRepository _settings;
  final Future<Directory> Function()? _rootOverride;

  static const audioExtensions = {
    '.flac',
    '.wav',
    '.m4a',
    '.aac',
    '.ogg',
    '.mp3',
  };

  Future<Directory> root() async {
    final override = _rootOverride;
    Directory dir;
    if (override != null) {
      dir = await override();
    } else if (Platform.isWindows) {
      final base = (await _settings.appuntiRoot()).trim();
      // Predefinita: Documenti\UniNotes (cartella propria dell'app, così
      // non si leggono appunti di altri programmi); chi aveva già la cartella
      // col nome precedente («University Notes») continua a usarla. Una
      // cartella scelta dall'utente vale solo se la sua unità esiste ancora.
      final docs = (await getApplicationDocumentsDirectory()).path;
      final old = Directory(p.join(docs, 'University Notes', 'Corsi'));
      dir = await old.exists()
          ? old
          : Directory(p.join(docs, 'UniNotes', 'Corsi'));
      if (base.isNotEmpty && await Directory(p.rootPrefix(base)).exists()) {
        dir = Directory(p.join(base, 'Corsi'));
      }
    } else {
      Directory base;
      try {
        base = await getApplicationDocumentsDirectory();
      } catch (_) {
        // Linux senza cartella Documenti (XDG): cartella dell'app.
        base = await getApplicationSupportDirectory();
      }
      dir = Directory(p.join(base.path, 'Appunti'));
    }
    await dir.create(recursive: true);
    return dir;
  }

  /// Nome della cartella del corso ("PoliTo - Analisi matematica I").
  static String folderName(Course c) {
    final uni = switch (c.universityId) {
      'polito' => 'PoliTo',
      'unito' => 'UniTO',
      _ => null,
    };
    final raw = [?uni, c.name].join(' - ');
    return safeName(raw);
  }

  static String safeName(String s) {
    var v = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    v = v.replaceAll(RegExp(r'[. ]+$'), '');
    if (v.length > 90) v = v.substring(0, 90).trim();
    return v.isEmpty ? 'Senza nome' : v;
  }

  /// La cartella delle risposte dell'AI si chiamava «Claude»: si rinomina in
  /// «AI» la prima volta che serve (se «AI» non esiste già).
  static Future<void> _migrateLegacy(String courseRoot) async {
    final old = Directory(p.join(courseRoot, 'Claude'));
    final now = Directory(p.join(courseRoot, NoteFolder.ai.dirName));
    try {
      if (await old.exists() && !await now.exists()) await old.rename(now.path);
    } on FileSystemException {
      // cartella in uso (es. OneDrive): si riprova al prossimo accesso
    }
  }

  /// Il corso ha cambiato nome (modifica, versione in inglese, nome nuovo
  /// nel catalogo): registrazioni e appunti seguono il nome nuovo. Se esiste
  /// già una cartella col nome nuovo i file si uniscono (senza sovrascrivere).
  Future<void> renameCourse(Course from, Course to) async {
    final base = (await root()).path;
    final src = Directory(p.join(base, folderName(from)));
    final dst = Directory(p.join(base, folderName(to)));
    if (src.path == dst.path || !await src.exists()) return;
    try {
      if (!await dst.exists()) {
        await src.rename(dst.path);
        return;
      }
      await for (final e in src.list(recursive: true)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: src.path);
        final target = File(p.join(dst.path, rel));
        if (await target.exists()) continue;
        await target.parent.create(recursive: true);
        await e.rename(target.path);
      }
      if (await src.list(recursive: true).where((e) => e is File).isEmpty) {
        await src.delete(recursive: true);
      }
    } on FileSystemException {
      // cartella in uso (es. sincronizzazione): resta com'è
    }
  }

  Future<Directory> courseDir(Course c, [NoteFolder? folder]) async {
    await _migrateLegacy(p.join((await root()).path, folderName(c)));
    final dir = Directory(
      p.joinAll([
        (await root()).path,
        folderName(c),
        if (folder != null) folder.dirName,
      ]),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// File del corso per cartella, dal più recente.
  Future<Map<NoteFolder, List<NoteFile>>> list(Course c) async {
    final out = <NoteFolder, List<NoteFile>>{};
    await _migrateLegacy(p.join((await root()).path, folderName(c)));
    for (final f in NoteFolder.values) {
      final dir = Directory(
        p.join((await root()).path, folderName(c), f.dirName),
      );
      final items = <NoteFile>[];
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (name.startsWith('.') || name.endsWith('.part')) continue;
          // dati delle registrazioni (segnalibri, testo con i tempi,
          // forma d'onda): si gestiscono insieme all'audio
          if (f == NoteFolder.recordings &&
              p.extension(name).toLowerCase() == '.json') {
            continue;
          }
          final st = await e.stat();
          items.add(NoteFile(e, f, st.modified, st.size));
        }
      }
      items.sort((a, b) => b.name.compareTo(a.name));
      out[f] = items;
    }
    return out;
  }

  /// Numero di file per corso (per l'elenco dei corsi).
  Future<int> count(Course c) async {
    final all = await list(c);
    return all.values.fold<int>(0, (a, l) => a + l.length);
  }

  /// Nome base di una nuova lezione: "2026-10-05 08-30 Lezione".
  static String lessonBaseName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}-${two(t.minute)} Lezione';
  }

  Future<String> newRecordingPath(
    Course c,
    DateTime t,
    String extension,
  ) async {
    final dir = await courseDir(c, NoteFolder.recordings);
    var base = lessonBaseName(t);
    var path = p.join(dir.path, '$base$extension');
    for (var i = 2; await File(path).exists(); i++) {
      path = p.join(dir.path, '$base ($i)$extension');
    }
    return path;
  }

  /// File Markdown [name] in [folder] (creato o sovrascritto).
  Future<File> writeText(
    Course c,
    NoteFolder folder,
    String name,
    String text,
  ) async {
    final dir = await courseDir(c, folder);
    final f = File(p.join(dir.path, '${safeName(name)}.md'));
    await f.writeAsString(text);
    return f;
  }

  /// File collegato con lo stesso nome in un'altra cartella (es. la
  /// trascrizione di una registrazione), se esiste.
  Future<File?> companion(Course c, NoteFile of, NoteFolder folder) async {
    final f = File(
      p.join(
        (await root()).path,
        folderName(c),
        folder.dirName,
        '${of.name}.md',
      ),
    );
    return await f.exists() ? f : null;
  }

  /// Suffisso della trascrizione fatta con Gemini: accanto a quella di
  /// Whisper (o dal vivo) `Trascrizioni/<lezione>.md` c'è
  /// `Trascrizioni/<lezione> (Gemini).md`.
  static const geminiSuffix = ' (Gemini)';

  /// Cartelle della stessa lezione: registrazione, trascrizione e riassunto
  /// hanno lo stesso nome e si rinominano insieme.
  static const lessonFolders = {
    NoteFolder.recordings,
    NoteFolder.transcripts,
    NoteFolder.summaries,
  };

  /// Rinomina [f] in [newName] (senza estensione). Per una lezione rinomina
  /// anche trascrizione, riassunto e PDF esportati con lo stesso nome.
  /// Restituisce i percorsi rinominati (vecchio → nuovo).
  Future<Map<String, String>> rename(
    Course c,
    NoteFile f,
    String newName,
  ) async {
    final name = safeName(newName);
    if (name == f.name) return const {};
    final base = p.join((await root()).path, folderName(c));
    final folders = lessonFolders.contains(f.folder)
        ? lessonFolders
        : {f.folder};
    final moves = <File, String>{};
    for (final folder in folders) {
      final dir = Directory(p.join(base, folder.dirName));
      if (!await dir.exists()) continue;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final b = p.basenameWithoutExtension(e.path);
        // Anche un file con il nuovo nome in un'altra cartella della lezione
        // (es. un riassunto) finirebbe collegato a questa: si blocca.
        if (b.toLowerCase() == name.toLowerCase() &&
            b.toLowerCase() != f.name.toLowerCase()) {
          throw FileSystemException(
            'Esiste già un file chiamato "$name"',
            e.path,
          );
        }
        if (b == f.name) {
          moves[e] = p.join(dir.path, '$name${p.extension(e.path)}');
        } else if (folder == NoteFolder.transcripts &&
            b == '${f.name}$geminiSuffix') {
          // trascrizione di Gemini della stessa lezione
          moves[e] = p.join(
            dir.path,
            '$name$geminiSuffix${p.extension(e.path)}',
          );
        }
      }
    }
    final done = <String, String>{};
    for (final m in moves.entries) {
      await m.key.rename(m.value);
      done[m.key.path] = m.value;
    }
    return done;
  }

  Future<void> delete(NoteFile f) async {
    if (await f.file.exists()) await f.file.delete();
  }
}
