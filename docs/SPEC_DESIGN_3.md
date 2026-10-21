# Design 3 — specifica del nuovo aspetto

Data: 16 settembre 2026 · Stato: sistema visivo approvato dal committente

## 1. Scopo

Design 3 riveste con un nuovo aspetto le stesse schermate di Design 2. Cambiano fondo, materiale delle
card, luci, ombre e colori; **non cambiano le informazioni, gli stati, i testi inglesi e la struttura
delle schermate**. Design 2 resta intatto e continua a valere come riferimento del contenuto.

La palette non è più vincolata ai soli colori del logo: restano predominanti il blu-azzurro e
l'arancione, ma sono ammesse tinte di supporto scelte per la funzione che rappresentano.

## 2. Ambito

17 pagine, 129 superfici, 733 schermate, più il prototipo in tema chiaro. (Le tre superfici aggiunte il 18/09/2026 — U-119 orizzonte dell'obiettivo, U-120 obiettivi secondari, U-121 impostazioni Informazioni — recepiscono DX-023 e DX-072 dell'allineamento documentale. Il 18/09 sono state disegnate anche le aree 17 e 18 di Costruzione_Interfaccia: U-101–U-106 (blocchi), U-107 (accessibilità al primo avvio), U-115–U-117 (traguardi) e U-118 (richiesta di recensione); U-057 e U-058 sono state ritirate perché assorbite da U-116 e U-117, e U-108–U-114 non sono state disegnate perché il catalogo le aveva già come U-018B, U-018C, U-020B, U-022, U-024B e U-027B. Lo stesso giorno sono arrivate l'area 21, U-130 peso obiettivo e U-131 struttura dei pasti, e l'area 20 per intero, U-122–U-129: il percorso della scheda del coach, dall'ingresso in coda alla settimana fino ai consensi revocabili nel profilo.)

| Pagina | Superfici | Titolo |
|---|---|---|
| 00-foundations.html | 13 | Interface foundations |
| 01-launch.html | 4 | Launch, registration and consent |
| 02-onboarding.html | 22 | Onboarding: first session, break, second session |
| 03-triage-plan.html | 5 | Triage, generation and plan delivery |
| 04-subscription.html | 4 | Subscription: paywall, prices, management |
| 05-today.html | 3 | Today and main navigation |
| 06-plan.html | 19 | Training plan |
| 07-session.html | 7 | Workout session |
| 08-progress.html | 10 | Progress, records and photos |
| 09-nutrition.html | 13 | Nutrition: plan, diary, recipe book |
| 10-calendar.html | 3 | Calendar |
| 11-health.html | 3 | Steps, health and integrations |
| 12-profile.html | 12 | Profile and settings |
| 13-privacy.html | 2 | Privacy: consents, export, deletion |
| 14-invite.html | 2 | Invite a friend |
| 15-widgets.html | 4 | Widgets and system surfaces |
| 16-support.html | 3 | Support, legal content and global states |

Fuori ambito: nuove schermate, nuovi stati, modifiche ai testi, modifiche a Design 2.

## 3. Fondo (tema scuro)

Strati sovrapposti, nell'ordine in cui vanno dichiarati:

1. luce di sezione alta — `radial-gradient(280px 200px at 50% 28%, rgba(56,160,255,.15), transparent 72%)`
2. luce di sezione bassa — `radial-gradient(280px 200px at 50% 68%, rgba(56,160,255,.13), transparent 72%)`
3. luce d'angolo — `radial-gradient(220px 160px at 20% 6%, rgba(37,99,235,.16), transparent 70%)`
4. bordi in ombra — `radial-gradient(140% 92% at 50% 45%, transparent 52%, rgba(0,0,0,.62) 100%)`
5. base — `linear-gradient(178deg,#02060f 0%,#030b18 30%,#041122 55%,#041426 80%,#020a16 100%)`

Grana: `radial-gradient(rgba(255,255,255,.05) .6px, transparent .7px)` con passo 3px e opacità 0.12,
su uno strato che non intercetta i tocchi.

Regola: nel fondo non compare mai l'arancione.

## 4. Sezioni-card

Materiale unico, uguale per tutte le card della stessa schermata. Nessuna card è più illuminata
delle altre.

- sfondo `linear-gradient(180deg,rgba(255,255,255,.085) 0%,rgba(255,255,255,.03) 34%,rgba(255,255,255,.012) 66%,rgba(0,8,20,.34) 100%)`
- bordo `1px solid rgba(160,205,255,.11)`
- vetro `backdrop-filter: blur(14px)`
- ombre `inset 0 1px 0 rgba(255,255,255,.18)`, `inset 0 -1px 0 rgba(0,0,0,.42)`, `0 12px 26px -16px rgba(0,0,0,.92)`
- filo di luce superiore: striscia da 1px, dal 16% all'84% della larghezza, `linear-gradient(90deg,transparent,rgba(190,228,255,.42),transparent)`
- faretto interno: riquadro 250×150 ancorato a −34px dal bordo alto, `radial-gradient(closest-side,rgba(56,189,248,.13),transparent)`, dietro al contenuto
- raggio 22px

Le card interne (piatti del carosello, riquadri di valori) usano lo stesso materiale attenuato:
sfondo `rgba(255,255,255,.05)`, bordo `rgba(255,255,255,.10)`, raggio 16px, nessun faretto.

## 5. Colori

**Fondo:** `#02060f` `#030b18` `#041122` `#041426` `#020a16`

**Blu-azzurro (la macchina):** `#0EA5E9` `#38BDF8` `#7DD3FC` `#BAE6FD` `#7DE8FF`

**Arancione (l'azione dell'utente):** `#FFB064` `#FF8A1F` `#E86F08` `#FFC46B`; testo sopra l'arancione `#1A0B00`

**Testo:** principale `#F3F7FB`, secondario `rgba(235,245,255,.75)`, spento `#8FA9C4`

**Tinte di supporto**, per distinguere un'area ma mai per un'azione:
nutrizione `#34D399`, piano `#818CF8`, progressi `#C084FC`.

Regole di colore:

- l'arancione compare solo su un'azione;
- una sola azione arancione per schermata;
- il blu-azzurro segnala ciò che fa la macchina (anelli, stati calcolati, voce attiva della barra);
- il dato mancante resta `- -` e non prende colore.

## 6. Scale

Riprese da Design 2 e invariate: testo 11 · 13 · 15 · 17 · 22 · 34 · 48; pesi 300 · 400 · 600 · 700;
raggi 10 · 14 · 22 · 28 · pillola; spazi 4 · 8 · 12 · 16 · 20 · 24 · 32 · 40 · 48.

## 7. Componenti

### 7.1 Titolo della sezione-card e filigrana

Titolo piccolo (11px, peso 600, `rgba(235,245,255,.75)`), senza quadratino colorato. Quando il titolo
apre una scelta (giorno, pasto) porta la freccia in giù accanto al testo, oppure una casella a pillola
con la voce scelta, allineata a destra.

Il simbolo dell'area diventa una filigrana: icona dell'app in `currentColor`, opacità 0.15, altezza
fra 36 e 58px, ancorata al centro in verticale sul lato destro della card e dentro il bordo. Il testo
riserva almeno 64px a destra. La filigrana non sta mai sopra un testo, un pulsante o una casella;
quando la card ha un'intestazione con selettore, la filigrana si sposta accanto al selettore.

### 7.2 Anelli

Contenitore 94px, disegno su viewBox 104, raggio 44, spessore 9, estremità arrotondata, partenza dal
centro in alto (rotazione −90°).

- traccia `rgba(255,255,255,.09)`
- passi: sfumatura `#0EA5E9 → #7DE8FF`
- energia: sfumatura `#FF7A18 → #FFC46B`
- bagliore `drop-shadow(0 0 2px rgba(255,255,255,.35))` più `drop-shadow(0 0 6px <tinta> .18)`, mai tagliato dal riquadro
- icona in un disco da 26px al centro in alto, dove parte l'arco: `radial-gradient(circle at 35% 30%,#1a3558,#081626 70%)`, bordo `rgba(255,255,255,.22)`, anello scuro `0 0 0 3px rgba(3,12,26,.9)`, icona 14px
- al centro il valore (17px, peso 700), sotto l'obiettivo (10px)
- la serie di giorni si appoggia in basso a destra dell'anello dei passi

I dati senza anello (sonno, peso) stanno sotto, separati da una linea sottile, in colonne con
etichetta piccola maiuscola sopra e valore sotto. Per questi dati non si usano icone.

### 7.3 Pulsanti

- **Primario:** `linear-gradient(180deg,#FFB064 0%,#FF8A1F 52%,#E86F08 100%)`, testo `#1A0B00`, raggio 14, altezza 38–40, rilievo `inset 0 1px 0 rgba(255,236,210,.75)` e `inset 0 -2px 0 rgba(150,60,0,.35)`, ombra **neutra** `0 6px 14px -8px rgba(0,0,0,.75)`. Nessun alone arancione.
- **Secondario:** `linear-gradient(180deg,rgba(255,255,255,.10),rgba(255,255,255,.03))`, bordo `rgba(255,255,255,.14)`, testo chiaro.
- **Flottante "+":** 48px, stesso arancione del primario; è l'unico a cui è concesso l'alone (`0 14px 30px -8px rgba(255,138,31,.55)`) più un anello scuro `0 0 0 6px rgba(3,10,22,.65)`, perché galleggia sul contenuto. Non copre mai un pulsante: sopra la barra il contenuto sfuma.
- Nel piatto del carosello l'ordine è **Replace** a sinistra e **Eaten** a destra.
- Area toccabile minima 44×44 anche quando il disegno è più piccolo.

### 7.4 Barra Today / Plan / Nutrition / Progress

Barra in vetro: `linear-gradient(180deg,rgba(255,255,255,.12),rgba(255,255,255,.035) 55%,rgba(0,0,0,.18))`,
bordo `rgba(255,255,255,.14)`, `inset 0 1px 0 rgba(255,255,255,.28)`, `inset 0 -1px 0 rgba(0,0,0,.4)`,
ombra `0 18px 34px -12px rgba(0,0,0,.95)`, altezza 58, raggio 29.

Voce attiva: `linear-gradient(180deg,rgba(56,189,248,.28),rgba(14,116,190,.12))`,
`inset 0 1px 0 rgba(190,232,255,.4)`, `0 6px 16px -8px rgba(56,189,248,.6)`, testo `#DCF0FF`,
icona con `drop-shadow(0 0 6px rgba(125,211,252,.8))`. Voci spente `#8FA9C4`.
Icone: quelle dell'app (Dashboard, Piano, nutrizione, Progressi).

### 7.5 Caroselli e selettori

Il carosello mostra il primo elemento intero e lascia intravedere il successivo; sotto, i puntini con
quello attivo allungato. I selettori (unità, pasto, giorno) sono pillole di vetro con la freccia in giù
e si aprono ancorati sotto la voce che li ha aperti.

## 8. Tema chiaro

Riprogettato il 21/10/2026 («mattina limpida», `AppTokens.light` e `AppTheme.light` nell'app): stesso
impianto del tema scuro, con una gerarchia netta tra fondo, card e card interne invece del bianco su
bianco del primo prototipo.

- **Fondo:** nebbia azzurra `#F0F5FB` `#EBF1F8` `#E6EDF6` `#E8EFF7` `#EEF3F9` con tre luci di cielo
  (`#7DD3FC` al 20% in alto a sinistra, `#93C5FD` al 12% a destra, `#7DD3FC` al 10% in basso); mai
  l'arancione.
- **Card di vetro:** bianco quasi pieno (dal 100% al 97%, l'ultima fermata appena azzurra `#FAFCFF`),
  bordo `#DAE3ED`, doppia ombra morbida (contatto `0 1 2` blu notte al 6%, profondità `0 10 28 −12`
  al 10%), filo di luce azzurro `#38BDF8` al 55% sul bordo alto (come nel tema scuro), faretto quasi
  spento.
- **Card interne:** velo azzurro `#0369A1` al 5% con bordo `#0369A1` al 14% (niente grigi).
- **Testi:** principale `#0F172A`, secondario `#334155`, attenuato `#52627A` (almeno 5,3:1 anche sul
  fondo più scuro).
- **Azzurro:** `#0369A1` (link, valori, primario; bianco sopra), `#086190` (icone ed etichette),
  `#0284C7` solo per anelli e grafici; voce attiva della barra `#E0F2FE`→`#CDE9FB` con testo `#075985`.
- **Arancione:** pulsanti con la stessa sfumatura del tema scuro e testo `#1A0B00`, ombra calda
  arancione invece che nera; come testo o icona `#B93F0B` (`orangeInk`).
- **Stati:** errore `#B91C1C` (contenitore `#FDE8E8`), esito positivo `#047857`, avviso `#A35208`;
  disattivato grigio-azzurro al 18% con testo attenuato; selezionato su `#E0F2FE`; interruttore spento
  su `#E6ECF3` con contorno `#718198`.
- **Campi:** fondo `#F8FAFD`, bordo `#BCC9D8`, a fuoco `#0369A1`.
- **Finestre e card dal basso:** bianco e `#FAFCFE`, velo blu notte `#0F172A` al 35–40% invece del
  nero; avvisi in basso e suggerimenti su `#1E293B` con testo `#F1F5F9`.
- **Grafici (serie):** `#0284C7` `#4F46E5` `#0D9488` `#9333EA` `#B45309` `#DB2777` `#64748B`, tutti
  almeno 3:1 sulle card (nel tema scuro le versioni chiare `#38BDF8` `#818CF8` `#2DD4BF` `#C084FC`
  `#FBBF24` `#F472B6` `#94A3B8`).
- **Colori fissi nelle schermate** (stati degli argomenti, attività, contatori): passano da
  `readableOn(colore, luminosità, minRatio: 3 o 4,5)`, che li scurisce sul chiaro e li schiarisce sullo
  scuro quanto basta.

Il contrasto delle coppie principali dei due temi (anche ad alto contrasto) è verificato da
`app/test/theme_contrast_test.dart`.

## 9. Struttura dei file

```
Design 3/Design 3/
  css/design-system.css     token: colori, scale, fondo, testo
  css/components-3.css      componenti: card, anelli, pulsanti, barra, caroselli
  css/theme-light.css       tema chiaro
  css/canvas.css            pagina-documento (intelaiatura, etichette, indice)
  css/icons.js              icone di sistema (da Design 2)
  css/brand-icons.js        icone dell'app (da Design 2)
  assets/                   logo e immagini (da Design 2)
  00-foundations.html … 16-support.html, prototype-light.html, index.html
_lavorazione/
  generatori/               render e verifiche, adattati da Design 2
  render/                   una PNG per schermata e stato
```

## 10. Verifiche

Gli strumenti di Design 2 vengono adattati e rieseguiti su Design 3:

- `render_stati.py` — una PNG per ognuna delle 733 schermate, più l'indice;
- `verifica_design.py` — regole automatiche: niente sovrapposizioni, niente testo troncato o tagliato,
  niente parole spezzate a metà, filigrana mai sotto un testo o un pulsante, aree toccabili 44×44,
  valori dentro le scale, contrasto sufficiente, una sola azione arancione per schermata;
- controllo a vista sulle tavole di riepilogo.

Una pagina è finita quando il verificatore segna zero e la tavola è stata guardata.

## 11. Decisioni prese in questa specifica

- **L'alone arancione** resta soltanto sul pulsante flottante "+", che galleggia sul contenuto; tutti
  gli altri pulsanti pieni, "Start workout" ed "Eaten" compresi, usano l'ombra neutra.
- **Le tinte di supporto** (verde, indaco, viola) colorano al massimo un'icona o un'etichetta d'area:
  non colorano fondi di card né pulsanti, per non fare concorrenza all'azzurro e all'arancione.
- **Le icone di sonno e peso** sono state tolte dalla card del riepilogo: restano solo quelle di passi
  ed energia, dentro gli anelli.
