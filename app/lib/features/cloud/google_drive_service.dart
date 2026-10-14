import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/services/external_launcher.dart';
import '../../core/services/loopback_oauth.dart';
import 'cloud_drive_service.dart';
import 'google_drive_client.dart';
import 'google_drive_sync.dart';
import 'google_oauth.dart';
import 'microsoft_oauth.dart' show OAuthRedirectMode;

export 'cloud_drive_service.dart';

/// Google Drive: le stesse funzioni di OneDrive (vedi [CloudDriveService])
/// nella cartella «UniNotes» del Drive dell'utente.
///
/// All'accesso crea (se manca) la cartella «UniNotes»; da lì in poi ciò che
/// si aggiunge nella cartella o nelle sottocartelle (dal sito, dal PC, dal
/// telefono) arriva nell'app, e ciò che si crea nell'app arriva nella
/// cartella.
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

  @override
  Future<void> signIn() async {
    if (!available) {
      throw OAuthException(
        'Questa versione dell\'app non include l\'ID client Google (vedi '
        'docs/google_drive_setup.md).',
      );
    }
    await storeTokens(await _oauthFactory(clientId, clientSecret).signIn());
    await setAccount(await drive().accountLabel());
    await drive().folderPath(await folder()); // cartella UniNotes subito
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
