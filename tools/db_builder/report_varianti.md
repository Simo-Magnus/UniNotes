# Varianti italiano/inglese: revisione

Generato da `ripulisci.py` il 2026-10-11. Regola (`pulizia._abbinamento`): stesso corso, anno, CFU e SSD; nome della versione inglese in inglese e della versione italiana in italiano; i due nomi devono essere la traduzione l'uno dell'altro (parole affini, dizionario `_TRADUZIONI`, titoli in uso `_FRASI`; numeri e lettere di modulo uguali) con somiglianza almeno 0,60 (0,75 per gli insegnamenti a scelta e per le coppie nello stesso piano, «gemelli»; −0,10 con docenti in comune; 0,90 se il semestre è diverso, 0,75 con docenti in comune); abbinamenti uno a uno, i casi a pari punteggio restano separati.

- **tenuta**: variante già presente che rispetta la regola;
- **annullata**: variante tolta dall'insegnamento; se il corso non aveva già quell'insegnamento inglese, è tornato un insegnamento a sé (campi della variante; anno, CFU, SSD dal genitore; percorso e obbligatorietà dal dato originale dell'adapter quando c'è);
- **nuova**: variante creata ora (percorso in lingua inglese o stesso piano).

Le annullate contano ogni coppia insegnamento/variante tolta (una versione inglese poteva essere variante di più insegnamenti); «ricreate» sono le versioni inglesi tornate insegnamenti a sé.

| Ateneo | Tenute | Annullate | Ricreate come insegnamenti | Nuove |
|---|---:|---:|---:|---:|
| iulm | 0 | 0 | 0 | 1 |
| liuc | 0 | 0 | 0 | 4 |
| luiss | 0 | 0 | 0 | 4 |
| polimi | 0 | 0 | 0 | 24 |
| polito | 65 | 140 | 109 | 25 |
| unica | 0 | 0 | 0 | 6 |
| unicatt | 0 | 0 | 0 | 2 |
| unifi | 0 | 0 | 0 | 5 |
| unime | 0 | 0 | 0 | 3 |
| unimore | 0 | 0 | 0 | 3 |
| unipd | 0 | 0 | 0 | 1 |
| unipg | 0 | 0 | 0 | 4 |
| uniroma1 | 38 | 185 | 77 | 0 |
| unite | 0 | 0 | 0 | 7 |
| unito | 0 | 0 | 0 | 2 |
| **totale** | 103 | 325 | 186 | 91 |

Note sulla prima revisione (ottobre 2026):

- le 186 versioni inglesi ricreate hanno tutte il percorso del dato originale dell'adapter (`database/contrib/auto/<ateneo>.json`); una (PoliTO) è stata poi unita a un insegnamento omonimo da `unisci_omonimi`;
- le 52 coppie «gemelli» misurate prima della revisione: 37 tenute perché traduzioni (PoliTO «Reti di calcolatori»/«Computer networks», «Sistemi operativi»/«Operating systems», …; una è stata abbinata come percorso in lingua inglese), 15 scartate (moduli A/B dello stesso insegnamento, «Applicazioni di Cad»/«Applicazioni Gis», «Storia del diritto di famiglia»/«Venetian Law History», «Diritto dei contratti e digitalizzazione»/«International Contract Law», …); la nuova regola ne trova altre 46 in PoliMi (insegnamenti «a numero chiuso» in inglese), UniCa, UniTE, UniFI e altri (elenco sotto);
- non trattati: i percorsi inglesi senza «in lingua inglese» nel nome (es. PoliMi «International track», LIUC «BE - …», LUMSA «PROGRAMMA INTERNAZIONALE»), che hanno percorsi distinti da quello italiano e quindi non sono né `varianti_lingua` né «gemelli».

## Annullate (325)

| Ateneo | Corso | Insegnamento italiano | Versione inglese | Somiglianza | Note |
|---|---|---|---|---:|---|
| polito | polito-l-17-architettura | Atelier Fondamenti di Progettazione da Tabella 1 (05SSEWG) | Architecture Design Studio (01SUHWG) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-17-architettura | Atelier Fondamenti di Progettazione da Tabella 1 - GYT () | Architecture Design Studio (01SUHWG) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| polito | polito-l-23-ingegneria-edile | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMH) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMH) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMH) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMH) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Tecnologie digitali in medicina - Intraprendenti (01WEXMH) | Ingegneria delle cellule e dei tessuti (01QZOMH) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Tecnologie digitali in medicina - Intraprendenti (01WEXMH) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMH) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Tecnologie digitali in medicina - Intraprendenti (01WEXMH) | Ingegneria nelle terapie medico-chirurgiche (01QZQMH) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMH) | Energia, progresso e sostenibilità (01OYZMH) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-23-ingegneria-edile | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMH) | Energy transition and society (Grandi Sfide - Energia) (01DEQMH) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-35-matematica-per-l-ingegneria | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMQ) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMQ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-35-matematica-per-l-ingegneria | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMQ) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMQ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-35-matematica-per-l-ingegneria | Tecnologie digitali in medicina - Intraprendenti (01WEXMQ) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMQ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-35-matematica-per-l-ingegneria | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMQ) | Energia, progresso e sostenibilità (01OYZMQ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-35-matematica-per-l-ingegneria | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMQ) | Energy transition and society (Grandi Sfide - Energia) (01DEQMQ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMC) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMC) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Tecnologie digitali in medicina - Intraprendenti (01WEXMC) | Ingegneria delle cellule e dei tessuti (01QZOMC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Tecnologie digitali in medicina - Intraprendenti (01WEXMC) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Tecnologie digitali in medicina - Intraprendenti (01WEXMC) | Ingegneria nelle terapie medico-chirurgiche (01QZQMC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMC) | Energia, progresso e sostenibilità (01OYZMC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-civile | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMC) | Energy transition and society (Grandi Sfide - Energia) (01DEQMC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMO) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMO) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMO) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMO) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Tecnologie digitali in medicina - Intraprendenti (01WEXMO) | Ingegneria delle cellule e dei tessuti (01QZOMO) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Tecnologie digitali in medicina - Intraprendenti (01WEXMO) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMO) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMO) | Energia, progresso e sostenibilità (01OYZMO) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-7-ingegneria-per-l-ambiente-e-il-territorio | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMO) | Energy transition and society (Grandi Sfide - Energia) (01DEQMO) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXNX) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHNX) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXNX) | Politica e tecnica (Grandi Sfide - Digitale) (01DEINX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Tecnologie digitali in medicina - Intraprendenti (01WEXNX) | Ingegneria delle cellule e dei tessuti (01QZONX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Tecnologie digitali in medicina - Intraprendenti (01WEXNX) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECNX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Tecnologie digitali in medicina - Intraprendenti (01WEXNX) | Ingegneria nelle terapie medico-chirurgiche (01QZQNX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYNX) | Energia, progresso e sostenibilità (01OYZNX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-elettronica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYNX) | Energy transition and society (Grandi Sfide - Energia) (01DEQNX) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXOD) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHOD) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXOD) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIOD) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Tecnologie digitali in medicina - Intraprendenti (01WEXOD) | Ingegneria delle cellule e dei tessuti (01QZOOD) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Tecnologie digitali in medicina - Intraprendenti (01WEXOD) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECOD) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Tecnologie digitali in medicina - Intraprendenti (01WEXOD) | Ingegneria nelle terapie medico-chirurgiche (01QZQOD) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYOD) | Energia, progresso e sostenibilità (01OYZOD) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-fisica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYOD) | Energy transition and society (Grandi Sfide - Energia) (01DEQOD) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-ingegneria-informatica | Algoritmi e strutture dati (03AAXYE) | Introduction to databases (01RKWYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.60) |
| polito | polito-l-8-ingegneria-informatica | Algoritmi e strutture dati (03AAXYE) | Computer architecture (02KTMYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| polito | polito-l-8-ingegneria-informatica | Basi di dati (14AFQYE) | Algorithms and data structures (01URNYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| polito | polito-l-8-ingegneria-informatica | Basi di dati (14AFQYE) | Computer architecture (02KTMYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| polito | polito-l-8-ingegneria-informatica | Calcolatori elettronici (12AGAYE) | Introduction to databases (01RKWYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| polito | polito-l-8-ingegneria-informatica | Calcolatori elettronici (12AGAYE) | Algorithms and data structures (01URNYE) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| polito | polito-l-8-l-9-ingegneria-gestionale | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXPL) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHPL) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXPL) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXPL) | Progettazione di applicazioni Internet (02HQZPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Tecnologie digitali in medicina - Intraprendenti (01WEXPL) | Ingegneria delle cellule e dei tessuti (01QZOPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Tecnologie digitali in medicina - Intraprendenti (01WEXPL) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Tecnologie digitali in medicina - Intraprendenti (01WEXPL) | Ingegneria nelle terapie medico-chirurgiche (01QZQPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYPL) | Energia, progresso e sostenibilità (01OYZPL) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-8-l-9-ingegneria-gestionale | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYPL) | Energy transition and society (Grandi Sfide - Energia) (01DEQPL) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Conflitti tra scienza, tecnologia e umanità (01HOGLZ) | Technology and innovation in everyday life. The Social Study of Science and Technology (01WUULZ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLZ) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHLZ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLZ) | Politica e tecnica (Grandi Sfide - Digitale) (01DEILZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Equipaggiamenti di bordo e sistemi avionici (02IJOLZ) | Evoluzione dei veicoli aerospaziali (01OQDLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Equipaggiamenti di bordo e sistemi avionici (02IJOLZ) | Sistemi di bordo aerospaziali (01MZBLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Introduzione alla meccanica del volo (01OEMLZ) | Fondamenti di meccanica del volo (01NFBLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Onde coerenti: dalle applicazioni ottiche alla computazione quantistica (01TNZLZ) | Introduzione all'informazione e calcolo quantistico (01UEHLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Onde coerenti: dalle applicazioni ottiche alla computazione quantistica (01TNZLZ) | Introduzione alle nanotecnologie (02JNULZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Propulsione aeronautica (02IHTLZ) | Fondamenti di macchine e propulsione (01MYYLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Reti e sistemi complessi: dai social network alle reti neurali (01TOBLZ) | Compatibilità elettromagnetica nell'integrazione dei sistemi (01QYYLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Tecnologie digitali in medicina - Intraprendenti (01WEXLZ) | Ingegneria delle cellule e dei tessuti (01QZOLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Tecnologie digitali in medicina - Intraprendenti (01WEXLZ) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Tecnologie digitali in medicina - Intraprendenti (01WEXLZ) | Ingegneria nelle terapie medico-chirurgiche (01QZQLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLZ) | Energia, progresso e sostenibilità (01OYZLZ) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-aerospaziale | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLZ) | Energy transition and society (Grandi Sfide - Energia) (01DEQLZ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-biomedica | Tecnologie digitali in medicina - Intraprendenti (01WEXMA) | Ingegneria delle cellule e dei tessuti (01QZOMA) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-biomedica | Tecnologie digitali in medicina - Intraprendenti (01WEXMA) | Ingegneria nelle terapie medico-chirurgiche (01QZQMA) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-biomedica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMA) | Energia, progresso e sostenibilità (01OYZMA) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMB) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMB) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMB) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMB) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Tecnologie digitali in medicina - Intraprendenti (01WEXMB) | Ingegneria delle cellule e dei tessuti (01QZOMB) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Tecnologie digitali in medicina - Intraprendenti (01WEXMB) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMB) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Tecnologie digitali in medicina - Intraprendenti (01WEXMB) | Ingegneria nelle terapie medico-chirurgiche (01QZQMB) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMB) | Energia, progresso e sostenibilità (01OYZMB) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-chimica-e-alimentare | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMB) | Energy transition and society (Grandi Sfide - Energia) (01DEQMB) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLS) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHLS) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLS) | Politica e tecnica (Grandi Sfide - Digitale) (01DEILS) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Tecnologie digitali in medicina - Intraprendenti (01WEXLS) | Ingegneria delle cellule e dei tessuti (01QZOLS) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Tecnologie digitali in medicina - Intraprendenti (01WEXLS) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECLS) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLS) | Energia, progresso e sostenibilità (01OYZLS) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-dei-materiali | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLS) | Energy transition and society (Grandi Sfide - Energia) (01DEQLS) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-elettrica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLX) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHLX) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-elettrica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXLX) | Politica e tecnica (Grandi Sfide - Digitale) (01DEILX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-elettrica | Tecnologie digitali in medicina - Intraprendenti (01WEXLX) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECLX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-elettrica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLX) | Energia, progresso e sostenibilità (01OYZLX) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-elettrica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYLX) | Energy transition and society (Grandi Sfide - Energia) (01DEQLX) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMK) | Cybersecurity and National Defence (Grandi Sfide - Digitale) (01DEHMK) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Dati, algoritmi e le frontiere dell'informatica - Intraprendenti (01GDXMK) | Politica e tecnica (Grandi Sfide - Digitale) (01DEIMK) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Tecnologie digitali in medicina - Intraprendenti (01WEXMK) | Ingegneria delle cellule e dei tessuti (01QZOMK) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Tecnologie digitali in medicina - Intraprendenti (01WEXMK) | Bio e nano tecnologie in medicina (Grandi Sfide - Salute) (01DECMK) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Tecnologie digitali in medicina - Intraprendenti (01WEXMK) | Ingegneria nelle terapie medico-chirurgiche (01QZQMK) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMK) | Energia, progresso e sostenibilità (01OYZMK) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-l-9-ingegneria-energetica | Tecnologie per l'accumulo di energia - Intraprendenti (01WEYMK) | Energy transition and society (Grandi Sfide - Energia) (01DEQMK) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Accounting and Corporate finance (03PEBYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | stesso nome (non è una traduzione); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Accounting and Corporate finance (03PEBYC) | Strategy and Organization (01QYQYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Analisi dei sistemi economici (05PBVYC) | Economics (09OIYYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Produzione assistita dal calcolatore (03BYKYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Quality Engineering (01OJDYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Gestione dell'innovazione e sviluppo prodotto (01KSUYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Innovation management and product development (01KYOYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Qualità nei Servizi e Customer Experience (01HHIYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Simulazione dei sistemi gestionali (01QGDYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Analysis and Management of Production Systems (01PPOYC) | Sustainable Manufacturing (01QGKYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Business law (05KYJYC) | Business law (03KYJYC) | 0.00 | stesso nome (non è una traduzione) |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Aruba (01WYHYC) | Business intelligence per big data (01RLBYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Aruba (01WYHYC) | Tecnologie e metodi per la trasformazione digitale (01VJPYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Idra Water (01WYJYC) | Economics and Innovation Management for the New Space Economy (01DVZYC) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Idra Water (01WYJYC) | Entrepreneurship (04JPYYC) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Idra Water (01WYJYC) | Imprenditorialità e business planning (01JEFYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Idra Water (01WYJYC) | Marketing (03BNTYC) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by Firms - Idra Water (01WYJYC) | Sustainable business management (01VJSYC) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Challenge@PoliTo by firms - Leonardo (02WYLYC) | Space exploration and resources (01DWBYC) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Corporate governance and finance (02TUOYC) | Economics (09OIYYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Economia aziendale (09AQGYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| polito | polito-lm-31-ingegneria-gestionale | Economia aziendale (09AQGYC) | Strategy and Organization (01QYQYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| polito | polito-lm-31-ingegneria-gestionale | Economics and business finance (01RRXYC) | Economics (09OIYYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Gestione dei progetti (10BDAYC) | Supply Chain Management (01QKLYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Information systems (02PDWYC) | Business intelligence per big data (01RLBYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Information systems (02PDWYC) | Tecnologie e metodi per la trasformazione digitale (01VJPYC) | 0.00 | il nome della versione inglese è italiano |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Produzione assistita dal calcolatore (03BYKYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Gestione dell'innovazione e sviluppo prodotto (01KSUYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Innovation management and product development (01KYOYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Qualità nei Servizi e Customer Experience (01HHIYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Simulazione dei sistemi gestionali (01QGDYC) | 0.00 | il nome della versione inglese è italiano; ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Sustainable Manufacturing (01QGKYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| polito | polito-lm-31-ingegneria-gestionale | Marketing (12BNTYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Marketing (12BNTYC) | Strategy and Organization (01QYQYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Organizational Models and HRM (01VHTYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Organizational Models and HRM (01VHTYC) | Strategy and Organization (01QYQYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Seminari per Tesi I/Thesis Seminar I (01WRZYC) | Thesis Seminar II (01VWOYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| polito | polito-lm-31-ingegneria-gestionale | Seminari per Tesi II/Thesis Seminar II (01WSAYC) | Thesis Seminar I (01VUCYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| polito | polito-lm-31-ingegneria-gestionale | Strategia e organizzazione (01QYPYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| polito | polito-lm-31-ingegneria-gestionale | Strategy and Organization (03QYQYC) | Accounting and Corporate finance (01PEBYC) | 0.00 | il nome della versione italiana è inglese |
| polito | polito-lm-31-ingegneria-gestionale | Strategy and Organization (03QYQYC) | Strategy and Organization (01QYQYC) | 0.00 | stesso nome (non è una traduzione) |
| polito | polito-lm-33-ingegneria-meccanica | Progettazione meccanica e trazione elettrica di veicoli su rotaia (01VJHYJ) | Dynamic design of machines (01OAIYJ) | 0.00 | i nomi non sono una traduzione (somiglianza 0.14 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia Aziendale (10626921) | Financial Reporting (10629126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia Politica (10629264) | Microeconomics (10626700) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia Politica (10629264) | Macroeconomics (10628047) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia delle Amministrazioni Pubbliche (1018181) | Budgeting and Business Planning (10616669) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia delle Amministrazioni Pubbliche (1018181) | Financial Analysis and Valuation (10616689) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia e Politica Monetaria (1017110) | Economic Policy (10600042) | 0.00 | i nomi non sono una traduzione (somiglianza 0.67 < 0.90) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia e Tecnica dei Mercati Mobiliari (1038113) | Banking and Finance (10616677) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia e gestione delle imprese (1017104) | Strategy and Performance Management (10616664) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Energia, Materie Prime ed Innovazione (1022404) | Energy and Commodity Management (10616691) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Management (1017158) | Marketing Management (10616745) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Management (1017159) | Entrepreneurship (10616674) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Marketing (1018184) | Marketing Management (10616745) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Matematica Corso Base (10626923) | Calculus and Linear Algebra (10627460) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Organizzazione aziendale (1017194) | Organization and Hr Management (10616676) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Produzione e Distribuzione Assicurativa Danni e Vita (10592730) | Banking and Finance (10616677) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Ragioneria (10626924) | Business Administration (10627264) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Ragioneria (10626924) | Financial Reporting (10629126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Revisione Aziendale (1017238) | Budgeting and Business Planning (10616669) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Revisione Aziendale (1017238) | Financial Analysis and Valuation (10616689) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Statistica Corso Base (1015450) | Statistics and Probability (10616666) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Tecnologia dei Cicli Produttivi (1017266) | Energy and Commodity Management (10616691) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Complementi di Politica Economica (1018168) | Labour Economics (10616723) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Complementi di Politica Economica (1018168) | Monetary and Financial Policy (10616722) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Dello Sviluppo (98422) | International Trade and Finance (10616726) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Dello Sviluppo (1017101) | Intermediate Macroeconomics (10616724) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Dello Sviluppo (1017101) | Intermediate Microeconomics (10616721) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Finanziaria (1035358) | International Trade and Finance (10616726) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Internazionale (1017122) | Intermediate Macroeconomics (10616724) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Internazionale (1017122) | Intermediate Microeconomics (10616721) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Internazionale (98431) | International Trade and Finance (10616726) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Politica (10629264) | Microeconomics (10626700) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia Politica (10629264) | Macroeconomics (10628047) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia aziendale (10626921) | Financial Reporting (10629126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia del Lavoro (1013874) | Monetary and Financial Policy (10616722) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Gestione della Banca (1018163) | Banking and Finance (10616677) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Istituzioni Dell'unione Europea (10606557) | Intermediate Macroeconomics (10616724) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Istituzioni Dell'unione Europea (10606557) | Intermediate Microeconomics (10616721) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Politica Monetaria (1017111) | Labour Economics (10616723) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Politica Monetaria (1017111) | Monetary and Financial Policy (10616722) | 0.00 | i nomi non sono una traduzione (somiglianza 0.67 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Politica del Welfare State (1018171) | Labour Economics (10616723) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia e Politica del Welfare State (1018171) | Monetary and Financial Policy (10616722) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Matematica Corso Base (10626923) | Calculus and Linear Algebra (10627460) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Metodi Statistici Avanzati (1017178) | Statistics and Probability (10616666) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Metodi Statistici Avanzati (1017178) | Statistical Inference (10616720) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.60) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Ragioneria (10626924) | Business Administration (10627264) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Ragioneria (10626924) | Financial Reporting (10629126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Statistica Corso Base (1015450) | Statistics and Probability (10616666) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Statistica Corso Base (1015450) | Statistical Inference (10616720) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Storia Dell'analisi Economica (1031664) | Intermediate Macroeconomics (10616724) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Storia Dell'analisi Economica (1031664) | Intermediate Microeconomics (10616721) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Degrado e Colore (10626882) | Geomaterials for Cultural Heritage (10627631) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Degrado e Colore (1037390) | Geomaterials for Cultural Heritage (10589750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Laboratorio di Fisica per Analisi Microclimatiche (10630265) | Climate Risk Assessment of Cultural Heritage (10627064) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Metodi della Ricerca Archeologica (10631145) | Experiment and Experience in Archaeology (10630878) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.65); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Metodi della Ricerca Archeologica (10631145) | Stone Tool Technology Laboratory (10626795) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Minerali Metallici e Gemme: Uso e Provenienza (10629412) | Geomaterials for Cultural Heritage (10627631) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-11-scienze-e-tecnologie-per-la-conservazione-dei-beni-culturali | Paleobiologia e Paleopatologia (10627273) | Bioarchaelogy and Cultural Heritage (10629521) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Analisi delle Serie Storiche (10626728) | Advanced Statistics for Finance (10628346) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Economia dei Mercati e degli Intermediari Finanziari Internazionali (10626665) | International Banking and Capital Markets (10625952) | 0.00 | i nomi non sono una traduzione (somiglianza 0.40 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Economia dei Mercati e degli Intermediari Finanziari Internazionali (10626665) | Artificial Intelligence in Banking and Finance (10627362) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Finanza Quantitativa (10629173) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Matematica Attuariale per le Assicurazioni Private (10632640) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Matematica Attuariale per le Assicurazioni Private (10632640) | Quantitative Financial Modelling (10627215) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Matematica corso avanzato (10626033) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Matematica corso avanzato (10626033) | Quantitative Financial Modelling (10627215) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Metodi e Modelli per la Finanza (1055921) | Risk Management and Capital Requirements (10592806) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Ottimizzazione e Gestione dei Rischi Finanziari (10620927) | Risk Management and Capital Requirements (10592806) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Probabilità e Processi Stocastici per le Assicurazioni e la Finanza (10627488) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.60) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Probabilità e Processi Stocastici per le Assicurazioni e la Finanza (10627488) | Quantitative Financial Modelling (10627215) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Tecnica e Finanza delle Assicurazioni (1018106) | Risk Management and Capital Requirements (10592806) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Teoria del Rischio (10628581) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Teoria del Rischio (10628581) | Quantitative Financial Modelling (10627215) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Teoria e Tecnica Attuariale per la Previdenza (1055924) | Risk Management and Capital Requirements (10592806) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Catalisi per L'industria e per L'ambiente (10628032) | Process and Product Safety in the Chemical Industry (10631331) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.90) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Computer Aided Process Control (10592819) | Chemical and Biochemical Plants (10616730) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Impianti di Trattamento degli Effluenti Gassosi (1019252) | Environmental Chemical Engineering (10616731) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Impianti di Trattamento degli Effluenti Gassosi (1019252) | Nanobiotechnology (10592628) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Principi di Ingegneria Biochimica (10629318) | Non Equilibrium Thermodynamics With An Application to the Microscale (10628944) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Principi di Ingegneria Biochimica (10629318) | Chemical Reactors (10629915) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Processi di Polimerizzazione (10628194) | Process and Product Safety in the Chemical Industry (10631331) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Progettazione degli Impianti Chimici II (1034948) | Environmental Chemical Engineering (10616731) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Progettazione degli Impianti Chimici II (1034948) | Nanobiotechnology (10592628) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Reattori Chimici (10625822) | Non Equilibrium Thermodynamics With An Application to the Microscale (10628944) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Sicurezza degli Impianti Chimici (1026994) | Chemical and Biochemical Plants (10616730) | 0.00 | i nomi non sono una traduzione (somiglianza 0.67 < 0.75) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Sistemi di Controllo degli Impianti Chimici (1034949) | Chemical and Biochemical Plants (10616730) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.75) |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Tecnologie Metallurgiche (10626042) | Advanced Metallic Materials (10629209) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Termodinamica Dell'ingegneria Chimica II (10626967) | Transport Phenomena in Multiphase Systems (10629492) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Termodinamica Dell'ingegneria Chimica II (10626967) | Principles of Biochemical Engineering (10630081) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-26-ingegneria-della-sicurezza-e-protezione-civile | Sicurezza degli Approvvigionamenti Energetici (10620970) | Sustainable Use of Underground Resources (10600038) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Accelerator Physics and Relativistic Electrodynamics (1042011) | Optical Quantum Technology (10589516) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Advanced Antenna Engineering (1042004) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Advanced Electromagnetics and Scattering (1042016) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Circuiti a Tempo Discreto (1021745) | Computational Intelligence (1044577) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Communication Theory and Engineering (10630086) | Radar Systems (10627354) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Compatibilita' Elettromagnetica (1042013) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.17 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Componenti Elettronici Integrati (10630500) | Digital Integrated System Architectures (10629539) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Componenti e Circuiti per L'elettronica di Potenza (1056159) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Design of Microprocessors and Accelerators (10621422) | Nanoelectronics Laboratory (1041750) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Digital Integrated Circuit Architectures (10627496) | Integrated Electronic Devices (10631058) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Digital Integrated Circuit Architectures (10627496) | Digital Integrated System Architectures (10629539) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Digital System Programming (1052242) | Nanoelectronics Laboratory (1041750) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Earth Observation (10589999) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Elaborazione delle Immagini (10627684) | Radar Systems (10627354) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Electromagnetic Technologies for Communications and Sensing (10621076) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Elettronica Analogica con Applicazioni (1021777) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Elettronica per L'ambiente (1021782) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Embedded Systems (1038139) | Nanoelectronics Laboratory (1041750) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Ground Penetrating Radar (1056086) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Interazione Bioelettromagnetica II (1021814) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Interazione Bioelettromagnetica i (1021813) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Laser Fundamentals (1041749) | Optical Quantum Technology (10589516) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Machine Learning for Signal Processing (1056158) | Computational Intelligence (1044577) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Microsistemi Fotonici (1021841) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Optics (1042012) | Optical Quantum Technology (10589516) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Optoelectronics and Photonic Applications (10630703) | Integrated Electronic Devices (10631058) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Optoelectronics and Photonic Applications (10630703) | Digital Integrated System Architectures (10629539) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Pattern Recognition (1044589) | Computational Intelligence (1044577) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Progetto di Circuiti Integrati (1021866) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Progetto di Sistemi Microelettronici a Radiofrequenza (1021868) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Quantum Computing and Neural Networks (10616834) | Computational Intelligence (1044577) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Radiofrequency Electronic Systems (10627025) | Integrated Electronic Devices (10631058) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Radiofrequency Electronic Systems (10627025) | Digital Integrated System Architectures (10629539) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Radiopropagation (1038350) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Recupero di Antenne (1056181) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Recupero di Comunicazioni Elettriche (10628297) | Radar Systems (10627354) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Recupero di Elettronica Digitale (1056185) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Recupero di Elettronica II (1056184) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Remote Sensing (10621500) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Sensori Integrati e Dispositivi di Sensing (10620470) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Sistemi Microelettromeccanici (1019528) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Strumentazione e Tecniche per la Diagnostica (1042021) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Tecnologie e Processi per L'elettronica (1044618) | Nanoelectronics Laboratory (1041750) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Teoria Dell'informazione e Codici i (10628917) | Radar Systems (10627354) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Therapeutic Applications of Low Frequency Electromagnetic Fields (10589485) | Artificial Materials - Metamaterials and Plasmonics for Electromagnetic Applications (10589170) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Wireless Access Networks (10628443) | Radar Systems (10627354) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Advanced Nuclear Energy Systems (10620729) | Fusion Reactor Technology (10616488) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Analisi di Rischio Negli Impianti Industriali (10627776) | Engineering Thermofluids (10626373) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Diagnostica delle Macchine e dei Sistemi Energetici (10627635) | Fluid Machinery (10626799) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Dinamica e Controllo degli Impianti Energetici (10616682) | Fusion Reactor Technology (10616488) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Energy Management (1047241) | Lighting Design (10600032) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Energy Management (1047241) | Principles and Design of Smart Cities (10600079) | 0.00 | il nome della versione italiana è inglese; ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Fondamenti di Termoidraulica Bifase (10627755) | Engineering Thermofluids (10626373) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Impianti Elettrici di Utilizzazione e Microreti Sostenibili e Intelligenti (10627128) | Electric Power Systems (10632129) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Impianti Elettrici di Utilizzazione e Microreti Sostenibili e Intelligenti (10627128) | Smart Grid for Power Systems (10626174) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Misure e Caratterizzazione di Materiali Nucleari (10600059) | Radiation Protection (1052082) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Modelli di Analisi dei Sistemi Energetici (10600083) | Fusion Reactor Technology (10616488) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Progettazione di Edifici Eco-sostenibili (10628564) | Sustainable Energy - Resources and Applications (10627126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Progettazione di Impianti di Riscaldamento Ventilazione e Condizionamento (10600052) | Lighting Design (10600032) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.90) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Progettazione di Impianti di Riscaldamento Ventilazione e Condizionamento (10600052) | Principles and Design of Smart Cities (10600079) | 0.00 | i nomi non sono una traduzione (somiglianza 0.20 < 0.90) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Radiazioni Ottiche Naturali e Artificiali (10616475) | Lighting Design (10600032) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Radiazioni Ottiche Naturali e Artificiali (10616475) | Principles and Design of Smart Cities (10600079) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Radioprotezione per L'ambiente e la Medicina Nucleare (1047248) | Radiation Protection (1052082) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Sostenibilita' Energetica Ambientale (10626617) | Sustainable Energy - Resources and Applications (10627126) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.75) |
| uniroma1 | uniroma1-lm-35-ingegneria-per-l-ambiente-e-il-territorio | Costruzioni Idrauliche per L'ambiente e il Territorio (10628135) | Hydraulic Risk Assessment and Mitigation (10629049) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-35-ingegneria-per-l-ambiente-e-il-territorio | Idraulica Ambientale e Marittima (10626937) | Urban Climate (10628852) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-35-ingegneria-per-l-ambiente-e-il-territorio | Impianti di Trattamento delle Acque (1017651) | Waste Management (10620255) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-35-ingegneria-per-l-ambiente-e-il-territorio | Pianificazione Territoriale (10626225) | Sustainable Development and Planning (10627059) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-35-ingegneria-per-l-ambiente-e-il-territorio | Studio di Impatto Ambientale e Analisi di Rischio (1022009) | Waste Management (10620255) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Costruzione Modelli Hbim (10622417) | Hbim Models for Architecture (10622421) | 0.00 | i nomi non sono una traduzione (somiglianza 0.67 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Diritto Bancario e dei Mercati Finanziari (10606516) | Competition Law (10600023) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia Pubblica Corso Avanzato (10628559) | Public finance (10626489) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Analisi Territoriale (10616771) | Global Networks and Regional Development (10616737) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Politiche Dell'innovazione (10606751) | Economics of Inequality (10606495) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Politiche Dell'innovazione (10606751) | International Money and Finance (10620844) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Politiche Dell'innovazione (10606751) | Macroeconomics and Financial Markets (10616773) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Politiche Dell'innovazione (10606751) | Policy Evaluation (10600022) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e Politiche Dell'innovazione (10606751) | Quantitative Macroeconomics and Policies (10620845) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Economia e politica monetaria corso avanzato (1026535) | Policy Evaluation (10606632) | 0.00 | i nomi non sono una traduzione (somiglianza 0.25 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Macroeconomia (10626934) | Advanced Microeconomics (10627987) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Matematica corso avanzato (10626033) | Mathematics for Economics and Finance (10627313) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.60); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Microeconomia - Analisi e Politiche (10627745) | Labour Economics and Policy (10628973) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-56-economia-politica | Microeconomia - Analisi e Politiche (10627745) | Macroeconomic Theory and Policy (10632060) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.90); ricreato come insegnamento, percorso dal dato originale |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Biologia Dello Sviluppo delle Piante: Applicazioni Industriali e Ambientali (10628144) | Molecular Biology of Stem Cells (10625965) | 0.00 | i nomi non sono una traduzione (somiglianza 0.17 < 0.90) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Computational Methods in Biology (10628699) | Structure Biosynthesis and Analysis of Proteins (10629448) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Controllo Epigenetico Dell'espressione Genica (10629482) | Molecular Biology of Stem Cells (10625965) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Epigenetica (10626145) | Human Genetics (10626284) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Epigenetica e Metabolismo in Fisiopatologia (10629927) | Molecular Oncology (10625966) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.75) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Genetica Dell'invecchiamento (10628587) | Human Genetics (10626284) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.75) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Genetica Dello Sviluppo (10628996) | Human Genetics (10626284) | 0.00 | i nomi non sono una traduzione (somiglianza 0.50 < 0.75) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Genome Evolution (10628728) | Human Genetics (10626284) | 0.00 | i nomi non sono una traduzione (somiglianza 0.00 < 0.90) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | High-resolution Rna Biology - Concepts and Tools (10627454) | Molecular Biology of Stem Cells (10625965) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Methods in Human Genetics (10627591) | Human Genetics (10626284) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Molecular Methods (10630060) | Molecular Biology of Stem Cells (10625965) | 0.00 | il nome della versione italiana è inglese |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Patologia Molecolare e Immunopatologia (10630362) | Molecular Oncology (10625966) | 0.00 | i nomi non sono una traduzione (somiglianza 0.33 < 0.75) |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Programming and Machine Learning for Biological Data (10628794) | Structure Biosynthesis and Analysis of Proteins (10629448) | 0.00 | il nome della versione italiana è inglese |

## Nuove (91)

| Ateneo | Corso | Insegnamento italiano | Versione inglese | Somiglianza | Note |
|---|---|---|---|---:|---|
| iulm | iulm-lm-59-marketing-consumi-e-comunicazione | Consumatori e Societa' (13937) | Consumer And Society (13940) | 1.00 | stesso piano (gemelli) |
| liuc | liuc-l-9-ingegneria-gestionale | Design e Gestione della Qualità (N91533) | Quality: Design And Management (N91493) | 1.00 | stesso piano (gemelli) |
| liuc | liuc-l-9-ingegneria-gestionale | Gestione Dell'impresa Sostenibile (N91552) | Managing Sustainable Company (N91553) | 1.00 | stesso piano (gemelli) |
| liuc | liuc-l-9-ingegneria-gestionale | Gestione e Controllo dei Processi Aziendali (N90305) | Business Process Management And Control (N90387) | 1.00 | stesso piano (gemelli) |
| liuc | liuc-l-9-ingegneria-gestionale | Sistemi di Produzione (N91488) | Manufacturing Systems (N91491) | 1.00 | stesso piano (gemelli) |
| luiss | luiss-lm-77-marketing | Analisi del Comportamento del Consumatore (MRKITA) | Consumer Behavior Analysis (MRKENG) | 1.00 | stesso piano (gemelli) |
| luiss | luiss-lm-77-marketing | Fondamenti di Economia Comportamentale (MRK13) | Behavioral Economics: Foundation (MRK03) | 1.02 | stesso piano (gemelli) |
| luiss | luiss-lm-77-marketing | Marketing e Diritto (MRK14) | Marketing And Law (MRK04) | 1.02 | stesso piano (gemelli) |
| luiss | luiss-lm-77-marketing | Metodi di Ricerca Qualitativi e Quantitativi per il Marketing (MRK12) | Qualitative & Quantitative Research Methods For Marketing (MRK02) | 1.07 | stesso piano (gemelli) |
| polimi | polimi-l-8-l-9-ingegneria-dell-automazione | Sistemi a Eventi Discreti (088691) | DISCRETE EVENT SYSTEMS Insegnamento a numero chiuso (064272) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-8-l-9-ingegneria-gestionale | Comportamento Organizzativo (052463) | ORGANIZATIONAL BEHAVIOUR Insegnamento a numero chiuso (053438) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-8-l-9-ingegneria-gestionale | Economia 2 (macroeconomia) (052462) | ECONOMICS 2 (MACROECONOMICS) Insegnamento a numero chiuso (061963) | 1.07 | stesso piano (gemelli) |
| polimi | polimi-l-8-l-9-ingegneria-gestionale | Gestione degli Impianti Industriali (072366) | INDUSTRIAL PLANTS MANAGEMENT Insegnamento a numero chiuso (061964) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-8-l-9-ingegneria-gestionale | Gestione e Organizzazione Aziendale (051478) | BUSINESS MANAGEMENT AND ORGANIZATION Insegnamento a numero chiuso (061961) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-chimica | Chimica Industriale (089147) | INDUSTRIAL CHEMISTRY Insegnamento a numero chiuso (063244) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Impianti di Produzione e Organizzazione di Impresa (086448) | Production Systems and Business Organization (063567) | 1.07 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Laboratorio di Progettazione Meccanica (063689) | Mechanical Design Laboratory (063690) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Meccanica delle Vibrazioni (086453) | Mechanics of Vibrations (058061) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Metodi Analitici e Numerici per L'ingegneria (054361) | Analytical and Numerical Methods for Engineering (063563) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Metodi di Calcolo delle Strutture (086437) | Methods of Structural Analysis (063564) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-l-9-ingegneria-meccanica | Misure Meccaniche e Termiche (083445) | Mechanical and Thermal Measurements (063562) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-12-design-della-comunicazione | Antropologia della Comunicazione (089560) | Anthropology of Communication (changes in Social Dynamics) (057288) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-12-design-della-comunicazione | Laboratorio di Progettazione di Artefatti e Sistemi Complessi -a (058387) | Complex Artefacts and System Design Studio (052943) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-12-product-service-system-design | Leadership & Strategie di Innovazione (063166) | Leadership & Innovation Strategy (063214) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-30-energy-engineering | Conversione Dell'energia a (054066) | Energy Conversion a (054065) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-30-energy-engineering | FONDAMENTI DI PROCESSI CHIMICI Insegnamento a numero chiuso (089781) | FUNDAMENTALS OF CHEMICAL PROCESSES Insegnamento a numero chiuso (095910) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-30-energy-engineering-replica-piacenza | Conversione Dell'energia a (054066) | Energy Conversion a (054065) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-30-energy-engineering-replica-piacenza | FONDAMENTI DI PROCESSI CHIMICI Insegnamento a numero chiuso (089781) | FUNDAMENTALS OF CHEMICAL PROCESSES Insegnamento a numero chiuso (095910) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-32-lm-35-geoinformatics-engineering | Architettura dei Calcolatori e Sistemi Operativi (085779) | Computer Architecture and Operating Systems [i.c.] (062057) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-4-architettura | METODI E TECNICHE COMPUTAZIONALI PER IL PROGETTO ARCHITETONICO E URBANO Insegnamento a numero chiuso (064671) | COMPUTATIONAL METHODS AND TECHNIQUES FOR ARCHITECTURAL AND URBAN DESIGN Insegnamento a numero chiuso (064672) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-4-architettura | METODI E TECNICHE PER LA MODELLAZIONE E SIMULAZIONE NEL PROGETTO ARCHITETTONICO Insegnamento a numero chiuso (064669) | METHODS AND TECHNIQUES FOR MODELING AND SIMULATION IN ARCHITECTURAL DESIGN Insegnamento a numero chiuso (064670) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-53-materials-engineering-and-nanotechnology | FISICA DELLO STATO SOLIDO Insegnamento a numero chiuso (085888) | SOLID STATE PHYSICS Insegnamento a numero chiuso (089473) | 1.02 | stesso piano (gemelli) |
| polimi | polimi-lm-53-materials-engineering-and-nanotechnology | Principi di Chimica dei Polimeri (054188) | Principles of Polymer Chemistry (054187) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-elettronica | Circuiti elettronici (12EIUXV) | Electronic Circuits (03OIGXV) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-elettronica | Elettronica applicata (04ATINX) | Applied electronics (02MZGNX) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-elettronica | Elettronica dei sistemi digitali (08ATNNX) | Digital systems electronics (04OIHNX) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Analisi matematica II (23ACIOD) | Mathematical analysis II (03KXUOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Analisi matematica II (23ACIXZ) | Mathematical analysis II (03KXUXZ) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-fisica | Circuiti elettronici (07EIUOD) | Electronic Circuits (03OIGOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Circuiti elettronici (07EIUXZ) | Electronic Circuits (03OIGXZ) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-fisica | Elettronica applicata (07ATIOD) | Applied electronics (02MZGOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Elettronica dei sistemi digitali (06ATNOD) | Digital systems electronics (01OIHOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Fisica II (19AXPOD) | Physics II (06KXWOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Fisica II (19AXPXZ) | Physics II (06KXWXZ) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-fisica | Metodi matematici per l'ingegneria (06BQXOD) | Mathematical methods (04LSIOD) | 1.02 | percorso in lingua inglese |
| polito | polito-l-8-ingegneria-fisica | Metodi matematici per l'ingegneria (06BQXXZ) | Mathematical methods (04LSIXZ) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-informatica | Controlli automatici (18AKSOA) | Automatic control (06LSLOA) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-informatica | Reti di calcolatori (15CDUOA) | Computer networks (08KSIOA) | 1.02 | stesso piano (gemelli) |
| polito | polito-l-8-ingegneria-informatica | Sistemi operativi (05CJCOA) | Operating systems (04JEZOA) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-31-ingegneria-gestionale | Gestione dell'innovazione e sviluppo prodotto (01KSUYC) | Innovation management and product development (01KYOYC) | 1.02 | percorso in lingua inglese |
| polito | polito-lm-32-ingegneria-informatica | Data Science e Tecnologie per le Basi di Dati (01SQMYG) | Data Science and Database Technology (01SQJYG) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-32-ingegneria-informatica | Ingegneria del software (05BIDYG) | Software engineering (04GSPYG) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-32-ingegneria-informatica | Programmazione di sistema (01GRSYG) | System and device programming (03NYHYG) | 1.07 | stesso piano (gemelli) |
| polito | polito-lm-32-ingegneria-informatica | Sicurezza dei sistemi informativi (01UDUYG) | Information systems security (01TYMYG) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-32-ingegneria-informatica | Tecnologie e servizi di rete (02KPNYG) | Computer network technologies and services (01OTWYG) | 0.77 | stesso piano (gemelli) |
| polito | polito-lm-32-lm-66-cybersecurity-engineering | Programmazione di sistema (02GRSWQ) | System and device programming (01NYHWQ) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-32-lm-66-cybersecurity-engineering | Sicurezza dei sistemi informativi (01UDUWQ) | Information systems security (01TYMWQ) | 1.02 | stesso piano (gemelli) |
| polito | polito-lm-44-ingegneria-matematica | Sicurezza dei sistemi informativi (01UDUYH) | Information systems security (01TYMYH) | 1.02 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Anatomia Umana 2 (MC/0800) | Human Anatomy 2 (MC/1015/EN) | 1.02 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Elementi di Informatica (giudizio-placement) (MC/0798) | Basics Of Computer Science (MC/0996/EN) | 1.00 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Fisiologia Umana (1342) | Human Physiology (MC/1016/EN) | 1.02 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Neuroanatomia-neurofisiologia (40/260) | Neuroanatomy-neurophysiology (MC/1017/EN) | 1.07 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Patologia Generale e Immunologia (MC/0801) | General Pathology And Immunology (MC/1020/EN) | 1.07 | stesso piano (gemelli) |
| unica | unica-lm-41-medicina-e-chirurgia | Tirocinio Introduttivo Valutazione Gestione Rischi (MC/0545) | Introductory Internship Risk Management Assessment (MC/1002/EN) | 1.00 | stesso piano (gemelli) |
| unicatt | unicatt-l-18-economia-aziendale | Finanza Aziendale (corso A) () | Introduction to Corporate Finance () | 1.00 | stesso piano (gemelli) |
| unicatt | unicatt-lm-56-economia | Macroeconomia () | Macroeconomics () | 1.00 | stesso piano (gemelli) |
| unifi | unifi-l-14-scienze-dei-servizi-giuridici | Diritto Dell'unione Europea (B030881) | European Union Law (B030884) | 1.02 | stesso piano (gemelli) |
| unifi | unifi-lmg-01-giurisprudenza-italiana-e-francese | Diritto Dell'unione Europea (0055011) | European Union Law (B029160) | 1.02 | stesso piano (gemelli) |
| unifi | unifi-lmg-01-giurisprudenza-italiana-e-francese | Filosofia del Diritto (0055005) | Philosophy Of Law (B031969) | 1.07 | stesso piano (gemelli) |
| unifi | unifi-lmg-01-giurisprudenza-italiana-e-tedesca | Diritto Dell'unione Europea (B024099) | European Union Law (B029146) | 1.02 | stesso piano (gemelli) |
| unifi | unifi-lmg-01-giurisprudenza-italiana-e-tedesca | Sistemi Giuridici Comparati (B024103) | Comparative Legal Systems (B029144) | 1.02 | stesso piano (gemelli) |
| unime | unime-l-36-scienze-politiche-e-delle-relazioni-internazionali | Economia Politica (1783) | Principles Of Economics (A001195) | 1.02 | stesso piano (gemelli) |
| unime | unime-l-36-scienze-politiche-e-delle-relazioni-internazionali | Istituzioni di Diritto Pubblico (3286) | Public Law (6905) | 1.02 | stesso piano (gemelli) |
| unime | unime-l-36-scienze-politiche-e-delle-relazioni-internazionali | Storia Moderna (6518) | Early Modern History (A000568) | 1.02 | stesso piano (gemelli) |
| unimore | unimore-lmg-01-giurisprudenza | Diritto e Religione (LMG-72) | Law And Religion (LMG-64) | 1.07 | stesso piano (gemelli) |
| unimore | unimore-lmg-01-giurisprudenza | Filosofia del Diritto (LMG-08) | Philosophy Of Law (LMG-09) | 1.02 | stesso piano (gemelli) |
| unimore | unimore-lmg-01-giurisprudenza | Storia del Diritto Medievale e Moderno (LMG-06) | History Of Medieval And Modern Law (LMG-57) | 1.07 | stesso piano (gemelli) |
| unipd | unipd-lm-39-linguistica | Logica (LE06105452) | Logic (SU0000152) | 1.02 | stesso piano (gemelli) |
| unipg | unipg-l-p03-metodologie-per-prodotto-e-processo | Approccio Sistemico alla Sostenibilita' (A005370) | Systemic Approach to Sustainability (A006187) | 1.02 | stesso piano (gemelli) |
| unipg | unipg-l-p03-metodologie-per-prodotto-e-processo | Catalisi per L'energia e L'industria con Laboratorio (A004796) | Catalysis for Energy and Industry With Laboratory (A006190) | 1.07 | stesso piano (gemelli) |
| unipg | unipg-l-p03-metodologie-per-prodotto-e-processo | Impianti Biotecnologici per Processo e Prodotto con Laboratorio (A004808) | Biotechnological Plants By Process and Product With Laboratory (A006193) | 1.02 | stesso piano (gemelli) |
| unipg | unipg-lm-33-ingegneria-meccanica | Tecnologie per la Transizione Energetica (A005730) | Technologies for Energy and Sustainable Transition (A006333) | 0.82 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Biochimica Generale (A000786) | General Biochemistry (A000716) | 1.02 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Biologia Molecolare (437) | Molecular Biology (A000722) | 1.02 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Chimica Analitica (539) | Analytical Chemistry (A000718) | 1.07 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Fisica Applicata e Biostatistica (A000709) | Applied Physics And Biostatistics (A000712) | 1.07 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Genetica e Laboratori di Genetica (A000797) | Genetics And Genetics Laboratories (A000723) | 1.07 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Ofa Chimica (A000330) | Ofa Chemistry (A000774) | 1.00 | stesso piano (gemelli) |
| unite | unite-l-2-biotecnologie | Struttura e Funzione degli Organismi (A000787) | Structure And Function Of Organisms (A000717) | 1.07 | stesso piano (gemelli) |
| unito | unito-lm-51-scienze-del-corpo-e-della-mente | Neuropsicologia Sperimentale e Clinica (PSI1370) | Clinical And Experimental Neuropsychology (PSI1371) | 1.07 | stesso piano (gemelli) |
| unito | unito-lm-51-scienze-del-corpo-e-della-mente | Neuroscienze del Comportamento Umano (PSI0451) | Human Behavioral Neuroscience (PSI0968) | 1.02 | stesso piano (gemelli) |

## Tenute (103)

| Ateneo | Corso | Insegnamento italiano | Versione inglese | Somiglianza | Note |
|---|---|---|---|---:|---|
| polito | polito-l-17-architettura | Cultura e fondamenti di Tecnologia dell'architettura (01SPXWG) | Architectural technology - Culture and fundamentals (01SUIWG) | 1.00 |  |
| polito | polito-l-17-architettura | Fisica tecnica ambientale (03AXZWG) | Building physics (01OTYWG) | 1.00 |  |
| polito | polito-l-17-architettura | Istituzioni di matematiche (06BJUWG) | Calculus (05OHTWG) | 1.00 |  |
| polito | polito-l-17-architettura | Laboratorio di disegno e rilievo dell'architettura (01PPLWG) | Architectural Drawing and Survey Laboratory (01PUBWG) | 1.00 |  |
| polito | polito-l-17-architettura | Laboratorio di geomatica per la modellazione dell'architettura (01PRUWG) | Laboratory of Geomatics for Architecture modeling (01PRYWG) | 1.00 |  |
| polito | polito-l-17-architettura | Lingua inglese I livello (07LKIWG) | English Language 1st level (02MCCWG) | 1.00 |  |
| polito | polito-l-17-architettura | Morfologia e concezione delle strutture (01PPMWG) | Morphology and concept of structures (01PQFWG) | 1.00 |  |
| polito | polito-l-17-architettura | Scienza e tecnologia dei materiali (14CFRWG) | Materials science and technology (05LLZWG) | 1.00 |  |
| polito | polito-l-17-architettura | Storia dell'architettura contemporanea (02CMDWG) | History of contemporary architecture (01LWRWG) | 1.00 |  |
| polito | polito-l-17-architettura | Storia dell'architettura moderna (07CMKWG) | History of early modern architecture (03PGYWG) | 1.00 |  |
| polito | polito-l-17-architettura | Urbanistica (27CYAWG) | Urban planning (03OUDWG) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Algebra lineare e geometria (01RKCYE) | Linear algebra and geometry (03KXTYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Algoritmi e strutture dati (03AAXYE) | Algorithms and data structures (01URNYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Analisi matematica I (16ACFYE) | Mathematical analysis I (04KWQYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Analisi matematica II (26ACIYE) | Mathematical analysis II (07KXUYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Basi di dati (14AFQYE) | Introduction to databases (01RKWYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Calcolatori elettronici (12AGAYE) | Computer architecture (02KTMYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Chimica (15AHMYE) | Chemistry (06KWRYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Elettromagnetismo e Teoria dei circuiti (01URKYE) | Electromagnetism and Circuit theory (01URLYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Fisica I (17AXOYE) | Physics I (04KXVYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Informatica (14BHDYE) | Computer sciences (07JCJYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Lingua inglese I livello (07LKIYE) | English Language 1st level (02MCCYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Metodi matematici per l'ingegneria (09BQXYE) | Mathematical methods for Computer Science (01UROYE) | 0.50 |  |
| polito | polito-l-8-ingegneria-informatica | Progettazione elettronica digitale (01GYAYE) | Digital Electronics Design (01GYBYE) | 1.00 |  |
| polito | polito-l-8-ingegneria-informatica | Tecniche di programmazione (01FYZYE) | Programming techniques (02OJPYE) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Algebra lineare e geometria (01RKCXP) | Linear algebra and geometry (03KXTXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Analisi matematica I (16ACFXP) | Mathematical analysis I (04KWQXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Analisi matematica II (22ACIXP) | Mathematical analysis II (02KXUXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Chimica (16AHMXP) | Chemistry (06KWRXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Disegno tecnico industriale (20APGXP) | Engineering drawing (07KXXXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Fisica I (17AXOXP) | Physics I (04KXVXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Fisica II (20AXPXP) | Physics II (05KXWXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Fondamenti di meccanica strutturale (09IHRXP) | Fundamentals of strength of materials (01NLAXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Informatica (14BHDXP) | Computer sciences (07JCJXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Lingua inglese I livello (07LKIXP) | English Language 1st level (02MCCXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Meccanica applicata alle macchine (07BOTXP) | Applied mechanics (03LMAXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Scienza e tecnologia dei materiali/Tecnologia dei materiali metallici (01NKZXP) | Science and technology of materials/Technology of metallic materials (01NLMXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-dell-autoveicolo | Termodinamica applicata e trasmissione del calore (06IHQXP) | Fundamentals of Engineering Thermodynamics and Heat Transfer (01NLGXP) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Algebra lineare e geometria (01RKCYI) | Linear algebra and geometry (03KXTYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Analisi matematica I (16ACFYI) | Mathematical analysis I (04KWQYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Analisi matematica II (22ACIYI) | Mathematical analysis II (02KXUYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Chimica (16AHMYI) | Chemistry (06KWRYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Disegno tecnico industriale (21APGYI) | Engineering drawing (04KXXYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Fisica I (17AXOYI) | Physics I (04KXVYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Fisica II (20AXPYI) | Physics II (05KXWYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Fondamenti di meccanica strutturale (09IHRYI) | Fundamentals of strength of materials (01NLAYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Informatica (14BHDYI) | Computer sciences (07JCJYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Lingua inglese I livello (07LKIYI) | English Language 1st level (02MCCYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Meccanica applicata alle macchine (07BOTYI) | Applied mechanics (03LMAYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Metodologie per l'ispezione e il controllo della qualità (01VUFYI) | Methodologies for Inspection and quality control (01VUGYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Scienza e tecnologia dei materiali/Tecnologia dei materiali metallici (01NKZYI) | Science and technology of materials/Technology of metallic materials (01NLMYI) | 1.00 |  |
| polito | polito-l-9-ingegneria-meccanica | Termodinamica applicata e trasmissione del calore (06IHQYI) | Fundamentals of Engineering Thermodynamics and Heat Transfer (01NLGYI) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Diritto commerciale (02ANYYC) | Business law (03KYJYC) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Gestione dei progetti (10BDAYC) | Project management (04IXTYC) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Ingegneria della qualità (01NBAYC) | Quality Engineering (01OJDYC) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Seminari per Tesi I/Thesis Seminar I (01WRZYC) | Thesis Seminar I (01VUCYC) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Seminari per Tesi II/Thesis Seminar II (01WSAYC) | Thesis Seminar II (01VWOYC) | 1.00 |  |
| polito | polito-lm-31-ingegneria-gestionale | Strategia e organizzazione (01QYPYC) | Strategy and Organization (01QYQYC) | 1.00 |  |
| polito | polito-lm-33-ingegneria-meccanica | Applicazioni avanzate di fisica tecnica/Modelli e metodi numerici (01NLNYJ) | Advanced engineering thermodynamics/Numerical modelling (01NMFYJ) | 0.71 |  |
| polito | polito-lm-33-ingegneria-meccanica | Costruzione di macchine (12ALPYJ) | Machine design (03MCHYJ) | 1.00 |  |
| polito | polito-lm-33-ingegneria-meccanica | Dinamica dei sistemi meccanici (03FOEYJ) | Mechanical system dynamics (01NMCYJ) | 1.00 |  |
| polito | polito-lm-33-ingegneria-meccanica | Economia e organizzazione aziendale (06ARHYJ) | Business Economics and Organization (01NMDYJ) | 0.67 |  |
| polito | polito-lm-33-ingegneria-meccanica | Macchine a fluido (04GKEYJ) | Fluid machinery (01HHMYJ) | 1.00 |  |
| polito | polito-lm-33-ingegneria-meccanica | Materiali per l'industria meccanica (03GJLYJ) | Materials for mechanical industries (01NMEYJ) | 1.00 |  |
| polito | polito-lm-33-ingegneria-meccanica | Sistemi integrati di produzione (07CJBYJ) | Integrated Manufacturing Systems (02MSIYJ) | 1.00 |  |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia Aziendale (10626921) | Business Administration (10627264) | 1.00 |  |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Economia e gestione delle imprese (1017104) | Corporate Management (10616746) | 0.67 |  |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Finanza Aziendale (1018186) | Corporate Finance (10616675) | 1.00 |  |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Matematica Finanziaria (1017164) | Financial Mathematics (10616667) | 1.00 |  |
| uniroma1 | uniroma1-l-18-economia-aziendale-e-management | Politica Economica (1017517) | Economic Policy (10600042) | 1.00 |  |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia aziendale (10626921) | Business Administration (10627264) | 1.00 |  |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Economia del Lavoro (1013874) | Labour Economics (10616723) | 1.00 |  |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Politica Economica (1017517) | Economic Policy (10600042) | 1.00 |  |
| uniroma1 | uniroma1-l-33-economia-e-finanza | Scienza delle Finanze (1006627) | Public Economics (10591675) | 1.00 |  |
| uniroma1 | uniroma1-lm-16-finanza-e-assicurazioni | Finanza Quantitativa (10629173) | Quantitative Financial Modelling (10627215) | 0.67 |  |
| uniroma1 | uniroma1-lm-22-ingegneria-chimica | Reattori Chimici (10625822) | Chemical Reactors (10629915) | 1.00 |  |
| uniroma1 | uniroma1-lm-26-ingegneria-della-sicurezza-e-protezione-civile | Sicurezza e Gestione dei Sistemi Elettrici (1044392) | Power Systems Safety (10589905) | 0.75 |  |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Componenti Elettronici Integrati (10630500) | Integrated Electronic Devices (10631058) | 1.00 |  |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Laboratorio Multisciplinare di Elettronica (10600538) | Multidisciplinary Laboratory of Electronics (10600539) | 0.67 |  |
| uniroma1 | uniroma1-lm-29-ingegneria-elettronica | Microonde (10626154) | Microwaves (10628941) | 1.00 |  |
| uniroma1 | uniroma1-lm-30-ingegneria-energetica-e-nucleare | Macchine Elettriche (10628462) | Electrical Machines (10627027) | 1.00 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Consolidamento degli Edifici Storici e Impianti (10622410) | Structural Consolidation and Hvac Plant in Historical Buildings (10622402) | 0.67 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Progettazione Architettonica II - Laboratorio (1007302) | Design Studio 2 (10596234) | 0.67 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Progettazione Architettonica i - Laboratorio (10622409) | Design Studio 1 (10629659) | 0.67 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Progettazione Tecnologica per la Riqualificazione Architettonica (10622411) | Technological Design for the Architectural Requalification (10622403) | 1.00 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Restauro dei Monumenti - Laboratorio (1035673) | Conservation Design Studio (1051528) | 0.67 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Rilievo Dell'architettura (10622408) | Architectural Survey (10622401) | 1.00 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Strumenti e Metodi della Ricerca Storica (10622407) | Tools and Methods for Historical Research (10622399) | 1.00 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Tecnica delle Costruzioni Antiche e Moderne (10622406) | Structural Engineering of Ancient and Modern Buildings (10622400) | 0.80 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Teoria e Tecnica del Restauro (10622415) | Theory and Practice of Conservation (10622418) | 1.00 |  |
| uniroma1 | uniroma1-lm-4-architettura-restauro | Valutazione Economica dei Progetti ed Esercizio Professionale (10596356) | Economic Evaluation of Projects (10596233) | 0.60 |  |
| uniroma1 | uniroma1-lm-56-economia-politica | Econometria Corso Avanzato (10626275) | Advanced Econometrics (10631409) | 1.00 |  |
| uniroma1 | uniroma1-lm-56-economia-politica | Macroeconomia (10626934) | Advanced Macroeconomics (10627504) | 1.00 |  |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Biologia Molecolare delle Cellule Staminali (10626102) | Molecular Biology of Stem Cells (10625965) | 1.00 |  |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Genetica Umana (10628926) | Human Genetics (10626284) | 1.00 |  |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Oncologia Molecolare (10629225) | Molecular Oncology (10625966) | 1.00 |  |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Regolazione Dell'espressione Genica Negli Eucarioti (10630637) | Gene Expression Regulation of Eukaryotes (10630791) | 1.00 |  |
| uniroma1 | uniroma1-lm-6-genetica-e-biologia-molecolare | Struttura, Biosintesi e Analisi delle Proteine (10626216) | Structure Biosynthesis and Analysis of Proteins (10629448) | 1.00 |  |
| uniroma1 | uniroma1-lm-81-scienze-dello-sviluppo-e-della-cooperazione-internazionale | Geopolitica e Storia del Mediterraneo e del Medio Oriente (10628817) | Geopolitics and History of the Mediterranean and the Middle East (10629876) | 1.00 |  |
| uniroma1 | uniroma1-lm-81-scienze-dello-sviluppo-e-della-cooperazione-internazionale | Politica Agricola Internazionale (1027850) | International Agricultural Policy (1027822) | 1.00 |  |
| uniroma1 | uniroma1-lm-81-scienze-dello-sviluppo-e-della-cooperazione-internazionale | Politica Economica Internazionale e Sviluppo (10627777) | International Development Policies (10629694) | 0.75 |  |
| uniroma1 | uniroma1-lm-81-scienze-dello-sviluppo-e-della-cooperazione-internazionale | Popolazione e Sviluppo (10626080) | Population and Development (10626541) | 1.00 |  |
| uniroma1 | uniroma1-lm-81-scienze-dello-sviluppo-e-della-cooperazione-internazionale | Statistica per lo Sviluppo (10629382) | Statistics for Development (10629715) | 1.00 |  |
