import '../../models/course.dart';
import '../links/ai_assistants.dart';

/// Richieste pronte per l'AI di riferimento dello studente (ChatGPT, Claude,
/// Copilot, Perplexity, NotebookLM, Gemini), da incollare nella sua chat
/// insieme ai file del corso.
///
/// Come sono costruiti i prompt (validi per tutti i modelli):
/// 1. **Ruolo e contesto**: tutor del corso, con nome, CFU e modalità d'esame;
///    il contesto riduce le risposte generiche.
/// 2. **Materiale**: l'elenco esatto dei file allegati (nomi), così il modello
///    sa cosa deve aprire e può dire se un file manca o non si legge.
/// 3. **Regole sulle fonti**: solo il materiale allegato; ciò che manca va
///    dichiarato, le integrazioni esterne segnalate con «[integrazione]» e
///    ogni sezione riporta il file di provenienza. È la difesa principale
///    contro le invenzioni (allucinazioni), comune a tutti i modelli.
/// 4. **Compito a passi numerati**: i modelli seguono meglio istruzioni
///    ordinate e verificabili che un'unica frase lunga.
/// 5. **Formato di uscita esplicito**: Markdown con titoli, formule in LaTeX
///    ($…$), tabelle dove servono; per le flashcard anche il CSV per Anki.
///    Il Markdown resta leggibile anche copiato in altre app.
/// 6. **Varianti per servizio**: NotebookLM lavora sulle «fonti» del
///    taccuino; Perplexity cerca sul web per impostazione predefinita, quindi
///    gli si chiede di non farlo.
enum AiTask {
  summary(
    'Riassunto',
    'Riassunto strutturato con concetti chiave e definizioni',
  ),
  questions(
    'Domande d\'esame',
    'Domande tipo esame con risposta, dagli appunti e dai materiali',
  ),
  flashcards('Flashcard', 'Domande e risposte brevi da ripassare'),
  review(
    'Analizza e correggi',
    'Approfondimenti, correzioni e collegamenti tra tutti gli appunti',
  ),
  exercises(
    'Esercizi',
    'Esercizi graduati con soluzione, presi dai materiali o creati',
  ),
  plan('Piano di ripasso', 'Cosa ripassare e in che ordine fino all\'esame');

  const AiTask(this.label, this.description);
  final String label;
  final String description;

  List<String> _steps(
    Course c, {
    DateTime? examDate,
    DateTime? today,
  }) => switch (this) {
    AiTask.summary => [
      'Individua gli argomenti trattati e ordinali come nel corso (o come '
          'nel libro di testo, se presente).',
      'Per ogni argomento scrivi: spiegazione chiara e completa, '
          'definizioni, enunciati di teoremi/leggi, formule, esempi fatti '
          'a lezione e collegamenti con gli altri argomenti.',
      'Chiudi con «Da sapere per l\'esame»: un elenco di controllo dei '
          'concetti, delle formule e delle dimostrazioni da saper '
          'esporre.',
    ],
    AiTask.questions => [
      'Prepara 15 domande d\'esame realistiche per «${c.name}»'
          '${c.examMode == null ? '' : ' (modalità d\'esame: ${c.examMode})'}, '
          'dalla più semplice alla più difficile: domande di teoria, di '
          'collegamento tra argomenti e, se la materia lo prevede, '
          'esercizi o casi applicativi.',
      'Se tra i file ci sono testi d\'esame o esercitazioni, usali come '
          'modello per stile e difficoltà.',
      'Per ogni domanda scrivi la risposta modello, i punti che un '
          'docente si aspetta di sentire e il file di riferimento.',
    ],
    AiTask.flashcards => [
      'Prepara 30 flashcard, una per concetto: definizioni, formule, '
          'proprietà, differenze tra concetti simili, cause ed effetti.',
      'Domande brevi e precise; risposte di una o due righe, '
          'autosufficienti (comprensibili senza il contesto).',
    ],
    AiTask.review => [
      'Leggi gli appunti (trascrizioni, riassunti, appunti personali) e '
          'confrontali con il libro di testo e le slide allegate.',
      'Elenca gli errori e le imprecisioni: citazione dal file, '
          'correzione motivata e fonte della correzione.',
      'Elenca le lacune: passaggi mancanti, argomenti del programma non '
          'coperti, esempi da aggiungere.',
      'Indica i collegamenti tra lezioni e argomenti e, per ogni '
          'argomento, i capitoli/paragrafi del libro da studiare.',
      'Segnala le contraddizioni tra file diversi.',
    ],
    AiTask.exercises => [
      'Prepara 10 esercizi sugli argomenti del materiale, in ordine di '
          'difficoltà crescente.',
      'Quando possibile prendili dalle esercitazioni o dai temi d\'esame '
          'allegati, indicando il file; altrimenti creali sul modello di '
          'quelli del corso.',
      'Scrivi prima tutti i testi e solo dopo, in una sezione '
          '«Soluzioni», le soluzioni passo passo: così posso provare da '
          'solo prima di guardarle.',
    ],
    AiTask.plan => [
      'Valuta quali argomenti sono coperti bene e quali poco nel '
          'materiale e stima il tempo di studio necessario per ciascuno.',
      if (examDate != null)
        'L\'esame è il ${_dmy(examDate)}'
            '${today == null ? '' : ' (tra ${examDate.difference(today).inDays} giorni)'}: '
            'proponi un piano giorno per giorno fino a quella data, con '
            'ripassi distanziati e una simulazione d\'esame finale.'
      else
        'Proponi un piano di ripasso settimana per settimana, con '
            'priorità, ripassi distanziati e una simulazione d\'esame '
            'finale.',
      'Per ogni giornata/settimana indica argomenti, file da usare e '
          'obiettivo verificabile (es. «so dimostrare il teorema X»).',
    ],
  };

  List<String> _format() => switch (this) {
    AiTask.flashcards => [
      'una tabella Markdown con due colonne: Domanda | Risposta;',
      'subito dopo, un blocco di codice CSV con separatore «;» (domanda;'
          'risposta, senza intestazione) da importare in Anki.',
    ],
    AiTask.questions => [
      'per ogni domanda: «### Domanda N», poi «**Risposta**», «**Punti '
          'attesi**» (elenco) e «Fonte: nome del file».',
    ],
    AiTask.review => [
      'sezioni «Errori», «Lacune», «Collegamenti», «Da studiare sul libro» e '
          '«Contraddizioni»; nelle prime due usa una tabella con le colonne '
          'File | Testo originale | Correzione | Fonte.',
    ],
    AiTask.plan => [
      'una tabella con le colonne Giorno (o Settimana) | Argomenti | File | '
          'Obiettivo, seguita dai consigli per la sessione.',
    ],
    _ => [
      'titoli e sottotitoli (##, ###) per argomento, elenchi puntati dove '
          'aiutano e, alla fine di ogni sezione, «Fonte: nome del file».',
    ],
  };

  /// Richiesta completa per [ai]. [files]: nomi dei file allegati (o delle
  /// fonti caricate); [scope]: frase che restringe a un modulo o argomento.
  String prompt(
    Course c,
    ReferenceAi ai, {
    List<String> files = const [],
    String? scope,
    DateTime? examDate,
    DateTime? today,
  }) {
    final notebook = ai == ReferenceAi.notebooklm;
    final cfu = c.cfu == null ? '' : ', ${c.cfu!.toStringAsFixed(0)} CFU';
    final b = StringBuffer()
      ..writeln('# Ruolo')
      ..writeln(
        'Sei un tutor universitario esperto della materia «${c.name}»$cfu. '
        'Mi aiuti a preparare l\'esame partendo dal mio materiale di studio.',
      )
      ..writeln()
      ..writeln('# Materiale');
    if (files.isEmpty) {
      b.writeln(
        notebook
            ? 'Usa le fonti caricate in questo taccuino.'
            : 'Usa i file che ti allego in questa chat.',
      );
    } else {
      b.writeln(
        notebook
            ? 'Usa come fonti i file caricati in questo taccuino:'
            : 'Ti allego questi file (appunti, trascrizioni, riassunti, libri, '
                  'slide):',
      );
      for (final f in files) {
        b.writeln('- $f');
      }
    }
    if (scope != null) b.writeln(scope);
    b
      ..writeln()
      ..writeln('# Regole')
      ..writeln(
        '- Basati solo sul materiale indicato. Se un\'informazione non c\'è, '
        'scrivi «non presente nel materiale»: non inventare.',
      )
      ..writeln(
        '- Se aggiungi conoscenze tue per completare un passaggio, segnalale '
        'con «[integrazione]».',
      )
      ..writeln(
        '- Se un file non si apre o è illeggibile, dimmelo all\'inizio della '
        'risposta.',
      );
    if (ai == ReferenceAi.perplexity) {
      b.writeln('- Non cercare sul web: lavora solo sui file allegati.');
    }
    b
      ..writeln()
      ..writeln('# Compito');
    final steps = _steps(c, examDate: examDate, today: today);
    for (var i = 0; i < steps.length; i++) {
      b.writeln('${i + 1}. ${steps[i]}');
    }
    b
      ..writeln()
      ..writeln('# Formato della risposta')
      ..writeln('- In italiano, in Markdown.')
      ..writeln(
        '- **Grassetto** per i termini chiave; formule e simboli matematici '
        'in LaTeX tra \$…\$ (o \$\$…\$\$ se su una riga a sé), anche dentro '
        'tabelle ed elenchi; il simbolo \$ solo per le formule (le valute '
        'scritte per esteso, es. «5 dollari»).',
      );
    for (final f in _format()) {
      b.writeln('- ${f[0].toUpperCase()}${f.substring(1)}');
    }
    b.write('- Niente premesse o saluti: inizia direttamente dal contenuto.');
    return b.toString();
  }
}

/// Richiesta per trascrivere una registrazione con Gemini (o NotebookLM)
/// usando l'account dell'utente, senza chiave API.
String manualTranscriptionPrompt(String course, {bool notebook = false}) =>
    '${notebook ? 'Usa come fonte la registrazione caricata. ' : ''}'
    'Trascrivi integralmente e fedelmente in italiano l\'audio allegato: è '
    'una lezione universitaria del corso «$course».\n'
    '- Non riassumere, non tradurre e non correggere il contenuto.\n'
    '- Dividi in paragrafi per argomento, con l\'orario [hh:mm:ss] '
    'all\'inizio di ognuno.\n'
    '- Scrivi le formule in LaTeX tra \$…\$ (o \$\$…\$\$ su una riga a sé) '
    'e i termini tecnici come li '
    'pronuncia il docente; se una parola non si capisce scrivi [incomprensibile].\n'
    '- Rispondi solo con la trascrizione, in Markdown.';

/// Richiesta per riassumere una trascrizione con l'AI di riferimento.
String summaryOfTranscriptPrompt(String course, String fileName) =>
    'Ti allego la trascrizione di una lezione del corso «$course» '
    '(«$fileName»). Scrivi un riassunto da studio in italiano, in Markdown: '
    'titoli per argomento, definizioni, formule in LaTeX (\$…\$ nel testo, '
    '\$\$…\$\$ su una riga a sé), esempi '
    'fatti a lezione e alla fine «Da sapere per l\'esame». Basati solo sulla '
    'trascrizione: se qualcosa non si capisce, segnalalo invece di '
    'inventarlo. Niente premesse: inizia direttamente dal contenuto.';

String _dmy(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
