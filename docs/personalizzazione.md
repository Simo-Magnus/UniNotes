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
(`showSuccessSnack`), transizioni tra pagine uguali in tutta l'app
(dissolvenza in avanti; su iOS e macOS quella del sistema, con il gesto per
tornare indietro).

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
  rispettata. Pagine, contatori e conferme compaiono senza movimento.
- **Ripristina le domande**: dopo una conferma azzera tutte le scelte «Non
  chiedere più» dell'app (le impostazioni con il prefisso `dont_ask_`, es.
  `dont_ask_attachment_kind`, `dont_ask_delete_recording`:
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
