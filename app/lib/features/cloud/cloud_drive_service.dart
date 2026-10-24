import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../core/services/loopback_oauth.dart';
import '../../core/services/power.dart';
import '../../repositories/settings_repository.dart';
import '../notes/notes_store.dart';
import 'data_sync.dart';
import 'folder_sync.dart';

/// Segreti degli account cloud (refresh token), nel portachiavi.
abstract class CloudSecrets {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureCloudSecrets implements CloudSecrets {
  SecureCloudSecrets([FlutterSecureStorage? s])
    : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryCloudSecrets implements CloudSecrets {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// Cosa si sincronizza (caselle in Collegamenti → OneDrive / Google Drive).
enum SyncScope {
  /// Dati dell'app (database): sessioni di Studio, moduli e argomenti,
  /// esami, voti, insegnamenti… uniti fra i dispositivi ([DataSync]).
  data('Dati dell\'app: Studio, esami, voti, insegnamenti', 'Dati'),
  recordings('Registrazioni delle lezioni', 'Corsi'),
  notes('Trascrizioni, riassunti e appunti', 'Corsi'),
  books(
    'Libri e materiale didattico copiati nell\'app, con le evidenziazioni',
    'Libri',
  ),
  attachments('Allegati di Studio (moduli e argomenti)', 'Allegati'),
  backup('Backup del database (copia per dispositivo)', 'Backup');

  const SyncScope(this.label, this.remoteDir);
  final String label;

  /// Sottocartella nella cartella cloud dell'app.
  final String remoteDir;

  /// Segno della casella «Dati» tolta a mano (chi aveva già scelto le
  /// caselle prima che esistesse la trova accesa).
  static const _noData = '-data';

  static Set<SyncScope> parse(String? v) {
    if (v == null) return SyncScope.values.toSet();
    final names = {for (final s in v.split(',')) s.trim()};
    return {
      for (final x in values)
        if (names.contains(x.name) ||
            (x == SyncScope.data && !names.contains(_noData)))
          x,
    };
  }

  static String encode(Set<SyncScope> s) => [
    for (final x in values)
      if (s.contains(x)) x.name,
    if (!s.contains(SyncScope.data)) _noData,
  ].join(',');
}

/// Cartelle locali delle parti sincronizzate oltre agli appunti (libri,
/// materiali, allegati) e backup JSON del database.
class SyncSources {
  const SyncSources({
    this.books,
    this.materials,
    this.attachments,
    this.backupJson,
    this.changeCounter,
    this.recordingInProgress,
    this.data,
    this.highlights,
    this.onChanged,
  });

  /// Evidenziazioni dei PDF (una per documento, cartella `evidenziazioni`).
  final Future<Directory> Function()? highlights;

  /// Dopo una sincronizzazione che ha portato o tolto file (libri,
  /// materiali, allegati, appunti…): le schermate aperte si aggiornano,
  /// qualunque sezione sia aperta.
  final void Function()? onChanged;

  /// Unione dei dati dell'app con gli altri dispositivi (casella «Dati»).
  final DataSync? data;
  final Future<Directory> Function()? books;
  final Future<Directory> Function()? materials;
  final Future<Directory> Function()? attachments;

  /// Esportazione JSON dei dati personali (BackupService.exportJson).
  final Future<String> Function()? backupJson;

  /// Numero di modifiche al database da quando l'app è aperta: se non è
  /// cambiato dall'ultimo backup non si riesporta nulla.
  final Future<int> Function()? changeCounter;

  /// Percorso della registrazione in corso (si sincronizza solo a fine
  /// registrazione: prima il file è incompleto).
  final String? Function()? recordingInProgress;
}

/// Una cartella locale sincronizzata con una sottocartella sul servizio.
class SyncTarget {
  const SyncTarget(this.key, this.local, this.remote, {this.include});
  final String key;
  final Directory local;
  final String remote;
  final bool Function(String rel)? include;
}

/// Sincronizzazione di tutto ciò che l'app crea con un servizio cloud
/// (OneDrive, Google Drive): account, cartella, cosa sincronizzare, backup
/// e controlli automatici sono comuni; ogni servizio aggiunge l'accesso e il
/// motore ([engine]).
///
/// Nella cartella scelta (predefinita «UniNotes») l'app tiene:
/// `Corsi/` (registrazioni, trascrizioni, riassunti, appunti per corso),
/// `Libri/`, `Materiali/`, `Allegati/` e `Backup/`. La sincronizzazione è
/// bidirezionale: le novità dell'app vanno sul servizio e quelle aggiunte o
/// modificate lì arrivano nell'app all'avvio, ogni N minuti, al ritorno
/// nell'app e quando torna la connessione.
abstract class CloudDriveService extends ChangeNotifier {
  CloudDriveService(
    this.settings,
    this.notes, {
    CloudSecrets? secrets,
    Future<Directory> Function()? stateDir,
    this.sources = const SyncSources(),
    String? deviceName,
  }) : secrets = secrets ?? SecureCloudSecrets(),
       stateDir = stateDir ?? getApplicationSupportDirectory,
       deviceName = deviceName ?? _defaultDevice();

  final SettingsRepository settings;
  final NotesStore notes;
  final CloudSecrets secrets;
  final SyncSources sources;
  final String deviceName;
  final Future<Directory> Function() stateDir;

  /// Nome mostrato («OneDrive», «Google Drive»).
  String get serviceName;

  /// Messaggio quando la sincronizzazione non parte o si interrompe per
  /// mancanza di connessione ([isNetworkError]).
  String get offlineMessage =>
      'Serve una connessione a internet per sincronizzare con $serviceName.';

  /// Prefisso delle impostazioni e dei file di stato («onedrive», «gdrive»).
  String get prefix;

  static const defaultFolder = 'UniNotes';
  static const defaultInterval = 10;
  static const intervals = [2, 5, 10, 15, 30, 60];

  /// Libri tenuti solo su questo dispositivo: vale per tutti i servizi.
  static const booksLocalOnlyKey = 'onedrive_books_local_only';

  String get refreshKey => '$prefix.refreshToken';
  String get folderKey => '${prefix}_folder';
  String get accountKey => '${prefix}_account';
  String get lastResultKey => '${prefix}_last_result';
  String get scopesKey => '${prefix}_scopes';
  String get intervalKey => '${prefix}_interval_minutes';
  String get lastSyncAtKey => '${prefix}_last_sync_at';
  String get wifiOnlyKey => '${prefix}_recordings_wifi_only';

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  static String _defaultDevice() {
    if (Platform.isAndroid || Platform.isIOS) return 'telefono';
    if (Platform.isMacOS) return 'Mac';
    return 'PC';
  }

  OAuthTokens? tokens;
  Timer? _timer;
  int _ticks = 0;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<List<ConnectivityResult>>? _net;
  Timer? _debounce;
  bool _syncing = false;
  String? progress;
  String? lastError;

  bool get syncing => _syncing;

  /// L'ultimo rinnovo dell'accesso è fallito perché scaduto o revocato
  /// (invalid_grant…): serve ricollegarsi (avviso «Collegamento
  /// interrotto»).
  bool authExpired = false;

  // ------------------------------------------------------------- account

  /// Accesso con l'account del servizio (salva refresh token e nome).
  Future<void> signIn();

  /// Nuovo access token dal refresh token salvato.
  Future<OAuthTokens> refreshTokens(String refreshToken);

  /// Motore di sincronizzazione di una parte.
  FolderSync engine(SyncTarget t, Directory state);

  /// Sottocartelle che l'app crea nella sua cartella sul servizio.
  static const appSubfolders = [
    'Dati',
    'Corsi',
    'Libri',
    'Materiali',
    'Allegati',
    'Evidenziazioni',
    'Backup',
  ];

  /// «Elimina tutti i dati» e disinstallazione: toglie dal servizio solo ciò
  /// che l'app ha creato, cioè le sue sottocartelle ([appSubfolders]) nella
  /// cartella scelta e, se poi resta vuota, la cartella stessa quando è
  /// quella dell'app («UniNotes» o il nome precedente). Altri file messi lì
  /// dall'utente restano. Tutto finisce nel cestino del servizio
  /// (recuperabile per circa 30 giorni). Restituisce le cartelle eliminate.
  Future<int> deleteRemoteAppData();

  /// La cartella [base] è quella creata dall'app (non una scelta a mano):
  /// solo questa si elimina quando resta vuota.
  static bool isAppFolder(String base) =>
      base == defaultFolder || base == legacyFolder;

  /// «Scollega»: toglie l'accesso salvato su questo dispositivo e poi, dove
  /// il servizio lo permette ([revoke]), anche presso il servizio. false = la
  /// revoca presso il servizio non è riuscita (senza rete, errore): il
  /// collegamento sul dispositivo è tolto comunque, senza aspettarla.
  Future<bool> signOut() async {
    stopAutoSync();
    String? refresh;
    try {
      refresh = await secrets.read(refreshKey);
    } catch (_) {}
    try {
      await secrets.delete(refreshKey);
    } catch (_) {
      // portachiavi che non risponde (chiave del sistema cambiata, voce
      // rovinata): il collegamento sul dispositivo si toglie lo stesso, non
      // si resta «collegati» senza poter scollegare
    }
    await settings.set(accountKey, null);
    tokens = null;
    notifyListeners();
    onScheduleChanged?.call();
    if (refresh == null || refresh.isEmpty) return true;
    try {
      return await revoke(refresh).timeout(const Duration(seconds: 10));
    } catch (_) {
      return false;
    }
  }

  /// Revoca del refresh token presso il servizio (true = revocato o niente
  /// da revocare). Predefinito: nessuna revoca. Microsoft non revoca un
  /// singolo token di un'app pubblica (`revokeSignInSessions` chiuderebbe
  /// tutte le sessioni dell'utente, su ogni app): la scheda OneDrive dice
  /// dove togliere l'accesso dall'account.
  Future<bool> revoke(String refreshToken) async => true;

  /// Token rifiutato dal servizio (401): il prossimo [accessToken] ne chiede
  /// uno nuovo con il refresh token invece di riusarlo fino alla scadenza.
  void forgetAccessToken() => tokens = null;

  Future<String> accessToken() async {
    final t = tokens;
    if (t != null && t.valid) return t.accessToken;
    final refresh = await secrets.read(refreshKey);
    if (refresh == null) {
      throw OAuthException(
        '$serviceName non collegato (Collegamenti → $serviceName).',
      );
    }
    final OAuthTokens n;
    try {
      n = await refreshTokens(refresh);
    } on OAuthException catch (e) {
      // accesso scaduto o revocato: l'app invita a ricollegarsi
      if (isExpiredGrant(e.message) && !authExpired) {
        authExpired = true;
        notifyListeners();
      }
      rethrow;
    }
    if (authExpired) {
      authExpired = false;
      notifyListeners();
    }
    tokens = n;
    if (n.refreshToken != null && n.refreshToken != refresh) {
      await secrets.write(refreshKey, n.refreshToken!);
    }
    return n.accessToken;
  }

  /// Impostazioni scritte durante l'accesso: tornano come prima se
  /// l'accesso non si completa ([completeSignIn]).
  List<String> get signInKeys => [accountKey];

  /// Accesso atomico: salva [t] ([storeTokens]) e poi esegue [then] (nome
  /// dell'account, cartella dell'app). Se [then] non riesce si torna allo
  /// stato di prima (refresh token e [signInKeys], di solito nessun
  /// collegamento) e l'errore arriva allo studente: l'app non resta
  /// «collegata» con un collegamento a metà.
  Future<void> completeSignIn(
    OAuthTokens t,
    Future<void> Function() then,
  ) async {
    String? prevRefresh;
    try {
      prevRefresh = await secrets.read(refreshKey);
    } catch (_) {}
    final prevSettings = {for (final k in signInKeys) k: await settings.get(k)};
    final prevTokens = tokens;
    final prevExpired = authExpired;
    await storeTokens(t);
    try {
      await then();
    } catch (_) {
      try {
        prevRefresh == null
            ? await secrets.delete(refreshKey)
            : await secrets.write(refreshKey, prevRefresh);
        for (final e in prevSettings.entries) {
          await settings.set(e.key, e.value);
        }
      } catch (_) {}
      tokens = prevTokens;
      authExpired = prevExpired;
      notifyListeners();
      rethrow;
    }
  }

  /// Dopo l'accesso: refresh token nel portachiavi.
  Future<void> storeTokens(OAuthTokens t) async {
    authExpired = false;
    if (t.refreshToken == null) {
      throw OAuthException(
        '$serviceName non ha restituito un token permanente.',
      );
    }
    await secrets.write(refreshKey, t.refreshToken!);
    tokens = t;
  }

  Future<void> setAccount(String who) async {
    await settings.set(accountKey, who.isEmpty ? 'collegato' : who);
    notifyListeners();
  }

  /// Nome predefinito della cartella prima di «UniNotes».
  static const legacyFolder = 'University Notes';

  Future<String> folder() async {
    final chosen = await settings.get(folderKey);
    if (chosen != null && chosen.trim().isNotEmpty) return chosen;
    // Chi sincronizzava già con la vecchia cartella predefinita la tiene
    // (altrimenti i dispositivi aggiornati userebbero una cartella vuota).
    try {
      final dir = await stateDir();
      await for (final e in dir.list()) {
        final name = p.basename(e.path);
        if (e is! File ||
            !name.startsWith('${prefix}_sync_') ||
            !name.endsWith('.json')) {
          continue;
        }
        final m = await _readState(e);
        final remote = m == null ? '' : '${m['remoteFolder'] ?? ''}';
        if (remote == legacyFolder || remote.startsWith('$legacyFolder/')) {
          await settings.set(folderKey, legacyFolder);
          return legacyFolder;
        }
      }
    } catch (_) {}
    return defaultFolder;
  }

  Future<void> setFolder(String v) => settings.set(
    folderKey,
    v.trim().replaceAll(RegExp(r'^[/\\]+|[/\\]+$'), ''),
  );

  // ------------------------------------------------- nome della cartella

  /// «Rinomina»: cambia il nome della cartella dell'app sul servizio (solo
  /// l'ultima parte del percorso; i file restano dove sono) e lo ricorda.
  /// Gli altri dispositivi la ritrovano da soli ([locateMovedFolder]).
  /// Restituisce il nuovo percorso.
  Future<String> renameFolder(String newName) async {
    final n = newName.trim();
    final err = validateFolderName(n);
    if (err != null) throw FormatException(err);
    final old = await folder();
    final cut = old.lastIndexOf('/');
    final next = cut < 0 ? n : '${old.substring(0, cut)}/$n';
    if (next == old) return old;
    await renameRemoteFolder(old, n);
    await moveSyncStates(old, next);
    await setFolder(next);
    notifyListeners();
    return next;
  }

  /// Nome di cartella non valido (null = valido).
  static String? validateFolderName(String name) {
    final n = name.trim();
    if (n.isEmpty) return 'Scrivi un nome.';
    if (RegExp(r'["*:<>?/\\|]').hasMatch(n)) {
      return 'Il nome non può contenere " * : < > ? / \\ |';
    }
    if (n.endsWith('.')) return 'Il nome non può finire con un punto.';
    return null;
  }

  /// Rinomina sul servizio la cartella [path] in [newName] (errore
  /// leggibile se esiste già una cartella con quel nome).
  Future<void> renameRemoteFolder(String path, String newName);

  /// La cartella dell'app [base] non c'è più sul servizio perché è stata
  /// rinominata o spostata (da un altro dispositivo o dal sito): il suo
  /// nuovo percorso, ritrovato dagli id salvati. Null se c'è ancora o non si
  /// ritrova (allora si ricrea come prima).
  Future<String?> locateMovedFolder(String base) async => null;

  /// Il file di stato [f] come mappa; null se è illeggibile (scritto a metà,
  /// di un'altra versione, non JSON): un file rovinato non deve fermare la
  /// lettura degli altri, né far perdere la cartella con cui si sincronizzava.
  static Future<Map<String, Object?>?> _readState(File f) async {
    try {
      final j = jsonDecode(await f.readAsString());
      return j is Map ? j.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  /// Stati della sincronizzazione di [old] spostati su [next] (stessi file,
  /// cartella con un altro nome): niente da rileggere né da ricaricare.
  Future<void> moveSyncStates(String old, String next) async {
    try {
      final dir = await stateDir();
      await for (final e in dir.list()) {
        final name = p.basename(e.path);
        if (e is! File ||
            !name.startsWith('${prefix}_sync_') ||
            !name.endsWith('.json')) {
          continue;
        }
        final m = await _readState(e);
        if (m == null) continue;
        final rf = '${m['remoteFolder'] ?? ''}';
        if (rf != old && !rf.startsWith('$old/')) continue;
        m['remoteFolder'] = '$next${rf.substring(old.length)}';
        await e.writeAsString(jsonEncode(m));
      }
    } catch (_) {}
  }

  /// Stati salvati di questo servizio (per [locateMovedFolder]).
  Future<List<Map<Object?, Object?>>> syncStates() async {
    final out = <Map<Object?, Object?>>[];
    try {
      final dir = await stateDir();
      await for (final e in dir.list()) {
        final name = p.basename(e.path);
        if (e is! File ||
            !name.startsWith('${prefix}_sync_') ||
            !name.endsWith('.json')) {
          continue;
        }
        final m = await _readState(e);
        if (m != null) out.add(m);
      }
    } catch (_) {}
    return out;
  }

  /// Prima sincronizzazione della sessione (e quelle complete): controlla se
  /// la cartella dell'app è stata rinominata altrove.
  bool _folderChecked = false;

  Future<void> _followMovedFolder({required bool force}) async {
    if (_folderChecked && !force) return;
    final base = await folder();
    final moved = await locateMovedFolder(base);
    _folderChecked = true;
    if (moved == null || moved == base) return;
    await moveSyncStates(base, moved);
    await setFolder(moved);
  }

  Future<Set<SyncScope>> scopes() async =>
      SyncScope.parse(await settings.get(scopesKey));
  Future<void> setScopes(Set<SyncScope> s) =>
      settings.set(scopesKey, SyncScope.encode(s));

  /// File dei libri (nomi nella cartella Libri dell'app) da non caricare.
  Future<Set<String>> booksLocalOnly() async => {
    for (final x in (await settings.get(booksLocalOnlyKey) ?? '').split('\n'))
      if (x.trim().isNotEmpty) x.trim(),
  };

  /// «Salva nel cloud» di un libro per tutti i [services] (OneDrive e
  /// Google Drive): la lista dei libri solo locali è comune
  /// ([booksLocalOnlyKey]), la casella «Libri» si riattiva su ognuno.
  static Future<void> setBookInCloudFor(
    Iterable<CloudDriveService> services,
    String storedFile,
    bool inCloud,
  ) async {
    for (final s in services) {
      await s.setBookInCloud(storedFile, inCloud);
    }
  }

  /// «Salva nel cloud» di un libro: [inCloud] false lo tiene solo su questo
  /// dispositivo; true lo rimette nella sincronizzazione (e attiva la
  /// casella «Libri» di questo servizio se era spenta; per tutti i servizi
  /// vedi [setBookInCloudFor]).
  Future<void> setBookInCloud(String storedFile, bool inCloud) async {
    final set = await booksLocalOnly();
    inCloud ? set.remove(storedFile) : set.add(storedFile);
    await settings.set(booksLocalOnlyKey, set.join('\n'));
    if (inCloud) {
      final sc = await scopes();
      if (!sc.contains(SyncScope.books)) {
        await setScopes({...sc, SyncScope.books});
      }
    }
  }

  /// Registrazioni (file grandi) solo con Wi‑Fi o cavo. Predefinito: sì sul
  /// telefono, no sul PC.
  Future<bool> recordingsWifiOnly() async {
    final v = await settings.get(wifiOnlyKey);
    return v == null ? Power.isMobile : v == '1';
  }

  Future<void> setRecordingsWifiOnly(bool v) =>
      settings.set(wifiOnlyKey, v ? '1' : '0');

  Future<int> intervalMinutes() async {
    final v = int.tryParse((await settings.get(intervalKey)) ?? '');
    return (v == null || v < 1) ? defaultInterval : v;
  }

  Future<void> setIntervalMinutes(int m) async {
    await settings.set(intervalKey, '$m');
    if (_timer != null) _restartTimer(m);
    onScheduleChanged?.call();
  }

  /// Collegamento o intervallo cambiati: la sincronizzazione in background
  /// si ripianifica (BackgroundSync, telefono).
  static void Function()? onScheduleChanged;

  /// Una sincronizzazione sta già girando fuori da questo motore (Android:
  /// il lavoro in background avviato ad app chiusa, che continua se nel
  /// frattempo l'app si apre): allora questa aspetta il giro successivo,
  /// così i due non lavorano insieme sugli stessi file. Null = nessuno.
  static Future<bool> Function()? busyElsewhere;

  /// «Elimina tutti i dati» in corso: nessuna sincronizzazione parte
  /// (timer, ritorno nell'app, lavoro periodico di Android che chiede
  /// all'app di sincronizzare). Resta acceso dopo un'eliminazione riuscita:
  /// il database è chiuso e l'app va riaperta.
  static bool hold = false;

  /// Una sincronizzazione gira fuori da questo motore ([busyElsewhere]).
  static Future<bool> busyElsewhereNow() => _busyElsewhere();

  static Future<bool> _busyElsewhere() async {
    final f = busyElsewhere;
    if (f == null) return false;
    try {
      return await f();
    } catch (_) {
      return false;
    }
  }

  /// Nome/indirizzo dell'account collegato (null = non collegato).
  Future<String?> account() => settings.get(accountKey);
  Future<bool> connected() async {
    try {
      return (await secrets.read(refreshKey))?.isNotEmpty == true;
    } catch (_) {
      // Portachiavi non disponibile (es. test, Linux senza keyring).
      return false;
    }
  }

  Future<String?> lastSyncLabel() => settings.get(lastResultKey);

  Future<DateTime?> lastSyncAt() async =>
      DateTime.tryParse((await settings.get(lastSyncAtKey)) ?? '');

  // ------------------------------------------------------------- sync

  /// Motivo per cui l'ultima [targets] ha lasciato fuori appunti e
  /// registrazioni (null = inclusi o non scelti).
  String? notesSkipped;

  /// Parti da sincronizzare secondo le caselle scelte.
  Future<List<SyncTarget>> targets() async {
    final base = await folder();
    final sc = await scopes();
    final out = <SyncTarget>[];
    // registrazioni solo con Wi‑Fi/cavo se scelto: con i dati mobili restano
    // in attesa (né caricate né scaricate, mai eliminate)
    final rec =
        sc.contains(SyncScope.recordings) &&
        (!await recordingsWifiOnly() || await Power.onWifi());
    final txt = sc.contains(SyncScope.notes);
    notesSkipped = null;
    final (root, fellBack) = rec || txt
        ? await notes.rootWithFallback()
        : (null, false);
    if (fellBack) {
      // cartella degli appunti scelta non raggiungibile (disco scollegato o
      // che non risponde): con quella predefinita al suo posto i file che
      // mancano lì sembrerebbero eliminati qui e si toglierebbero dal
      // servizio e dagli altri dispositivi. Si salta, e lo si dice.
      notesSkipped =
          'Appunti e registrazioni non sincronizzati: la cartella degli '
          'appunti scelta non è raggiungibile (disco scollegato?).';
    } else if (root != null) {
      final recDir = NoteFolder.recordings.dirName;
      final recording = sources.recordingInProgress?.call();
      out.add(
        SyncTarget(
          'corsi',
          root,
          '$base/Corsi',
          include: (rel) {
            final parts = rel.split('/');
            final isRec = parts.length > 1 && parts[1] == recDir;
            if (isRec && recording != null) {
              final full = p.joinAll([root.path, ...parts]);
              if (p.equals(full, recording)) return false;
            }
            return isRec ? rec : txt;
          },
        ),
      );
    }
    if (sc.contains(SyncScope.books)) {
      if (sources.books != null) {
        // libri tenuti solo su questo dispositivo («Salva nel cloud» spento)
        final localOnly = await booksLocalOnly();
        out.add(
          SyncTarget(
            'libri',
            await sources.books!(),
            '$base/Libri',
            include: (rel) => !localOnly.contains(rel),
          ),
        );
      }
      if (sources.materials != null) {
        out.add(
          SyncTarget(
            'materiali',
            await sources.materials!(),
            '$base/Materiali',
          ),
        );
      }
      // evidenziazioni dei PDF (file JSON per documento, con lo stesso nome
      // su tutti i dispositivi: vedi PdfHighlights)
      if (sources.highlights != null) {
        out.add(
          SyncTarget(
            'evidenziazioni',
            await sources.highlights!(),
            '$base/Evidenziazioni',
            include: (rel) => !rel.contains('/') && rel.endsWith('.json'),
          ),
        );
      }
    }
    if (sc.contains(SyncScope.attachments) && sources.attachments != null) {
      out.add(
        SyncTarget('allegati', await sources.attachments!(), '$base/Allegati'),
      );
    }
    if (sc.contains(SyncScope.backup) && sources.backupJson != null) {
      out.add(SyncTarget('backup', await _backupDir(), '$base/Backup'));
    }
    return out;
  }

  Future<Directory> _backupDir() async {
    final d = Directory(p.join((await stateDir()).path, '${prefix}_backup'));
    await d.create(recursive: true);
    return d;
  }

  /// Identificativo breve e stabile di questa installazione (due PC o due
  /// telefoni non scrivono lo stesso file di backup).
  Future<String> installId() async {
    const key = 'install_id';
    final v = await settings.get(key);
    if (v != null && v.isNotEmpty) return v;
    final r = Random.secure();
    final id = List.generate(
      3,
      (_) => r.nextInt(256),
    ).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await settings.set(key, id);
    return id;
  }

  /// Scrive il backup JSON di questo dispositivo solo se i dati sono
  /// cambiati (niente caricamenti inutili a ogni sincronizzazione).
  int? _backupChanges;

  Future<void> _writeBackup() async {
    final counter = sources.changeCounter;
    int? changes;
    if (counter != null) {
      try {
        changes = await counter();
        // nessuna modifica dall'ultimo backup: niente export
        if (changes == _backupChanges) return;
      } catch (_) {}
    }
    final json = await sources.backupJson!();
    Object? data;
    try {
      data = jsonDecode(json);
    } on FormatException {
      return;
    }
    if (data is Map) data.remove('createdAt');
    final hash = sha1.convert(utf8.encode(jsonEncode(data))).toString();
    final dir = await _backupDir();
    final mark = File(p.join(dir.path, '.ultimo_backup'));
    if (await mark.exists() && await mark.readAsString() == hash) {
      _backupChanges = changes;
      return;
    }
    final name = NotesStore.safeName('Backup $deviceName ${await installId()}');
    await File(p.join(dir.path, '$name.json')).writeAsString(json);
    await mark.writeAsString(hash);
    _backupChanges = changes;
  }

  /// Copia locale della cartella `Dati` (registri dei dati di ogni
  /// dispositivo, [DataSync]).
  Future<Directory> dataDir() async {
    final d = Directory(p.join((await stateDir()).path, '${prefix}_dati'));
    await d.create(recursive: true);
    return d;
  }

  /// Dati dell'app: si scaricano i registri nuovi degli altri dispositivi,
  /// si uniscono al database e, se il registro di questo dispositivo è
  /// cambiato, si carica. Senza novità (né qui né sul servizio) non si fa
  /// nulla.
  Future<void> _syncData(
    SyncReport total,
    Directory state, {
    required bool force,
  }) async {
    final data = sources.data!;
    final target = SyncTarget(
      'dati',
      await dataDir(),
      '${await folder()}/Dati',
      include: (rel) => !rel.contains('/') && rel.endsWith(DataSync.extension),
    );
    final remote = force || await engine(target, state).needsSync();
    if (remote) {
      progress = 'Dati dell\'app: novità dagli altri dispositivi…';
      notifyListeners();
      total.add(await engine(target, state).run());
    }
    if (!remote && await data.hasBase() && !await data.hasLocalChanges()) {
      return;
    }
    progress = 'Dati dell\'app: unione con gli altri dispositivi…';
    notifyListeners();
    final r = await data.mergeFolder(
      target.local,
      ownName: DataSync.ownFileName(deviceName, await installId()),
      device: deviceName,
      installId: await installId(),
    );
    total.dataChanges += r.applied;
    if (r.ownChanged) total.add(await engine(target, state).run());
  }

  /// Sincronizza. Con [force] = false prima chiede al servizio le sole
  /// novità e salta le parti senza modifiche. [auto]: controllo automatico
  /// (avvio, timer, ritorno nell'app).
  Future<SyncReport?> sync({bool force = true, bool auto = false}) async {
    // il segno va messo prima di ogni attesa: due richieste quasi insieme
    // (avvio, timer, «Sincronizza ora», ritorno nell'app, lavoro in
    // background) altrimenti passano entrambe e lavorano sugli stessi file
    // di stato
    if (_syncing || hold) return null;
    _syncing = true;
    var ready = false;
    try {
      ready = await connected() && !await _busyElsewhere();
    } catch (_) {
      // portachiavi non leggibile: come non collegato
    }
    if (!ready) {
      _syncing = false;
      return null;
    }
    lastError = null;
    progress = 'Sincronizzazione con $serviceName…';
    notifyListeners();
    try {
      final total = SyncReport();
      final state = await stateDir();
      try {
        await _followMovedFolder(force: force);
      } catch (e) {
        if (isNetworkError(e)) rethrow;
      }
      if (sources.data != null && (await scopes()).contains(SyncScope.data)) {
        await _syncData(total, state, force: force);
      }
      if (sources.backupJson != null &&
          (await scopes()).contains(SyncScope.backup)) {
        await _writeBackup();
      }
      for (final t in await targets()) {
        final e = engine(t, state);
        if (!force && !await e.needsSync()) continue;
        final r = await e.run(
          onProgress: (s) {
            progress = s;
            notifyListeners();
          },
        );
        total.add(r);
      }
      final skipped = notesSkipped;
      if (skipped != null) total.errors.add(skipped);
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      await settings.set(lastSyncAtKey, now.toIso8601String());
      await settings.set(
        lastResultKey,
        '${two(now.day)}/${two(now.month)} ${two(now.hour)}:${two(now.minute)} · $total',
      );
      if (total.errors.isNotEmpty) lastError = total.errors.first;
      _lastRun = DateTime.now();
      // file arrivati o tolti: le schermate si aggiornano (i dati del
      // database lo fanno già con l'unione, DataSync.onApplied)
      if (total.downloaded + total.deletedLocal + total.conflicts > 0) {
        try {
          sources.onChanged?.call();
        } catch (_) {}
      }
      return total;
    } catch (e) {
      if (isNetworkError(e)) {
        // senza connessione: il messaggio che la chiede (anche nei controlli
        // automatici); l'ultima sincronizzazione riuscita resta mostrata e si
        // riprova da sola quando torna la rete
        lastError = offlineMessage;
        return null;
      }
      lastError = '$e';
      try {
        await settings.set(lastResultKey, 'Errore: $e');
      } catch (_) {
        // database non scrivibile: l'errore resta comunque in lastError
      }
      return null;
    } finally {
      _syncing = false;
      progress = null;
      notifyListeners();
    }
  }

  /// Sincronizza all'avvio, poi ogni N minuti, al ritorno nell'app e quando
  /// torna la connessione, se collegato. Una volta su sei si rilegge tutto.
  void startAutoSync() {
    unawaited(() async {
      _restartTimer(await intervalMinutes());
    }());
    onScheduleChanged?.call();
    try {
      _lifecycle ??= AppLifecycleListener(onResume: _soon);
    } catch (_) {
      // Nessun binding (es. test).
    }
    // Alcuni sistemi (Linux senza D-Bus) lanciano l'errore fuori dallo
    // stream: la zona lo raccoglie, la sincronizzazione periodica resta attiva.
    runZonedGuarded(() {
      _net ??= Connectivity().onConnectivityChanged.listen((r) {
        if (r.any((c) => c != ConnectivityResult.none)) _soon();
      }, onError: (_) {});
    }, (_, _) {});
    unawaited(sync(auto: true));
  }

  void _restartTimer(int minutes) {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: minutes), (_) {
      _ticks++;
      unawaited(sync(force: _ticks % 6 == 0, auto: true));
    });
  }

  /// Fine dell'ultima sincronizzazione riuscita in questa sessione.
  DateTime? _lastRun;

  /// Controllo leggero poco dopo un evento (rete tornata, app riaperta);
  /// saltato se l'ultima sincronizzazione è di meno di 2 minuti fa, così
  /// tornare spesso nell'app non rallenta il ritorno.
  void _soon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(seconds: 5), () {
      final last = _lastRun;
      if (last != null &&
          DateTime.now().difference(last) < const Duration(minutes: 2)) {
        return;
      }
      unawaited(sync(force: false, auto: true));
    });
  }

  void stopAutoSync() {
    _timer?.cancel();
    _timer = null;
    _debounce?.cancel();
    _lifecycle?.dispose();
    _lifecycle = null;
    unawaited(_net?.cancel());
    _net = null;
  }

  @override
  void dispose() {
    stopAutoSync();
    super.dispose();
  }
}
