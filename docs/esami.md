# Esami e insegnamenti

Come l'app tiene esami, prove in itinere ed esoneri (sezione **Esami**) e il
nome degli insegnamenti. Codice in `app/lib/features/exams/`,
`app/lib/features/courses/`, `app/lib/repositories/exam_repository.dart` e
`course_repository.dart`; test in `app/test/exams_*.dart`.

## Stati di una prova

| Stato | Chiave | Dove si vede |
|---|---|---|
| Da prenotare | `planned` | Da sostenere |
| Prenotato | `booked` | Da sostenere (contatore «prenotati») |
| Sostenuto (in attesa dell'esito) | `taken` | Sostenuti |
| Superato | `passed` | Sostenuti, medie, CFU |
| Non superato | `failed` | Sostenuti e, per l'esame finale, anche Da sostenere |
| Annullato | `cancelled` | Sostenuti |
| Da completare | `to_complete` | Solo in Esami → Anni precedenti (vedi sotto) |

- Toccando l'icona di una prova si scelgono **due** passi
  (`nextExamStatuses` in `exam_status.dart`). «Sostenuto» apre subito il menù
  dell'esito: «In attesa dell'esito», «Non superato», «Idoneità (senza voto)»
  o un voto 18-30 (lode con 30); così «Non superato» si raggiunge da «Da
  prenotare» e da «Prenotato».
- Il menù «Voto» (dettaglio della prova e modulo) ha le stesse voci: scegliere
  un voto segna la prova come superata, «Non superato» la segna non superata.
  Le prove in itinere e gli esoneri hanno il punteggio libero e la casella
  «Non superata».
- **Non superato**: l'esame finale resta in «Da sostenere» con lo stato rosso
  visibile, finché l'insegnamento non ha un altro esame finale più avanti
  (superato, in attesa o di nuovo prenotato). Dall'icona si **riprenota**
  («Riprenota» → Prenotato): la data dell'appello già passato si toglie. Non
  entra nelle medie né nei CFU, è contato tra i «Non superati» di Sostenuti e
  delle Medie, non ha promemoria (che riguardano solo le prove da prenotare o
  prenotate).

## Un esame, uno stato

Lo stato è un solo dato, salvato sulla prova (tabella `exams`): «Da
sostenere», «Sostenuti», il dettaglio, la Home e i promemoria lo rileggono dal
database dopo ogni modifica (`revision.bump()`).

Prima lo stesso esame poteva comparire con due stati diversi perché un
insegnamento aveva **due esami finali**: quello creato dal database dei corsi
(«Da prenotare») e quello aggiunto a mano con «Nuova prova». Ora:

- una prova nuova di tipo esame finale per un insegnamento che ha già il suo
  esame finale **aggiorna** quello (il modulo lo dice sotto il menù «Corso»);
- `ExamRepository.mergeDuplicateFinals()` (all'apertura di Esami e
  Insegnamenti) unisce i doppioni già presenti: gli esami finali da prenotare o
  prenotati confluiscono nell'esame principale dell'insegnamento
  (`primaryFinal`: stato, voto e data sono i suoi, i campi vuoti si riempiono
  dai doppioni). Resta la riga creata dal database dei corsi, se c'è: ha
  l'`external_id`, quindi «Aggiorna database» non ricrea il doppione e la
  sincronizzazione tra dispositivi la riconosce. Restano anche le prove già
  sostenute e gli appelli aggiunti a mano con la loro data (tentativi veri).

## Nuova prova: menù «Corso»

Solo gli insegnamenti dell'anno che lo studente frequenta e gli arretrati
degli anni passati con l'esame non ancora superato (dall'anno di partenza in
poi, e degli anni prima solo quelli segnati «Da sostenere»: mai quelli «Da
completare»), mai quelli degli anni successivi; senza quelli esclusi in
Impostazioni → Esclusioni (OFA, inglese, facoltativi, riconosciuti dal nome
ufficiale). Ogni voce mostra solo il nome dell'insegnamento
(`offeredInExamForm` in `exam_form.dart`).

## Anni precedenti

Chi inizia a usare UniNotes al 2°, 3° anno o dopo non ha compilato gli esami
degli anni prima. Codice: `features/exams/previous_years.dart` (dati, azioni,
promemoria) e `previous_years_screen.dart` (pagina e riquadro), Home in
`features/dashboard/widgets/previous_years_card.dart`; test in
`test/previous_years_test.dart`.

- **Anno di partenza** (`profile.start_year`, schema v13,
  `StudentProfile.startYear`): l'anno di corso scelto nell'onboarding o nel
  cambio di corso (`ProfileRepository.replace`). Il passaggio al nuovo anno
  accademico non lo cambia. Sta nella tabella `profile`, quindi va nel backup
  e si sincronizza tra i dispositivi come il resto del percorso.
- **Da completare** (`to_complete`): gli esami (finali e prove in itinere)
  degli insegnamenti degli anni prima dell'anno di partenza che lo studente
  non ha mai toccato. Non sono arretrati: non compaiono in «Da sostenere», nel
  menù «Corso», nella Home (prossime prove), nei promemoria, nel calendario;
  non contano in medie, CFU, «Non superati» e statistiche. In Insegnamenti
  l'insegnamento ha lo stato «Da completare». Gli arretrati si contano
  dall'anno di partenza in avanti, più quelli degli anni prima che lo
  studente segna «Da sostenere» (o «Non superato»).
- Chi li crea: l'import del database dei corsi crea gli esami nuovi degli
  anni prima dell'anno di partenza già «Da completare»
  (`DataPackImporter._newExamStatus`); il cambio di corso segna quelli mai
  toccati (`ExamRepository.markToComplete`: da prenotare, senza voto, note,
  argomenti e materiali come li ha messi l'import). Sullo stesso corso di
  laurea si segnano solo gli anni che prima erano seguiti nell'app, così le
  scelte già fatte restano; scendendo di anno gli esami «Da completare»
  dall'anno di partenza in poi tornano «Da prenotare»
  (`restoreFromStartYear`, anche a ogni avvio).
- **Migrazione** (profili di una versione precedente, `start_year` vuoto): al
  primo avvio `ProfileRepository.ensureStartYear` ricava l'anno di partenza
  (anno frequentato meno gli anni accademici passati dalla creazione del
  profilo, almeno 1: nel dubbio più basso, quindi più arretrati come prima),
  lo salva e segna «Da completare» gli esami mai toccati degli anni prima. Una
  volta sola: poi l'anno c'è.
- **Esami → Da sostenere**: in cima il riquadro «Anni precedenti» («3 esami
  del 1° e del 2° anno da completare», pulsante «Completa»); quando non
  resta nulla diventa il riepilogo «Anni precedenti completati · 12
  sostenuti · 2 da sostenere» con «Modifica». Non c'è se l'anno di partenza
  è il 1°. Scelto il riquadro (e non una quarta scheda) perché è un compito
  da fare una volta: una scheda fissa resterebbe vuota per sempre.
- **Pagina Anni precedenti**: spiegazione con il contatore «N da
  completare», poi gli anni («1° anno · 2024/25»), ognuno con gli
  insegnamenti obbligatori e, sotto «A scelta», quelli a scelta. Ogni riga:
  solo il nome dell'insegnamento, lo stato a parole e due scelte
  («Sostenuto», «Da sostenere»). «Sostenuto» apre il menù dell'esito
  (parte da «Idoneità (senza voto)»: il voto 18-30 e la lode sono
  facoltativi; ci sono anche «Non superato» e «In attesa dell'esito»);
  toccandolo di nuovo si cambia l'esito. «Da sostenere» lo rende un
  arretrato (tornano anche le sue prove in itinere); toccandolo di nuovo
  torna «Da completare». Toccando la riga di un esame già scelto si apre il
  dettaglio della prova. Per ogni anno con obbligatori da completare
  «Segna tutti come sostenuti» (superati senza voto; i voti si aggiungono
  dopo) con la conferma «Annulla» / «Segna tutti» e la casella «Non chiedere
  più» (`dont_ask_mark_all_taken`, si ripristina da Impostazioni →
  «Ripristina le domande»). Gli insegnamenti a scelta non contano tra quelli
  da completare e «Segna tutti» non li tocca: chi non li ha scelti li lascia
  così. Non compaiono gli insegnamenti esclusi (Esclusioni), quelli a scelta
  tolti dal piano e gli archiviati.
- **Come si chiede** (`PreviousYearsPrompt`, impostazioni del dispositivo):
  - Home: riquadro «Completa gli esami degli anni precedenti» subito dopo
    l'onboarding o il cambio di corso, finché ci sono obbligatori da
    completare. Due pulsanti: «Completa» (apre la pagina) e «Più tardi» (lo
    nasconde per 7 giorni, `previous_years_later`).
  - Notifica «Esami degli anni precedenti» (canale `anni_precedenti`,
    sezione Esami): alle 18 di 3 giorni dopo l'onboarding o il cambio di
    corso (`previous_years_since`; per chi aggiorna l'app, dal primo avvio) e
    una sola ripetizione dopo 14 giorni; nessuna se non resta nulla da
    completare. Tocco → Esami → Anni precedenti. Interruttore in Impostazioni
    → Notifiche (`notif_previous_years`).
  - Scelta: il riquadro nella Home è il modo principale (si vede subito, non
    blocca nulla, si rimanda); la notifica serve a chi non riapre l'app nei
    primi giorni, con al massimo due avvisi per non essere insistente; la
    pagina resta in Esami per completare con calma.

Limiti noti: gli insegnamenti che il database dei corsi toglie (cambio di
piano) con un esame «Da completare» si archiviano invece di sparire (lo
stato conta come dato dello studente in `retireStaleCourses`); le prove in
itinere del database spostate di data restano nascoste se «Da completare».
Su un dispositivo con una versione precedente dell'app «Da completare» si
legge come «Da prenotare».

## Eliminare una prova

Dialogo «Eliminare la prova?» con «Annulla» ed «Elimina» e la casella «Non
chiedere più» (impostazione `dont_ask_delete_exam`, si annulla da Impostazioni
→ «Ripristina le domande»). L'esame finale di un insegnamento a scelta, che
toglie l'insegnamento dal piano, chiede sempre.

«Segnala date d'esame» non c'è più: le date dipendono dal canale e dal
docente, si indicano su ogni prova.

## Nome dell'insegnamento

- Si cambia toccando il nome nel dettaglio della prova o dell'insegnamento, o
  dal modulo dell'insegnamento. Il nome scelto sta in `courses.custom_name`
  (schema v12); `courses.name` resta il nome ufficiale del database dei corsi.
- `Course.name` restituisce il nome scelto o, se non c'è, quello ufficiale
  (`officialName`): tutte le sezioni (Esami, Insegnamenti, Studio, Registra,
  Libri, Home, notifiche, calendario) lo leggono dall'insegnamento, nessuna ne
  tiene una copia. Le cartelle di registrazioni e appunti seguono il nome
  nuovo (`NotesStore.renameCourse`).
- «Aggiorna database» riscrive solo `name`: il nome scelto resta. Cambiare il
  nome non segna più l'insegnamento come «modificato a mano» (`user_edited`),
  così codice, docenti, anno e CFU continuano ad aggiornarsi.
- **Ripristina il nome originale**: l'icona nel campo del nome, oppure il
  campo svuotato. La riga «Nome originale: …» compare sotto il nome quando è
  stato cambiato.
- OFA ed esclusioni si riconoscono dal nome ufficiale, anche se lo studente ha
  rinominato l'insegnamento.
- La colonna fa parte della tabella `courses`: va nel backup e nella
  sincronizzazione con OneDrive e Google Drive come gli altri dati.
- Gli insegnamenti aggiunti a mano non hanno un nome ufficiale: cambiarne il
  nome cambia direttamente `name`.
