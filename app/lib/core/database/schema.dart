/// Schema SQLite.
///
/// Tabelle "pubbliche" (aggiornabili da data pack senza toccare dati
/// personali): universities, degrees, place_categories, places, benefits.
/// Tabelle "personali": tutte le altre. Le preferenze/note dell'utente sui
/// luoghi pubblici stanno in place_personal, separate da places.
library;

const int kSchemaVersion = 11;

/// Tabelle con dati personali, in ordine di dipendenza (usato da backup).
const List<String> kPersonalTables = [
  'courses',
  'events',
  'exams',
  'modules',
  'topics',
  'attachments',
  'study_sessions',
  'books',
  'materials',
  'place_personal',
  'app_settings',
  'profile',
  'plan_years',
];
// Le tabelle mail_* non vanno nel backup: le caselle sono legate al
// dispositivo (password nel suo portachiavi) e la cache si riscarica.

const List<String> kPublicTables = [
  'universities',
  'degrees',
  'place_categories',
  'places',
  'benefits',
];

const List<String> kSchemaV1 = [
  '''
  CREATE TABLE universities (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    short_name TEXT NOT NULL,
    color INTEGER NOT NULL,
    website TEXT,
    source TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE degrees (
    id TEXT PRIMARY KEY,
    university_id TEXT NOT NULL,
    name TEXT NOT NULL,
    class_code TEXT,
    min_entry_score TEXT,
    max_graduation_score TEXT,
    reference_averages TEXT,
    notes TEXT,
    source TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE courses (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE,
    university_id TEXT,
    degree_id TEXT,
    name TEXT NOT NULL,
    code TEXT,
    teacher TEXT,
    year INTEGER,
    semester TEXT,
    cfu REAL,
    description TEXT,
    color INTEGER,
    status TEXT NOT NULL DEFAULT 'active',
    lecture_hours REAL,
    difficulty REAL,
    study_hours_estimate REAL,
    exam_mode TEXT,
    exam_structure TEXT,
    optional_oral_info TEXT,
    materials_found INTEGER,
    materials_note TEXT,
    source TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE events (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE,
    course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
    university_id TEXT,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    start_at TEXT NOT NULL,
    end_at TEXT,
    all_day INTEGER NOT NULL DEFAULT 0,
    room TEXT,
    building TEXT,
    site TEXT,
    teacher TEXT,
    notes TEXT,
    place_id INTEGER,
    source TEXT
  )''',
  'CREATE INDEX idx_events_start ON events(start_at)',
  '''
  CREATE TABLE exams (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE,
    course_id INTEGER REFERENCES courses(id) ON DELETE CASCADE,
    kind TEXT NOT NULL DEFAULT 'final',
    title TEXT,
    date TEXT,
    time TEXT,
    location TEXT,
    exam_type TEXT,
    status TEXT NOT NULL DEFAULT 'planned',
    grade INTEGER,
    laude INTEGER NOT NULL DEFAULT 0,
    cfu REAL,
    topics TEXT,
    study_materials TEXT,
    notes TEXT,
    source TEXT
  )''',
  'CREATE INDEX idx_exams_date ON exams(date)',
  '''
  CREATE TABLE modules (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    course_id INTEGER NOT NULL REFERENCES courses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE topics (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id INTEGER NOT NULL REFERENCES modules(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'not_started',
    theory_done INTEGER NOT NULL DEFAULT 0,
    exercises_done INTEGER NOT NULL DEFAULT 0,
    review_done INTEGER NOT NULL DEFAULT 0,
    notes TEXT,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE study_sessions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
    topic_id INTEGER REFERENCES topics(id) ON DELETE SET NULL,
    start_at TEXT NOT NULL,
    end_at TEXT,
    duration_minutes INTEGER NOT NULL,
    activity_type TEXT NOT NULL DEFAULT 'other',
    notes TEXT
  )''',
  'CREATE INDEX idx_sessions_start ON study_sessions(start_at)',
  '''
  CREATE TABLE books (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE,
    course_id INTEGER REFERENCES courses(id) ON DELETE SET NULL,
    title TEXT NOT NULL,
    author TEXT,
    isbn TEXT,
    edition TEXT,
    publisher TEXT,
    year INTEGER,
    format TEXT NOT NULL DEFAULT 'other',
    ownership_status TEXT NOT NULL DEFAULT 'wanted',
    physical_location TEXT,
    notes TEXT,
    file_path TEXT,
    expected_file_name TEXT,
    language TEXT,
    required INTEGER
  )''',
  '''
  CREATE TABLE materials (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE,
    course_id INTEGER REFERENCES courses(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    local_path TEXT,
    kind TEXT NOT NULL DEFAULT 'other',
    academic_year TEXT,
    author TEXT,
    source TEXT,
    notes TEXT
  )''',
  '''
  CREATE TABLE place_categories (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    icon TEXT,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE places (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE NOT NULL,
    category_id TEXT NOT NULL,
    name TEXT NOT NULL,
    lat REAL NOT NULL,
    lon REAL NOT NULL,
    address TEXT,
    city TEXT,
    description TEXT,
    phone TEXT,
    website TEXT,
    opening_hours TEXT,
    source TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE place_personal (
    place_external_id TEXT PRIMARY KEY,
    favorite INTEGER NOT NULL DEFAULT 0,
    notes TEXT
  )''',
  '''
  CREATE TABLE benefits (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    external_id TEXT UNIQUE NOT NULL,
    university_id TEXT,
    category TEXT NOT NULL,
    title TEXT NOT NULL,
    description TEXT,
    url TEXT,
    source TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE app_settings (
    key TEXT PRIMARY KEY,
    value TEXT
  )''',
];

/// v2: libri copiati dentro l'app e posizione di lettura.
/// `stored_file` è il nome del file nella cartella libri dell'app (relativo,
/// così resta valido dopo un ripristino del backup); `last_page` è l'ultima
/// pagina letta (1 = prima).
const List<String> kMigrationV2 = [
  'ALTER TABLE books ADD COLUMN stored_file TEXT',
  'ALTER TABLE books ADD COLUMN last_page INTEGER',
  'ALTER TABLE books ADD COLUMN page_count INTEGER',
  'ALTER TABLE books ADD COLUMN last_opened_at TEXT',
];

/// v3: materiali didattici copiati dentro l'app, con posizione di lettura.
const List<String> kMigrationV3 = [
  'ALTER TABLE materials ADD COLUMN stored_file TEXT',
  'ALTER TABLE materials ADD COLUMN last_page INTEGER',
  'ALTER TABLE materials ADD COLUMN page_count INTEGER',
];

/// v4: allegati di moduli e argomenti dello studio (file copiati nell'app o
/// file degli Appunti: registrazioni, trascrizioni, riassunti…) e note
/// d'esame importate (per aggiornarle finché l'utente non le modifica).
const List<String> kMigrationV4 = [
  '''
  CREATE TABLE attachments (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    module_id INTEGER REFERENCES modules(id) ON DELETE CASCADE,
    topic_id INTEGER REFERENCES topics(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    stored_file TEXT,
    path TEXT,
    created_at TEXT NOT NULL
  )''',
  'CREATE INDEX idx_attachments_module ON attachments(module_id)',
  'CREATE INDEX idx_attachments_topic ON attachments(topic_id)',
  'ALTER TABLE exams ADD COLUMN imported_notes TEXT',
  // Le note già importate dal seed (righe con external_id) si considerano
  // non modificate dall'utente.
  'UPDATE exams SET imported_notes = notes WHERE external_id IS NOT NULL',
];

/// Sezione Email: caselle configurate e cache dei messaggi (intestazioni e,
/// dopo l'apertura, il testo). Nessuna password nel database.
const List<String> kMigrationV5 = [
  '''
  CREATE TABLE mail_accounts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    label TEXT NOT NULL,
    email TEXT NOT NULL,
    username TEXT NOT NULL,
    imap_host TEXT NOT NULL,
    imap_port INTEGER NOT NULL,
    smtp_host TEXT NOT NULL,
    smtp_port INTEGER NOT NULL,
    auth TEXT NOT NULL DEFAULT 'password',
    university_id TEXT,
    enabled INTEGER NOT NULL DEFAULT 1,
    oauth_client_id TEXT,
    sort INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE mail_messages (
    account_id INTEGER NOT NULL REFERENCES mail_accounts(id) ON DELETE CASCADE,
    uid INTEGER NOT NULL,
    subject TEXT,
    from_name TEXT,
    from_email TEXT,
    to_text TEXT,
    date TEXT NOT NULL,
    seen INTEGER NOT NULL DEFAULT 0,
    has_attachments INTEGER NOT NULL DEFAULT 0,
    body_text TEXT,
    body_html TEXT,
    message_id TEXT,
    references_text TEXT,
    PRIMARY KEY (account_id, uid)
  )''',
  'CREATE INDEX idx_mail_messages_date ON mail_messages(date)',
  '''
  CREATE TABLE mail_state (
    account_id INTEGER PRIMARY KEY REFERENCES mail_accounts(id) ON DELETE CASCADE,
    uid_validity INTEGER,
    last_sync TEXT,
    last_error TEXT
  )''',
];

/// v6: percorso di studio dello studente (ateneo, corso, anno) scelto
/// nell'onboarding, stato degli anni del piano e dati del catalogo pubblico
/// (`database/corsi/<ateneo>.json`) sugli insegnamenti e sui libri.
///
/// - `profile`: una sola riga (id = 1). `current_year` è l'anno del piano
///   frequentato nell'anno accademico `reference_aa` ("2026/27");
///   `fuori_corso` = 1 se lo studente è oltre la durata normale.
/// - `plan_years`: stato di ogni anno del piano
///   (`in_corso | completato | completato_parziale | futuro`) con il suo
///   anno accademico.
/// - `courses.books_status` / `exams_status`: `completo | da_aggiungere |
///   nessun_libro` come nel catalogo ("Da aggiungere" nell'interfaccia).
/// - `books.catalog_choice`: scelta dello studente su un libro del catalogo
///   (`kept` = Tieni, `removed` = Rimuovi, null = da decidere). L'import non
///   la tocca mai, così un libro rimosso non ricompare.
/// - `books.user_edited`: 1 se lo studente ha modificato i dati del libro:
///   l'import non li sovrascrive più.
const List<String> kMigrationV6 = [
  '''
  CREATE TABLE profile (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    university_id TEXT NOT NULL,
    university_name TEXT NOT NULL,
    university_short TEXT,
    university_type TEXT,
    degree_id TEXT NOT NULL,
    degree_name TEXT NOT NULL,
    degree_type TEXT NOT NULL,
    class_code TEXT,
    duration_years INTEGER NOT NULL,
    current_year INTEGER NOT NULL,
    fuori_corso INTEGER NOT NULL DEFAULT 0,
    reference_aa TEXT NOT NULL,
    manual INTEGER NOT NULL DEFAULT 0,
    catalog_version TEXT,
    created_at TEXT,
    updated_at TEXT
  )''',
  '''
  CREATE TABLE plan_years (
    year INTEGER PRIMARY KEY,
    academic_year TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'futuro'
  )''',
  'ALTER TABLE courses ADD COLUMN books_status TEXT',
  'ALTER TABLE courses ADD COLUMN exams_status TEXT',
  'ALTER TABLE courses ADD COLUMN syllabus_url TEXT',
  'ALTER TABLE courses ADD COLUMN ssd TEXT',
  'ALTER TABLE courses ADD COLUMN mandatory INTEGER',
  'ALTER TABLE courses ADD COLUMN curriculum TEXT',
  'ALTER TABLE books ADD COLUMN catalog_choice TEXT',
  'ALTER TABLE books ADD COLUMN user_edited INTEGER NOT NULL DEFAULT 0',
];

/// v7: insegnamenti modificati dallo studente (l'aggiornamento del database
/// non riscrive nome, codice, docenti…) e lingua dell'esame scelta.
const List<String> kMigrationV7 = [
  'ALTER TABLE courses ADD COLUMN user_edited INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE courses ADD COLUMN exam_language TEXT',
];

/// v8: percorso (curriculum, orientamento) seguito dallo studente.
const List<String> kMigrationV8 = [
  'ALTER TABLE profile ADD COLUMN curriculum TEXT',
];

/// v9: sessioni Focus (Studio → Focus): modulo collegato, sessione Focus e
/// durata scelta (pause comprese).
const List<String> kMigrationV9 = [
  'ALTER TABLE study_sessions ADD COLUMN module_id INTEGER '
      'REFERENCES modules(id) ON DELETE SET NULL',
  'ALTER TABLE study_sessions ADD COLUMN focus INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE study_sessions ADD COLUMN planned_minutes INTEGER',
];

/// v10: Studio → Argomenti. `attachments.kinds`: tipo del file allegato
/// (`teoria,esercizi,ripasso`, anche più di uno; null = non indicato);
/// `modules.notes`: nota del modulo (menu «Nota»).
const List<String> kMigrationV10 = [
  'ALTER TABLE attachments ADD COLUMN kinds TEXT',
  'ALTER TABLE modules ADD COLUMN notes TEXT',
];

/// v11: argomenti e materiali da studiare importati dal database per l'esame
/// (programma ufficiale e libri dell'insegnamento). Il valore importato resta
/// accanto al campo: «Aggiorna database» lo aggiorna solo finché lo studente
/// non l'ha cambiato. Le righe esistenti partono da null: i campi vuoti si
/// riempiono al prossimo import, quelli già scritti dallo studente restano.
const List<String> kMigrationV11 = [
  'ALTER TABLE exams ADD COLUMN imported_topics TEXT',
  'ALTER TABLE exams ADD COLUMN imported_study_materials TEXT',
];

/// Categorie di luogo predefinite (dato pubblico, aggiornabile).
const List<Map<String, Object>> kDefaultPlaceCategories = [
  {'id': 'university', 'name': 'Università', 'icon': 'school', 'sort': 0},
  {
    'id': 'department',
    'name': 'Facoltà / Dipartimento',
    'icon': 'account_balance',
    'sort': 1,
  },
  {'id': 'library', 'name': 'Biblioteche', 'icon': 'local_library', 'sort': 2},
  {'id': 'study_room', 'name': 'Sale studio', 'icon': 'menu_book', 'sort': 3},
  {
    'id': 'study_room_edisu',
    'name': 'Sale studio EDISU',
    'icon': 'menu_book',
    'sort': 4,
  },
  {
    'id': 'canteen_edisu',
    'name': 'Mense EDISU',
    'icon': 'restaurant',
    'sort': 5,
  },
  {
    'id': 'residence_edisu',
    'name': 'Residenze EDISU',
    'icon': 'apartment',
    'sort': 6,
  },
  {'id': 'copy_shop', 'name': 'Copisterie', 'icon': 'print', 'sort': 7},
  {'id': 'bookshop', 'name': 'Librerie', 'icon': 'auto_stories', 'sort': 8},
  {
    'id': 'other',
    'name': 'Altri luoghi universitari',
    'icon': 'place',
    'sort': 9,
  },
];
