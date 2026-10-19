import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../repositories/settings_repository.dart';
import 'catalog_models.dart';

/// Indirizzo predefinito del database pubblico (cartella `database/` del
/// repository su GitHub, file "raw").
const String kDefaultCatalogBaseUrl =
    'https://raw.githubusercontent.com/Simo-Magnus/UniNotes/main/database';

/// Cartella degli asset con la parte del database inclusa nell'app (solo i
/// file comuni: atenei, indice dei corsi, meta, corsi sostituiti).
const String kCatalogAssetDir = 'assets/database';

/// Messaggio per lo studente quando i dati del corso non sono sul
/// dispositivo e non si possono scaricare.
const String kServeConnessione =
    'Serve una connessione per scaricare i dati del tuo corso.';

/// Avanzamento di un download: byte ricevuti e attesi (null se il server
/// non lo dice, per esempio con la compressione gzip in trasferimento).
typedef CatalogByteProgress = void Function(int ricevuti, int? attesi);

/// Scarica il testo di un URL. Iniettabile nei test.
typedef CatalogFetcher = Future<String> Function(
  Uri uri, {
  CatalogByteProgress? onProgress,
});

/// Scarica un URL direttamente nel file [dest], senza tenerlo tutto in
/// memoria, e restituisce i byte ricevuti. Iniettabile nei test.
typedef CatalogFileFetcher = Future<int> Function(
  Uri uri,
  File dest, {
  CatalogByteProgress? onProgress,
});

/// Legge un asset come testo (default: rootBundle). Iniettabile nei test.
typedef CatalogAssetLoader = Future<String> Function(String path);

/// Legge un asset come byte (per i file compressi `.json.gz`).
typedef CatalogAssetBytesLoader = Future<Uint8List> Function(String path);

Future<Uint8List> _rootBundleBytes(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

/// Da dove è arrivato un file del catalogo.
enum CatalogSource {
  remote('aggiornato da internet'),
  cache('copia salvata sul dispositivo'),
  bundled('copia inclusa nell\'app');

  const CatalogSource(this.label);
  final String label;
}

class CatalogResult<T> {
  const CatalogResult(this.data, this.source, {this.error});
  final T data;
  final CatalogSource source;

  /// Errore della rete se si è ripiegato su cache o asset.
  final Object? error;

  bool get offline => source != CatalogSource.remote;
}

class CatalogException implements Exception {
  CatalogException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Il file non c'è nel database (risposta 404): non è un problema di rete,
/// per esempio un ateneo senza calendario delle sessioni o un corso non
/// ancora nel database.
class CatalogNotFoundException extends CatalogException {
  CatalogNotFoundException([
    super.message = 'File non ancora presente nel database (404).',
  ]);
}

/// Nessuna connessione a internet (o tempo scaduto).
class CatalogOfflineException extends CatalogException {
  CatalogOfflineException([super.message = 'Nessuna connessione a internet.']);
}

/// Percorsi (relativi alla cartella `database/`) dei file di un corso.
abstract final class CatalogPaths {
  /// Dati del corso di laurea: tutti gli anni, i percorsi, libri, appelli e
  /// i moduli di studio dei suoi insegnamenti.
  static String corso(String ateneoId, String corsoId) =>
      'per_corso/$ateneoId/$corsoId.json';

  /// Impronte (sha256) e dimensioni dei file dei corsi dell'ateneo.
  static String indice(String ateneoId) => 'per_corso/$ateneoId/indice.json';

  /// Calendari delle sessioni d'esame dell'ateneo (pochi KB).
  static String sessioni(String ateneoId) => 'sessioni/$ateneoId.json';
}

/// Avanzamento del download dei dati del corso (per la barra
/// nell'onboarding e in Impostazioni → Il mio percorso).
class CatalogProgress {
  const CatalogProgress({
    required this.ateneoId,
    required this.etichetta,
    this.indice = 1,
    this.totale = 1,
    this.ricevuti = 0,
    this.attesi,
    this.ricevutiPrima = 0,
  });
  final String ateneoId;

  /// Cosa si sta scaricando ("corso di laurea", …).
  final String etichetta;

  /// File in corso (1..[totale]).
  final int indice;
  final int totale;

  /// Byte ricevuti del file in corso e attesi (null se non noti).
  final int ricevuti;
  final int? attesi;

  /// Byte dei file già scaricati in questo download.
  final int ricevutiPrima;

  int get ricevutiTotali => ricevutiPrima + ricevuti;

  /// 0..1 se la dimensione del file è nota, altrimenti null (barra
  /// indeterminata: con gzip in trasferimento il server non la dice).
  double? get frazione {
    final a = attesi;
    if (a == null || a <= 0) return null;
    final f = ((indice - 1) + (ricevuti / a).clamp(0.0, 1.0)) / totale;
    return f.isFinite ? f.clamp(0.0, 1.0) : null;
  }
}

/// Esito di [CatalogService.scaricaCorso].
class AteneoScaricato {
  const AteneoScaricato({
    required this.ateneoId,
    this.corsoId,
    this.scaricati = 0,
    this.invariati = 0,
    this.byte = 0,
    this.corsi = false,
    this.corsiAggiornati = false,
    this.corsiAssenti = false,
    this.errore,
  });
  final String ateneoId;
  final String? corsoId;

  /// File scaricati ora e file già aggiornati sul dispositivo.
  final int scaricati;
  final int invariati;

  /// Byte scaricati ora (dopo la decompressione).
  final int byte;

  /// Il file del corso è sul dispositivo (scaricato ora o prima).
  final bool corsi;

  /// …ed è quello attuale del database (scaricato ora o verificato).
  final bool corsiAggiornati;

  /// Il database non ha (ancora) il corso o l'ateneo (404).
  final bool corsiAssenti;

  /// Primo errore (di rete o file non valido), se c'è stato.
  final Object? errore;

  /// Nessuna copia del corso e niente rete: serve una connessione.
  bool get senzaRete => !corsi && !corsiAssenti && errore != null;
}

/// Dati del corso salvati sul dispositivo (Impostazioni → Il mio percorso).
class AteneoSulDispositivo {
  const AteneoSulDispositivo({
    required this.ateneoId,
    required this.corsi,
    required this.byte,
    this.versione,
    this.scaricatoIl,
  });
  final String ateneoId;

  /// C'è il file del corso.
  final bool corsi;

  /// Spazio occupato dai file del corso e dell'ateneo nella cache.
  final int byte;

  /// `meta.json.versione` dell'ultimo download completo e sua data.
  final String? versione;
  final DateTime? scaricatoIl;
}

/// Registro dell'ultimo download (`ateneo.json` nella cache): corso,
/// versione del database, impronte del file del corso e dell'indice dei
/// corsi dell'ateneo e file assenti (404), così «Aggiorna database»
/// riscarica solo ciò che è cambiato e i file assenti non si richiedono a
/// ogni lettura.
class _Registro {
  const _Registro({
    required this.ateneoId,
    this.corsoId,
    this.versione,
    this.scaricatoIl,
    this.sha256Corso,
    this.sha256Indice,
    this.assenti = const {},
  });
  final String ateneoId;
  final String? corsoId;
  final String? versione;
  final DateTime? scaricatoIl;
  final String? sha256Corso;
  final String? sha256Indice;
  final Set<String> assenti;

  static _Registro? fromJson(Object? json) {
    if (json is! Map || json['ateneo'] is! String) return null;
    final assenti = json['assenti'];
    return _Registro(
      ateneoId: json['ateneo'] as String,
      corsoId: json['corso'] as String?,
      versione: json['versione'] as String?,
      scaricatoIl: DateTime.tryParse('${json['scaricato_il']}'),
      sha256Corso: json['sha256_corso'] as String?,
      sha256Indice: json['sha256_indice'] as String?,
      assenti: {
        if (assenti is List)
          for (final a in assenti)
            if (a is String) a,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'ateneo': ateneoId,
    'corso': corsoId,
    'versione': versione,
    'scaricato_il': scaricatoIl?.toIso8601String(),
    'sha256_corso': sha256Corso,
    'sha256_indice': sha256Indice,
    'assenti': assenti.toList()..sort(),
  };
}

/// Accesso al database pubblico degli atenei.
///
/// L'app include negli asset solo i file comuni (atenei, indice dei corsi,
/// meta, corsi sostituiti: circa 1 MB) per scegliere ateneo e corso anche
/// offline. Dei dati veri scarica solo quelli del **corso di laurea scelto**
/// ([scaricaCorso]): un file con tutti gli anni, i percorsi, libri, appelli
/// e i moduli di studio dei suoi insegnamenti (`per_corso/<ateneo>/<corso>.json`,
/// da pochi KB a circa 1 MB), più i calendari delle sessioni dell'ateneo. I
/// file si salvano nella cartella di supporto dell'app (`database_cache/`),
/// da cui si leggono anche offline; cambiando corso o ateneo quelli del
/// precedente si eliminano.
///
/// Per sapere se un corso è cambiato basta `per_corso/<ateneo>/indice.json`
/// (impronte sha256 dei file dei corsi), la cui impronta è in `meta.json`.
///
/// I file si scaricano a pezzi in un file temporaneo, si controllano e si
/// sostituiscono con una rinomina, così un download interrotto non lascia
/// mai un file troncato. Download dello stesso file o dello stesso corso
/// chiamati insieme condividono lo stesso Future: non si scrive mai due
/// volte nello stesso file.
class CatalogService {
  CatalogService(
    this._settings, {
    CatalogFetcher? fetcher,
    CatalogFileFetcher? fileFetcher,
    CatalogAssetLoader? assetLoader,
    CatalogAssetBytesLoader? assetBytesLoader,
    Future<Directory> Function()? cacheDir,
    this.timeout = const Duration(seconds: 30),
  }) : _fetcher = fetcher ?? defaultFetcher(timeout: timeout),
       _fileFetcher =
           fileFetcher ??
           (fetcher != null
               ? _fileFetcherDaTesto(fetcher)
               : defaultFileFetcher(timeout: timeout)),
       _assetLoader = assetLoader ?? rootBundle.loadString,
       _assetBytesLoader = assetBytesLoader ?? _rootBundleBytes,
       _cacheDir = cacheDir ?? _defaultCacheDir;

  final SettingsRepository _settings;
  final CatalogFetcher _fetcher;
  final CatalogFileFetcher _fileFetcher;
  final CatalogAssetLoader _assetLoader;
  final CatalogAssetBytesLoader _assetBytesLoader;
  final Future<Directory> Function() _cacheDir;
  final Duration timeout;

  UniversitaCatalog? _universita;
  IndiceCorsi? _indice;
  CorsiSostituiti? _sostituiti;

  /// Download in corso dei dati del corso (null quando non si scarica).
  final ValueNotifier<CatalogProgress?> progresso = ValueNotifier(null);

  /// File già cercati in rete in questa sessione (non si richiedono di
  /// nuovo a ogni lettura se mancano o la rete non c'è).
  final Set<String> _tentati = {};

  /// Download completi recenti (l'import subito dopo un download non
  /// riscarica) e corsi scaricati da poco da soli (onboarding: prima il
  /// corso per la scelta del percorso, poi il resto). Chiave: ateneo/corso.
  final Map<String, (DateTime, AteneoScaricato)> _recenti = {};
  final Map<String, (DateTime, String)> _corsiRecenti = {};

  /// Download in corso per corso ([completo]: anche le sessioni) e per file
  /// (percorso relativo → byte ricevuti e impronta).
  final Map<String, ({Future<AteneoScaricato> f, bool completo})> _inCorso = {};
  final Map<String, Future<(int, String)>> _fileInCorso = {};

  /// Nome del registro dell'ultimo download nella cache.
  static const _registroFile = 'ateneo.json';

  static String _chiave(String ateneoId, String corsoId) =>
      '$ateneoId/$corsoId';

  static Future<Directory> _defaultCacheDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, 'database_cache'));
  }

  // ------------------------------------------------------------ indirizzo

  Future<String> baseUrl() async {
    final v = (await _settings.get(SettingKeys.catalogBaseUrl))?.trim();
    if (v == null || v.isEmpty) return kDefaultCatalogBaseUrl;
    // un indirizzo non sicuro (es. arrivato da un backup) non si usa
    final uri = Uri.tryParse(v);
    return (uri != null && _secure(uri)) ? v : kDefaultCatalogBaseUrl;
  }

  static bool _secure(Uri uri) =>
      uri.host.isNotEmpty &&
      (uri.isScheme('https') ||
          (uri.isScheme('http') &&
              (uri.host == 'localhost' || uri.host == '127.0.0.1')));

  /// Salva l'indirizzo (vuoto = predefinito). Lancia se non è http(s).
  Future<void> setBaseUrl(String? url) async {
    final v = url?.trim() ?? '';
    if (v.isNotEmpty) {
      final uri = Uri.tryParse(v);
      if (uri == null || !_secure(uri)) {
        throw CatalogException('Indirizzo non valido: usa un URL https://…');
      }
    }
    await _settings.set(
      SettingKeys.catalogBaseUrl,
      v.isEmpty ? null : v.replaceAll(RegExp(r'/+$'), ''),
    );
  }

  Future<Uri> _url(String relative) async =>
      Uri.parse('${await baseUrl()}/$relative');

  /// L'errore viene dalla rete (offline, tempo scaduto), non dal file.
  static bool erroreDiRete(Object e) =>
      e is CatalogOfflineException ||
      e is SocketException ||
      e is TimeoutException ||
      e is HttpException;

  // ---------------------------------------------------------- lettura base

  Future<File> _cacheFile(String relative) async {
    // nomi dal catalogo (es. id dell'ateneo o del corso): mai fuori dalla
    // cache
    if (relative.split(RegExp(r'[/\\]')).any((s) => s == '..' || s.isEmpty) ||
        p.isAbsolute(relative)) {
      throw CatalogException('Percorso non valido: $relative');
    }
    return File(p.join((await _cacheDir()).path, relative));
  }

  Future<String?> _readCache(String relative) async {
    try {
      final f = await _cacheFile(relative);
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return null;
  }

  Future<bool> _inCache(String relative) async {
    try {
      return await (await _cacheFile(relative)).exists();
    } catch (_) {
      return false;
    }
  }

  /// Scrittura atomica: file temporaneo, poi rinomina (un'interruzione non
  /// lascia mai un file a metà).
  Future<void> _writeCache(String relative, String text) async {
    File? tmp;
    try {
      final f = await _cacheFile(relative);
      await f.parent.create(recursive: true);
      tmp = File('${f.path}.${_tmpSeq++}.part');
      await tmp.writeAsString(text, flush: true);
      await _sostituisci(tmp, f);
    } catch (_) {
      // La cache è facoltativa (es. disco pieno): si continua senza.
      await _eliminaSilenzioso(tmp);
    }
  }

  static int _tmpSeq = 0;

  /// Rinomina [tmp] in [dest] (su Windows, se la rinomina sopra un file
  /// esistente non riesce, prima si elimina quello).
  static Future<void> _sostituisci(File tmp, File dest) async {
    try {
      await tmp.rename(dest.path);
    } on FileSystemException {
      if (await dest.exists()) await dest.delete();
      await tmp.rename(dest.path);
    }
  }

  static Future<void> _eliminaSilenzioso(FileSystemEntity? f) async {
    try {
      if (f != null && await f.exists()) await f.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> _deleteCache(String relative) async {
    try {
      final f = await _cacheFile(relative);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// La cartella della cache esiste o si può usare (nei test senza
  /// path_provider no: lì non si scarica nulla in automatico).
  Future<bool> _cacheDisponibile() async {
    try {
      await _cacheDir();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Asset inclusi nell'app: `<file>` oppure `<file>.gz` (solo i file
  /// comuni).
  Future<String?> _readAsset(String relative) async {
    try {
      return await _assetLoader('$kCatalogAssetDir/$relative');
    } catch (_) {}
    try {
      final bytes = await _assetBytesLoader('$kCatalogAssetDir/$relative.gz');
      return utf8.decode(gzip.decode(bytes));
    } catch (_) {
      return null;
    }
  }

  /// Callback di avanzamento del download di un file: aggiorna
  /// [progresso] (file [indice] di [totale], dopo [prima] byte già
  /// ricevuti in questo download).
  CatalogByteProgress _avanzamento({
    required String ateneoId,
    required String etichetta,
    int indice = 1,
    int totale = 1,
    int prima = 0,
  }) => (int r, int? attesi) {
    progresso.value = CatalogProgress(
      ateneoId: ateneoId,
      etichetta: etichetta,
      indice: indice,
      totale: totale,
      ricevuti: r,
      attesi: attesi,
      ricevutiPrima: prima,
    );
  };

  /// Legge [relative] (file comuni, piccoli) con la precedenza rete →
  /// cache → asset e lo converte con [parse]. Un file scaricato ma non
  /// valido non sostituisce la cache.
  Future<CatalogResult<T>?> _load<T>(
    String relative,
    T Function(Object? json) parse, {
    required bool remote,
  }) async {
    Object? error;
    if (remote) {
      try {
        final text = await _fetcher(await _url(relative));
        final data = parse(jsonDecode(text));
        await _writeCache(relative, text);
        return CatalogResult(data, CatalogSource.remote);
      } catch (e) {
        error = e;
      }
    }
    for (final (source, read) in [
      (CatalogSource.cache, _readCache),
      (CatalogSource.bundled, _readAsset),
    ]) {
      final text = await read(relative);
      if (text == null) continue;
      try {
        return CatalogResult(parse(jsonDecode(text)), source, error: error);
      } catch (e) {
        error ??= e;
      }
    }
    return null;
  }

  // ------------------------------------------------- file del corso scelto

  /// Scarica il file [rel] nella cache: a pezzi in un file temporaneo
  /// (`.part`), controllo del JSON, poi rinomina. Un file non valido o un
  /// download interrotto lasciano la copia precedente. Chiamate
  /// contemporanee per lo stesso file aspettano lo stesso download.
  /// Restituisce i byte ricevuti e l'impronta sha256.
  Future<(int, String)> _scaricaFile(
    String rel,
    _Tipo tipo, {
    required String ateneoId,
    int indice = 1,
    int totale = 1,
    int prima = 0,
  }) {
    _tentati.add(rel);
    // (la callback non restituisce il Future rimosso: whenComplete
    // aspetterebbe sé stesso)
    return _fileInCorso[rel] ??=
        _scaricaFileOra(
          rel,
          tipo,
          ateneoId: ateneoId,
          indice: indice,
          totale: totale,
          prima: prima,
        ).whenComplete(() {
          _fileInCorso.remove(rel);
        });
  }

  Future<(int, String)> _scaricaFileOra(
    String rel,
    _Tipo tipo, {
    required String ateneoId,
    required int indice,
    required int totale,
    required int prima,
  }) async {
    final dest = await _cacheFile(rel);
    final tmp = File('${dest.path}.part');
    try {
      await dest.parent.create(recursive: true);
      final avanza = _avanzamento(
        ateneoId: ateneoId,
        etichetta: tipo.etichetta,
        indice: indice,
        totale: totale,
        prima: prima,
      );
      avanza(0, null);
      final n = await _fileFetcher(await _url(rel), tmp, onProgress: avanza);
      final sha = await _controlla(tmp, tipo);
      await _sostituisci(tmp, dest);
      return (n, sha);
    } catch (_) {
      await _eliminaSilenzioso(tmp);
      rethrow;
    }
  }

  /// Legge dalla cache il file [rel] tenendo solo ciò che chiede [filtro].
  /// Restituisce il modello (null se il file non c'è) e l'eventuale errore.
  /// Un file illeggibile (troncato, non JSON) si elimina, così alla
  /// prossima richiesta si riscarica.
  Future<(Object?, Object?)> _leggiCache(
    String rel,
    _Tipo tipo,
    _Filtro filtro,
  ) async {
    final File f;
    try {
      f = await _cacheFile(rel);
      if (!await f.exists()) return (null, null);
    } catch (_) {
      return (null, null);
    }
    try {
      return (await _leggi(f, tipo, filtro), null);
    } catch (e) {
      if (e is FormatException || e is CatalogFormatException) {
        await _eliminaSilenzioso(f);
        _tentati.remove(rel);
        _recenti.clear();
        _corsiRecenti.clear();
      }
      return (null, e);
    }
  }

  /// Un file del corso o dell'ateneo: rete (se [remote]) → cache. Se manca
  /// e [scarica], si scarica da internet (una volta per sessione, non se
  /// l'ultimo download l'ha trovato assente nel database): così i
  /// chiamanti che leggono la copia salvata funzionano anche se lo
  /// studente non ha ancora scaricato i dati.
  Future<CatalogResult<T>?> _loadFile<T>(
    String rel,
    _Tipo tipo, {
    required String ateneoId,
    String? corsoId,
    required bool remote,
    bool scarica = true,
    _Filtro filtro = _senzaFiltro,
  }) async {
    Object? error;
    if (remote) {
      try {
        if (corsoId != null) {
          // il file del corso passa dall'indice (impronte) e dal registro
          final d = await scaricaCorso(
            ateneoId,
            corsoId,
            soloCorso: true,
            pulisci: false,
          );
          if (d.errore != null) throw d.errore!;
          if (d.corsiAssenti) throw CatalogNotFoundException();
        } else {
          await _scaricaFile(rel, tipo, ateneoId: ateneoId);
        }
        final (data, e) = await _leggiCache(rel, tipo, filtro);
        if (data is T) return CatalogResult(data, CatalogSource.remote);
        error = e;
      } catch (e) {
        error = e;
      } finally {
        // (non durante il download del corso: lo chiude quello)
        if (_inCorso.isEmpty) progresso.value = null;
      }
    }
    final (cached, e) = await _leggiCache(rel, tipo, filtro);
    if (cached is T) {
      return CatalogResult(cached, CatalogSource.cache, error: error);
    }
    error ??= e;
    if (remote || !scarica) return null;
    // download già in corso (del corso, o per le sessioni di un corso
    // dell'ateneo): si aspetta quello
    final inCorso = corsoId != null
        ? _inCorso[_chiave(ateneoId, corsoId)]
        : _inCorso.entries
              .where((e) => e.key.startsWith('$ateneoId/'))
              .firstOrNull
              ?.value;
    if (inCorso != null) {
      await inCorso.f;
      return _loadFile(
        rel,
        tipo,
        ateneoId: ateneoId,
        corsoId: corsoId,
        remote: false,
        scarica: false,
        filtro: filtro,
      );
    }
    if (!await _cacheDisponibile() || _tentati.contains(rel)) return null;
    final registro = await _registro();
    if (registro?.ateneoId == ateneoId && registro!.assenti.contains(rel)) {
      return null;
    }
    return _loadFile(
      rel,
      tipo,
      ateneoId: ateneoId,
      corsoId: corsoId,
      remote: true,
      filtro: filtro,
    );
  }

  // ------------------------------------------------------------- pubblici

  /// Elenco degli atenei (cache → asset; [refresh] prova prima la rete).
  Future<UniversitaCatalog> universita({bool refresh = false}) async {
    if (_universita != null && !refresh) return _universita!;
    final r = await _load(
      'universita.json',
      UniversitaCatalog.fromJson,
      remote: refresh,
    );
    if (r == null) {
      throw CatalogException('Elenco delle università non disponibile.');
    }
    return _universita = r.data;
  }

  /// Indice compatto dei corsi di tutti gli atenei (vuoto se manca).
  Future<IndiceCorsi> indiceCorsi({bool refresh = false}) async {
    if (_indice != null && !refresh) return _indice!;
    final r = await _load(
      'indice_corsi.json',
      IndiceCorsi.fromJson,
      remote: refresh,
    );
    return _indice = r?.data ?? IndiceCorsi.empty;
  }

  /// Corsi di laurea eliminati perché doppioni e uniti a un altro
  /// (`corsi_sostituiti.json`); vuoto se il file manca o non è leggibile.
  Future<CorsiSostituiti> corsiSostituiti({bool refresh = false}) async {
    if (_sostituiti != null && !refresh) return _sostituiti!;
    final r = await _load(
      'corsi_sostituiti.json',
      CorsiSostituiti.fromJson,
      remote: refresh,
    );
    return _sostituiti = r?.data ?? CorsiSostituiti.empty;
  }

  /// Dati del corso di laurea [corso] dell'ateneo (tutti gli anni):
  /// prova la rete (se [remote]), poi la copia salvata; se manca la
  /// scarica (con [scarica]). null se non disponibile (es. offline al
  /// primo uso).
  Future<CatalogResult<CorsiAteneo>?> corsiAteneo(
    String ateneoId, {
    required String corso,
    bool remote = true,
    bool scarica = true,
  }) => _loadFile(
    CatalogPaths.corso(ateneoId, corso),
    _Tipo.corso,
    ateneoId: ateneoId,
    corsoId: corso,
    remote: remote,
    scarica: scarica,
  );

  /// Sessioni d'esame dell'ateneo (calendari ufficiali): rete se
  /// [remote], poi la copia salvata (scaricata se manca).
  Future<CatalogResult<SessioniAteneo>?> sessioni(
    String ateneoId, {
    bool remote = false,
    bool scarica = true,
  }) => _loadFile(
    CatalogPaths.sessioni(ateneoId),
    _Tipo.sessioni,
    ateneoId: ateneoId,
    remote: remote,
    scarica: scarica,
  );

  /// Moduli di studio proposti per gli insegnamenti del corso [corso]
  /// (sono nello stesso file del corso); con [insegnamenti] (id) solo i loro.
  Future<CatalogResult<ModuliAteneo>?> moduli(
    String ateneoId, {
    required String corso,
    bool remote = false,
    bool scarica = true,
    Iterable<String>? insegnamenti,
  }) => _loadFile(
    CatalogPaths.corso(ateneoId, corso),
    _Tipo.moduli,
    ateneoId: ateneoId,
    corsoId: corso,
    remote: remote,
    scarica: scarica,
    filtro: (insegnamenti: insegnamenti?.toSet()),
  );

  /// `meta.json` dalla rete; null se offline o assente.
  Future<DatabaseMeta?> remoteMeta() async {
    try {
      final text = await _fetcher(await _url('meta.json'));
      final meta = DatabaseMeta.fromJson(jsonDecode(text));
      await _writeCache('meta.json', text);
      return meta;
    } catch (_) {
      return null;
    }
  }

  /// `meta.json` già presente (cache o asset).
  Future<DatabaseMeta?> localMeta() async =>
      (await _load('meta.json', DatabaseMeta.fromJson, remote: false))?.data;

  /// Aggiorna da internet elenco atenei, indice dei corsi e mappa dei corsi
  /// sostituiti (in cache). Ritorna true se almeno uno è stato scaricato.
  Future<bool> refreshIndexes() async {
    final u = await _load(
      'universita.json',
      UniversitaCatalog.fromJson,
      remote: true,
    );
    if (u != null) _universita = u.data;
    final i = await _load(
      'indice_corsi.json',
      IndiceCorsi.fromJson,
      remote: true,
    );
    if (i != null) _indice = i.data;
    // facoltativo: senza file (404) resta la copia già salvata o inclusa
    final c = await _load(
      'corsi_sostituiti.json',
      CorsiSostituiti.fromJson,
      remote: true,
    );
    if (c != null) _sostituiti = c.data;
    return u?.source == CatalogSource.remote ||
        i?.source == CatalogSource.remote ||
        c?.source == CatalogSource.remote;
  }

  // ------------------------------------------------------ dati del corso

  Future<_Registro?> _registro() async {
    final text = await _readCache(_registroFile);
    if (text == null) return null;
    try {
      return _Registro.fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  /// Impronta del corso [corsoId] in `per_corso/<ateneo>/indice.json`
  /// (scaricato ora, in memoria: pochi KB). Lancia
  /// [CatalogNotFoundException] se l'ateneo o il corso non sono nel
  /// database.
  Future<String?> _shaDaIndice(String ateneoId, String corsoId) async {
    final text = await _fetcher(await _url(CatalogPaths.indice(ateneoId)));
    final json = jsonDecode(text);
    final corsi = json is Map ? json['corsi'] : null;
    if (corsi is! Map) {
      throw CatalogFormatException('Indice dei corsi dell\'ateneo non valido.');
    }
    final voce = corsi[corsoId];
    if (voce == null) throw CatalogNotFoundException();
    return voce is Map ? voce['sha256'] as String? : null;
  }

  /// Scarica da internet i dati del corso di laurea [corsoId] dell'ateneo
  /// [ateneoId] (con [soloCorso] solo il file del corso, per esempio per la
  /// scelta del percorso nell'onboarding; altrimenti anche le sessioni
  /// d'esame dell'ateneo) nella cache, aggiornando [progresso].
  ///
  /// Con [meta] (`meta.json` online, scaricato se non passato) riscarica
  /// solo ciò che è cambiato: il corso se la sua impronta
  /// nell'indice dell'ateneo è diversa, le sessioni se è cambiata la
  /// versione del database. Un file assente nel database (404) si ricorda,
  /// così non si richiede a ogni lettura. Senza rete restano le copie già
  /// salvate ([AteneoScaricato.senzaRete] se manca anche quella del corso).
  /// Con [pulisci] (e il corso disponibile) elimina dalla cache i file degli
  /// altri corsi e atenei. Un download fatto da meno di 15 minuti non si
  /// ripete, salvo [forza]. Chiamate contemporanee per lo stesso corso
  /// aspettano lo stesso download. Non lancia.
  Future<AteneoScaricato> scaricaCorso(
    String ateneoId,
    String corsoId, {
    DatabaseMeta? meta,
    bool pulisci = true,
    bool forza = false,
    bool soloCorso = false,
  }) async {
    AteneoScaricato r;
    final k = _chiave(ateneoId, corsoId);
    try {
      final recente = _recenti[k];
      if (!forza &&
          recente != null &&
          DateTime.now().difference(recente.$1) < _validitaRecente) {
        r = recente.$2;
      } else {
        r = await _accoda(
          ateneoId,
          corsoId,
          meta,
          soloCorso: soloCorso,
          forza: forza,
        );
      }
      if (pulisci && r.corsi) await eliminaAltri(ateneoId, corsoId);
    } catch (e) {
      r = AteneoScaricato(ateneoId: ateneoId, corsoId: corsoId, errore: e);
    }
    return r;
  }

  static const _validitaRecente = Duration(minutes: 15);

  /// Un download del corso alla volta: se ce n'è già uno che copre la
  /// richiesta (completo, o anche solo del corso se basta quello) si
  /// aspetta quello; altrimenti il nuovo parte quando finisce il precedente.
  Future<AteneoScaricato> _accoda(
    String ateneoId,
    String corsoId,
    DatabaseMeta? meta, {
    required bool soloCorso,
    required bool forza,
  }) {
    final k = _chiave(ateneoId, corsoId);
    final c = _inCorso[k];
    if (c != null && (c.completo || soloCorso)) return c.f;
    final prima = c?.f;
    late final Future<AteneoScaricato> f;
    f =
        () async {
          if (prima != null) await prima;
          return _scarica(
            ateneoId,
            corsoId,
            meta,
            soloCorso: soloCorso,
            forza: forza,
          );
        }().whenComplete(() {
          if (identical(_inCorso[k]?.f, f)) _inCorso.remove(k);
        });
    _inCorso[k] = (f: f, completo: !soloCorso);
    return f;
  }

  Future<AteneoScaricato> _scarica(
    String id,
    String corsoId,
    DatabaseMeta? meta, {
    required bool soloCorso,
    required bool forza,
  }) async {
    meta ??= await remoteMeta();
    final prima = await _registro();
    final stessoAteneo = prima?.ateneoId == id;
    final stessoCorso = stessoAteneo && prima?.corsoId == corsoId;
    final stessaVersione =
        stessoAteneo &&
        meta?.versione != null &&
        prima?.versione == meta?.versione;
    final shaIndiceOnline = meta?.atenei[id]?.sha256PerCorso;
    final k = _chiave(id, corsoId);
    final relCorso = CatalogPaths.corso(id, corsoId);
    final relSessioni = CatalogPaths.sessioni(id);
    final totale = soloCorso ? 1 : 2;
    var shaCorso = stessoCorso ? prima?.sha256Corso : null;
    var shaIndice = stessoAteneo ? prima?.sha256Indice : null;
    final assenti = <String>{
      // download del solo corso: per le sessioni vale il registro
      if (soloCorso && stessoAteneo)
        for (final a in prima?.assenti ?? const <String>{})
          if (a == relSessioni) a,
    };
    var scaricati = 0, invariati = 0, byte = 0;
    var corsi = false, corsiAggiornati = false, corsiAssenti = false;
    Object? errore;
    try {
      // 1. il corso di laurea
      final presente = await _inCache(relCorso);
      final recente = _corsiRecenti[k];
      final appena =
          !forza &&
          recente != null &&
          DateTime.now().difference(recente.$1) < _validitaRecente;
      if (presente &&
          (appena ||
              (stessoCorso &&
                  shaIndiceOnline != null &&
                  shaIndiceOnline == prima?.sha256Indice))) {
        invariati++;
        corsi = corsiAggiornati = true;
        if (appena) shaCorso = recente.$2;
      } else {
        try {
          final atteso = await _shaDaIndice(id, corsoId);
          shaIndice = shaIndiceOnline;
          if (presente && atteso != null && atteso == shaCorso) {
            invariati++;
            corsi = corsiAggiornati = true;
          } else {
            final (n, sha) = await _scaricaFile(
              relCorso,
              _Tipo.corso,
              ateneoId: id,
              totale: totale,
            );
            byte += n;
            scaricati++;
            corsi = corsiAggiornati = true;
            shaCorso = sha;
            _corsiRecenti[k] = (DateTime.now(), sha);
          }
        } on CatalogNotFoundException {
          // il corso (o l'ateneo) non c'è (più) nel database
          assenti.add(relCorso);
          await _deleteCache(relCorso);
          corsiAssenti = true;
          shaCorso = null;
        } catch (e) {
          errore ??= e;
          if (presente) corsi = true; // resta la copia salvata
        }
      }
      // 2. le sessioni d'esame dell'ateneo
      if (!soloCorso && !(errore != null && erroreDiRete(errore))) {
        final presenti = await _inCache(relSessioni);
        if (presenti && stessaVersione) {
          invariati++;
        } else if (!presenti &&
            stessaVersione &&
            (prima?.assenti.contains(relSessioni) ?? false)) {
          assenti.add(relSessioni);
          invariati++;
        } else {
          try {
            final (n, _) = await _scaricaFile(
              relSessioni,
              _Tipo.sessioni,
              ateneoId: id,
              indice: totale,
              totale: totale,
              prima: byte,
            );
            byte += n;
            scaricati++;
          } on CatalogNotFoundException {
            assenti.add(relSessioni);
            await _deleteCache(relSessioni);
          } catch (e) {
            errore ??= e;
          }
        }
      } else if (!soloCorso) {
        _tentati.add(relSessioni);
      }
    } finally {
      progresso.value = null;
    }
    if (scaricati + invariati + assenti.length > 0) {
      await _writeCache(
        _registroFile,
        jsonEncode(
          _Registro(
            ateneoId: id,
            corsoId: corsoId,
            // con errori la versione non si segna: si ricontrolla tutto; col
            // solo corso resta quella delle sessioni già sul dispositivo
            versione: errore != null
                ? null
                : soloCorso
                ? (stessaVersione ? prima?.versione : null)
                : meta?.versione,
            scaricatoIl: DateTime.now(),
            sha256Corso: shaCorso,
            sha256Indice: corsiAggiornati ? shaIndice : null,
            assenti: assenti,
          ).toJson(),
        ),
      );
    }
    final r = AteneoScaricato(
      ateneoId: id,
      corsoId: corsoId,
      scaricati: scaricati,
      invariati: invariati,
      byte: byte,
      corsi: corsi,
      corsiAggiornati: corsiAggiornati,
      corsiAssenti: corsiAssenti,
      errore: errore,
    );
    if (errore == null && !soloCorso) _recenti[k] = (DateTime.now(), r);
    return r;
  }

  /// Elimina dalla cache i file diversi dal corso [corsoId] dell'ateneo
  /// [ateneoId] e dalle sessioni dell'ateneo (cambio di corso o d'ateneo:
  /// l'app resta leggera). I file comuni restano, e anche i download in
  /// corso del corso (`<corso>.json.part`). Elimina anche i file per
  /// ateneo delle versioni precedenti dell'app (`corsi/`, `moduli/`).
  Future<void> eliminaAltri(String ateneoId, [String? corsoId]) async {
    try {
      final dir = await _cacheDir();
      // file delle versioni precedenti (dati di tutto l'ateneo) e cartella
      // dei gruppi degli studenti, non più usata
      for (final vecchia in ['corsi', 'moduli', 'community']) {
        await _eliminaSilenzioso(Directory(p.join(dir.path, vecchia)));
      }
      final perCorso = Directory(p.join(dir.path, 'per_corso'));
      if (await perCorso.exists()) {
        await for (final e in perCorso.list()) {
          if (e is! Directory || p.basename(e.path) != ateneoId) {
            await _eliminaSilenzioso(e);
            continue;
          }
          await for (final f in e.list()) {
            final nome = p.basename(f.path);
            if (corsoId == null || !nome.startsWith('$corsoId.json')) {
              await _eliminaSilenzioso(f);
            }
          }
        }
      }
      final sessioni = Directory(p.join(dir.path, 'sessioni'));
      if (await sessioni.exists()) {
        await for (final e in sessioni.list()) {
          if (e is File && !p.basename(e.path).startsWith('$ateneoId.json')) {
            await _eliminaSilenzioso(e);
          }
        }
      }
      final tieni = corsoId == null ? null : _chiave(ateneoId, corsoId);
      _recenti.removeWhere((k, _) => k != tieni);
      _corsiRecenti.removeWhere((k, _) => k != tieni);
      final r = await _registro();
      if (r != null &&
          (r.ateneoId != ateneoId ||
              (corsoId != null && r.corsoId != corsoId))) {
        await _deleteCache(_registroFile);
      }
    } catch (_) {
      // la pulizia è facoltativa
    }
  }

  /// Dati del corso [corsoId] presenti sul dispositivo (senza rete).
  Future<AteneoSulDispositivo> datiCorso(
    String ateneoId,
    String corsoId,
  ) async {
    var byte = 0;
    var corsi = false;
    for (final rel in [
      CatalogPaths.corso(ateneoId, corsoId),
      CatalogPaths.sessioni(ateneoId),
    ]) {
      try {
        final file = await _cacheFile(rel);
        if (await file.exists()) {
          byte += await file.length();
          if (rel.startsWith('per_corso/')) corsi = true;
        }
      } catch (_) {}
    }
    final r = await _registro();
    final stesso = r?.ateneoId == ateneoId && r?.corsoId == corsoId;
    return AteneoSulDispositivo(
      ateneoId: ateneoId,
      corsi: corsi,
      byte: byte,
      versione: stesso ? r!.versione : null,
      scaricatoIl: stesso ? r!.scaricatoIl : null,
    );
  }

  // ------------------------------------------------------------ download

  /// Scaricamento con dart:io HttpClient, timeout e limite di 50 MB (i file
  /// del database sono di pochi KB o MB; in trasferimento sono compressi
  /// con gzip e HttpClient li decomprime da solo).
  static CatalogFetcher defaultFetcher({
    Duration timeout = const Duration(seconds: 30),
    int maxBytes = 50 * 1024 * 1024,
  }) => (Uri uri, {CatalogByteProgress? onProgress}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        if (response.statusCode == HttpStatus.notFound) {
          throw CatalogNotFoundException();
        }
        throw CatalogException(
          'Il server ha risposto con errore ${response.statusCode}.',
        );
      }
      // con gzip la lunghezza è quella compressa: non serve per i byte
      // ricevuti (già decompressi)
      final attesi =
          response.contentLength > 0 &&
              response.compressionState !=
                  HttpClientResponseCompressionState.decompressed
          ? response.contentLength
          : null;
      final builder = BytesBuilder(copy: true);
      var avvisati = 0;
      await for (final chunk in response.timeout(timeout)) {
        builder.add(chunk);
        if (builder.length > maxBytes) {
          throw CatalogException('File troppo grande.');
        }
        // al massimo un aggiornamento ogni 256 KB
        if (onProgress != null && builder.length - avvisati >= 256 * 1024) {
          avvisati = builder.length;
          onProgress(avvisati, attesi);
        }
      }
      onProgress?.call(builder.length, attesi);
      final text = utf8.decode(builder.takeBytes());
      return text.startsWith('﻿') ? text.substring(1) : text;
    } on SocketException {
      throw CatalogOfflineException();
    } on HttpException {
      throw CatalogOfflineException('Connessione interrotta.');
    } on TimeoutException {
      throw CatalogOfflineException('Tempo scaduto durante il download.');
    } finally {
      client.close(force: true);
    }
  };

  /// Come [defaultFetcher] ma scrive a pezzi direttamente in `dest`: in
  /// memoria resta solo il pezzo in arrivo.
  static CatalogFileFetcher defaultFileFetcher({
    Duration timeout = const Duration(seconds: 30),
    int maxBytes = 50 * 1024 * 1024,
  }) => (Uri uri, File dest, {CatalogByteProgress? onProgress}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    RandomAccessFile? out;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close().timeout(timeout);
      if (response.statusCode != HttpStatus.ok) {
        await response.drain<void>().catchError((_) {});
        if (response.statusCode == HttpStatus.notFound) {
          throw CatalogNotFoundException();
        }
        throw CatalogException(
          'Il server ha risposto con errore ${response.statusCode}.',
        );
      }
      final attesi =
          response.contentLength > 0 &&
              response.compressionState !=
                  HttpClientResponseCompressionState.decompressed
          ? response.contentLength
          : null;
      var ricevuti = 0, avvisati = 0;
      var primo = true;
      out = await dest.open(mode: FileMode.write);
      await for (final chunk in response.timeout(timeout)) {
        var c = chunk;
        // BOM UTF-8 iniziale: il decoder JSON non lo accetta
        if (primo) {
          primo = false;
          if (c.length >= 3 && c[0] == 0xEF && c[1] == 0xBB && c[2] == 0xBF) {
            c = c.sublist(3);
          }
        }
        ricevuti += c.length;
        if (ricevuti > maxBytes) throw CatalogException('File troppo grande.');
        await out.writeFrom(c);
        // al massimo un aggiornamento ogni 256 KB
        if (onProgress != null && ricevuti - avvisati >= 256 * 1024) {
          avvisati = ricevuti;
          onProgress(ricevuti, attesi);
        }
      }
      final f = out;
      out = null;
      await f.flush();
      await f.close();
      onProgress?.call(ricevuti, attesi);
      return ricevuti;
    } on SocketException {
      throw CatalogOfflineException();
    } on HttpException {
      throw CatalogOfflineException('Connessione interrotta.');
    } on TimeoutException {
      throw CatalogOfflineException('Tempo scaduto durante il download.');
    } finally {
      if (out != null) {
        try {
          await out.close();
        } catch (_) {}
      }
      client.close(force: true);
    }
  };

  /// Adatta un [CatalogFetcher] di testo (test) al download su file.
  static CatalogFileFetcher _fileFetcherDaTesto(CatalogFetcher fetcher) =>
      (Uri uri, File dest, {CatalogByteProgress? onProgress}) async {
        final bytes = utf8.encode(await fetcher(uri, onProgress: onProgress));
        await dest.writeAsBytes(bytes, flush: true);
        return bytes.length;
      };

  /// Messaggio chiaro per lo studente su un errore del download o della
  /// lettura dei dati del corso.
  static String descriviErrore(Object? e) {
    if (e == null || erroreDiRete(e)) return kServeConnessione;
    if (e is FileSystemException) {
      return 'Non riesco a salvare i dati del tuo corso sul dispositivo: '
          'controlla lo spazio libero e riprova.';
    }
    if (e is FormatException || e is CatalogFormatException) {
      return 'Il file del tuo corso è arrivato incompleto o non valido: '
          'riprova.';
    }
    if (e is CatalogException) return e.message;
    return 'Download dei dati del tuo corso non riuscito: riprova.';
  }
}

// --------------------------------------------------------- lettura dei file

/// Tipo di file della cache: etichetta per l'indicatore di download e
/// modello in cui si converte.
enum _Tipo {
  corso('corso di laurea'),
  moduli('corso di laurea'),
  sessioni('sessioni d\'esame');

  const _Tipo(this.etichetta);
  final String etichetta;
}

/// Cosa tenere leggendo i moduli: solo quelli degli [insegnamenti]; null =
/// tutti.
typedef _Filtro = ({Set<String>? insegnamenti});

const _Filtro _senzaFiltro = (insegnamenti: null);

/// File più grandi si decodificano in un isolate a parte, per non bloccare
/// l'interfaccia. I file di un corso sono quasi sempre più piccoli.
const _sogliaIsolate = 512 * 1024;

Object _modello(_Tipo tipo, Object? json, _Filtro f) => switch (tipo) {
  _Tipo.corso => CorsiAteneo.fromJson(json),
  _Tipo.sessioni => SessioniAteneo.fromJson(json),
  _Tipo.moduli => ModuliAteneo.fromJson(_moduliDelCorso(json, f)),
};

/// `moduli` del file del corso nella forma di `moduli/<ateneo>.json`,
/// tenendo solo gli insegnamenti del filtro.
Map<String, Object?> _moduliDelCorso(Object? json, _Filtro f) {
  if (json is! Map) {
    throw CatalogFormatException('File del corso non valido.');
  }
  final tutti = json['moduli'];
  final ins = f.insegnamenti;
  return {
    'universita_id': json['universita_id'],
    'insegnamenti': {
      if (tutti is Map)
        for (final e in tutti.entries)
          if (ins == null || ins.contains(e.key)) e.key: e.value,
    },
  };
}

/// Decodifica e controlla il testo [text] ([tipo]) e ne restituisce il
/// modello.
Object _converti(String text, _Tipo tipo, _Filtro f) {
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  return _modello(tipo, jsonDecode(t), f);
}

/// Legge il file della cache [f] e restituisce il modello (filtrato con
/// [filtro]); gli errori (file troncato…) arrivano al chiamante. I file
/// grandi si leggono in un isolate.
Future<Object> _leggi(File f, _Tipo tipo, _Filtro filtro) async {
  final n = await f.length();
  if (n < _sogliaIsolate) {
    return _converti(await f.readAsString(), tipo, filtro);
  }
  final path = f.path;
  return Isolate.run(
    () => _converti(File(path).readAsStringSync(), tipo, filtro),
  );
}

/// Controlla il file appena scaricato [f] (JSON completo e radice valida)
/// e ne restituisce l'impronta sha256.
Future<String> _controlla(File f, _Tipo tipo) async {
  final n = await f.length();
  final path = f.path;
  String controlla() {
    final bytes = File(path).readAsBytesSync();
    _modello(tipo, jsonDecode(utf8.decode(bytes)), _senzaFiltro);
    return crypto.sha256.convert(bytes).toString();
  }

  if (n < _sogliaIsolate) return controlla();
  return Isolate.run(controlla);
}
