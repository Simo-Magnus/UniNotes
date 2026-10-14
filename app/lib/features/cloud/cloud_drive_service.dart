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
  recordings('Registrazioni delle lezioni', 'Corsi'),
  notes('Trascrizioni, riassunti e appunti', 'Corsi'),
  books('Libri e materiali copiati nell\'app', 'Libri'),
  attachments('Allegati di Studio', 'Allegati'),
  backup('Backup del database (dati dell\'app)', 'Backup');

  const SyncScope(this.label, this.remoteDir);
  final String label;

  /// Sottocartella nella cartella cloud dell'app.
  final String remoteDir;

  static Set<SyncScope> parse(String? v) {
    if (v == null) return SyncScope.values.toSet();
    return {
      for (final s in v.split(','))
        for (final x in values)
          if (x.name == s.trim()) x,
    };
  }
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
  });
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

  /// Prefisso delle impostazioni e dei file di stato («onedrive», «gdrive»).
  String get prefix;

  static const defaultFolder = 'UniNotes';
  static const defaultInterval = 10;
  static const intervals = [5, 10, 15, 30, 60];

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
    'Corsi',
    'Libri',
    'Materiali',
    'Allegati',
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

  Future<void> signOut() async {
    stopAutoSync();
    await secrets.delete(refreshKey);
    await settings.set(accountKey, null);
    tokens = null;
    notifyListeners();
  }

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
        final m = jsonDecode(await e.readAsString());
        final remote = m is Map ? '${m['remoteFolder'] ?? ''}' : '';
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

  Future<Set<SyncScope>> scopes() async =>
      SyncScope.parse(await settings.get(scopesKey));
  Future<void> setScopes(Set<SyncScope> s) =>
      settings.set(scopesKey, s.map((e) => e.name).join(','));

  /// File dei libri (nomi nella cartella Libri dell'app) da non caricare.
  Future<Set<String>> booksLocalOnly() async => {
    for (final x in (await settings.get(booksLocalOnlyKey) ?? '').split('\n'))
      if (x.trim().isNotEmpty) x.trim(),
  };

  /// «Salva nel cloud» di un libro: [inCloud] false lo tiene solo su questo
  /// dispositivo; true lo rimette nella sincronizzazione (e attiva la
  /// casella «Libri» se era spenta).
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
    if (rec || txt) {
      final recDir = NoteFolder.recordings.dirName;
      final root = await notes.root();
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

  /// Sincronizza. Con [force] = false prima chiede al servizio le sole
  /// novità e salta le parti senza modifiche. [auto]: controllo automatico
  /// (avvio, timer, ritorno nell'app).
  Future<SyncReport?> sync({bool force = true, bool auto = false}) async {
    if (_syncing || !await connected()) return null;
    _syncing = true;
    lastError = null;
    progress = 'Sincronizzazione con $serviceName…';
    notifyListeners();
    try {
      final total = SyncReport();
      final state = await stateDir();
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
      final now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      await settings.set(lastSyncAtKey, now.toIso8601String());
      await settings.set(
        lastResultKey,
        '${two(now.day)}/${two(now.month)} ${two(now.hour)}:${two(now.minute)} · $total',
      );
      if (total.errors.isNotEmpty) lastError = total.errors.first;
      _lastRun = DateTime.now();
      return total;
    } catch (e) {
      lastError = '$e';
      await settings.set(lastResultKey, 'Errore: $e');
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
