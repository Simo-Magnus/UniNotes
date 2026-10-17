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

/// Messaggio per lo studente quando i dati dell'ateneo non sono sul
/// dispositivo e non si possono scaricare.
const String kServeConnessione =
    'Serve una connessione per scaricare i dati del tuo ateneo.';

/// Avanzamento di un download: byte ricevuti e attesi (null se il server
/// non lo dice, per esempio con la compressione gzip in trasferimento).
typedef CatalogByteProgress = void Function(int ricevuti, int? attesi);

/// Scarica il testo di un URL. Iniettabile nei test.
typedef CatalogFetcher =
    Future<String> Function(Uri uri, {CatalogByteProgress? onProgress});

/// Scarica un URL direttamente nel file [dest], senza tenerlo tutto in
/// memoria (i corsi dei grandi atenei superano i 50 MB), e restituisce i
/// byte ricevuti. Iniettabile nei test.
typedef CatalogFileFetcher =
    Future<int> Function(Uri uri, File dest, {CatalogByteProgress? onProgress});

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
/// per esempio un ateneo senza calendario delle sessioni o senza moduli di studio.
class CatalogNotFoundException extends CatalogException {
  CatalogNotFoundException([
    super.message = 'File non ancora presente nel database (404).',
  ]);
}

/// Nessuna connessione a internet (o tempo scaduto).
class CatalogOfflineException extends CatalogException {
  CatalogOfflineException([super.message = 'Nessuna connessione a internet.']);
}

/// Un file dei dati di un ateneo: cartella nel database e descrizione per
/// l'indicatore di download.
typedef FileAteneo = ({String cartella, String etichetta});

/// File scaricati per l'ateneo scelto, nell'ordine del download: prima i
/// corsi (indispensabili per il piano di studi), poi quelli facoltativi.
const List<FileAteneo> kFileAteneo = [
  (cartella: 'corsi', etichetta: 'corsi e insegnamenti'),
  (cartella: 'sessioni', etichetta: 'sessioni d\'esame'),
  (cartella: 'moduli', etichetta: 'moduli di studio'),
];

/// Avanzamento del download dei dati di un ateneo (per la barra
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

  /// Cosa si sta scaricando ("corsi e insegnamenti", …).
  final String etichetta;

  /// File in corso (1..[totale]).
  final int indice;
  final int totale;

  /// Byte ricevuti del file in corso e attesi (null se non noti).
  final int ricevuti;
  final int? attesi;

  /// Byte dei file dell'ateneo già scaricati in questo download.
  final int ricevutiPrima;

  int get ricevutiTotali => ricevutiPrima + ricevuti;

  /// 0..1 se la dimensione del file è nota, altrimenti null (barra
  /// indeterminata: con gzip in trasferimento il server non la dice).
  double? get frazione {
    final a = attesi;
    if (a == null || a <= 0) return null;
    return ((indice - 1) + (ricevuti / a).clamp(0.0, 1.0)) / totale;
  }
}

/// Esito di [CatalogService.scaricaAteneo].
class AteneoScaricato {
  const AteneoScaricato({
    required this.ateneoId,
    this.scaricati = 0,
    this.invariati = 0,
    this.byte = 0,
    this.corsi = false,
    this.corsiAggiornati = false,
    this.corsiAssenti = false,
    this.errore,
  });
  final String ateneoId;

  /// File scaricati ora e file già aggiornati sul dispositivo.
  final int scaricati;
  final int invariati;

  /// Byte scaricati ora (dopo la decompressione).
  final int byte;

  /// `corsi/<ateneo>.json` è sul dispositivo (scaricato ora o prima).
  final bool corsi;

  /// …ed è quello attuale del database (scaricato ora o verificato).
  final bool corsiAggiornati;

  /// Il database non ha (ancora) i corsi dell'ateneo (404).
  final bool corsiAssenti;

  /// Primo errore (di rete o file non valido), se c'è stato.
  final Object? errore;

  /// Nessuna copia dei corsi e niente rete: serve una connessione.
  bool get senzaRete => !corsi && !corsiAssenti && errore != null;
}

/// Dati dell'ateneo salvati sul dispositivo (Impostazioni → Il mio percorso).
class AteneoSulDispositivo {
  const AteneoSulDispositivo({
    required this.ateneoId,
    required this.corsi,
    required this.byte,
    this.versione,
    this.scaricatoIl,
  });
  final String ateneoId;

  /// C'è il file dei corsi (sul disco o, nelle build locali complete, negli
  /// asset).
  final bool corsi;

  /// Spazio occupato dai file dell'ateneo nella cache.
  final int byte;

  /// `meta.json.versione` dell'ultimo download completo e sua data.
  final String? versione;
  final DateTime? scaricatoIl;
}

/// Registro dell'ultimo download dei dati di un ateneo (`ateneo.json` nella
/// cache): versione del database, impronta dei corsi e file assenti (404),
/// così «Aggiorna database» riscarica solo ciò che è cambiato e i file
/// assenti non si richiedono a ogni lettura.
class _Registro {
  const _Registro({
    required this.ateneoId,
    this.versione,
    this.scaricatoIl,
    this.sha256Corsi,
    this.assenti = const {},
  });
  final String ateneoId;
  final String? versione;
  final DateTime? scaricatoIl;
  final String? sha256Corsi;
  final Set<String> assenti;

  static _Registro? fromJson(Object? json) {
    if (json is! Map || json['ateneo'] is! String) return null;
    final assenti = json['assenti'];
    return _Registro(
      ateneoId: json['ateneo'] as String,
      versione: json['versione'] as String?,
      scaricatoIl: DateTime.tryParse('${json['scaricato_il']}'),
      sha256Corsi: json['sha256_corsi'] as String?,
      assenti: {
        if (assenti is List)
          for (final a in assenti)
            if (a is String) a,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'ateneo': ateneoId,
    'versione': versione,
    'scaricato_il': scaricatoIl?.toIso8601String(),
    'sha256_corsi': sha256Corsi,
    'assenti': assenti.toList()..sort(),
  };
}

/// Accesso al database pubblico degli atenei.
///
/// L'app include negli asset solo i file comuni (atenei, indice dei corsi,
/// meta, corsi sostituiti: circa 1 MB) per scegliere ateneo e corso anche
/// offline. I dati di ogni ateneo (corsi, sessioni, moduli) si
/// scaricano da internet solo per l'ateneo scelto ([scaricaAteneo]) e si
/// salvano nella cartella di supporto dell'app (`database_cache/`), da cui
/// si leggono anche offline. Cambiando ateneo i file del precedente si
/// eliminano.
///
/// Ordine di lettura: rete (se richiesta) → copia su disco → asset (le
/// build locali con `sync_assets.py --completo` includono anche i file per
/// ateneo). Un file per ateneo che manca ovunque si scarica alla prima
/// lettura, se c'è rete (una volta per sessione). Ogni download riuscito
/// aggiorna la copia su disco.
///
/// I file per ateneo (decine di MB per gli atenei grandi) non passano mai
/// interi dalla memoria del thread dell'interfaccia: si scaricano a pezzi in
/// un file temporaneo, si controllano e si leggono in un isolate a parte
/// ([Isolate.run]) tenendo solo ciò che serve (un corso di laurea, i moduli
/// dei suoi insegnamenti) e si sostituiscono con una rinomina, così un
/// download interrotto non lascia mai un file troncato. Download dello
/// stesso file o dello stesso ateneo chiamati insieme condividono lo stesso
/// Future: non si scrive mai due volte nello stesso file.
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

  /// Download in corso dei dati di un ateneo (null quando non si scarica).
  final ValueNotifier<CatalogProgress?> progresso = ValueNotifier(null);

  /// File per ateneo già cercati in rete in questa sessione (non si
  /// richiedono di nuovo a ogni lettura se mancano o la rete non c'è).
  final Set<String> _tentati = {};

  /// Download completi recenti (l'import subito dopo un download non
  /// riscarica) e corsi scaricati da poco da soli (onboarding: prima i
  /// corsi per la scelta del percorso, poi il resto).
  final Map<String, (DateTime, AteneoScaricato)> _recenti = {};
  final Map<String, (DateTime, String)> _corsiRecenti = {};

  /// Download in corso per ateneo ([completo]: tutti i file, non solo i
  /// corsi) e per file (percorso relativo → byte ricevuti e impronta).
  final Map<String, ({Future<AteneoScaricato> f, bool completo})> _inCorso =
      {};
  final Map<String, Future<(int, String)>> _fileInCorso = {};

  /// Nome del registro dell'ultimo download nella cache.
  static const _registroFile = 'ateneo.json';

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
    // nomi dal catalogo (es. id dell'ateneo): mai fuori dalla cache
    if (relative.split(RegExp(r'[/\\]')).any((s) => s == '..') ||
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

  static Future<void> _eliminaSilenzioso(File? f) async {
    try {
      if (f != null && await f.exists()) await f.delete();
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

  /// Asset inclusi nell'app: `<file>` oppure `<file>.gz`. Le build
  /// pubblicate includono solo i file comuni; i file per ateneo ci sono
  /// solo nelle build locali con `tools/db_builder/sync_assets.py --completo`.
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

  /// Callback di avanzamento del download di un file di [ateneoId]: aggiorna
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

  // ------------------------------------------------------ file per ateneo

  static String _etichetta(String cartella) => kFileAteneo
      .firstWhere(
        (f) => f.cartella == cartella,
        orElse: () => (cartella: cartella, etichetta: cartella),
      )
      .etichetta;

  /// Scarica `<cartella>/<ateneoId>.json` nella cache: a pezzi in un file
  /// temporaneo (`.part`), controllo del JSON in un isolate, poi rinomina.
  /// Un file non valido o un download interrotto lasciano la copia
  /// precedente. Chiamate contemporanee per lo stesso file aspettano lo
  /// stesso download. Restituisce i byte ricevuti e l'impronta sha256.
  Future<(int, String)> _scaricaFile(
    String ateneoId,
    String cartella, {
    int indice = 1,
    int totale = 1,
    int prima = 0,
  }) {
    final rel = '$cartella/$ateneoId.json';
    _tentati.add(rel);
    // (la callback non restituisce il Future rimosso: whenComplete
    // aspetterebbe sé stesso)
    return _fileInCorso[rel] ??= _scaricaFileOra(
      ateneoId,
      cartella,
      indice: indice,
      totale: totale,
      prima: prima,
    ).whenComplete(() {
      _fileInCorso.remove(rel);
    });
  }

  Future<(int, String)> _scaricaFileOra(
    String ateneoId,
    String cartella, {
    required int indice,
    required int totale,
    required int prima,
  }) async {
    final rel = '$cartella/$ateneoId.json';
    final dest = await _cacheFile(rel);
    final tmp = File('${dest.path}.part');
    try {
      await dest.parent.create(recursive: true);
      final avanza = _avanzamento(
        ateneoId: ateneoId,
        etichetta: _etichetta(cartella),
        indice: indice,
        totale: totale,
        prima: prima,
      );
      avanza(0, null);
      final n = await _fileFetcher(await _url(rel), tmp, onProgress: avanza);
      final sha = await _controllaInIsolate(tmp.path, cartella);
      await _sostituisci(tmp, dest);
      if (cartella == 'corsi') _corsiRecenti[ateneoId] = (DateTime.now(), sha);
      return (n, sha);
    } catch (_) {
      await _eliminaSilenzioso(tmp);
      rethrow;
    }
  }

  /// Legge dalla cache `<cartella>/<ateneoId>.json` in un isolate, tenendo
  /// solo ciò che chiede [filtro]. Restituisce il modello (null se il file
  /// non c'è) e l'eventuale errore. Un file illeggibile (troncato, non JSON)
  /// si elimina, così alla prossima richiesta si riscarica.
  Future<(Object?, Object?)> _leggiCache(
    String ateneoId,
    String cartella,
    _Filtro filtro,
  ) async {
    final rel = '$cartella/$ateneoId.json';
    final File f;
    try {
      f = await _cacheFile(rel);
      if (!await f.exists()) return (null, null);
    } catch (_) {
      return (null, null);
    }
    try {
      return (await _leggiInIsolate(f.path, cartella, filtro), null);
    } catch (e) {
      if (e is FormatException || e is CatalogFormatException) {
        await _eliminaSilenzioso(f);
        _tentati.remove(rel);
        _recenti.remove(ateneoId);
        if (cartella == 'corsi') _corsiRecenti.remove(ateneoId);
      }
      return (null, e);
    }
  }

  /// Asset dell'ateneo (solo nelle build locali complete): `<file>` o
  /// `<file>.gz`, decodificati fuori dal thread dell'interfaccia.
  Future<Object?> _leggiAsset(
    String relative,
    String cartella,
    _Filtro filtro,
  ) async {
    try {
      final text = await _assetLoader('$kCatalogAssetDir/$relative');
      return await _testoInIsolate(text, cartella, filtro);
    } catch (_) {}
    try {
      final gz = await _assetBytesLoader('$kCatalogAssetDir/$relative.gz');
      return await _gzInIsolate(gz, cartella, filtro);
    } catch (_) {
      return null;
    }
  }

  /// Un file dell'ateneo [ateneoId] nella [cartella]: rete (se [remote]) →
  /// cache → asset. Se manca ovunque e [scarica], si scarica da internet
  /// (una volta per sessione, non se l'ultimo download l'ha trovato assente
  /// nel database): così i chiamanti che leggono la copia salvata
  /// funzionano anche se lo studente non ha ancora scaricato i dati.
  Future<CatalogResult<T>?> _loadAteneo<T>(
    String ateneoId,
    String cartella, {
    required bool remote,
    bool scarica = true,
    _Filtro filtro = _senzaFiltro,
  }) async {
    final relative = '$cartella/$ateneoId.json';
    Object? error;
    if (remote) {
      try {
        await _scaricaFile(ateneoId, cartella);
        final (data, e) = await _leggiCache(ateneoId, cartella, filtro);
        if (data is T) return CatalogResult(data, CatalogSource.remote);
        error = e;
      } catch (e) {
        error = e;
      } finally {
        // (non durante il download di tutto l'ateneo: lo chiude quello)
        if (!_inCorso.containsKey(ateneoId)) progresso.value = null;
      }
    }
    final (cached, e) = await _leggiCache(ateneoId, cartella, filtro);
    if (cached is T) {
      return CatalogResult(cached, CatalogSource.cache, error: error);
    }
    error ??= e;
    final bundled = await _leggiAsset(relative, cartella, filtro);
    if (bundled is T) {
      return CatalogResult(bundled, CatalogSource.bundled, error: error);
    }
    if (remote || !scarica) return null;
    // download dell'ateneo già in corso: si aspetta quello
    final inCorso = _inCorso[ateneoId];
    if (inCorso != null) {
      await inCorso.f;
      return _loadAteneo(
        ateneoId,
        cartella,
        remote: false,
        scarica: false,
        filtro: filtro,
      );
    }
    if (!await _cacheDisponibile() || _tentati.contains(relative)) return null;
    final registro = await _registro();
    if (registro?.ateneoId == ateneoId &&
        registro!.assenti.contains(relative)) {
      return null;
    }
    return _loadAteneo(ateneoId, cartella, remote: true, filtro: filtro);
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

  /// Corsi e insegnamenti di un ateneo: prova la rete (se [remote]), poi
  /// la copia salvata; se manca la scarica (con [scarica]). null se non
  /// disponibile (es. offline al primo uso). Con [corso] il risultato
  /// contiene solo quel corso di laurea: gli altri non restano mai in
  /// memoria (i file dei grandi atenei superano i 50 MB).
  Future<CatalogResult<CorsiAteneo>?> corsiAteneo(
    String ateneoId, {
    bool remote = true,
    bool scarica = true,
    String? corso,
  }) => _loadAteneo(
    ateneoId,
    'corsi',
    remote: remote,
    scarica: scarica,
    filtro: (corso: corso, insegnamenti: null),
  );

  /// Sessioni d'esame dell'ateneo (calendari ufficiali): rete se
  /// [remote], poi la copia salvata (scaricata se manca).
  Future<CatalogResult<SessioniAteneo>?> sessioni(
    String ateneoId, {
    bool remote = false,
    bool scarica = true,
  }) => _loadAteneo(ateneoId, 'sessioni', remote: remote, scarica: scarica);

  /// Moduli di studio proposti per gli insegnamenti dell'ateneo; con
  /// [insegnamenti] (id) solo i loro.
  Future<CatalogResult<ModuliAteneo>?> moduli(
    String ateneoId, {
    bool remote = false,
    bool scarica = true,
    Iterable<String>? insegnamenti,
  }) => _loadAteneo(
    ateneoId,
    'moduli',
    remote: remote,
    scarica: scarica,
    filtro: (corso: null, insegnamenti: insegnamenti?.toSet()),
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

  // ---------------------------------------------------- dati dell'ateneo

  Future<_Registro?> _registro() async {
    final text = await _readCache(_registroFile);
    if (text == null) return null;
    try {
      return _Registro.fromJson(jsonDecode(text));
    } catch (_) {
      return null;
    }
  }

  /// Scarica da internet i dati dell'ateneo scelto (corsi, sessioni,
  /// moduli; con [soloCorsi] solo i corsi, per esempio per la scelta del
  /// percorso nell'onboarding) nella cache, aggiornando [progresso].
  ///
  /// Con [meta] (`meta.json` online, scaricato se non passato) riscarica
  /// solo ciò che è cambiato: i corsi se l'impronta sha256 è diversa, gli
  /// altri file se è cambiata la versione del database. Un file assente nel
  /// database (404) si ricorda, così non si richiede a ogni lettura. Senza
  /// rete restano le copie già salvate ([AteneoScaricato.senzaRete] se
  /// manca anche quella dei corsi). Con [pulisci] (e i corsi disponibili)
  /// elimina dalla cache i file degli altri atenei. Un download fatto da
  /// meno di 15 minuti non si ripete, salvo [forza]. Chiamate contemporanee
  /// per lo stesso ateneo aspettano lo stesso download (un secondo tocco o
  /// un ritorno al riepilogo non ne avviano un altro). Non lancia.
  Future<AteneoScaricato> scaricaAteneo(
    String ateneoId, {
    DatabaseMeta? meta,
    bool pulisci = true,
    bool forza = false,
    bool soloCorsi = false,
  }) async {
    AteneoScaricato r;
    try {
      final recente = _recenti[ateneoId];
      if (!forza &&
          recente != null &&
          DateTime.now().difference(recente.$1) < _validitaRecente) {
        r = recente.$2;
      } else {
        r = await _accoda(ateneoId, meta, soloCorsi: soloCorsi, forza: forza);
      }
      if (pulisci && r.corsi) await eliminaAltriAtenei(ateneoId);
    } catch (e) {
      r = AteneoScaricato(ateneoId: ateneoId, errore: e);
    }
    return r;
  }

  static const _validitaRecente = Duration(minutes: 15);

  /// Un download dell'ateneo alla volta: se ce n'è già uno che copre la
  /// richiesta (completo, o anche solo dei corsi se bastano quelli) si
  /// aspetta quello; altrimenti il nuovo parte quando finisce il precedente.
  Future<AteneoScaricato> _accoda(
    String id,
    DatabaseMeta? meta, {
    required bool soloCorsi,
    required bool forza,
  }) {
    final c = _inCorso[id];
    if (c != null && (c.completo || soloCorsi)) return c.f;
    final prima = c?.f;
    late final Future<AteneoScaricato> f;
    f = () async {
      if (prima != null) await prima;
      return _scarica(id, meta, soloCorsi: soloCorsi, forza: forza);
    }().whenComplete(() {
      if (identical(_inCorso[id]?.f, f)) _inCorso.remove(id);
    });
    _inCorso[id] = (f: f, completo: !soloCorsi);
    return f;
  }

  Future<AteneoScaricato> _scarica(
    String id,
    DatabaseMeta? meta, {
    required bool soloCorsi,
    required bool forza,
  }) async {
    meta ??= await remoteMeta();
    final prima = await _registro();
    final stessoAteneo = prima?.ateneoId == id;
    final stessaVersione =
        stessoAteneo && meta?.versione != null && prima!.versione == meta!.versione;
    final shaOnline = meta?.atenei[id]?.sha256;
    var shaCorsi = stessoAteneo ? prima!.sha256Corsi : null;
    // corsi scaricati da soli pochi minuti fa (scelta del percorso)
    final corsiRecenti = _corsiRecenti[id];
    final corsiAppena =
        !forza &&
        corsiRecenti != null &&
        DateTime.now().difference(corsiRecenti.$1) < _validitaRecente;
    final file = soloCorsi ? kFileAteneo.take(1).toList() : kFileAteneo;
    final assenti = <String>{
      // download dei soli corsi: per gli altri file vale il registro
      if (soloCorsi && stessoAteneo)
        for (final a in prima!.assenti)
          if (!a.startsWith('corsi/')) a,
    };
    var scaricati = 0, invariati = 0, byte = 0;
    var corsi = false, corsiAggiornati = false, corsiAssenti = false;
    Object? errore;
    try {
      for (final (i, f) in file.indexed) {
        final rel = '${f.cartella}/$id.json';
        final isCorsi = i == 0;
        final presente = await _inCache(rel);
        // già aggiornato sul dispositivo: non si riscarica
        final aggiornato =
            presente &&
            ((isCorsi && corsiAppena) ||
                (isCorsi && shaOnline != null
                    ? shaOnline == shaCorsi
                    : stessaVersione));
        if (aggiornato) {
          invariati++;
          if (isCorsi) {
            corsi = corsiAggiornati = true;
            if (corsiAppena) shaCorsi = corsiRecenti.$2;
          }
          continue;
        }
        if (!presente && stessaVersione && prima.assenti.contains(rel)) {
          assenti.add(rel);
          invariati++;
          continue;
        }
        try {
          final (n, sha) = await _scaricaFile(
            id,
            f.cartella,
            indice: i + 1,
            totale: file.length,
            prima: byte,
          );
          byte += n;
          scaricati++;
          if (isCorsi) {
            corsi = corsiAggiornati = true;
            shaCorsi = sha;
          }
        } on CatalogNotFoundException {
          // non c'è (più) nel database: niente copia vecchia
          assenti.add(rel);
          await _deleteCache(rel);
          if (isCorsi) {
            corsiAssenti = true;
            shaCorsi = null;
          }
        } catch (e) {
          errore ??= e;
          if (isCorsi && presente) corsi = true; // resta la copia salvata
          // offline: inutile provare gli altri file
          if (erroreDiRete(e)) {
            for (final g in file.skip(i + 1)) {
              _tentati.add('${g.cartella}/$id.json');
            }
            break;
          }
        }
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
            // con errori la versione non si segna: si ricontrolla tutto; coi
            // soli corsi resta quella degli altri file già sul dispositivo
            versione: errore != null
                ? null
                : soloCorsi
                ? (stessaVersione ? prima.versione : null)
                : meta?.versione,
            scaricatoIl: DateTime.now(),
            sha256Corsi: shaCorsi,
            assenti: assenti,
          ).toJson(),
        ),
      );
    }
    final r = AteneoScaricato(
      ateneoId: id,
      scaricati: scaricati,
      invariati: invariati,
      byte: byte,
      corsi: corsi,
      corsiAggiornati: corsiAggiornati,
      corsiAssenti: corsiAssenti,
      errore: errore,
    );
    if (errore == null && !soloCorsi) _recenti[id] = (DateTime.now(), r);
    return r;
  }

  /// Elimina dalla cache i file per ateneo diversi da [ateneoId] (cambio
  /// d'ateneo: l'app resta leggera). I file comuni restano, e anche i
  /// download in corso di [ateneoId] (`<id>.json.part`).
  Future<void> eliminaAltriAtenei(String ateneoId) async {
    try {
      final dir = await _cacheDir();
      // una tantum: la cartella dei gruppi degli studenti, non più usata
      final vecchia = Directory(p.join(dir.path, 'community'));
      if (await vecchia.exists()) await vecchia.delete(recursive: true);
      for (final f in kFileAteneo) {
        final d = Directory(p.join(dir.path, f.cartella));
        if (!await d.exists()) continue;
        await for (final e in d.list()) {
          if (e is File && !p.basename(e.path).startsWith('$ateneoId.json')) {
            await _eliminaSilenzioso(e);
          }
        }
      }
      _recenti.removeWhere((k, _) => k != ateneoId);
      _corsiRecenti.removeWhere((k, _) => k != ateneoId);
      final r = await _registro();
      if (r != null && r.ateneoId != ateneoId) {
        await _deleteCache(_registroFile);
      }
    } catch (_) {
      // la pulizia è facoltativa
    }
  }

  /// Dati di [ateneoId] presenti sul dispositivo (senza rete).
  Future<AteneoSulDispositivo> datiAteneo(String ateneoId) async {
    var byte = 0;
    for (final f in kFileAteneo) {
      try {
        final file = await _cacheFile('${f.cartella}/$ateneoId.json');
        if (await file.exists()) byte += await file.length();
      } catch (_) {}
    }
    // negli asset (build locali complete) basta che il file compresso ci
    // sia: niente decompressione a ogni apertura delle Impostazioni
    final corsi =
        await _inCache('corsi/$ateneoId.json') ||
        await _assetBytesLoader(
          '$kCatalogAssetDir/corsi/$ateneoId.json.gz',
        ).then((_) => true, onError: (_) => false);
    final r = await _registro();
    final stesso = r?.ateneoId == ateneoId;
    return AteneoSulDispositivo(
      ateneoId: ateneoId,
      corsi: corsi,
      byte: byte,
      versione: stesso ? r!.versione : null,
      scaricatoIl: stesso ? r!.scaricatoIl : null,
    );
  }

  // ------------------------------------------------------------ download

  /// Scaricamento con dart:io HttpClient, timeout e limite di 200 MB (i
  /// corsi degli atenei più grandi superano i 45 MB; in trasferimento sono
  /// compressi con gzip e HttpClient li decomprime da solo).
  static CatalogFetcher defaultFetcher({
    Duration timeout = const Duration(seconds: 30),
    int maxBytes = 200 * 1024 * 1024,
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
      final builder = BytesBuilder(copy: false);
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

  /// Come [defaultFetcher] ma scrive a pezzi direttamente in `dest` (file
  /// grandi dell'ateneo): in memoria resta solo il pezzo in arrivo, con
  /// la contropressione del disco ([IOSink.addStream]).
  static CatalogFileFetcher defaultFileFetcher({
    Duration timeout = const Duration(seconds: 30),
    int maxBytes = 200 * 1024 * 1024,
  }) => (Uri uri, File dest, {CatalogByteProgress? onProgress}) async {
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout;
    IOSink? sink;
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
      sink = dest.openWrite();
      await sink.addStream(
        response.timeout(timeout).map((chunk) {
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
          // al massimo un aggiornamento ogni 256 KB
          if (onProgress != null && ricevuti - avvisati >= 256 * 1024) {
            avvisati = ricevuti;
            onProgress(ricevuti, attesi);
          }
          return c;
        }),
      );
      final s = sink;
      sink = null;
      await s.close();
      onProgress?.call(ricevuti, attesi);
      return ricevuti;
    } on SocketException {
      throw CatalogOfflineException();
    } on HttpException {
      throw CatalogOfflineException('Connessione interrotta.');
    } on TimeoutException {
      throw CatalogOfflineException('Tempo scaduto durante il download.');
    } finally {
      if (sink != null) {
        try {
          await sink.close();
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
  /// lettura dei dati dell'ateneo.
  static String descriviErrore(Object? e) {
    if (e == null || erroreDiRete(e)) return kServeConnessione;
    if (e is FileSystemException) {
      return 'Non riesco a salvare i dati del tuo ateneo sul dispositivo: '
          'controlla lo spazio libero e riprova.';
    }
    if (e is FormatException || e is CatalogFormatException) {
      return 'Il file del tuo ateneo è arrivato incompleto o non valido: '
          'riprova.';
    }
    if (e is CatalogException) return e.message;
    return 'Download dei dati del tuo ateneo non riuscito: riprova.';
  }
}

// ------------------------------------------- lettura fuori dal thread UI

/// Cosa tenere leggendo un file per ateneo: solo il corso di laurea
/// [corso] (file dei corsi) o solo gli [insegnamenti] (file dei moduli);
/// null = tutto.
typedef _Filtro = ({String? corso, Set<String>? insegnamenti});

const _Filtro _senzaFiltro = (corso: null, insegnamenti: null);

/// Testi più corti si decodificano subito, senza avviare un isolate.
const _sogliaIsolate = 256 * 1024;

/// Reviver della decodifica: scarta appena letti i rami che non servono,
/// così anche di un file di decine di MB resta in memoria solo il
/// necessario. Con [soloRadice] tiene solo i campi semplici della radice
/// (controllo di un file scaricato: sintassi completa, memoria minima).
Object? Function(Object? key, Object? value)? _reviver(
  _Filtro f, {
  bool soloRadice = false,
}) {
  if (soloRadice) {
    return (k, v) => k == null || (v is! Map && v is! List) ? v : null;
  }
  final corso = f.corso, ins = f.insegnamenti;
  if (corso != null) {
    // elementi della lista `corsi`: gli unici oggetti con `insegnamenti`
    return (k, v) =>
        k is int && v is Map && v.containsKey('insegnamenti') && v['id'] != corso
        ? null
        : v;
  }
  if (ins != null) {
    // voci di `insegnamenti` (chiave: id dell'insegnamento)
    return (k, v) =>
        k is String &&
            v is Map &&
            (v.containsKey('moduli') || v.containsKey('programma')) &&
            !ins.contains(k)
        ? null
        : v;
  }
  return null;
}

Object _modello(String cartella, Object? json) => switch (cartella) {
  'corsi' => CorsiAteneo.fromJson(json),
  'sessioni' => SessioniAteneo.fromJson(json),
  'moduli' => ModuliAteneo.fromJson(json),
  _ => throw CatalogException('Cartella del database sconosciuta: $cartella'),
};

/// Ultimo valore ricevuto da una conversione a pezzi.
class _Ultimo<T> implements Sink<T> {
  T? value;
  @override
  void add(T data) => value = data;
  @override
  void close() {}
}

/// Decodifica il JSON del file [path] a pezzi (byte → oggetti, senza
/// passare da un'unica stringa), con l'impronta sha256 dei byte se
/// [impronta].
Future<(Object?, String?)> _decodificaFile(
  String path,
  Object? Function(Object? key, Object? value)? reviver, {
  bool impronta = false,
}) async {
  final out = _Ultimo<Object?>();
  final json = utf8.decoder
      .fuse(JsonDecoder(reviver))
      .startChunkedConversion(out);
  final digest = _Ultimo<crypto.Digest>();
  final hash = impronta ? crypto.sha256.startChunkedConversion(digest) : null;
  await for (final chunk in File(path).openRead()) {
    hash?.add(chunk);
    json.add(chunk);
  }
  hash?.close();
  json.close();
  return (out.value, digest.value?.toString());
}

/// Legge il file della cache [path] in un isolate e restituisce il modello
/// (filtrato con [f]); gli errori (file troncato…) arrivano al chiamante.
Future<Object> _leggiInIsolate(String path, String cartella, _Filtro f) =>
    Isolate.run(() async {
      final (json, _) = await _decodificaFile(path, _reviver(f));
      return _modello(cartella, json);
    });

/// Controlla in un isolate il file appena scaricato [path] (JSON completo e
/// radice valida) e ne restituisce l'impronta sha256.
Future<String> _controllaInIsolate(String path, String cartella) =>
    Isolate.run(() async {
      final (json, sha) = await _decodificaFile(
        path,
        _reviver(_senzaFiltro, soloRadice: true),
        impronta: true,
      );
      _modello(cartella, json);
      return sha!;
    });

/// Asset di testo: in un isolate se è grande.
Future<Object> _testoInIsolate(String text, String cartella, _Filtro f) {
  Object leggi() => _modello(cartella, JsonDecoder(_reviver(f)).convert(text));
  if (text.length < _sogliaIsolate) return Future.value(leggi());
  return Isolate.run(leggi);
}

/// Asset compresso (`.json.gz`): decompressione e decodifica in un isolate.
Future<Object> _gzInIsolate(Uint8List gz, String cartella, _Filtro f) =>
    Isolate.run(
      () => _modello(
        cartella,
        utf8.decoder.fuse(JsonDecoder(_reviver(f))).convert(gzip.decode(gz)),
      ),
    );
