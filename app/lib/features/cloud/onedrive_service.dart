import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/services/external_launcher.dart';
import '../../core/services/loopback_oauth.dart';
import '../../repositories/settings_repository.dart';
import 'cloud_drive_service.dart';
import 'graph_client.dart';
import 'microsoft_admin_consent.dart';
import 'microsoft_oauth.dart';
import 'onedrive_folders.dart';
import 'onedrive_sync.dart';
import 'onenote.dart';

export 'cloud_drive_service.dart';

/// OneDrive (tutto su tutti i dispositivi, vedi [CloudDriveService]) e
/// OneNote (lettura).
class OneDriveService extends CloudDriveService {
  OneDriveService(
    super.settings,
    super.notes, {
    super.secrets,
    this.transport,
    LoopbackOAuth Function(String clientId, String tenant)? oauthFactory,
    super.stateDir,
    super.sources,
    String? builtInClientId,
    super.deviceName,
  }) : _oauthFactory = oauthFactory ?? _defaultOAuth,
       builtInClientId = builtInClientId ?? MicrosoftOAuth.builtInClientId;

  /// ID applicazione incluso nella build (`--dart-define=MS_CLIENT_ID`).
  final String builtInClientId;

  /// Trasporto HTTP di Graph (nei test: server finto).
  final GraphTransport? transport;
  final LoopbackOAuth Function(String clientId, String tenant) _oauthFactory;

  @override
  String get serviceName => 'OneDrive';

  @override
  String get prefix => 'onedrive';

  static LoopbackOAuth _defaultOAuth(String clientId, String tenant) =>
      MicrosoftOAuth(
        clientId: clientId,
        tenant: tenant,
        mode: microsoftRedirectMode(mobile: CloudDriveService.isMobile),
        openBrowser: (u) async => (await ExternalLauncher.openUrl('$u')).ok,
      );

  /// ID applicazione dell'impostazione `onedrive_client_id` se presente,
  /// altrimenti quello incluso nell'app. L'app non ha un'interfaccia per
  /// cambiarlo (né il tenant): le due impostazioni si leggono se ci sono
  /// (es. scritte da una versione precedente); [setTenant] lo usa solo
  /// [signInPersonal], [setClientId] solo i test.
  Future<String> clientId() async {
    final custom = (await settings.get(SettingKeys.onedriveClientId))?.trim();
    return (custom == null || custom.isEmpty) ? builtInClientId : custom;
  }

  /// ID dell'impostazione `onedrive_client_id` (vuoto = quello dell'app).
  Future<String> customClientId() async =>
      (await settings.get(SettingKeys.onedriveClientId))?.trim() ?? '';
  Future<void> setClientId(String v) =>
      settings.set(SettingKeys.onedriveClientId, v.trim());

  bool get hasBuiltInClientId => builtInClientId.trim().isNotEmpty;

  /// Tipo di account (tenant) dell'impostazione `onedrive_tenant`: common
  /// (predefinito), consumers, organizations o un ID.
  Future<String> tenant() async => MicrosoftOAuth.normalizeTenant(
    await settings.get(SettingKeys.onedriveTenant),
  );
  Future<void> setTenant(String v) => settings.set(
    SettingKeys.onedriveTenant,
    MicrosoftOAuth.normalizeTenant(v),
  );

  /// L'accesso con l'account universitario è stato bloccato dall'ateneo
  /// (serve il consenso dell'amministratore): la scheda OneDrive tiene il
  /// link «Perché non riesco a collegare l'account universitario?».
  static const adminConsentKey = 'onedrive_admin_consent_needed';

  Future<bool> adminConsentNeeded() async =>
      (await settings.get(adminConsentKey)) == '1';
  Future<void> setAdminConsentNeeded(bool v) =>
      settings.set(adminConsentKey, v ? '1' : null);

  /// «Usa un account Microsoft personale»: di nuovo la pagina di Microsoft
  /// con la scelta dell'account (`prompt=select_account`); se l'impostazione
  /// `onedrive_tenant` ammette solo account universitari si torna a
  /// «common».
  Future<void> signInPersonal() async {
    final t = await tenant();
    final personal = MicrosoftAdminConsent.tenantForPersonal(t);
    if (personal != t) await setTenant(personal);
    await signIn();
  }

  // ------------------------------------------------------------- account

  static final _guid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
  );

  @override
  Future<void> signIn() async {
    final id = await clientId();
    if (id.isEmpty) {
      throw OAuthException(
        'Questa versione dell\'app non include l\'ID applicazione Microsoft: '
        'serve una build con MS_CLIENT_ID (vedi docs/onedrive_setup.md).',
      );
    }
    if (!_guid.hasMatch(id)) {
      throw OAuthException(
        'L\'ID applicazione non ha il formato giusto: copia «ID applicazione '
        '(client)» dalla pagina Panoramica della registrazione (36 caratteri, '
        'es. 1a2b3c4d-…), non l\'ID oggetto né il segreto.',
      );
    }
    final t = await _oauthFactory(id, await tenant()).signIn();
    // nome dell'account e cartella subito; se non riescono l'accesso non
    // resta salvato a metà
    await completeSignIn(t, () async {
      // nome dell'account e cartella dell'app insieme (una richiesta di
      // rete in meno da aspettare dopo il ritorno dal browser)
      final g = graph();
      final base = await folder();
      final folderReady = OneDriveSync.ensureFolder(g, base)..ignore();
      final me = await g.getJson('me', {
        r'$select': 'displayName,userPrincipalName,mail',
      });
      await folderReady;
      await setAccount(
        [
          me?['displayName'],
          me?['mail'] ?? me?['userPrincipalName'],
        ].whereType<String>().join(' · '),
      );
    });
  }

  @override
  Future<OAuthTokens> refreshTokens(String refreshToken) async {
    final id = await clientId();
    if (id.isEmpty) {
      throw OAuthException('OneDrive non collegato (Collegamenti → OneDrive).');
    }
    return _oauthFactory(id, await tenant()).refresh(refreshToken);
  }

  GraphClient graph() => GraphClient(accessToken, transport: transport);

  OneNoteReader oneNote() => OneNoteReader(graph());

  OneDriveFolderBrowser folders() => OneDriveFolderBrowser(graph());

  @override
  Future<void> renameRemoteFolder(String path, String newName) async {
    final g = graph();
    final it = await g.getJson('me/drive/root:/${GraphClient.drivePath(path)}');
    final id = it?['id'];
    if (id is! String) {
      // non c'è ancora sul servizio: basta il nome nuovo, la si crea così
      return;
    }
    try {
      await g.sendJson('PATCH', 'me/drive/items/$id', {
        'name': newName,
        '@microsoft.graph.conflictBehavior': 'fail',
      });
    } on GraphException catch (e) {
      if (e.status == 409) {
        throw GraphException(409, 'Esiste già una cartella «$newName» lì.');
      }
      rethrow;
    }
  }

  /// La cartella `<base>/Libri` (o un'altra dell'app) ha un id salvato: se
  /// esiste ancora sotto un'altra cartella, quella è la cartella dell'app
  /// rinominata.
  @override
  Future<String?> locateMovedFolder(String base) async {
    final g = graph();
    if (await g.getJson('me/drive/root:/${GraphClient.drivePath(base)}', {
          r'$select': 'id',
        }) !=
        null) {
      return null;
    }
    for (final m in await syncStates()) {
      final id = m['folderId'];
      final rf = '${m['remoteFolder'] ?? ''}';
      if (id is! String || !rf.startsWith('$base/')) continue;
      final it = await g.getJson('me/drive/items/$id', {
        r'$select': 'id,name,parentReference,deleted',
      });
      if (it == null || it['deleted'] != null) continue;
      final path = (it['parentReference'] as Map?)?['path'];
      if (path is! String) continue;
      final at = path.indexOf('root:');
      if (at < 0) continue;
      final parent = Uri.decodeComponent(
        path.substring(at + 5),
      ).replaceAll(RegExp(r'^/+'), '');
      if (parent.isNotEmpty) return parent;
    }
    return null;
  }

  @override
  Future<int> deleteRemoteAppData() async {
    final g = graph();
    final base = await folder();
    Future<String?> folderId(String path) async {
      final it = await g.getJson(
        'me/drive/root:/${GraphClient.drivePath(path)}',
      );
      final id = it?['id'];
      return (it?['folder'] != null && id is String) ? id : null;
    }

    var removed = 0;
    for (final sub in CloudDriveService.appSubfolders) {
      final id = await folderId('$base/$sub');
      if (id == null) continue;
      await g.request('DELETE', 'me/drive/items/$id');
      removed++;
    }
    final rootId = await folderId(base);
    if (rootId != null && CloudDriveService.isAppFolder(base)) {
      final page = await g.getJson('me/drive/items/$rootId/children', {
        r'$select': 'id',
        r'$top': '1',
      });
      if ((page?['value'] as List? ?? const []).isEmpty) {
        await g.request('DELETE', 'me/drive/items/$rootId');
        removed++;
      }
    }
    return removed;
  }

  @override
  OneDriveSync engine(SyncTarget t, Directory state) => OneDriveSync(
    graph: graph(),
    localRoot: t.local,
    remoteFolder: t.remote,
    stateFile: File(p.join(state.path, 'onedrive_sync_${t.key}.json')),
    deviceName: deviceName,
    include: t.include,
  );
}
