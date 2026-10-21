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

Solo gli insegnamenti dell'anno che lo studente frequenta e quelli degli anni
passati con l'esame non ancora superato, mai quelli degli anni successivi;
senza quelli esclusi in Impostazioni → Esclusioni (OFA, inglese, facoltativi,
riconosciuti dal nome ufficiale). Ogni voce mostra solo il nome
dell'insegnamento (`offeredInExamForm` in `exam_form.dart`).

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
