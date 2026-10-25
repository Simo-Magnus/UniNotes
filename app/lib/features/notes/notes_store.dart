import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/course.dart';
import '../../repositories/settings_repository.dart';
import 'recycle_bin.dart' show RecycleBin, moveFile;
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

  /// Nome del file senza estensione (identifica la lezione: registrazione,
  /// trascrizione e riassunto hanno lo stesso).
  String get name => p.basenameWithoutExtension(file.path);

  /// Nome come lo vede l'utente: orario con «:» (vedi
  /// [NotesStore.displayName]).
  String get title => NotesStore.displayName(name);
  String get extension => p.extension(file.path).toLowerCase();
  bool get isAudio => NotesStore.audioExtensions.contains(extension);
}

/// Appunti dei corsi come file normali, una cartella per corso:
///
///     <radice>/PoliTo - Analisi matematica I/Registrazioni/2026-10-05 08꞉30.flac
///     <radice>/PoliTo - Analisi matematica I/Trascrizioni/2026-10-05 08꞉30.md
///     <radice>/PoliTo - Analisi matematica I/Riassunti/2026-10-05 08꞉30.md
///
/// L'orario del nome ha «꞉» (U+A789, simile ai due punti ma ammesso nei nomi
/// dei file di Windows): le schermate mostrano «08:30» ([NotesStore.displayName]).
/// Le registrazioni di prima, «2026-10-05 08-30 Lezione», restano com'erano
/// e si mostrano anch'esse con «08:30».
///
/// Trascrizione e riassunto hanno lo stesso nome della registrazione (la
/// trascrizione di Gemini ha in più « (Gemini)», vedi [NotesStore.geminiSuffix]); i
/// dati della registrazione (segnalibri, testo con i tempi, forma d'onda)
/// sono in `Registrazioni/<nome>.json` (recorder/recording_meta.dart).
/// Radice: sul PC `<cartella Appunti>/Corsi` (predefinita Documenti\UniNotes),
/// altrove la cartella documenti dell'app.
class NotesStore {
  NotesStore(
    this._settings, {
    Future<Directory> Function()? root,
    this.onFilesMoved,
  }) : _rootOverride = root;

  final SettingsRepository _settings;
  final Future<Directory> Function()? _rootOverride;

  /// File portati dalla cartella di ripiego a quella scelta (vecchio
  /// percorso → nuovo): AppServices aggiorna gli allegati di Studio.
  Future<void> Function(Map<String, String> moved)? onFilesMoved;

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
      final fallback = await _defaultWindowsRoot();
      dir = fallback;
      final prefix = p.rootPrefix(base);
      if (base.isNotEmpty && await _reachable(prefix)) {
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
        // (unità sparita dopo l'ultimo controllo riuscito: non si ricorda
        // più come raggiungibile)
        _reach[prefix] = (false, clock());
      }
      final chosen = p.join(base, 'Corsi');
      fellBack = base.isNotEmpty && !p.equals(dir.path, chosen);
      if (fellBack) {
        await _markFallback();
      } else if (base.isNotEmpty && !p.equals(fallback.path, chosen)) {
        await _moveFallbackLater(fallback, dir);
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
    return (dir, fellBack);
  }

  /// Cartella predefinita degli appunti su Windows (quella di ripiego).
  static Future<Directory> _defaultWindowsRoot() async {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final old = Directory(p.join(docs, 'University Notes', 'Corsi'));
    return await old.exists()
        ? old
        : Directory(p.join(docs, 'UniNotes', 'Corsi'));
  }

  /// Radici per i percorsi degli allegati sincronizzati: la cartella scelta
  /// anche quando ora non è raggiungibile (i percorsi si traducono, il disco
  /// non si tocca) e, se diversa, quella di ripiego, i cui file prendono lo
  /// stesso posto nella cartella scelta quando torna. Senza una cartella
  /// scelta: la radice di sempre, e nessuna di ripiego.
  Future<(String, String?)> syncRoots() async {
    if (_rootOverride == null && Platform.isWindows) {
      final base = (await _settings.appuntiRoot()).trim();
      if (base.isNotEmpty) {
        final chosen = p.join(base, 'Corsi');
        final fallback = (await _defaultWindowsRoot()).path;
        return (chosen, p.equals(chosen, fallback) ? null : fallback);
      }
    }
    return ((await root()).path, null);
  }

  /// L'unità (o la cartella di rete) [prefix] risponde. Una condivisione di
  /// rete spenta fa aspettare Windows decine di secondi per ogni controllo, e
  /// la radice si chiede a ogni lettura degli appunti: dopo [_reachTimeout]
  /// si considera non raggiungibile (si usa la cartella predefinita). Un
  /// disco USB o di rete che si sveglia ci mette diversi secondi: il primo
  /// controllo aspetta fino a 15 secondi (prima 4: si finiva nella cartella
  /// di ripiego, vuota, e le registrazioni nuove si salvavano lì). L'esito
  /// si ricorda: raggiungibile per [_rememberReachable] senza ricontrollare;
  /// non raggiungibile si risponde subito e si ricontrolla dietro le quinte
  /// al massimo ogni [_recheckUnreachable] (nessuna attesa a ogni lettura).
  static const _reachTimeout = Duration(seconds: 15);
  static const _rememberReachable = Duration(minutes: 2);
  static const _recheckUnreachable = Duration(seconds: 20);
  static final _reach = <String, (bool, DateTime)>{};
  static final _checking = <String, Future<bool>>{};

  /// Controllo dell'unità (sostituibile nei test).
  @visibleForTesting
  static Future<bool> Function(String prefix) probe = _probeDefault;
  static Future<bool> _probeDefault(String prefix) =>
      Directory(prefix).exists();

  /// Orologio dei controlli (sostituibile nei test).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  /// Dimentica gli esiti dei controlli delle unità (test).
  @visibleForTesting
  static void forgetReachability() => _reach.clear();

  static Future<bool> _reachable(String prefix) {
    final known = _reach[prefix];
    if (known != null) {
      final (ok, at) = known;
      final age = clock().difference(at);
      if (ok && !age.isNegative && age < _rememberReachable) {
        return Future.value(true);
      }
      if (!ok) {
        if (age.isNegative || age >= _recheckUnreachable) {
          unawaited(_check(prefix));
        }
        return Future.value(false);
      }
    }
    return _check(prefix);
  }

  /// Un controllo alla volta per unità.
  static Future<bool> _check(String prefix) => _checking[prefix] ??= () async {
    var ok = false;
    try {
      ok = await probe(prefix).timeout(_reachTimeout, onTimeout: () => false);
    } catch (_) {
      ok = false;
    }
    _reach[prefix] = (ok, clock());
    // toglie dalla mappa questo stesso controllo (niente da attendere)
    // ignore: unawaited_futures
    _checking.remove(prefix);
    return ok;
  }();

  // ----------------------------------- file salvati nella cartella di ripiego

  /// Momento dal quale si usa la cartella di ripiego al posto di quella
  /// scelta (ISO 8601): i file salvati da allora si portano in quella scelta
  /// quando torna raggiungibile.
  static const fallbackSinceKey = 'notes_fallback_since';
  DateTime? _fallbackSince;
  bool _fallbackLoaded = false;
  Future<int>? _moving;

  /// Spostamento dalla cartella di ripiego in corso (null = nessuno).
  Future<int>? get fallbackMove => _moving;

  Future<DateTime?> _loadFallbackSince() async {
    if (_fallbackLoaded) return _fallbackSince;
    try {
      _fallbackSince = DateTime.tryParse(
        (await _settings.get(fallbackSinceKey) ?? '').trim(),
      );
      _fallbackLoaded = true;
    } catch (_) {
      // impostazioni non leggibili: si riprova la volta dopo
    }
    return _fallbackSince;
  }

  Future<void> _markFallback() async {
    if (await _loadFallbackSince() != null) return;
    final now = clock();
    try {
      await _settings.set(fallbackSinceKey, now.toIso8601String());
      _fallbackSince = now;
      _fallbackLoaded = true;
    } catch (_) {}
  }

  /// La cartella scelta è tornata: i file salvati nel frattempo nella
  /// cartella di ripiego [from] si portano in [to], dietro le quinte (una
  /// registrazione lunga su un altro disco richiede tempo).
  Future<void> _moveFallbackLater(Directory from, Directory to) async {
    if (_moving != null) return;
    final since = await _loadFallbackSince();
    if (since == null || _moving != null) return;
    final run = _moveFromFallback(from, to, since);
    _moving = run;
    unawaited(
      run.then((_) {}, onError: (_) {}).whenComplete(() => _moving = null),
    );
  }

  /// Sposta in [to] i file di [from] modificati da [since] in poi (stesso
  /// percorso relativo; un nome già presente prende « (2)», mai una
  /// sovrascrittura) e gli elementi del cestino eliminati da allora. File in
  /// uso o non spostabili restano dove sono (il momento resta e si riprova
  /// al prossimo accesso). Restituisce quanti file sono stati spostati.
  Future<int> _moveFromFallback(
    Directory from,
    Directory to,
    DateTime since,
  ) async {
    final cutoff = since.subtract(const Duration(seconds: 5));
    final moved = <String, String>{};
    var left = false;
    try {
      final files = <File>[];
      if (await from.exists()) {
        await for (final e in from.list(recursive: true, followLinks: false)) {
          if (e is File) files.add(e);
        }
      }
      for (final f in files) {
        final rel = p.relative(f.path, from: from.path);
        final parts = p.split(rel);
        if (parts.isEmpty || p.basename(rel).endsWith('.part')) continue;
        bool wanted;
        if (parts.first == RecycleBin.dirName) {
          // elemento del cestino: conta la data dell'eliminazione (il nome
          // della sua cartella), non quella del file
          final ms = parts.length < 3
              ? null
              : int.tryParse(parts[1].split('-').first);
          wanted = ms != null && ms >= cutoff.millisecondsSinceEpoch;
        } else if (parts.any((x) => x.startsWith('.'))) {
          // altri nascosti (cestini della sincronizzazione): restano
          continue;
        } else {
          try {
            wanted = !(await f.stat()).modified.isBefore(cutoff);
          } on FileSystemException {
            left = true;
            continue;
          }
        }
        if (!wanted) continue;
        var dest = p.join(to.path, rel);
        final stem = p.withoutExtension(dest);
        final ext = p.extension(dest);
        for (var i = 2; await File(dest).exists(); i++) {
          dest = '$stem ($i)$ext';
        }
        try {
          await Directory(p.dirname(dest)).create(recursive: true);
          await moveFile(File(f.path), dest);
          moved[f.path] = dest;
        } catch (_) {
          left = true;
        }
      }
    } catch (_) {
      left = true;
    }
    if (moved.isNotEmpty) {
      try {
        await onFilesMoved?.call(moved);
      } catch (_) {}
    }
    if (!left) {
      try {
        await _settings.set(fallbackSinceKey, null);
        _fallbackSince = null;
      } catch (_) {}
    }
    return moved.length;
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
    final v = cutText(
      name,
      room < 20 ? 20 : room,
    ).trim().replaceAll(RegExp(r'[. ]+$'), '');
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
  /// già una cartella col nome nuovo i file si uniscono (senza sovrascrivere:
  /// un nome già presente prende « (2)»).
  ///
  /// Non lancia errori: il nome nel database è già cambiato (chi chiama sta
  /// importando il catalogo o ha salvato il corso) e una cartella degli
  /// appunti non raggiungibile (unità scollegata, sincronizzazione in corso,
  /// permessi) non deve far fallire o ripetere tutto il resto. Se la
  /// cartella non si lascia rinominare (in uso) la rinomina resta in sospeso
  /// ([pendingRenamesKey]): l'app continua a usare la cartella col nome di
  /// prima e riprova a ogni accesso. Restituisce false in quel caso (chi
  /// chiama lo dice con [renamePendingNote]).
  Future<bool> renameCourse(Course from, Course to) async {
    final toName = folderName(to);
    final fromName = folderName(from);
    if (fromName == toName) return true;
    try {
      final pending = await _pendingRenames();
      // la cartella può avere ancora un nome più vecchio (rinomina di prima
      // non ancora riuscita)
      final srcName = pending.remove(fromName) ?? fromName;
      final (dir, fellBack) = await rootWithFallback();
      final base = dir.path;
      if (srcName == fromName) await _adoptOldFolder(base, from);
      if (srcName == toName) {
        // tornato al nome che la cartella ha ancora
        await _savePending();
        return true;
      }
      pending[toName] = srcName;
      await _savePending();
      if (!await Directory(p.join(base, srcName)).exists()) {
        // niente da rinominare qui; con la cartella di ripiego la cartella
        // vera è sull'unità scelta: la rinomina resta in sospeso finché
        // torna
        if (!fellBack) {
          pending.remove(toName);
          await _savePending();
        }
        return true;
      }
      if (await _moveFolder(base, srcName, toName)) {
        pending.remove(toName);
        await _savePending();
        return true;
      }
      return false;
    } on Exception {
      // impostazioni o cartella dei documenti non disponibili: resta com'è
      return false;
    }
  }

  /// Messaggio quando la cartella di un insegnamento non si è lasciata
  /// rinominare ([renameCourse] ha restituito false).
  static const renamePendingNote =
      'La cartella degli appunti è in uso (un altro programma o la '
      'sincronizzazione la tiene aperta): registrazioni e appunti restano '
      'nella cartella col nome di prima, che l\'app continua a usare, e '
      'prendono il nome nuovo appena la cartella si libera.';

  /// Rinomine delle cartelle degli insegnamenti non ancora riuscite: nome
  /// nuovo della cartella → nome che ha ancora sul disco (JSON).
  static const pendingRenamesKey = 'notes_pending_course_renames';
  Map<String, String>? _pending;

  Future<Map<String, String>> _pendingRenames() async {
    final cached = _pending;
    if (cached != null) return cached;
    final out = <String, String>{};
    try {
      final raw = await _settings.get(pendingRenamesKey);
      if (raw != null && raw.trim().isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) {
          for (final e in j.entries) {
            final k = e.key, v = e.value;
            if (k is String && v is String && k.isNotEmpty && v.isNotEmpty) {
              out[k] = v;
            }
          }
        }
      }
    } on Exception {
      // impostazione illeggibile (database chiuso, testo rovinato): nessuna
      // rinomina in sospeso; non si ricorda, si rilegge la volta dopo
      return out;
    }
    return _pending = out;
  }

  Future<void> _savePending() async {
    final m = _pending ?? const {};
    try {
      await _settings.set(pendingRenamesKey, m.isEmpty ? null : jsonEncode(m));
    } on Exception {
      // resta in memoria per questa sessione
    }
  }

  /// La cartella di [c] ha una rinomina in sospeso (cartella in uso).
  bool hasPendingRename(Course c) =>
      _pending?.containsKey(folderName(c)) ?? false;

  /// Porta la cartella [from] di [base] in [to] (rinomina, o unione file per
  /// file se [to] esiste già). true se [from] non c'è più.
  static Future<bool> _moveFolder(String base, String from, String to) async {
    final src = Directory(p.join(base, from));
    final dst = Directory(p.join(base, to));
    try {
      if (!await src.exists()) return true;
      if (!await dst.exists()) {
        await src.rename(dst.path);
        return true;
      }
      // (senza seguire i collegamenti: un collegamento a una cartella che
      // contiene la cartella stessa farebbe ripetere l'elenco all'infinito,
      // e i file fuori dalla cartella del corso non si spostano)
      final files = [
        await for (final e in src.list(recursive: true, followLinks: false))
          if (e is File) e.path,
      ];
      var left = false;
      for (final path in files) {
        final rel = p.relative(path, from: src.path);
        var target = p.join(dst.path, rel);
        final stem = p.withoutExtension(target);
        final ext = p.extension(target);
        for (var i = 2; await File(target).exists(); i++) {
          target = '$stem ($i)$ext';
        }
        try {
          await Directory(p.dirname(target)).create(recursive: true);
          await File(path).rename(target);
        } on FileSystemException {
          left = true; // file in uso: si riprova al prossimo accesso
        }
      }
      if (left) return false;
      // la vecchia cartella si toglie solo se non ha più file né
      // collegamenti (restano le cartelle vuote)
      if (await src
          .list(recursive: true, followLinks: false)
          .where((e) => e is! Directory)
          .isEmpty) {
        await src.delete(recursive: true);
      }
      return !await src.exists();
    } on FileSystemException {
      return false;
    }
  }

  /// Cartelle di [c] in [base]: quella da usare e, durante un'unione non
  /// finita, quella col nome di prima che ha ancora dei file (solo da
  /// leggere). Prima riprova la rinomina in sospeso.
  Future<(String, String?)> _courseFolders(
    String base,
    Course c, {
    bool fellBack = false,
  }) async {
    await _adoptOldFolder(base, c);
    final now = folderName(c);
    final pending = await _pendingRenames();
    final before = pending[now];
    if (before == null) return (now, null);
    if (before == now || await _moveFolder(base, before, now)) {
      // (con la cartella di ripiego quella vera è sull'unità scelta)
      if (!fellBack) {
        pending.remove(now);
        await _savePending();
      }
      return (now, null);
    }
    return await Directory(p.join(base, now)).exists()
        ? (now, before)
        : (before, null);
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
    var v = [
      ?uni,
      c.name,
    ].join(' - ').replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
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

  /// Radice e cartelle di [c] (vedi [_courseFolders]).
  Future<(String, String, String?)> _resolve(Course c) async {
    // la radice una volta sola (ogni lettura la crea se manca: un accesso
    // al disco in più per volta)
    final (dir, fellBack) = await rootWithFallback();
    final base = dir.path;
    final (main, extra) = await _courseFolders(base, c, fellBack: fellBack);
    await _migrateLegacy(p.join(base, main));
    return (base, main, extra);
  }

  Future<Directory> courseDir(Course c, [NoteFolder? folder]) async {
    final (base, name, _) = await _resolve(c);
    final dir = Directory(
      p.joinAll([base, name, if (folder != null) folder.dirName]),
    );
    await dir.create(recursive: true);
    return dir;
  }

  /// File del corso per cartella, dal più recente (anche quelli rimasti
  /// nella cartella col nome di prima durante un'unione non finita).
  Future<Map<NoteFolder, List<NoteFile>>> list(Course c) async {
    final out = <NoteFolder, List<NoteFile>>{};
    final (base, name, extra) = await _resolve(c);
    for (final f in NoteFolder.values) {
      final items = <NoteFile>[];
      for (final folder in [name, ?extra]) {
        await _listInto(Directory(p.join(base, folder, f.dirName)), f, items);
      }
      items.sort((a, b) => b.name.compareTo(a.name));
      out[f] = items;
    }
    return out;
  }

  static Future<void> _listInto(
    Directory dir,
    NoteFolder f,
    List<NoteFile> items,
  ) async {
    if (!await dir.exists()) return;
    try {
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        if (name.startsWith('.') || name.endsWith('.part')) continue;
        // dati delle registrazioni (segnalibri, testo con i tempi, forma
        // d'onda): si gestiscono insieme all'audio
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
      // scollegato, sincronizzazione che la sposta): si mostrano i file già
      // letti invece di rompere la schermata
    }
  }

  /// Numero di file per corso (per l'elenco dei corsi).
  ///
  /// Solo i nomi, senza leggere data e dimensione di ogni file: l'elenco dei
  /// corsi lo chiede per ognuno, e con registrazioni a centinaia la lettura
  /// dei dettagli rendeva lenta la schermata. Stessi file che mostra [list].
  Future<int> count(Course c) async {
    final (base, name, extra) = await _resolve(c);
    var n = 0;
    for (final (folder, f) in [
      for (final folder in [name, ?extra])
        for (final f in NoteFolder.values) (folder, f),
    ]) {
      final dir = Directory(p.join(base, folder, f.dirName));
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

  /// «꞉» (U+A789, «modifier letter colon»): sembra due punti ma è un
  /// carattere ammesso nei nomi dei file di Windows (e di OneDrive, Android,
  /// macOS, Linux), dove i due punti veri sono vietati. Nei file delle
  /// lezioni sta al posto dei due punti dell'orario; nelle schermate si
  /// mostra sempre «:» (vedi [displayName]).
  static const lookalikeColon = '꞉';

  /// Nome base (sul disco) di una nuova lezione: «2026-10-05 08꞉30», che
  /// l'utente vede come «2026-10-05 08:30». Senza la parola «Lezione».
  static String lessonBaseName(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}$lookalikeColon${two(t.minute)}';
  }

  /// Data e ora all'inizio di un nome: il «-» fra ore e minuti è quello delle
  /// registrazioni fatte prima che l'orario avesse i due punti.
  static final RegExp _legacyTime = RegExp(
    r'^(\d{4}-\d{2}-\d{2} \d{2})-(\d{2})(?=$| )',
  );

  /// Nome di un file degli appunti come lo vede l'utente: con i due punti
  /// veri nell'orario («2026-10-05 08:30»), sia per i nomi nuovi (con «꞉»)
  /// sia per le registrazioni di prima («2026-10-05 08-30 Lezione»). Il nome
  /// sul disco non cambia: serve solo per titoli, elenchi e messaggi.
  static String displayName(String stem) {
    final s = stem.replaceAll(lookalikeColon, ':');
    return s.replaceFirstMapped(_legacyTime, (m) => '${m[1]}:${m[2]}');
  }

  /// Nome da usare sul disco per un titolo scritto dall'utente: i due punti
  /// veri (vietati nei nomi dei file di Windows) diventano «꞉», poi come
  /// [safeName]. Inverso di [displayName] per i nomi nuovi.
  static String fileStem(String title) =>
      safeName(title.replaceAll(':', lookalikeColon));

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
    final f = File(p.join(dir.path, '${fileStem(name)}.md'));
    // scrittura sicura: disco pieno o interruzione non lasciano il file
    // vuoto o a metà
    await writeStringAtomic(f, text);
    return f;
  }

  /// File collegato con lo stesso nome in un'altra cartella (es. la
  /// trascrizione di una registrazione), se esiste.
  Future<File?> companion(Course c, NoteFile of, NoteFolder folder) async {
    // accanto al file stesso (anche nella cartella col nome di prima di
    // un'unione non finita), altrimenti nella cartella del corso
    final (base, name, _) = await _resolve(c);
    for (final dir in {
      p.join(p.dirname(p.dirname(of.file.path)), folder.dirName),
      p.join(base, name, folder.dirName),
    }) {
      final f = File(p.join(dir, '${of.name}.md'));
      if (await f.exists()) return f;
    }
    return null;
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
    final (rootPath, folderNow, _) = await _resolve(c);
    var base = p.join(rootPath, folderNow);
    // file rimasto nella cartella col nome di prima (unione non finita):
    // si rinomina lì
    if (!p.isWithin(base, f.file.path)) {
      base = p.dirname(p.dirname(f.file.path));
    }
    // (la cartella più lunga della lezione: «Registrazioni»; il resto è
    // l'estensione, « (Gemini)» e il file temporaneo)
    final name = fitToPath(
      fileStem(newName),
      p.join(base, NoteFolder.recordings.dirName),
      reserve: 20,
    );
    // stesso nome per l'utente (es. «08:30» scritto al posto del «08-30» di
    // una registrazione di prima): il file non si tocca
    if (name == f.name || displayName(name) == f.title) return const {};
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
