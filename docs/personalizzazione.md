# Suoni, aspetto e formule

Tre cose che valgono in tutta l'app: suoni e vibrazioni con le
microinterazioni, contrasto e grandezza dei caratteri, formule LaTeX nel
testo dell'utente.

## Suoni e vibrazioni

Impostazioni → **Suoni e vibrazioni**: interruttori **Suoni** (predefinito
attivo: suoni brevi e discreti) e **Vibrazioni** (solo sul telefono,
predefinito attivo; sul PC il sistema non le ha e l'interruttore non c'è).

Un servizio unico (`app/lib/core/feedback/`): le schermate chiamano un
evento (`FeedbackEvent`), il servizio sceglie suono e vibrazione secondo le
preferenze (`feedbackFor`, logica pura).

| Evento | Suono | Vibrazione | Dove |
|---|---|---|---|
| tocco | — | leggera | pulsanti principali (Avvia, pulsante flottante +, voci della barra) |
| scelta | — | selezione | interruttori, schede, scelte |
| conferma | `conferma` | leggera | appunto salvato, sessione del cronometro salvata, esame salvato |
| traguardo | `conferma` | media | argomento completato, esame superato |
| avviso | `avviso` | media | errore del registratore |
| inizio / fine Focus | `focus_inizio` / `focus_fine` | media / forte | sessione Focus |
| inizio / fine pausa | `pausa_inizio` / `pausa_fine` | leggera | sessione Focus |
| inizio / fine registrazione | `registrazione_inizio` / `registrazione_fine` | media | registratore |

I suoni sono **generati da codice**, nessun file preso da internet:
`app/tool/genera_suoni.py` (Python, solo libreria standard) scrive in
`app/assets/suoni/` dei WAV mono 16 bit a 44,1 kHz, da 35 ms a 2,2 s, con
picco tra il 22 e il 34% del massimo. Per rigenerarli:
`python tool/genera_suoni.py` dalla cartella `app/`. Li riproduce media_kit
(già usato dal lettore), con due lettori a turno; se l'audio non si apre i
suoni si spengono senza errori.

**Microinterazioni** (`core/feedback/motion.dart`): pulsanti principali che
si abbassano appena alla pressione (`Pressable`, scala 0,96), contatori che
scorrono al nuovo valore (`AnimatedCount`: argomenti completati, minuti di
oggi, settimana Focus), spunta con un piccolo rimbalzo nelle conferme
(`showSuccessSnack`).

**Animazioni come su iOS, su tutte le piattaforme** (dal 24/10/2026):

- **Cambio di pagina** (`IosPageTransitionsBuilder` in `motion.dart`, nel tema
  per Android, iOS, Windows, macOS e Linux): la pagina nuova entra da destra
  con la curva e la durata di iOS (500 ms) e l'ombra sul bordo sinistro;
  quella sotto scorre a sinistra di un terzo (parallasse) e si scurisce appena.
  Si torna indietro trascinando dal bordo sinistro (dito, o mouse su PC), con
  il gesto «Indietro» di Android 14+ (la pagina segue il dito invece di
  chiudersi solo alla fine), con due dita verso destra sul touchpad del PC e
  con il tasto «Indietro» del mouse. Il tasto «Indietro» di Android e i tasti
  di navigazione funzionano come prima. I gesti non partono sulla prima pagina,
  durante una transizione e sui moduli che chiedono conferma prima di chiudere
  (`PopScope`).
- **Moduli a schermo intero** (aggiungi/modifica libro, esame, insegnamento,
  voti dell'anno, onboarding: route con `fullscreenDialog`): salgono dal basso
  come i moduli di iOS; la pagina sotto resta ferma. «Aggiungi libro» aveva una
  dissolvenza propria (`PageRouteBuilder`) che lasciava vedere la lista dei
  libri attraverso il form: ora usa la stessa route degli altri moduli.
- **Finestre e fogli dal basso** (`showAppDialog`, `showAppSheet` in
  `core/feedback/app_modals.dart`, usati da tutta l'app al posto di
  `showDialog`/`showModalBottomSheet`): la molla di iOS (`kIosSpring`,
  smorzamento critico, rigidità 522,35 come `CASpringAnimation`). Le finestre
  compaiono con dissolvenza e un leggero ingrandimento all'indietro (da 1,15 a
  1, come gli avvisi di iOS) in 404 ms e si chiudono con una dissolvenza rapida;
  i fogli salgono in 450 ms e scendono in 320 ms con la molla rovesciata. Il
  fondo sotto si scurisce come prima, senza contenuti sovrapposti.
- **Riquadri che si aprono** (`ExpansionTile`): la molla al posto di 200 ms che
  acceleravano verso la fine (`kIosExpansionAnimation` nel tema).
- **Sezioni principali** (barra in basso sul telefono, colonna di navigazione
  su tablet e PC; `SectionStack` in `core/router/section_stack.dart`):
  dissolvenza «fade through» di Material in 240 ms (curva easeOutCubic): la
  sezione uscente sparisce nel primo terzo, poi la nuova compare con un
  leggero ingrandimento (da 0,96 a 1). Le due non si vedono mai insieme, quindi
  la sezione sotto non traspare attraverso quella nuova (fondo trasparente
  sopra quello dell'app) e non c'è nessun lampo nel tema scuro.

**Sezioni persistenti**: ogni sezione si costruisce la prima volta che si apre
e poi resta viva nascosta (prima si ricostruiva da zero a ogni cambio, con il
cerchio di caricamento). Tornandoci restano scheda interna, scorrimento,
filtri e ricerca, e i dati si rileggono senza cerchio (`RevisionBuilder`
mostra quelli di prima finché arrivano i nuovi; con la sezione nascosta un
`revision.bump()` non ricarica niente, si rilegge al ritorno). Le sezioni
nascoste non si disegnano, non ricevono tocchi, tasti né fuoco, il lettore
dello schermo non le legge, le loro animazioni sono ferme (`TickerMode`), gli
`Hero` spenti, e la sezione File nascosta non prende i file trascinati sulla
finestra. `SectionActive` (in `widgets/section_active.dart`) dice ai widget se
la loro sezione è visibile; il mixin `SectionReturn` rilegge al ritorno ciò
che si leggeva a ogni apertura (stato di OneDrive, Google Drive e Whisper,
permessi del calendario e delle notifiche). Dettagli:
- dopo l'avvio (1,5 s, una alla volta) si preparano nascoste Registra, Studio
  ed Esami: anche la prima apertura è senza attesa; le altre sezioni si
  costruiscono alla prima apertura. Il cerchio di caricamento compare solo se
  un caricamento dura più di 250 ms (`DelayedSpinner`);
- corso, percorso o anno mostrato cambiati («Cambia corso», selettore
  dell'anno, nuovo anno accademico): le sezioni nascoste si ricreano da zero
  alla prossima apertura; con poca memoria (avviso del sistema) si buttano;
- una richiesta di scheda di Studio (notifica Focus, «Avvia» nella Home) vale
  anche con Studio già costruita (`StudyScreen.tabRequest`);
- toccare la voce già attiva riporta la sezione in cima, come su iOS (anche il
  tocco sulla barra di stato di iOS); ogni sezione ha il suo
  `PrimaryScrollController`, quindi le liste delle sezioni nascoste non si
  agganciano a quello della pagina;
- passando dalla barra in basso alla colonna di navigazione (rotazione del
  tablet, finestra ridimensionata) le sezioni restano le stesse.

Test: `tab_switch_test.dart`.

**Pagine opache durante le transizioni** (`PageBackdrop` in `motion.dart`): le
schermate hanno lo Scaffold trasparente e le card sono di vetro traslucido.
Sotto la pagina che entra (o esce) si stende lo stesso fondo dell'app, pieno e
già disegnato come immagine (`RepaintBoundary`), e scorre con la pagina: della
pagina sotto si vede solo la parte scoperta, come nella parallasse di iOS, e si
compone una sola pagina alla volta. A transizione finita il fondo si toglie
(identico a quello dell'app) e le pagine sotto non si disegnano più (route
opache), quindi non costa nulla a regime.

**Fluidità**: la transizione si ricostruisce a ogni fotogramma, quindi lì ci
sono solo widget leggeri (la pagina è già salvata come immagine dalla route);
le vecchie transizioni proprie di «Aggiungi libro» e dell'ordine dei moduli
creavano una curva nuova a ogni fotogramma (ascoltatori che si accumulavano),
ora tolte. Il vetro non usa `BackdropFilter`. Le immagini del lettore sono già
ridotte alla decodifica (`limitedImage`).

**«Riduci animazioni»** (sistema o app): pagine, sezioni, finestre, fogli e
riquadri compaiono e scompaiono subito; durante un gesto «Indietro» la pagina segue
comunque il dito. Finché la route è in movimento la pagina resta opaca.
Restano con le animazioni di Material i menu a tendina e i menu dei tre
puntini (brevi).

Test: `page_transitions_test.dart` (transizioni, opacità, gesti, «Riduci
animazioni») e `ios_motion_test.dart` (finestre, fogli, molla e controllo che
nel codice non ci siano `showDialog`, `showModalBottomSheet`,
`PageRouteBuilder` o route trasparenti). Da provare su un telefono vero: la
fluidità (profilo della timeline) e il gesto «Indietro» di Android 14+.

## Aspetto

Contrasto e grandezza del testo si scelgono già nel **primo passo
dell'onboarding** («Come preferisci leggere?», prima della ricerca
dell'ateneo, con la stessa anteprima): le schermate successive si leggono
subito come preferisce lo studente. Poi si cambiano in Impostazioni →
**Aspetto**, oltre al tema:

- **Contrasto**: Standard o **Alto contrasto** (`AppTokens.highContrast`):
  testi più chiari nel tema scuro e più scuri nel tema chiaro (testo
  secondario almeno 10:1, testo spento almeno 7:1 sulle card), bordi più
  marcati, card quasi opache invece delle trasparenze deboli. Arancione
  delle azioni e azzurro restano quelli di Design 3.
- **Grandezza dei caratteri**: cinque passi (Piccolo 0,9 · Standard ·
  Grande 1,15 · Più grande 1,3 · Massimo 1,5) con anteprima. Si moltiplica
  per la grandezza scelta nel sistema (anche quella non lineare di Android
  14+), entro 0,85–2× (`AppTextScaler` in `core/theme/display_prefs.dart`),
  ed è applicata a tutta l'app con il `textScaler` del MediaQuery.
- **Riduci animazioni**: oltre all'impostazione del sistema, che è sempre
  rispettata. Pagine, finestre, fogli dal basso, riquadri che si aprono,
  contatori e conferme compaiono senza movimento.
- **Ripristina le domande**: dopo una conferma azzera tutte le scelte «Non
  chiedere più» dell'app (le impostazioni con il prefisso `dont_ask_`, es.
  `dont_ask_attachment_kind`, `dont_ask_delete_recording`,
  `dont_ask_delete_exam`:
  `resetDontAskQuestions` in `features/settings/sections/questions_reset.dart`).
  Ogni nuova casella «Non chiedere più» usa una chiave con quel prefisso.

Con i caratteri grandi le schermate principali non si rompono:
`app/test/large_text_test.dart` apre Studio (tutte le schede), la sessione
Focus, Impostazioni, Home, Esami, Insegnamenti, Libri e la barra in basso a
1,5× e 2× su un telefono da 400 px e fallisce a ogni testo che esce dal suo
spazio. Le righe che uscivano ora vanno a capo (data della Home, contatori
degli esami, intestazione degli atenei negli Insegnamenti, percentuali di
avanzamento). La barra in basso e i riquadri flottanti hanno un'altezza
fissa di Design 3: lì i caratteri crescono fino a 1,3×.

## Formule LaTeX

Le formule scritte nel testo dell'utente si vedono disegnate (pacchetto
`flutter_math_fork` 0.7.4) in: appunti, trascrizioni, riassunti e risposte
dell'AI (vista Markdown, `features/notes/markdown_view.dart`), nomi e note di
moduli e argomenti di Studio, programmi e descrizioni degli insegnamenti,
argomenti delle prove.

| Scrittura | Risultato |
|---|---|
| `$x^2$`, `\(x^2\)` | formula nella riga |
| `$$E = mc^2$$` dentro una riga | formula «a sé» nella riga |
| `$$` … `$$` o `\[` … `\]` su righe proprie | formula centrata su righe proprie (scorre se è larga) |
| `\$` | il simbolo del dollaro |

**Il `$` usato come valuta non apre una formula**: dopo il `$` non ci deve
essere uno spazio, un `$` seguito da un numero e poi da uno spazio, dalla
punteggiatura o dalla fine è un prezzo (`costa $5 al mese`, `$10,50`,
`5$ e 10$`), e serve un `$` di chiusura non preceduto da uno spazio e non
seguito da una cifra. Nei blocchi di codice e nel codice in linea niente
formule. Logica in `features/notes/markdown_lite.dart` (`parseInline`,
`parseMathOnly`, `parseMarkdown`), test in `app/test/math_latex_test.dart`.

**Errori**: una formula con un errore di sintassi (o un comando non
supportato) resta scritta così com'è, in rosso, con i suoi delimitatori:
mai un crash.

**Editor degli appunti**: il pulsante **Σ Inserisci formula** apre un campo
LaTeX con i modelli rapidi (frazione, potenza, radice, somma, integrale,
limite, matrice, lettere greche) e l'**anteprima dal vivo**; si sceglie «Nella
riga» o «Su una riga a sé» e la formula entra al cursore (o al posto del
testo selezionato). Se `$…$` si confonderebbe con un prezzo (es. `2 x`) si
usa `\(…\)`.

**AI**: le richieste di riassunti, domande, flashcard e trascrizioni
(`features/notes/ai_prompts.dart`, da usare nell'app dell'AI di riferimento)
chiedono formule in LaTeX tra `$…$` (o `$$…$$` su una riga a sé) e di non
usare il `$` per altro.

Limiti: nell'esportazione in PDF e nel lettore universale (file Markdown
aperti da File) le formule restano in LaTeX, in carattere monospaziato; le
formule non si selezionano né si cercano con «Trova nel testo».
