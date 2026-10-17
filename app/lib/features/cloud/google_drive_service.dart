import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/services/external_launcher.dart';
import '../../core/services/loopback_oauth.dart';
import 'cloud_drive_service.dart';
import 'drive_picker.dart';
import 'google_drive_client.dart';
import 'google_drive_sync.dart';
import 'google_oauth.dart';
import 'incoming_files.dart';
import 'microsoft_oauth.dart' show OAuthRedirectMode;

export 'cloud_drive_service.dart';
export 'drive_picker.dart' show PickerResult;
export 'incoming_files.dart' show IncomingDestination;

/// Avviso da mostrare una volta nella scheda Google Drive.
enum DriveNotice {
  /// All'accesso la cartella dell'app non c'era (primo uso, oppure creata da
  /// una registrazione precedente dell'app, che con `drive.file` non si
  /// vede) ed è stata creata: i file vecchi si recuperano con «Importa da
  /// Drive».
  newFolder,

  /// L'accesso della versione precedente non vale più (nuova registrazione
  /// dell'app presso Google): basta ricollegarsi.
  reconnect,
}

/// File scelti con «Importa da Drive», divisi per cosa farne.
class DriveImportPlan {
  /// Già nella cartella dell'app (es. caricati dal sito di Drive dentro
  /// UniNotes): da ora si sincronizzano da soli.
  final List<String> inside = [];

  /// Fuori dalla cartella dell'app: si copiano dove sceglie lo studente.
  final List<({String id, String name})> outside = [];

  /// Documenti Google (Documenti, Fogli, Presentazioni…): non sono file da
  /// scaricare.
  final List<String> skipped = [];
}

/// Google Drive: le stesse funzioni di OneDrive (vedi [CloudDriveService])
/// nella cartella «UniNotes» del Drive dell'utente, con lo scope
/// `drive.file`.
///
/// All'accesso crea (se manca) la cartella «UniNotes»; da lì in poi ciò che
/// l'app crea su un dispositivo arriva sugli altri. I file messi nella
/// cartella da altre vie (sito o app di Drive, Drive per desktop,
/// condivisioni) l'app non li vede: entrano con «Importa da Drive»
/// ([planImport], Google Picker) oppure passando dall'app («Condividi →
/// UniNotes», «Apri in UniNotes», trascinamento sulla finestra).
class GoogleDriveService extends CloudDriveService {
  GoogleDriveService(
    super.settings,
    super.notes, {
    super.secrets,
    this.transport,
    LoopbackOAuth Function(String clientId, String secret)? oauthFactory,
    super.stateDir,
    super.sources,
    String? builtInClientId,
    String? builtInClientSecret,
    super.deviceName,
  }) : _oauthFactory = oauthFactory ?? _defaultOAuth,
       clientId = builtInClientId ?? GoogleOAuth.builtInClientId,
       clientSecret = builtInClientSecret ?? GoogleOAuth.desktopClientSecret;

  /// ID client incluso nella build (`--dart-define=GOOGLE_CLIENT_ID`, …).
  final String clientId;
  final String clientSecret;

  /// Trasporto HTTP (nei test: server finto).
  final GraphTransport? transport;
  final LoopbackOAuth Function(String clientId, String secret) _oauthFactory;

  @override
  String get serviceName => 'Google Drive';

  @override
  String get prefix => 'gdrive';

  bool get available => clientId.trim().isNotEmpty;

  static LoopbackOAuth _defaultOAuth(String clientId, String secret) =>
      GoogleOAuth(
        clientId: clientId,
        clientSecret: CloudDriveService.isMobile ? null : secret,
        mode: CloudDriveService.isMobile
            ? OAuthRedirectMode.customScheme
            : OAuthRedirectMode.loopback,
        openBrowser: (u) async => (await ExternalLauncher.openUrl('$u')).ok,
      );

  /// Scope con cui è stato dato l'accesso salvato (manca per gli accessi
  /// delle versioni con lo scope `drive`).
  String get grantedScopeKey => '${prefix}_granted_scope';
  String get noticeKey => '${prefix}_notice';

  /// L'accesso della versione precedente è stato tolto ora: l'app avvisa
  /// una volta (vedi [takeReconnectAlert]).
  bool _reconnectAlert = false;

  @override
  Future<void> signIn() async {
    if (!available) {
      throw OAuthException(
        'Questa versione dell\'app non include l\'ID client Google (vedi '
        'docs/google_drive_setup.md).',
      );
    }
    await storeTokens(await _oauthFactory(clientId, clientSecret).signIn());
    if (await notice() == DriveNotice.reconnect) {
      await settings.set(noticeKey, null);
    }
    await setAccount(await drive().accountLabel());
    // Cartella UniNotes subito. Se non si trova (prima volta, o creata da
    // una registrazione precedente dell'app, che con drive.file non si
    // vede) se ne crea una nuova, senza errori, e si spiega una volta come
    // recuperare i file vecchi.
    final d = drive();
    final base = await folder();
    if (await d.folderPath(base, create: false) == null) {
      await d.folderPath(base);
      if (await settings.get(noticeShownKey) != '1') {
        await settings.set(noticeKey, DriveNotice.newFolder.name);
      }
    }
    notifyListeners();
  }

  String get noticeShownKey => '${noticeKey}_shown';

  @override
  Future<void> storeTokens(OAuthTokens t) async {
    await super.storeTokens(t);
    await settings.set(grantedScopeKey, GoogleOAuth.defaultScope);
  }

  /// Avviso in attesa per la scheda Google Drive.
  Future<DriveNotice?> notice() async {
    final v = await settings.get(noticeKey);
    for (final n in DriveNotice.values) {
      if (n.name == v) return n;
    }
    return null;
  }

  /// «Ho capito»: l'avviso sulla cartella nuova non torna più.
  Future<void> dismissNotice() async {
    final was = await notice();
    await settings.set(noticeKey, null);
    if (was == DriveNotice.newFolder) await settings.set(noticeShownKey, '1');
    notifyListeners();
  }

  /// true una sola volta dopo che l'accesso della versione precedente è
  /// stato tolto (avviso discreto fuori da Collegamenti).
  bool takeReconnectAlert() {
    final v = _reconnectAlert;
    _reconnectAlert = false;
    return v;
  }

  /// Accesso salvato da una versione precedente (scope `drive`, forse di
  /// un altro progetto Google Cloud): se Google lo rifiuta lo si toglie in
  /// silenzio e si chiede di ricollegarsi, senza «errori» né «collegamento
  /// interrotto». Senza rete non si tocca nulla (si riprova dopo).
  Future<void> migrateLegacyAccess() async {
    if (await settings.get(grantedScopeKey) == GoogleOAuth.defaultScope) {
      return;
    }
    String? refresh;
    try {
      refresh = await secrets.read(refreshKey);
    } catch (_) {
      return;
    }
    if (refresh == null || refresh.isEmpty || !available) return;
    try {
      tokens = await refreshTokens(refresh);
      // stesso progetto: l'accesso vale ancora
      await settings.set(grantedScopeKey, GoogleOAuth.defaultScope);
    } on OAuthException catch (e) {
      if (!legacyRejected(e.message)) return;
      await secrets.delete(refreshKey);
      await settings.set(accountKey, null);
      tokens = null;
      await settings.set(noticeKey, DriveNotice.reconnect.name);
      _reconnectAlert = true;
      notifyListeners();
    }
  }

  /// Google rifiuta l'accesso salvato (client diverso, revocato, scaduto),
  /// non un problema di rete.
  static bool legacyRejected(String message) {
    final m = message.toLowerCase();
    return isExpiredGrant(m) ||
        m.contains('unauthorized_client') ||
        m.contains('invalid_client') ||
        m.contains('deleted_client');
  }

  @override
  Future<SyncReport?> sync({bool force = true, bool auto = false}) async {
    await migrateLegacyAccess();
    return super.sync(force: force, auto: auto);
  }

  // ------------------------------------------------------- Importa da Drive

  /// Picker di Google per questa piattaforma.
  DrivePicker picker() => DrivePicker(
    openBrowser: (u) async => (await ExternalLauncher.openUrl('$u')).ok,
    mobileClientId: CloudDriveService.isMobile ? clientId : null,
  );

  /// Cosa fare dei file scelti nel Picker ([ids]): con `drive.file` ora
  /// l'app li vede; quelli già dentro la cartella dell'app si
  /// sincronizzeranno da soli, gli altri vanno copiati.
  Future<DriveImportPlan> planImport(List<String> ids) async {
    final d = drive();
    final plan = DriveImportPlan();
    final rootId = await d.folderPath(await folder(), create: false);
    // cartella → dentro la cartella dell'app? (le cartelle non create
    // dall'app non sono accessibili: Google risponde 404, cioè «fuori»)
    final known = <String, bool>{?rootId: true};
    Future<bool> insideApp(List<Object?> parents, [int depth = 0]) async {
      if (rootId == null || depth > 20) return false;
      for (final pid in parents.whereType<String>()) {
        final hit = known[pid];
        if (hit != null) {
          if (hit) return true;
          continue;
        }
        Map<String, Object?>? meta;
        try {
          meta = await d.fileMeta(pid, fields: 'id,parents');
        } on DriveException {
          meta = null;
        }
        final up =
            meta != null &&
            await insideApp(meta['parents'] as List? ?? const [], depth + 1);
        known[pid] = up;
        if (up) return true;
      }
      return false;
    }

    for (final id in ids) {
      final meta = await d.fileMeta(id);
      if (meta == null || meta['trashed'] == true) continue;
      final name = '${meta['name'] ?? id}';
      final mime = '${meta['mimeType'] ?? ''}';
      if (mime.startsWith('application/vnd.google-apps.')) {
        plan.skipped.add(name);
      } else if (await insideApp(meta['parents'] as List? ?? const [])) {
        plan.inside.add(name);
      } else {
        plan.outside.add((id: id, name: name));
      }
    }
    return plan;
  }

  /// Copia [files] in `UniNotes/Materiali/<cartella>` su Drive (la copia è
  /// dell'app, l'originale resta dov'è); nomi già presenti → « (2)».
  /// Restituisce quanti file sono stati copiati.
  Future<int> copyIntoApp(
    List<({String id, String name})> files,
    IncomingDestination dest,
  ) async {
    if (files.isEmpty) return 0;
    final d = drive();
    final target = (await d.folderPath(
      '${await folder()}/Materiali/${dest.folder}',
    ))!;
    final taken = {for (final it in await d.children(target)) '${it['name']}'};
    var n = 0;
    for (final f in files) {
      final name = IncomingFiles.uniqueAmong(
        taken,
        IncomingFiles.safeFileName(f.name),
      );
      taken.add(name);
      await d.copyFile(f.id, target, name);
      n++;
    }
    return n;
  }

  @override
  Future<OAuthTokens> refreshTokens(String refreshToken) {
    if (!available) {
      throw OAuthException(
        'Google Drive non collegato (Collegamenti → Google Drive).',
      );
    }
    return _oauthFactory(clientId, clientSecret).refresh(refreshToken);
  }

  GoogleDriveClient drive() =>
      GoogleDriveClient(accessToken, transport: transport);

  GoogleDriveFolderBrowser folders() => GoogleDriveFolderBrowser(drive());

  @override
  Future<int> deleteRemoteAppData() async {
    final d = drive();
    final base = await folder();
    final rootId = await d.folderPath(base, create: false);
    if (rootId == null) return 0;
    Future<void> trash(String id) => d.sendJson(
      'PATCH',
      d.url('files/$id', {'fields': 'id'}),
      {'trashed': true},
    );
    var removed = 0;
    for (final sub in CloudDriveService.appSubfolders) {
      final id = await d.findFolder(rootId, sub);
      if (id == null) continue;
      await trash(id);
      removed++;
    }
    if (CloudDriveService.isAppFolder(base) &&
        (await d.children(rootId)).isEmpty) {
      await trash(rootId);
      removed++;
    }
    return removed;
  }

  @override
  GoogleDriveSync engine(SyncTarget t, Directory state) => GoogleDriveSync(
    drive: drive(),
    localRoot: t.local,
    remoteFolder: t.remote,
    stateFile: File(p.join(state.path, 'gdrive_sync_${t.key}.json')),
    deviceName: deviceName,
    include: t.include,
  );
}
