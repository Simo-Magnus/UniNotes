import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
class CatalogService {
  CatalogService(
    this._settings, {
    CatalogFetcher? fetcher,
    CatalogAssetLoader? assetLoader,
    CatalogAssetBytesLoader? assetBytesLoader,
    Future<Directory> Function()? cacheDir,
    this.timeout = const Duration(seconds: 30),
  }) : _fetcher = fetcher ?? defaultFetcher(timeout: timeout),
       _assetLoader = assetLoader ?? rootBundle.loadString,
       _assetBytesLoader = assetBytesLoader ?? _rootBundleBytes,
       _cacheDir = cacheDir ?? _defaultCacheDir;

  final SettingsRepository _settings;
  final CatalogFetcher _fetcher;
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

  /// Download completi recenti (l'onboarding scarica nel riepilogo e
  /// l'import subito dopo non riscarica) e download in corso.
  final Map<String, (DateTime, AteneoScaricato)> _recenti = {};
  final Map<String, Future<AteneoScaricato>> _inCorso = {};

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

  Future<void> _writeCache(String relative, String text) async {
    try {
      final f = await _cacheFile(relative);
      await f.parent.create(recursive: true);
      await f.writeAsString(text, flush: true);
    } catch (_) {
      // La cache è facoltativa (es. disco pieno): si continua senza.
    }
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

  /// Scarica [relative]; con [ateneoId] aggiorna [progresso] (file [indice]
  /// di [totale], dopo [prima] byte già ricevuti). Restituisce il testo e i
  /// byte ricevuti.
  Future<(String, int)> _download(
    String relative, {
    String? ateneoId,
    String etichetta = '',
    int indice = 1,
    int totale = 1,
    int prima = 0,
  }) async {
    var ricevuti = 0;
    void avanza(int r, int? attesi) {
      ricevuti = r;
      if (ateneoId == null) return;
      progresso.value = CatalogProgress(
        ateneoId: ateneoId,
        etichetta: etichetta,
        indice: indice,
        totale: totale,
        ricevuti: r,
        attesi: attesi,
        ricevutiPrima: prima,
      );
    }

    avanza(0, null);
    final text = await _fetcher(await _url(relative), onProgress: avanza);
    return (text, ricevuti > 0 ? ricevuti : text.length);
  }

  /// Legge [relative] con la precedenza rete → cache → asset e lo converte
  /// con [parse]. Un file scaricato ma non valido non sostituisce la cache.
  Future<CatalogResult<T>?> _load<T>(
    String relative,
    T Function(Object? json) parse, {
    required bool remote,
    String? ateneoId,
    String etichetta = '',
  }) async {
    Object? error;
    if (remote) {
      try {
        final (text, _) = await _download(
          relative,
          ateneoId: ateneoId,
          etichetta: etichetta,
        );
        final data = parse(jsonDecode(text));
        await _writeCache(relative, text);
        return CatalogResult(data, CatalogSource.remote);
      } catch (e) {
        error = e;
      } finally {
        if (ateneoId != null) progresso.value = null;
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

  /// Un file dell'ateneo [ateneoId] nella [cartella]: rete (se [remote]) →
  /// cache → asset. Se manca ovunque e [scarica], si scarica da internet
  /// (una volta per sessione, non se l'ultimo download l'ha trovato assente
  /// nel database): così i chiamanti che leggono la copia salvata
  /// funzionano anche se lo studente non ha ancora scaricato i dati.
  Future<CatalogResult<T>?> _loadAteneo<T>(
    String ateneoId,
    String cartella,
    T Function(Object? json) parse, {
    required bool remote,
    bool scarica = true,
  }) async {
    final relative = '$cartella/$ateneoId.json';
    final etichetta = kFileAteneo
        .firstWhere(
          (f) => f.cartella == cartella,
          orElse: () => (cartella: cartella, etichetta: cartella),
        )
        .etichetta;
    if (remote) _tentati.add(relative);
    final r = await _load(
      relative,
      parse,
      remote: remote,
      ateneoId: ateneoId,
      etichetta: etichetta,
    );
    if (r != null || remote || !scarica) return r;
    // download dell'ateneo già in corso: si aspetta quello
    final inCorso = _inCorso[ateneoId];
    if (inCorso != null) {
      await inCorso;
      return _load(relative, parse, remote: false);
    }
    if (!await _cacheDisponibile() || !_tentati.add(relative)) return null;
    final registro = await _registro();
    if (registro?.ateneoId == ateneoId &&
        registro!.assenti.contains(relative)) {
      return null;
    }
    return _load(
      relative,
      parse,
      remote: true,
      ateneoId: ateneoId,
      etichetta: etichetta,
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

  /// Corsi e insegnamenti di un ateneo: prova la rete (se [remote]), poi
  /// la copia salvata; se manca la scarica (con [scarica]). null se non
  /// disponibile (es. offline al primo uso).
  Future<CatalogResult<CorsiAteneo>?> corsiAteneo(
    String ateneoId, {
    bool remote = true,
    bool scarica = true,
  }) => _loadAteneo(
    ateneoId,
    'corsi',
    CorsiAteneo.fromJson,
    remote: remote,
    scarica: scarica,
  );

  /// Sessioni d'esame dell'ateneo (calendari ufficiali): rete se
  /// [remote], poi la copia salvata (scaricata se manca).
  Future<CatalogResult<SessioniAteneo>?> sessioni(
    String ateneoId, {
    bool remote = false,
    bool scarica = true,
  }) => _loadAteneo(
    ateneoId,
    'sessioni',
    SessioniAteneo.fromJson,
    remote: remote,
    scarica: scarica,
  );

  /// Moduli di studio proposti per gli insegnamenti dell'ateneo.
  Future<CatalogResult<ModuliAteneo>?> moduli(
    String ateneoId, {
    bool remote = false,
    bool scarica = true,
  }) => _loadAteneo(
    ateneoId,
    'moduli',
    ModuliAteneo.fromJson,
    remote: remote,
    scarica: scarica,
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
  /// moduli) nella cache, aggiornando [progresso].
  ///
  /// Con [meta] (`meta.json` online, scaricato se non passato) riscarica
  /// solo ciò che è cambiato: i corsi se l'impronta sha256 è diversa, gli
  /// altri file se è cambiata la versione del database. Un file assente nel
  /// database (404) si ricorda, così non si richiede a ogni lettura. Senza
  /// rete restano le copie già salvate ([AteneoScaricato.senzaRete] se
  /// manca anche quella dei corsi). Con [pulisci] (e i corsi disponibili)
  /// elimina dalla cache i file degli altri atenei. Un download completo
  /// fatto da meno di 15 minuti non si ripete, salvo [forza]. Non lancia.
  Future<AteneoScaricato> scaricaAteneo(
    String ateneoId, {
    DatabaseMeta? meta,
    bool pulisci = true,
    bool forza = false,
  }) async {
    final recente = _recenti[ateneoId];
    final AteneoScaricato r;
    if (!forza &&
        recente != null &&
        DateTime.now().difference(recente.$1) < const Duration(minutes: 15)) {
      r = recente.$2;
    } else {
      // (la callback non restituisce il Future rimosso: whenComplete
      // aspetterebbe sé stesso)
      r = await (_inCorso[ateneoId] ??= _scarica(ateneoId, meta).whenComplete(
        () {
          _inCorso.remove(ateneoId);
        },
      ));
    }
    if (pulisci && r.corsi) await eliminaAltriAtenei(ateneoId);
    return r;
  }

  Future<AteneoScaricato> _scarica(String id, DatabaseMeta? meta) async {
    meta ??= await remoteMeta();
    final prima = await _registro();
    final stessoAteneo = prima?.ateneoId == id;
    final stessaVersione =
        stessoAteneo && meta?.versione != null && prima!.versione == meta!.versione;
    final shaOnline = meta?.atenei[id]?.sha256;
    var shaCorsi = stessoAteneo ? prima!.sha256Corsi : null;
    final assenti = <String>{};
    var scaricati = 0, invariati = 0, byte = 0;
    var corsi = false, corsiAggiornati = false, corsiAssenti = false;
    Object? errore;
    try {
      for (final (i, f) in kFileAteneo.indexed) {
        final rel = '${f.cartella}/$id.json';
        final isCorsi = i == 0;
        final presente = await _inCache(rel);
        // già aggiornato sul dispositivo: non si riscarica
        final aggiornato =
            presente &&
            (isCorsi && shaOnline != null
                ? shaOnline == shaCorsi
                : stessaVersione);
        if (aggiornato) {
          invariati++;
          if (isCorsi) corsi = corsiAggiornati = true;
          continue;
        }
        if (!presente && stessaVersione && prima.assenti.contains(rel)) {
          assenti.add(rel);
          invariati++;
          continue;
        }
        _tentati.add(rel);
        try {
          final (text, n) = await _download(
            rel,
            ateneoId: id,
            etichetta: f.etichetta,
            indice: i + 1,
            totale: kFileAteneo.length,
            prima: byte,
          );
          _parser(f.cartella)(jsonDecode(text));
          await _writeCache(rel, text);
          byte += n;
          scaricati++;
          if (isCorsi) {
            corsi = corsiAggiornati = true;
            shaCorsi = crypto.sha256.convert(utf8.encode(text)).toString();
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
            for (final g in kFileAteneo.skip(i + 1)) {
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
            // con errori la versione non si segna: si ricontrolla tutto
            versione: errore == null ? meta?.versione : null,
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
    if (errore == null) _recenti[id] = (DateTime.now(), r);
    return r;
  }

  /// Controllo del file scaricato (un errore lascia la copia precedente).
  static Object Function(Object? json) _parser(String cartella) =>
      switch (cartella) {
        'corsi' => CorsiAteneo.fromJson,
        'sessioni' => SessioniAteneo.fromJson,
        'moduli' => ModuliAteneo.fromJson,
        _ => (json) => json!,
      };

  /// Elimina dalla cache i file per ateneo diversi da [ateneoId] (cambio
  /// d'ateneo: l'app resta leggera). I file comuni restano.
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
          if (e is File && p.basename(e.path) != '$ateneoId.json') {
            await e.delete();
          }
        }
      }
      _recenti.removeWhere((k, _) => k != ateneoId);
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
}
