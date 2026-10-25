// Dati fittizi (ma realistici) per gli screenshot del portfolio: un corso
// inventato di Ingegneria Informatica in un ateneo generico, nessun dato
// personale. Le date sono relative a oggi e pensate per un giorno fra
// settembre e gennaio (primo semestre in corso), come le regole dell'app per
// lo stato degli insegnamenti.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:university_notes/core/catalog/catalog_models.dart';
import 'package:university_notes/core/catalog/path_setup.dart';
import 'package:university_notes/core/constants/enums.dart';
import 'package:university_notes/core/services/app_services.dart';
import 'package:university_notes/features/notes/notes_store.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/models/book.dart';
import 'package:university_notes/models/course.dart';
import 'package:university_notes/models/exam.dart';
import 'package:university_notes/models/study.dart';

import '../support/monkey_harness.dart' show wavBytes;

const kAteneoFinto = Ateneo(
  id: 'esempio',
  nome: 'Università degli Studi di Esempio',
  sigla: 'UniEsempio',
  tipo: TipoAteneo.statale,
  regioni: ['Lombardia'],
  sedi: [SedeAteneo(regione: 'Lombardia', citta: 'Milano')],
);

/// Un insegnamento del piano di Ingegneria Informatica.
class _C {
  const _C(this.nome, this.anno, this.sem, this.cfu, this.docente);
  final String nome;
  final int anno;
  final String sem;
  final double cfu;
  final String docente;
}

const _piano = <_C>[
  _C('Analisi matematica 1', 1, '1', 10, 'Prof. Bianchi'),
  _C('Fisica generale', 1, '1', 8, 'Prof.ssa Conti'),
  _C('Fondamenti di informatica', 1, '1', 10, 'Prof. Gallo'),
  _C('Algebra lineare e geometria', 1, '2', 8, 'Prof.ssa Marchetti'),
  _C('Analisi matematica 2', 1, '2', 8, 'Prof. Bianchi'),
  _C('Programmazione', 1, '2', 10, 'Prof. Gallo'),
  _C('Algoritmi e strutture dati', 2, '1', 10, 'Prof.ssa Ferraro'),
  _C('Basi di dati', 2, '1', 8, 'Prof. Villa'),
  _C('Architettura degli elaboratori', 2, '1', 8, 'Prof. Sala'),
  _C('Calcolo delle probabilità', 2, '1', 6, 'Prof.ssa Neri'),
  _C('Sistemi operativi', 2, '2', 8, 'Prof. Orsini'),
  _C('Reti di calcolatori', 2, '2', 8, 'Prof.ssa Greco'),
  _C('Ingegneria del software', 2, '2', 8, 'Prof. Riva'),
  _C('Intelligenza artificiale', 3, '1', 8, 'Prof.ssa Fontana'),
  _C('Sicurezza informatica', 3, '2', 6, 'Prof. Leone'),
];

/// [giorniFa] giorni fa alle [h]:[m] (con il costruttore, così l'ora legale
/// non sposta l'orario).
DateTime _alle(int giorniFa, int h, int m) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day - giorniFa, h, m);
}

DateTime _day(int offset) {
  final n = DateTime.now();
  return DateTime(n.year, n.month, n.day).add(Duration(days: offset));
}

/// Piano, esami, voti, studio, libri, appunti e registrazioni.
Future<void> riempiPortfolio(AppServices s) async {
  await PathSetupService(s).apply(
    const PathSelection(
      ateneo: kAteneoFinto,
      tipo: TipoCorso.l,
      manualName: 'Ingegneria Informatica',
      manualClass: 'L-8',
      manualDuration: 3,
      year: 2,
    ),
    now: DateTime.now(),
    remote: false,
  );
  await s.loadProfile();
  final profile = s.profile.value!;
  final ids = <String, int>{};
  for (final c in _piano) {
    ids[c.nome] = await s.courses.insert(
      Course(
        name: c.nome,
        universityId: kAteneoFinto.id,
        degreeId: profile.degreeId,
        year: c.anno,
        semester: c.sem,
        cfu: c.cfu,
        teacher: c.docente,
        mandatory: true,
      ),
    );
  }

  // --- esami superati del primo anno (voto, data)
  final voti = <String, (int, bool, int)>{
    'Analisi matematica 1': (27, false, -300),
    'Fisica generale': (24, false, -280),
    'Fondamenti di informatica': (30, true, -270),
    'Algebra lineare e geometria': (26, false, -140),
    'Analisi matematica 2': (25, false, -120),
    'Programmazione': (29, false, -75),
  };
  for (final e in voti.entries) {
    await s.exams.save(
      Exam(
        courseId: ids[e.key]!,
        date: _day(e.value.$3),
        time: '09:00',
        status: ExamStatus.passed,
        grade: e.value.$1,
        laude: e.value.$2,
        location: 'Aula Magna',
        examType: 'scritto+orale',
      ),
    );
  }

  Future<void> esame(
    String corso, {
    required int giorni,
    String? ora,
    required ExamStatus stato,
    String? aula,
    String tipo = 'scritto',
    String? argomenti,
    List<String> materiali = const [],
  }) => s.exams.save(
    Exam(
      courseId: ids[corso]!,
      date: _day(giorni),
      time: ora,
      status: stato,
      location: aula,
      examType: tipo,
      topics: argomenti,
      studyMaterials: materiali,
    ),
  );

  await esame(
    'Algoritmi e strutture dati',
    giorni: 88,
    ora: '09:00',
    stato: ExamStatus.booked,
    aula: 'Aula B2',
    tipo: 'scritto+orale',
    argomenti:
        'Complessità e ricorsione, alberi di ricerca e AVL, heap, tabelle '
        'hash, visite e cammini minimi nei grafi.',
    materiali: const ['Demetrescu, Finocchi, Italiano', 'Appunti delle lezioni'],
  );
  await esame(
    'Basi di dati',
    giorni: 101,
    ora: '14:30',
    stato: ExamStatus.planned,
    aula: 'Laboratorio 3',
    tipo: 'scritto+orale',
  );
  await esame(
    'Architettura degli elaboratori',
    giorni: 96,
    ora: '10:00',
    stato: ExamStatus.planned,
    aula: 'Aula A1',
  );
  await esame(
    'Calcolo delle probabilità',
    giorni: 110,
    ora: '09:00',
    stato: ExamStatus.planned,
    aula: 'Aula C4',
  );
  // prove in itinere
  await s.exams.save(
    Exam(
      courseId: ids['Algoritmi e strutture dati']!,
      kind: ExamKind.midterm,
      title: 'Prima prova in itinere',
      date: _day(11),
      time: '11:00',
      status: ExamStatus.booked,
      location: 'Aula B2',
      examType: 'scritto',
      topics: 'Complessità, ricorsione, alberi binari di ricerca e AVL.',
    ),
  );
  await s.exams.save(
    Exam(
      courseId: ids['Basi di dati']!,
      kind: ExamKind.midterm,
      title: 'Prova di SQL',
      date: _day(-9),
      time: '15:00',
      status: ExamStatus.passed,
      grade: 27,
      location: 'Laboratorio 3',
      examType: 'quiz',
    ),
  );
  await s.exams.save(
    Exam(
      courseId: ids['Basi di dati']!,
      kind: ExamKind.midterm,
      title: 'Progetto di gruppo',
      date: _day(24),
      status: ExamStatus.booked,
      examType: 'progetto',
    ),
  );
  await s.exams.save(
    Exam(
      courseId: ids['Calcolo delle probabilità']!,
      kind: ExamKind.midterm,
      title: 'Prova in itinere',
      date: _day(16),
      time: '14:00',
      status: ExamStatus.booked,
      location: 'Aula C4',
      examType: 'scritto',
    ),
  );

  await _studio(s, ids);
  await _libri(s, ids);
  await _appunti(s, ids);
}

// ------------------------------------------------------------------ studio

Future<void> _studio(AppServices s, Map<String, int> ids) async {
  // modulo: (nome, [(argomento, stato)])
  final piano =
      <String, List<(String, List<(String, TopicStatus)>)>>{
        'Algoritmi e strutture dati': [
          (
            'Complessità e ricorsione',
            [
              ('Notazione asintotica', TopicStatus.completed),
              ('Ricorrenze e teorema dell\'esperto', TopicStatus.completed),
              ('Divide et impera', TopicStatus.toReview),
            ],
          ),
          (
            'Strutture dati',
            [
              ('Liste, pile e code', TopicStatus.completed),
              ('Alberi binari di ricerca', TopicStatus.partial),
              ('Alberi AVL', TopicStatus.inProgress),
              ('Heap e code di priorità', TopicStatus.notStarted),
              ('Tabelle hash', TopicStatus.notStarted),
            ],
          ),
          (
            'Grafi',
            [
              ('Visite in ampiezza e in profondità', TopicStatus.toReview),
              ('Cammini minimi', TopicStatus.notStarted),
              ('Alberi di copertura minimi', TopicStatus.notStarted),
            ],
          ),
        ],
        'Basi di dati': [
          (
            'Modello relazionale e SQL',
            [
              ('Algebra relazionale', TopicStatus.completed),
              ('SQL: interrogazioni', TopicStatus.completed),
              ('SQL: join e raggruppamenti', TopicStatus.partial),
              ('Normalizzazione', TopicStatus.inProgress),
            ],
          ),
          (
            'Progettazione',
            [
              ('Modello entità-relazione', TopicStatus.completed),
              ('Progettazione logica', TopicStatus.notStarted),
              ('Transazioni e concorrenza', TopicStatus.notStarted),
            ],
          ),
        ],
        'Architettura degli elaboratori': [
          (
            'Linguaggio macchina',
            [
              ('Istruzioni RISC-V', TopicStatus.completed),
              ('Chiamate di procedura', TopicStatus.partial),
            ],
          ),
          (
            'Processore',
            [
              ('Percorso dei dati', TopicStatus.inProgress),
              ('Pipeline e hazard', TopicStatus.notStarted),
            ],
          ),
        ],
        'Calcolo delle probabilità': [
          (
            'Probabilità discreta',
            [
              ('Spazi di probabilità', TopicStatus.completed),
              ('Probabilità condizionata e Bayes', TopicStatus.partial),
              ('Variabili aleatorie', TopicStatus.notStarted),
            ],
          ),
        ],
      };
  final topicIds = <String, List<int>>{};
  for (final e in piano.entries) {
    var m = 0;
    for (final mod in e.value) {
      final mid = await s.study.insertModule(
        StudyModule(courseId: ids[e.key]!, name: mod.$1, sort: m++),
      );
      var t = 0;
      for (final top in mod.$2) {
        final done = top.$2 == TopicStatus.completed;
        final id = await s.study.insertTopic(
          Topic(
            moduleId: mid,
            name: top.$1,
            status: top.$2,
            theoryDone: done || top.$2 == TopicStatus.partial,
            exercisesDone: done,
            reviewDone: done && t == 0,
            sort: t++,
          ),
        );
        (topicIds[e.key] ??= []).add(id);
      }
    }
  }

  // sessioni degli ultimi ~50 giorni, più fitte nelle ultime due settimane
  final r = Random(7);
  final corsi = piano.keys.toList();
  const tipi = [
    ActivityType.theory,
    ActivityType.exercises,
    ActivityType.review,
    ActivityType.reading,
    ActivityType.theory,
    ActivityType.exercises,
  ];
  final now = DateTime.now();
  for (var d = 0; d < 50; d++) {
    final giorno = _day(-d);
    // un giorno su sette di riposo
    if (d % 7 == 5) continue;
    final n = d < 14 ? 1 + r.nextInt(2) : (r.nextInt(3) == 0 ? 0 : 1);
    for (var k = 0; k < n; k++) {
      final corso = corsi[(d + k * 2 + r.nextInt(2)) % corsi.length];
      final minuti = [30, 45, 50, 60, 75, 90, 25][r.nextInt(7)];
      final inizio = giorno.add(Duration(hours: 9 + k * 5, minutes: r.nextInt(40)));
      // niente sessioni nel futuro di oggi
      if (inizio.add(Duration(minutes: minuti)).isAfter(now)) continue;
      final tIds = topicIds[corso]!;
      await s.study.insertSession(
        StudySession(
          courseId: ids[corso],
          topicId: tIds[r.nextInt(tIds.length)],
          start: inizio,
          end: inizio.add(Duration(minutes: minuti)),
          durationMinutes: minuti,
          activityType: tipi[(d + k) % tipi.length],
          focus: r.nextInt(3) == 0,
          plannedMinutes: minuti,
        ),
      );
    }
  }
}

// ------------------------------------------------------------------- libri

Future<void> _libri(AppServices s, Map<String, int> ids) async {
  final dir = await s.library.directory();
  Future<void> libro(
    String corso,
    String titolo,
    String autori,
    String editore,
    int anno,
    BookFormat formato,
    BookOwnership possesso, {
    bool? obbligatorio,
    int? pagina,
    int? pagine,
    String? isbn,
  }) async {
    String? file;
    if (formato != BookFormat.paper && possesso == BookOwnership.owned) {
      file = '${titolo.toLowerCase().replaceAll(RegExp(r'[^a-z]+'), '_')}.md';
      File(p.join(dir.path, file)).writeAsStringSync('# $titolo\n');
    }
    await s.books.insert(
      Book(
        courseId: ids[corso],
        title: titolo,
        author: autori,
        publisher: editore,
        year: anno,
        isbn: isbn,
        format: formato,
        ownership: possesso,
        required: obbligatorio,
        storedFile: file,
        lastPage: pagina,
        pageCount: pagine,
        lastOpenedAt: pagina == null
            ? null
            : DateTime.now().subtract(Duration(days: 2 + (pagina % 5))),
        physicalLocation: formato == BookFormat.paper &&
                possesso == BookOwnership.owned
            ? 'Scaffale della camera'
            : null,
      ),
    );
  }

  await libro(
    'Algoritmi e strutture dati',
    'Algoritmi e strutture dati',
    'Demetrescu, Finocchi, Italiano',
    'McGraw-Hill',
    2020,
    BookFormat.pdf,
    BookOwnership.owned,
    obbligatorio: true,
    pagina: 187,
    pagine: 520,
  );
  await libro(
    'Algoritmi e strutture dati',
    'Introduzione agli algoritmi e strutture dati',
    'Cormen, Leiserson, Rivest, Stein',
    'McGraw-Hill',
    2010,
    BookFormat.paper,
    BookOwnership.borrowed,
    obbligatorio: false,
  );
  await libro(
    'Basi di dati',
    'Basi di dati',
    'Atzeni, Ceri, Paraboschi, Torlone',
    'McGraw-Hill',
    2018,
    BookFormat.paper,
    BookOwnership.owned,
    obbligatorio: true,
  );
  await libro(
    'Architettura degli elaboratori',
    'Struttura e progetto dei calcolatori',
    'Patterson, Hennessy',
    'Zanichelli',
    2022,
    BookFormat.ebook,
    BookOwnership.owned,
    obbligatorio: true,
    pagina: 64,
    pagine: 640,
  );
  await libro(
    'Calcolo delle probabilità',
    'Calcolo delle probabilità',
    'Sheldon M. Ross',
    'Apogeo',
    2013,
    BookFormat.paper,
    BookOwnership.wanted,
    obbligatorio: true,
  );
  await libro(
    'Sistemi operativi',
    'Sistemi operativi',
    'Silberschatz, Galvin, Gagne',
    'Pearson',
    2019,
    BookFormat.paper,
    BookOwnership.wanted,
    obbligatorio: true,
  );
  await libro(
    'Reti di calcolatori',
    'Reti di calcolatori e Internet',
    'Kurose, Ross',
    'Pearson',
    2022,
    BookFormat.pdf,
    BookOwnership.owned,
    obbligatorio: true,
    pagina: 12,
    pagine: 880,
  );
  await libro(
    'Analisi matematica 1',
    'Analisi matematica 1',
    'Bramanti, Pagani, Salsa',
    'Zanichelli',
    2014,
    BookFormat.paper,
    BookOwnership.owned,
    obbligatorio: true,
  );
  await libro(
    'Fisica generale',
    'Fisica 1: meccanica e termodinamica',
    'Mazzoldi, Nigro, Voci',
    'EdiSES',
    2020,
    BookFormat.paper,
    BookOwnership.sold,
    obbligatorio: true,
  );
  await libro(
    'Programmazione',
    'Il linguaggio C: fondamenti e tecniche di programmazione',
    'Kernighan, Ritchie',
    'Pearson',
    2004,
    BookFormat.paper,
    BookOwnership.owned,
    obbligatorio: false,
  );
}

// ----------------------------------------------------------------- appunti

/// Lezione registrata: data, titolo, durata, segmenti della trascrizione.
class Lezione {
  const Lezione(this.corso, this.quando, this.durata, this.segmenti, this.riassunto);
  final String corso;
  final DateTime quando;
  final Duration durata;

  /// (minuti dall'inizio, testo)
  final List<(int, String)> segmenti;
  final String riassunto;
}

final kLezioneAvl = Lezione(
  'Algoritmi e strutture dati',
  _alle(3, 10, 30),
  const Duration(hours: 1, minutes: 38, seconds: 12),
  const [
    (
      0,
      'Buongiorno a tutti. Oggi parliamo degli alberi AVL, cioè degli alberi '
          'binari di ricerca che si mantengono bilanciati a ogni inserimento.',
    ),
    (
      3,
      'Ricordiamo il problema: in un albero binario di ricerca la ricerca '
          'costa al più l\'altezza dell\'albero, e nel caso peggiore l\'altezza '
          'è lineare nel numero dei nodi.',
    ),
    (
      9,
      'Se inseriamo le chiavi in ordine crescente otteniamo di fatto una '
          'lista: tutte le operazioni diventano O di n. Vogliamo garantire '
          'altezza logaritmica.',
    ),
    (
      16,
      'Definiamo il fattore di bilanciamento di un nodo come la differenza '
          'tra l\'altezza del sottoalbero sinistro e quella del destro. Un '
          'albero è AVL se in ogni nodo questo valore è meno uno, zero o uno.',
    ),
    (
      27,
      'Il teorema fondamentale: un albero AVL con n nodi ha altezza minore o '
          'uguale a uno virgola quarantaquattro per il logaritmo in base due '
          'di n. La dimostrazione usa gli alberi di Fibonacci.',
    ),
    (
      41,
      'Vediamo ora le rotazioni. Quando un inserimento sbilancia un nodo '
          'ripristiniamo la proprietà con una rotazione semplice, a destra o a '
          'sinistra, oppure con una rotazione doppia.',
    ),
    (
      55,
      'Il caso sinistra-sinistra si risolve con una rotazione a destra sul '
          'nodo sbilanciato. Il caso sinistra-destra richiede prima una '
          'rotazione a sinistra sul figlio e poi una a destra sul nodo.',
    ),
    (
      68,
      'In totale servono al più due rotazioni per ogni inserimento, quindi '
          'l\'inserimento resta O di logaritmo di n. Per la cancellazione '
          'invece le rotazioni possono arrivare fino alla radice.',
    ),
    (
      82,
      'Per la prossima volta provate a costruire a mano un albero AVL '
          'inserendo le chiavi dieci, venti, trenta, quaranta, cinquanta e '
          'venticinque, annotando ogni rotazione.',
    ),
    (
      94,
      'Ci vediamo giovedì: parleremo degli heap e delle code di priorità. '
          'Buon lavoro a tutti.',
    ),
  ],
  'Alberi AVL: definizione tramite fattore di bilanciamento, altezza '
      'logaritmica garantita, rotazioni semplici e doppie.',
);

final kLezioneSql = Lezione(
  'Basi di dati',
  _alle(5, 14, 30),
  const Duration(hours: 1, minutes: 24, seconds: 40),
  const [
    (0, 'Riprendiamo da dove eravamo rimasti: le interrogazioni SQL con più tabelle.'),
    (
      6,
      'Il join naturale combina le tuple che hanno gli stessi valori sugli '
          'attributi comuni. In SQL conviene sempre esplicitare la condizione.',
    ),
    (
      19,
      'Con il raggruppamento calcoliamo funzioni aggregate come conteggio, '
          'somma e media per ogni gruppo di tuple.',
    ),
    (
      33,
      'La clausola having filtra i gruppi dopo l\'aggregazione, mentre where '
          'filtra le singole tuple prima del raggruppamento.',
    ),
  ],
  'Join, raggruppamenti e differenza tra where e having.',
);

final kLezioneRisc = Lezione(
  'Architettura degli elaboratori',
  _alle(8, 9, 0),
  const Duration(hours: 1, minutes: 12, seconds: 5),
  const [
    (0, 'Oggi vediamo come le istruzioni RISC-V diventano numeri binari.'),
    (
      11,
      'Il formato R usa tre registri e due campi di funzione, mentre il '
          'formato I contiene un valore immediato di dodici bit.',
    ),
    (
      30,
      'Le istruzioni di salto condizionato usano il formato B: l\'offset è '
          'espresso in multipli di due byte.',
    ),
  ],
  'Formati delle istruzioni RISC-V: R, I, S, B.',
);

Duration _mmss(int minuti) => Duration(minutes: minuti, seconds: (minuti * 7) % 53);

String _stampa(Duration d) {
  String due(int v) => v.toString().padLeft(2, '0');
  return '[${due(d.inHours)}:${due(d.inMinutes % 60)}:${due(d.inSeconds % 60)}]';
}

Future<File> scriviLezione(
  AppServices s,
  Course corso,
  Lezione l, {
  bool conRiassunto = true,
}) async {
  final path = await s.notes.newRecordingPath(corso, l.quando, '.wav');
  File(path)
    ..writeAsBytesSync(wavBytes(2))
    ..setLastModifiedSync(l.quando.add(l.durata));
  final base = p.basenameWithoutExtension(path);
  final segs = <TranscriptSegment>[];
  final md = StringBuffer('# Trascrizione\n\n');
  for (var i = 0; i < l.segmenti.length; i++) {
    final at = _mmss(l.segmenti[i].$1);
    final fine = i + 1 < l.segmenti.length
        ? _mmss(l.segmenti[i + 1].$1)
        : l.durata;
    segs.add(TranscriptSegment(at, fine, l.segmenti[i].$2));
    md.write('${_stampa(at)} ${l.segmenti[i].$2}\n\n');
  }
  // forma d'onda: parlato con pause e picchi
  final r = Random(l.quando.day + 3);
  final n = l.durata.inMilliseconds ~/ 100;
  final peaks = Uint8List(n);
  var level = 120.0;
  for (var i = 0; i < n; i++) {
    level += (r.nextDouble() - 0.5) * 60;
    level = level.clamp(25, 230);
    final pausa = (i ~/ 40) % 9 == 8;
    peaks[i] = (pausa ? 6 + r.nextInt(14) : level * (0.6 + r.nextDouble() * 0.4))
        .round()
        .clamp(0, 255);
  }
  final meta = RecordingMeta(
    duration: l.durata,
    started: l.quando,
    course: corso.name,
    segments: segs,
    transcriptSource: 'whisper small',
    language: 'it',
    peaks: peaks,
    bookmarks: [
      Bookmark(_mmss(16), 'Definizione di fattore di bilanciamento'),
      Bookmark(_mmss(41), 'Rotazioni'),
    ],
  );
  await meta.save(path);
  await s.notes.writeText(corso, NoteFolder.transcripts, base, md.toString());
  if (conRiassunto) {
    await s.notes.writeText(
      corso,
      NoteFolder.summaries,
      base,
      '## Riassunto\n\n${l.riassunto}\n',
    );
  }
  return File(path);
}

const kAppuntiAvl = r'''# Alberi AVL

Un **albero AVL** è un albero binario di ricerca in cui, per ogni nodo $v$,
il *fattore di bilanciamento*

$$\beta(v) = h(\mathrm{sx}(v)) - h(\mathrm{dx}(v)) \in \{-1, 0, 1\}.$$

## Altezza

Un albero AVL con $n$ nodi ha altezza $h \le 1{,}44 \log_2 n$, quindi ricerca,
inserimento e cancellazione costano $O(\log n)$.

## Rotazioni

- **Sinistra-sinistra**: rotazione semplice a destra sul nodo sbilanciato.
- **Destra-destra**: rotazione semplice a sinistra.
- **Sinistra-destra** e **destra-sinistra**: rotazione doppia.

> Dopo un inserimento servono al più **due** rotazioni.

## Da ripassare

1. Dimostrazione con gli alberi di Fibonacci
2. Cancellazione: le rotazioni risalgono fino alla radice
3. Esercizio: costruire l'albero con le chiavi 10, 20, 30, 40, 50, 25
''';

Future<void> _appunti(AppServices s, Map<String, int> ids) async {
  final corsi = await s.courses.all();
  Course corso(String n) => corsi.firstWhere((c) => c.name == n);
  await scriviLezione(s, corso(kLezioneAvl.corso), kLezioneAvl);
  await scriviLezione(s, corso(kLezioneSql.corso), kLezioneSql);
  await scriviLezione(s, corso(kLezioneRisc.corso), kLezioneRisc);
  // una seconda lezione di algoritmi, più vecchia
  await scriviLezione(
    s,
    corso('Algoritmi e strutture dati'),
    Lezione(
      'Algoritmi e strutture dati',
      _alle(10, 10, 30),
      const Duration(hours: 1, minutes: 31),
      const [
        (0, 'Oggi concludiamo la ricorsione e passiamo agli alberi binari di ricerca.'),
        (
          14,
          'Il teorema dell\'esperto permette di risolvere le ricorrenze del '
              'tipo T di n uguale a a volte T di n su b più f di n.',
        ),
      ],
      'Teorema dell\'esperto e alberi binari di ricerca.',
    ),
  );
  await s.notes.writeText(
    corso('Algoritmi e strutture dati'),
    NoteFolder.notes,
    'Alberi AVL',
    kAppuntiAvl,
  );
  await s.notes.writeText(
    corso('Basi di dati'),
    NoteFolder.notes,
    'Normalizzazione',
    '# Normalizzazione\n\nForme normali: 1NF, 2NF, 3NF e BCNF.\n',
  );
}
