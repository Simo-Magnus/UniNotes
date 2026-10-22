# Studio: Argomenti e Sessioni Studio

Codice in `app/lib/features/study/`. Tre schede: **Argomenti**, **Sessioni
Studio**, **Statistiche**. Sopra le schede, solo se gli insegnamenti vengono
da più atenei, il filtro per ateneo: nessuna scelta = tutti (niente «Tutte»).
Gli insegnamenti compaiono solo con il loro nome.

## Argomenti (`topics_tab.dart`, `module_card.dart`, `topic_tile.dart`)

- **Card dell'insegnamento**: nome (toccalo per cambiare insegnamento),
  avanzamento, numero di moduli e argomenti, **Libri**, **Registrazioni**,
  **Sessione focus** (Sessioni Studio con l'insegnamento scelto, «Tutto
  l'insegnamento» e il timer pronto), **Revisiona con AI**, «Aggiungi
  modulo». Con almeno un modulo c'è un secondo **«Aggiungi modulo» sotto
  l'ultimo modulo** (stessa azione, così con tanti moduli non si torna in
  cima): riga contornata a tutta larghezza al livello delle card dei
  moduli, alta 44 px, diversa da «Aggiungi argomento» (pulsante di testo
  dentro il modulo). Senza moduli resta solo quello in alto (niente
  doppione). Lo verifica `study_sessions_stats_focus_test.dart`.
  Menu ⋮ accanto al nome (se ci sono moduli): **Ordina i moduli**
  e **Rimuovi tutti i moduli** (moduli, argomenti e file allegati
  dell'insegnamento, dopo la conferma; le sessioni di studio restano).
  Non c'è più la card «Corso».
- **Elenco degli insegnamenti** (`pickCourse`, `CoursePickerList`,
  `course_groups.dart`): diviso in **1° semestre**, **2° semestre**,
  **Annuale** (e «Semestre non indicato»; con l'anno davanti se gli anni
  sono più d'uno) e **OFA** in fondo (nome con «OFA» o «obblighi
  formativi»). Solo il nome dell'insegnamento, niente stato.
  L'insegnamento scelto (`CoursePickTile`) **non è in azzurro**, il colore
  dei titoli dei gruppi: è segnato con l'arancione «da testo» dell'app
  (`AppTokens.orangeInk`, la scelta dell'utente nel Design 3) come
  barretta a sinistra, fondo appena tinto, nome in semigrassetto e spunta;
  contrasto ≥ 4,5:1 sul foglio in tema scuro, chiaro e ad alto contrasto
  (verificato nei test). Tenendo
  premuto un insegnamento e trascinandolo se ne cambia l'ordine dentro il
  suo gruppo: si salva (`study_course_order` in `app_settings`, id in JSON)
  e vale in tutto Studio (menu di Sessioni Studio e Statistiche). Il primo
  insegnamento aperto è il primo «in corso» nell'ordine scelto. Su schermi
  larghi non c'è più l'elenco laterale con nomi e stato: la colonna degli
  argomenti è centrata (max 880 px).
- **Revisiona con AI** (`study_ai.dart`): un dialogo con *Modulo* («Tutto
  l'insegnamento» o un modulo), *Argomento* (dopo aver scelto un modulo:
  «Tutto il modulo» o un argomento) e *Che cosa chiedere* (riassunto,
  domande d'esame…), con Annulla e Continua; poi il prompt e i file da
  allegare. Dal menu di un modulo o di un argomento la scelta parte già
  impostata.
- **Modulo**: titolo (toccalo per nome e nota; **tienilo premuto** per
  l'ordine dei moduli), argomenti fatti/totali, barra di avanzamento,
  nota, file del modulo (allegati in passato). Menu ⋮: **Sessione focus
  sul modulo**, **Revisiona con AI**, **Elimina tutti gli argomenti** (il
  modulo resta; con conferma), **Elimina modulo**, **Nota**.
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
  Aggiungendo file (dal dispositivo o dagli appunti) l'app chiede **«Che
  tipo di file è?»**: caselle Teoria, Ripasso, Esercizi (anche più d'una o
  nessuna; all'inizio è segnata Teoria, poi l'ultima scelta), la casella
  **«Non chiedere più»** e i pulsanti Annulla / Allega
  (`chooseAttachmentKinds`). Con «Non chiedere più» si usa sempre l'ultimo
  tipo scelto (`attachment_kind_last`; la scelta è in
  `dont_ask_attachment_kind`: tutte le domande «Non chiedere più» usano
  chiavi `dont_ask_…`, da azzerare insieme con un ripristino delle domande
  nelle Impostazioni).
- **Spostare gli argomenti**: tieni premuta la riga e trascinala. La riga
  si solleva (ombra, scala del 3%, filo azzurro: `reorder_lift.dart`), le
  altre scorrono per farle posto e, portandola verso il bordo alto o basso
  dello schermo, la pagina scorre da sola, tanto più veloce quanto più la
  riga va oltre il bordo (fino a ~1200 px/s): così si porta un argomento
  oltre quelli fuori dallo schermo. Gli argomenti stanno in un viewport
  senza scorrimento proprio (`ShrinkWrappingViewport` +
  `SliverReorderableList`), quindi lo scorrimento automatico muove la
  pagina. Con «Riduci animazioni» niente scala né transizione del
  sollevamento.
- **Ordine dei moduli** (`module_order_dialog.dart`): tenendo premuto il
  nome di un modulo (o da ⋮ dell'insegnamento → Ordina i moduli) si apre al
  centro una finestra di vetro con tutti i moduli numerati (quello premuto
  evidenziato): tieni premuto un modulo, o trascina la maniglia a destra,
  e portalo dove vuoi. L'ordine si salva a ogni spostamento
  (`reorderModules`); un solo pulsante, «Fatto». I moduli non si
  trascinano più direttamente nella pagina.

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
   - anello del timer (`FocusRing`, anche nella schermata della sessione):
     cifre grandi in proporzione all'anello (~22% del diametro per «25:00»,
     17% con le ore), semigrassetto, a larghezza fissa (tabular figures),
     colore pieno del testo (in pausa quello secondario); si rimpiccioliscono
     solo le cifre se non ci stanno. Etichetta e riga sotto hanno una
     larghezza propria e si accorciano con «…» invece di rimpicciolire il
     tempo. L'anello è grande quanto la larghezza permette (schermata: fino
     a 380 px; card: 180-260 px).
4. **Obiettivo di oggi** e **Focus questa settimana**.
5. **Sessioni** (storico, `sessions_tab.dart`): accanto al titolo la
   casella dell'intervallo (`SessionRange`: Oggi, Ultimi 7 giorni, Ultimi
   15 giorni, Ultimi 30 giorni, Ultimi 60 giorni, Ultimi 6 mesi, Ultimo
   anno; sempre oggi compreso, da mezzanotte). Si apre su **Ultimi 7
   giorni**; la scelta resta finché l'app è aperta (cambiando scheda o
   sezione) e torna a 7 giorni al riavvio. Titolo, casella e «Aggiungi»
   stanno sulla stessa riga, centrati in verticale, con area di tocco di
   44 px. Ogni sessione ha l'**icona della sua attività** nel cerchio del
   colore della materia (Teoria `menu_book`, Esercizi `edit_note`, Ripasso
   `replay` come i tipi dei file; Lettura `auto_stories`, Simulazione
   `quiz`, Altro `category`, tutte «outlined»); le sessioni Focus hanno in
   più un bollino con l'icona Focus. Le stesse icone sono nei menu
   «Attività». Tocco su una sessione per modificarla.

## Statistiche (`stats_tab.dart`)

In alto 7 giorni / 30 giorni / Sempre per riepilogo e ripartizioni.

- **Per materia** e **Per argomento**: tempo e barra della quota, senza la
  percentuale sul totale (`ProgressRow(showPercent: false)`); «Per
  attività» la mantiene.
- **Per argomento**: casella con **Tutte le materie** (unica eccezione alla
  regola «niente Tutti», chiesta dall'utente) e i nomi delle materie con
  almeno una sessione, nell'ordine di Studio.
- Grafici, sempre sugli stessi periodi: **Giornaliero (ultimi 7 giorni)**
  (oggi compreso), **Mensile (ultime 4 settimane)** (settimane da lunedì,
  questa compresa) e **Semestrale (ultimi 6 mesi)** (questo mese
  compreso).

La regolazione e la spiegazione del Non disturbare sono in **Impostazioni →
Focus e Non disturbare** (`focus/focus_quiet_section.dart`).

Test: `app/test/study_screen_test.dart`, `app/test/study_reorder_test.dart`,
`app/test/study_timer_test.dart`, `app/test/focus_test.dart`,
`app/test/study_sessions_stats_focus_test.dart`.

Gruppi degli insegnamenti (`course_groups.dart`): semestri scritti in modo
diverso ma con la stessa etichetta («1» e «1° semestre» da dati importati)
finiscono in un gruppo solo, così negli elenchi non ci sono chiavi doppie e
il selettore della Home li raggiunge tutti. Dati limite (vuoti, enormi, fuori
scala, caratteri ×3, 320 px, finestra ridimensionata a metà animazione):
`app/test/crash_ui_test.dart`.
