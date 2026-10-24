import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/course.dart';
import '../../repositories/settings_repository.dart';
import 'safe_files.dart';

/// Sottocartelle degli appunti di un corso.
enum NoteFolder {
  recordings('Registrazioni', 'Registrazioni delle lezioni'),
  transcripts('Trascrizioni', 'Trascrizioni'),
  summaries('Riassunti', 'Riassunti lezioni e Appunti'),
  notes('Appunti', 'Note'),
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

  Future<Directory> root() async => (await rootWithFallback()).$1;

  /// Radice degli appunti e se è quella predefinita usata al posto della
  /// cartella scelta dall'utente (unità scollegata o che non risponde,
  /// cartella non scrivibile). La sincronizzazione non usa quella di
  /// ripiego: i file della cartella scelta, che lì non ci sono, sembrerebbero
  /// eliminati e si toglierebbero dal servizio e dagli altri dispositivi.
  Future<(Directory, bool)> rootWithFallback() async {
    final override = _rootOverride;
    Directory dir;
    var fellBack = false;
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
      final fallback = await old.exists()
          ? old
          : Directory(p.join(docs, 'UniNotes', 'Corsi'));
      dir = fallback;
      if (base.isNotEmpty && await _reachable(p.rootPrefix(base))) {
        dir = Directory(p.join(base, 'Corsi'));
      }
      try {
        await dir.create(recursive: true);
      } on FileSystemException {
        // cartella scelta non utilizzabile (sola lettura, nome occupato da
        // un file, unità che non risponde): si torna a quella predefinita
        // invece di rendere inutilizzabili tutte le schermate degli appunti
        if (dir.path == fallback.path) rethrow;
        dir = fallback;
      }
      fellBack = base.isNotEmpty && !p.equals(dir.path, p.join(base, 'Corsi'));
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
    return (dir, fellBack);
  }

  /// L'unità (o la cartella di rete) [prefix] risponde. Una condivisione di
  /// rete spenta fa aspettare Windows decine di secondi per ogni controllo, e
  /// la radice si chiede a ogni lettura degli appunti: dopo [_reachTimeout]
  /// si considera non raggiungibile (si usa la cartella predefinita).
  static const _reachTimeout = Duration(seconds: 4);
  static Future<bool> _reachable(String prefix) => Directory(prefix)
      .exists()
      .timeout(_reachTimeout, onTimeout: () => false)
      .catchError((Object _) => false);

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

  /// Nome valido come cartella o file su ogni sistema: niente caratteri
  /// vietati su Windows, punti e spazi finali, punti iniziali (il file
  /// sparirebbe dagli elenchi, che saltano i nascosti, e «.eliminati» è il
  /// cestino), al massimo 90 caratteri (senza spezzare un'emoji) e, su
  /// Windows, mai un nome riservato (CON, aux.txt, COM1…) che il sistema
  /// non lascia creare. Con [windows] si sceglie il sistema (test).
  static String safeName(String s, {bool? windows}) {
    var v = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
    v = v.replaceFirst(RegExp(r'^[. ]+'), '');
    v = cutText(v, 90).replaceAll(RegExp(r'[. ]+$'), '');
    if (v.isEmpty) return 'Senza nome';
    if ((windows ?? Platform.isWindows) && isWindowsReservedName(v)) {
      final dot = v.indexOf('.');
      final stem = (dot < 0 ? v : v.substring(0, dot)).trimRight();
      v = '${stem}_${dot < 0 ? '' : v.substring(dot)}';
    }
    return v;
  }

  /// Windows: i percorsi oltre 260 caratteri (MAX_PATH) non li reggono tutti
  /// i componenti (lettore audio, condivisione, programmi esterni): [name]
  /// si accorcia perché `<dirPath>/<name>` più [reserve] caratteri (estensione
  /// e suffissi) resti sotto i 240. Altrove non cambia nulla.
  static String fitToPath(
    String name,
    String dirPath, {
    int reserve = 16,
    bool? windows,
  }) {
    if (!(windows ?? Platform.isWindows)) return name;
    final room = 240 - dirPath.length - 1 - reserve;
    if (name.length <= room) return name;
    final v = cutText(name, room < 20 ? 20 : room)
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    return v.isEmpty ? 'Senza nome' : v;
  }

  /// La cartella delle risposte dell'AI si chiamava «Claude»: si rinomina in
  /// «AI» la prima volta che serve. Se «AI» esiste già (la sincronizzazione
  /// ha riportato «Claude» da un dispositivo con l'app vecchia, o una copia
  /// di appunti di prima) i file si portano dentro «AI» senza sovrascrivere
  /// nulla, e «Claude» si toglie quando resta vuota: i file lì non si
  /// vedrebbero in nessuna schermata.
  static Future<void> _migrateLegacy(String courseRoot) async {
    final old = Directory(p.join(courseRoot, 'Claude'));
    final now = Directory(p.join(courseRoot, NoteFolder.ai.dirName));
    try {
      if (!await old.exists()) return;
      if (!await now.exists()) {
        await old.rename(now.path);
        return;
      }
      await for (final e in old.list(followLinks: false)) {
        final name = p.basename(e.path);
        final target = p.join(now.path, name);
        if (e is File) {
          // un file con lo stesso nome già in «AI» non si sovrascrive
          final base = p.basenameWithoutExtension(name);
          final ext = p.extension(name);
          var dest = target;
          for (var i = 2; File(dest).existsSync(); i++) {
            dest = p.join(now.path, '$base ($i)$ext');
          }
          await e.rename(dest);
        } else if (e is Directory &&
            await FileSystemEntity.type(target) ==
                FileSystemEntityType.notFound) {
          await e.rename(target);
        }
      }
      if (await old.list(followLinks: false).isEmpty) await old.delete();
    } on FileSystemException {
      // cartella in uso (es. OneDrive): si riprova al prossimo accesso
    }
  }

  /// Il corso ha cambiato nome (modifica, versione in inglese, nome nuovo
  /// nel catalogo): registrazioni e appunti seguono il nome nuovo. Se esiste
  /// già una cartella col nome nuovo i file si uniscono (senza sovrascrivere).
  ///
  /// Non lancia errori: il nome nel database è già cambiato (chi chiama sta
  /// importando il catalogo o ha salvato il corso) e una cartella degli
  /// appunti non raggiungibile (unità scollegata, sincronizzazione in corso,
  /// permessi) non deve far fallire o ripetere tutto il resto.
  Future<void> renameCourse(Course from, Course to) async {
    try {
      final base = (await root()).path;
      await _adoptOldFolder(base, from);
      final src = Directory(p.join(base, folderName(from)));
      final dst = Directory(p.join(base, folderName(to)));
      if (src.path == dst.path || !await src.exists()) return;
      if (!await dst.exists()) {
        await src.rename(dst.path);
        return;
      }
      // (senza seguire i collegamenti: un collegamento a una cartella che
      // contiene la cartella stessa farebbe ripetere l'elenco all'infinito,
      // e i file fuori dalla cartella del corso non si spostano)
      await for (final e in src.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        final rel = p.relative(e.path, from: src.path);
        final target = File(p.join(dst.path, rel));
        if (await target.exists()) continue;
        await target.parent.create(recursive: true);
        await e.rename(target.path);
      }
      // la vecchia cartella si toglie solo se non ha più file né
      // collegamenti (restano le cartelle vuote)
      if (await src
          .list(recursive: true, followLinks: false)
          .where((e) => e is! Directory)
          .isEmpty) {
        await src.delete(recursive: true);
      }
    } on Exception {
      // cartella in uso (es. sincronizzazione) o dei documenti non
      // disponibile: resta com'è
    }
  }

  /// Nome della cartella di [c] come lo calcolava [safeName] fino al terzo
  /// giro della caccia ai crash (ottobre 2026): punto iniziale tenuto, punti
  /// finali tolti prima del taglio a 90 caratteri e non dopo.
  static String _oldFolderName(Course c) {
    final uni = switch (c.universityId) {
      'polito' => 'PoliTo',
      'unito' => 'UniTO',
      _ => null,
    };
    var v = [?uni, c.name]
        .join(' - ')
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
        .trim();
    v = v.replaceAll(RegExp(r'[. ]+$'), '');
    if (v.length > 90) v = v.substring(0, 90).trim();
    return v.isEmpty ? 'Senza nome' : v;
  }

  /// La cartella di [c] con il nome di prima ([_oldFolderName]: per esempio
  /// «… Private C.» di un insegnamento del database dei corsi, o «.NET …»)
  /// prende il nome di adesso, se quella nuova non c'è ancora: senza,
  /// registrazioni e appunti sparivano dall'app con l'aggiornamento (su
  /// Windows i due nomi sono già la stessa cartella).
  static Future<void> _adoptOldFolder(String base, Course c) async {
    final now = folderName(c);
    final old = _oldFolderName(c);
    if (old == now) return;
    try {
      final from = Directory(p.join(base, old));
      final to = Directory(p.join(base, now));
      if (!await from.exists() || await to.exists()) return;
      await from.rename(to.path);
    } on FileSystemException {
      // cartella in uso: si riprova al prossimo accesso
    }
  }

  Future<Directory> courseDir(Course c, [NoteFolder? folder]) async {
    // la radice una volta sola (ogni lettura la crea se manca: un accesso
    // al disco in più per volta)
    final base = (await root()).path;
    await _adoptOldFolder(base, c);
    await _migrateLegacy(p.join(base, folderName(c)));
    final dir = Directory(
      p.joinAll([base, folderName(c), if (folder != null) folder.dirName]),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// File del corso per cartella, dal più recente.
  Future<Map<NoteFolder, List<NoteFile>>> list(Course c) async {
    final out = <NoteFolder, List<NoteFile>>{};
    final base = (await root()).path;
    await _adoptOldFolder(base, c);
    await _migrateLegacy(p.join(base, folderName(c)));
    for (final f in NoteFolder.values) {
      final dir = Directory(p.join(base, folderName(c), f.dirName));
      final items = <NoteFile>[];
      if (await dir.exists()) {
        try {
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
            final FileStat st;
            try {
              st = await e.stat();
            } on FileSystemException {
              continue; // file bloccato o tolto durante l'elenco
            }
            // un file tolto durante l'elenco non dà errore: tipo «non trovato»
            if (st.type != FileSystemEntityType.file) continue;
            items.add(NoteFile(e, f, st.modified, st.size));
          }
        } on FileSystemException {
          // cartella sparita o senza permesso durante la lettura (disco
          // scollegato, sincronizzazione che la sposta): si mostrano i file
          // già letti invece di rompere la schermata
        }
      }
      items.sort((a, b) => b.name.compareTo(a.name));
      out[f] = items;
    }
    return out;
  }

  /// Numero di file per corso (per l'elenco dei corsi).
  ///
  /// Solo i nomi, senza leggere data e dimensione di ogni file: l'elenco dei
  /// corsi lo chiede per ognuno, e con registrazioni a centinaia la lettura
  /// dei dettagli rendeva lenta la schermata. Stessi file che mostra [list].
  Future<int> count(Course c) async {
    final base = (await root()).path;
    await _adoptOldFolder(base, c);
    await _migrateLegacy(p.join(base, folderName(c)));
    var n = 0;
    for (final f in NoteFolder.values) {
      final dir = Directory(p.join(base, folderName(c), f.dirName));
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final name = p.basename(e.path);
          if (name.startsWith('.') || name.endsWith('.part')) continue;
          if (f == NoteFolder.recordings &&
              p.extension(name).toLowerCase() == '.json') {
            continue;
          }
          n++;
        }
      } on FileSystemException {
        // cartella sparita o illeggibile: si contano i file già letti
      }
    }
    return n;
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
    // scrittura sicura: disco pieno o interruzione non lasciano il file
    // vuoto o a metà
    await writeStringAtomic(f, text);
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
    final base = p.join((await root()).path, folderName(c));
    // (la cartella più lunga della lezione: «Registrazioni»; il resto è
    // l'estensione, « (Gemini)» e il file temporaneo)
    final name = fitToPath(
      safeName(newName),
      p.join(base, NoteFolder.recordings.dirName),
      reserve: 20,
    );
    if (name == f.name) return const {};
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
    // nessun file di arrivo già presente (es. «<nuovo> (Gemini).md»
    // rimasto da prima): la rinomina lo sostituirebbe senza dirlo
    for (final m in moves.entries) {
      // (cambio solo di maiuscole: è lo stesso file sui dischi che non le
      // distinguono)
      if (m.key.path.toLowerCase() != m.value.toLowerCase() &&
          await File(m.value).exists()) {
        throw FileSystemException(
          'Esiste già un file chiamato "${p.basename(m.value)}"',
          m.value,
        );
      }
    }
    final done = <String, String>{};
    try {
      for (final m in moves.entries) {
        await m.key.rename(m.value);
        done[m.key.path] = m.value;
      }
    } catch (_) {
      // un file in uso (lettore, Whisper): si rimettono i nomi di prima,
      // la lezione non resta rinominata a metà
      for (final d in done.entries.toList().reversed) {
        try {
          await File(d.value).rename(d.key);
        } catch (_) {}
      }
      rethrow;
    }
    return done;
  }

  Future<void> delete(NoteFile f) async {
    if (await f.file.exists()) await f.file.delete();
  }
}
