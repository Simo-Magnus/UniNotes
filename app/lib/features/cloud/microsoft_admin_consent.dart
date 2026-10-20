import 'microsoft_oauth.dart';

/// Permesso delegato di Microsoft Graph chiesto dall'app, con il motivo
/// (mostrato nel testo per l'ateneo e nella pagina per gli amministratori).
class GraphPermission {
  const GraphPermission(this.scope, this.reason);
  final String scope;
  final String reason;
}

/// Account universitari che non possono dare il consenso a UniNotes:
/// riconoscimento dell'errore e testo da mandare al servizio informatico
/// dell'ateneo. L'editore dell'app non è verificato (servono un dominio e un
/// ente legale), quindi molti atenei bloccano il consenso degli studenti o
/// lo tolgono del tutto: serve l'approvazione di un amministratore.
class MicrosoftAdminConsent {
  MicrosoftAdminConsent._();

  /// Pagina pubblica per gli amministratori IT (sito/amministratori.html).
  /// È anche l'URI di ritorno del consenso amministratore: va registrato in
  /// Entra come piattaforma «Web» (vedi docs/onedrive_setup.md).
  static const adminPageUrl =
      'https://simo-magnus.github.io/UniNotes/amministratori.html';

  /// Permessi delegati di Microsoft Graph, nell'ordine in cui li mostra la
  /// pagina per gli amministratori.
  static const permissions = [
    GraphPermission(
      'User.Read',
      'leggere nome e indirizzo dell\'account, per mostrare quale account è '
          'collegato',
    ),
    GraphPermission(
      'Files.ReadWrite',
      'leggere e scrivere la cartella di UniNotes (o quella scelta dallo '
          'studente) nel suo OneDrive, per sincronizzare appunti, '
          'registrazioni e materiali',
    ),
    GraphPermission(
      'Notes.Read',
      'mostrare in sola lettura i blocchi appunti OneNote dello studente',
    ),
    GraphPermission(
      'offline_access',
      'restare collegati senza ripetere l\'accesso ogni volta',
    ),
    GraphPermission(
      'Calendars.ReadWrite',
      'solo nell\'app per Windows e chiesto a parte: scrivere le date degli '
          'esami in un calendario «UniNotes» di Outlook',
    ),
  ];

  /// Codici di Microsoft Entra per cui serve l'amministratore dell'ateneo:
  /// consenso mancante (65001), consenso rifiutato (65004: anche dalla
  /// pagina «Richiede l'approvazione dell'amministratore» con «Torna
  /// all'applicazione»), consenso solo dell'amministratore (90094, 90095),
  /// utente non assegnato all'app (50105).
  static const codes = {'65001', '65004', '90094', '90095', '50105'};

  static final _code = RegExp(r'AADSTS(\d+)');
  static final _texts = RegExp(
    r"need admin approval|admin approval|admin consent|"
    r"only an admin can grant|"
    r"approvazione dell'amministratore|approvazione di un amministratore|"
    r"consenso dell'amministratore|richiede l'approvazione",
    caseSensitive: false,
  );

  /// L'accesso Microsoft è fallito perché l'ateneo deve approvare l'app.
  static bool isAdminConsentError(Object? error) {
    final text = '${error ?? ''}'.replaceAll('’', "'");
    if (text.isEmpty) return false;
    for (final m in _code.allMatches(text)) {
      if (codes.contains(m.group(1))) return true;
    }
    return _texts.hasMatch(text);
  }

  /// Consenso rifiutato (AADSTS65004): può averlo annullato lo studente.
  static bool isDeclined(Object? error) =>
      RegExp(r'AADSTS65004').hasMatch('${error ?? ''}');

  static final _guid = RegExp(
    r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
    r'[0-9a-fA-F]{12}$',
  );

  /// ID applicazione valido (vuoto o malformato = nessun ID da mostrare).
  static String? validId(String? clientId) {
    final id = clientId?.trim() ?? '';
    return _guid.hasMatch(id) ? id : null;
  }

  /// Scope del consenso amministratore: tutti i permessi delegati elencati,
  /// compreso il calendario, così l'approvazione copre anche Windows.
  static String get adminScopes => [
    for (final p in permissions)
      p.scope == 'offline_access'
          ? p.scope
          : 'https://graph.microsoft.com/${p.scope}',
  ].join(' ');

  /// Consenso amministratore per qualsiasi tenant (endpoint v2.0 con
  /// `organizations`): l'amministratore accede, sceglie il proprio tenant e
  /// approva; Microsoft torna sulla pagina per gli amministratori. Null se
  /// l'ID non c'è: niente link rotti.
  static Uri? consentUrl(String? clientId) {
    final id = validId(clientId);
    if (id == null) return null;
    return Uri.https(
      'login.microsoftonline.com',
      '/organizations/v2.0/adminconsent',
      {
        'client_id': id,
        'scope': adminScopes,
        'redirect_uri': adminPageUrl,
        'state': 'uninotes',
      },
    );
  }

  /// Oggetto del messaggio per il servizio informatico.
  static const requestSubject =
      'Richiesta di approvazione dell\'app UniNotes (Microsoft Entra)';

  /// Testo pronto da mandare all'help desk dell'ateneo. Senza un ID valido
  /// non contiene né l'ID né il link di consenso (li trovano nella pagina).
  static String requestText({String? clientId}) {
    final id = validId(clientId);
    final consent = consentUrl(id);
    final b = StringBuffer()
      ..writeln('Buongiorno,')
      ..writeln(
        'vorrei collegare il mio account universitario Microsoft a UniNotes, '
        'un\'app gratuita e senza pubblicità per gli studenti universitari '
        '(codice pubblico su GitHub). L\'accesso è bloccato perché serve '
        'l\'approvazione di un amministratore: vi chiedo di valutare il '
        'consenso amministratore per l\'app nel tenant dell\'ateneo.',
      )
      ..writeln()
      ..writeln('Nome dell\'app: UniNotes');
    if (id != null) b.writeln('ID applicazione (client): $id');
    b
      ..writeln(
        'Editore: non verificato (progetto personale, senza dominio né ente '
        'legale)',
      )
      ..writeln()
      ..writeln('Permessi delegati Microsoft Graph richiesti:');
    for (final p in permissions) {
      b.writeln('- ${p.scope}: ${p.reason}');
    }
    b
      ..writeln()
      ..writeln(
        'I dati restano sul dispositivo e nell\'account dello studente, '
        'nessun server di UniNotes: l\'app comunica direttamente con '
        'Microsoft Graph e i token restano sul dispositivo.',
      )
      ..writeln()
      ..writeln('Informazioni per gli amministratori: $adminPageUrl');
    if (consent != null) {
      b.writeln('Link per il consenso amministratore: $consent');
    }
    b
      ..writeln(
        'In alternativa: Microsoft Entra admin center → Applicazioni '
        'aziendali → UniNotes → Autorizzazioni → «Concedi il consenso '
        'amministratore».',
      )
      ..writeln()
      ..write('Grazie.');
    return b.toString();
  }

  /// Tenant per riprovare con un account personale: «common» se quello
  /// dell'impostazione `onedrive_tenant` ammette solo account di lavoro o
  /// scuola.
  static String tenantForPersonal(String tenant) {
    final t = MicrosoftOAuth.normalizeTenant(tenant);
    return t == 'common' || t == 'consumers' ? t : MicrosoftOAuth.defaultTenant;
  }
}
