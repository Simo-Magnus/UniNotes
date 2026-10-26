# Sicurezza

## Segnalare una vulnerabilità

Se trovi una falla di sicurezza o di privacy in UniNotes (app, pagine del sito,
build automatica, strumenti del database), **non aprire una issue pubblica**:
segnalala in privato con la funzione di GitHub *Private vulnerability
reporting*:

1. apri la scheda **Security** della repository
   [Simo-Magnus/UniNotes](https://github.com/Simo-Magnus/UniNotes/security);
2. scegli **Report a vulnerability**
   ([link diretto](https://github.com/Simo-Magnus/UniNotes/security/advisories/new));
3. descrivi il problema, la versione dell'app (Impostazioni → Privacy e
   informazioni) e il sistema operativo, e se puoi i passi per riprodurlo.

La segnalazione resta visibile solo a te e allo sviluppatore finché la
correzione non è pubblicata. Riceverai una risposta appena possibile; quando
la falla è corretta la segnalazione può diventare un avviso pubblico, con il
tuo nome se lo desideri.

Se non hai un account GitHub, scrivi a `uninotes-supporto@googlegroups.com`
chiedendo un canale privato, **senza** i dettagli della falla nel primo
messaggio.

## Versioni seguite

Si correggono l'ultima versione pubblicata e la versione di prova
«ultima-build». Le versioni precedenti non ricevono correzioni: aggiorna
l'app.

## Cosa non serve segnalare

- L'ID applicazione Microsoft, gli ID client OAuth di Google e la chiave API
  del selettore di Google Drive presenti nell'app o nel sito: non sono
  segreti (la protezione viene dalle restrizioni impostate da Google e
  dall'accesso dello studente, non dalla loro segretezza).
- Gli indirizzi email istituzionali dei docenti nel database dei corsi: sono
  pubblicati dagli atenei nelle pagine degli insegnamenti.

Le verifiche già fatte sono descritte in [`docs/sicurezza.md`](docs/sicurezza.md).

---

## Reporting a vulnerability (English)

Please do not open a public issue. Use GitHub's **Private vulnerability
reporting**: *Security → Report a vulnerability* in
[Simo-Magnus/UniNotes](https://github.com/Simo-Magnus/UniNotes/security/advisories/new).
Only the latest release and the "ultima-build" test build are supported.
