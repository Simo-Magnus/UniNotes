# Studio: Argomenti e Sessioni Studio

Codice in `app/lib/features/study/`. Tre schede: **Argomenti**, **Sessioni
Studio**, **Statistiche**. Sopra le schede, solo se gli insegnamenti vengono
da più atenei, il filtro per ateneo: nessuna scelta = tutti (niente «Tutte»).
Gli insegnamenti compaiono solo con il loro nome.

## Argomenti (`topics_tab.dart`, `module_card.dart`, `topic_tile.dart`)

- **Card dell'insegnamento**: nome (toccalo per cambiare insegnamento:
  si apre l'elenco; su schermi larghi c'è anche l'elenco a sinistra),
  avanzamento, numero di moduli e argomenti, **Libri**, **Registrazioni**,
  **Sessione focus** (Sessioni Studio con l'insegnamento scelto, «Tutto
  l'insegnamento» e il timer pronto), **Revisiona con AI**, «Aggiungi
  modulo». Non c'è più la card «Corso».
- **Revisiona con AI** (`study_ai.dart`): un dialogo con *Modulo* («Tutto
  l'insegnamento» o un modulo), *Argomento* (dopo aver scelto un modulo:
  «Tutto il modulo» o un argomento) e *Che cosa chiedere* (riassunto,
  domande d'esame…), con Annulla e Continua; poi il prompt e i file da
  allegare. Dal menu di un modulo o di un argomento la scelta parte già
  impostata.
- **Modulo**: titolo (toccalo per nome e nota), argomenti fatti/totali,
  barra di avanzamento, nota, file del modulo (allegati in passato).
  Menu ⋮: **Sessione focus sul modulo**, **Revisiona con AI**, **Elimina
  modulo**, **Nota**.
- **Argomento**: **pallino dello stato** a sinistra (toccalo per cambiare
  stato), poi il nome; toccando la riga si apre la **nota** (con il nome,
  per correggerlo). Sotto, rientrati: la nota, i **file allegati** e
  **Aggiungi file** (dagli appunti del corso o dal dispositivo). Menu ⋮:
  Sessione focus sull'argomento, Revisiona con AI, Elimina argomento, Nota.
- **File allegati** (`attachments.dart`, `AttachmentTile`): ogni file è una
  casella con l'icona del tipo di file, il titolo (tocca per aprirlo) e le
  icone colorate di **Teoria** (blu), **Esercizi** (arancione) e **Ripasso**
  (viola) che gli sono state assegnate (anche più di una). Il menu ⋮ della
  casella segna o toglie i tipi e rimuove il file. Le spunte
  Teoria/Esercizi/Ripasso sull'argomento non ci sono più: lo stato si
  sceglie dal pallino.
- **Spostare** moduli e argomenti: tieni premuto il titolo del modulo (o la
  riga dell'argomento) e trascinalo; l'ordine si salva subito
  (`reorderModules`, `reorderTopics`). Niente più «Sposta su/giù».

Database (migrazione v10, `schema.dart`): `attachments.kinds` (`teoria,
esercizi,ripasso`, null = non indicato) e `modules.notes`.

## Sessioni Studio (`study_sessions_tab.dart`)

Focus e Sessioni in un'unica schermata:

1. **Che cosa studi**: insegnamento → modulo («Tutto l'insegnamento») →
   argomento («Tutto il modulo»), più l'attività. La scelta vive in
   `StudyTimer.instance` e vale per cronometro e timer; durante una
   sessione resta bloccata.
2. **File**: una card per modulo (o una sola per l'argomento scelto) con
   tutti i file allegati, divisi per argomento; un tocco li apre.
3. **Cronometro** o **Timer** (scelta a due):
   - cronometro: tempo grande, **Avvia/Pausa**; sotto **Elimina** e
     **Salva** (sotto il minuto non si salva);
   - timer: come il Focus (durata, pause automatiche, silenzio del sistema;
     vedi [focus.md](focus.md)); con una sessione in corso l'anello e «Apri
     la sessione».
4. **Obiettivo di oggi** e **Focus questa settimana**.
5. **Storico** delle sessioni (ultimi 60 giorni ↔ tutte, «Aggiungi» per una
   sessione a mano, tocco per modificarla).

La regolazione e la spiegazione del Non disturbare sono in **Impostazioni →
Focus e Non disturbare** (`focus/focus_quiet_section.dart`).

Test: `app/test/study_screen_test.dart`, `app/test/study_timer_test.dart`,
`app/test/focus_test.dart`.
