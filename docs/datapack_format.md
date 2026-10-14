# Formato "data pack" (v1)

Il data pack è il formato interno con cui i dati del piano di studi entrano nell'app **UniNotes**.
L'app lo produce da sola: converte il piano di studi del database pubblico (`database/corsi/<ateneo>.json`, vedi `docs/database_format.md`) in un data pack alla fine dell'onboarding e a ogni «Aggiorna database» (Impostazioni → Il mio percorso).

Non c'è più un'importazione di data pack da file o da indirizzo (la card «Importa corsi ed esami» è stata tolta): in Impostazioni → Esporta/importa dati si importano solo i dati esportati dall'app (.json). L'importazione avviene in **una singola transazione SQLite**: se si interrompe, il database resta com'era.

## Regole

- Tutte le date/ore sono stringhe ISO 8601 in ora locale (Europe/Rome) **senza** fuso: `"2026-10-05T08:30:00"`. Date senza ora: `"2026-10-05"`.
- Ogni elemento sincronizzabile ha un `externalId` stabile (stringa) usato per l'upsert. Convenzione: `"<universita>:<tipo>:<id>"`, es. `"polito:course:01RKCPL"`.
- I campi sconosciuti vanno **omessi o messi a `null`**. Non inventare dati.
- `universityId`: l'`id` di un ateneo di `database/universita.json` (qualsiasi ateneo italiano). Un ateneo senza `color` riceve un colore deterministico ricavato dall'id.
- I dati personali modificati dall'utente nell'app (stato corso, voti, stato esami, note, stato libro, posizione fisica, preferiti) **non vengono mai sovrascritti** dall'import.
- Prima dell'import l'app applica il filtro esclusioni scelto dallo studente (alla fine dell'onboarding o in Impostazioni → Esclusioni: OFA, inglese e lingua straniera, corsi facoltativi; nessuno di default): elementi il cui titolo/nome corrisponde vengono saltati.

## Struttura

```jsonc
{
  "format": "university-manager-datapack",
  "version": 1,
  "generatedAt": "2026-10-01T10:00:00",
  "source": "seed-pubblico | catalogo:<ateneo> | manuale",
  // Se true, gli eventi (lezioni ecc.) con lo stesso "source" e un externalId
  // non presente in questo pack vengono rimossi (es. orario aggiornato).
  "replaceEventsOfSameSource": false,
  // Facoltativo: elimina gli eventi con questi "source" non presenti nel pack
  // (es. l'orario provvisorio ricostruito dai PDF di introduzione ai corsi,
  // source "orario-pdf:polito" / "orario-pdf:unito", quando arriva l'orario ufficiale).
  "removeEventsOfSources": [],

  "universities": [
    { "id": "polito", "name": "Politecnico di Torino", "shortName": "PoliTo",
      "color": "#1565C0", "website": "https://www.polito.it" }
  ],

  "degrees": [
    { "id": "polito:ing-informatica", "universityId": "polito",
      "name": "Ingegneria Informatica", "classCode": "L-8",
      "minEntryScore": "…testo libero, es. soglia TIL…",
      "maxGraduationScore": "110/110 e lode",
      "referenceAverages": "…testo libero…",
      "notes": null, "source": "https://…", "updatedAt": "2026-10-01" }
  ],

  "courses": [
    { "externalId": "polito:course:01RKCPL", "universityId": "polito",
      "degreeId": "polito:ing-informatica",
      "name": "Analisi matematica I", "code": "01RKCPL",
      "teacher": "Nome Cognome", "year": 1, "semester": "1",   // "1", "2", "annuale", …
      "cfu": 10, "lectureHours": 100, "difficulty": 4,          // 0-5
      "studyHoursEstimate": 150,                                // facoltativo, non più usato dall'app
      "examMode": "scritto+orale",                              // scritto | orale | scritto+orale | altro
      "examStructure": "Descrizione dettagliata della prova…",
      "optionalOralInfo": "Orale facoltativo per chi… perché…",
      "description": "Argomenti del corso…",
      "materialsFound": true,
      "materialsNote": "Materiale del docente trovato in …",
      "source": "https://…", "updatedAt": "2026-10-01",
      // Dal database pubblico (facoltativi):
      "booksStatus": "da_aggiungere",    // completo | da_aggiungere | nessun_libro
      "examsStatus": "da_aggiungere",    // completo | da_aggiungere
      "syllabusUrl": "https://…", "ssd": "MAT/05",
      "mandatory": true, "curriculum": null }
  ],

  "events": [
    { "externalId": "polito:lecture:123", "type": "lecture",   // lecture | exam_window | event | deadline | study_plan
      "courseExternalId": "polito:course:01RKCPL", "universityId": "polito",
      "title": "Analisi matematica I", "start": "2026-10-05T08:30:00",
      "end": "2026-10-05T10:00:00", "allDay": false,
      "room": "Aula 1", "building": "Sede centrale", "site": "Torino",
      "teacher": "…", "notes": null, "source": "catalogo:polito" }
  ],

  "exams": [
    { "externalId": "polito:midterm:01RKCPL:1", "courseExternalId": "polito:course:01RKCPL",
      "kind": "midterm",                     // final | midterm
      "title": "Prima prova in itinere",
      "date": "2026-11-12", "time": "14:00", "location": "…",
      "examType": "scritto",                 // scritto | orale | scritto+orale | quiz | progetto | altro
      "cfu": null,
      "topics": "Argomenti oggetto della prova…",
      "studyMaterials": ["Lezioni 1-8 (slide)", "D:\\Materiale_Ingegneria_Info\\…\\L01.pdf"],
      "notes": "Fonte: avviso del docente del …", "source": "…" }
  ],

  "books": [
    { "externalId": "polito:book:01RKCPL:1", "courseExternalId": "polito:course:01RKCPL",
      "title": "…", "author": "…", "isbn": null, "edition": null, "publisher": null, "year": null,
      "required": true,                      // true = obbligatorio, false = consigliato
      "format": "pdf",                       // cartaceo | ebook | pdf | altro
      "filePath": "D:\\Libri\\Ingegneria Info\\….pdf",   // se trovato in locale
      "expectedFileName": null, "language": "italiano", "downloaded": true }
  ],

  "materials": [
    { "externalId": "unito:material:abc", "courseExternalId": "unito:course:…",
      "title": "Lezione 1.pdf", "localPath": "D:\\Materiale_Psicologia\\…\\Lezione 1.pdf",
      "kind": "lecture",                     // lecture | exam_text | exercise | notice | other
      "academicYear": "2025/26", "author": "docente del corso | altro docente: …",
      "source": "moodle" }
  ],

  "placeCategories": [
    { "id": "university", "name": "Università", "icon": "school" }
  ],

  "places": [
    { "externalId": "osm:node:123", "categoryId": "study_room_edisu", "name": "…",
      "lat": 45.06, "lon": 7.66, "address": "…", "city": "Torino",
      "description": null, "phone": null, "website": null, "openingHours": null,
      "source": "…", "updatedAt": "2026-10-01" }
  ],

  "benefits": [
    { "externalId": "polito:benefit:office365", "universityId": "polito",
      "category": "software", "title": "Microsoft 365", "description": "…",
      "url": "https://…", "source": "…", "updatedAt": "2026-10-01" }
  ],

  // Facoltativo: struttura di Studio pronta per una materia, costruita dai
  // capitoli dei libri di testo obbligatori e dagli argomenti delle slide.
  // L'app la importa SOLO nei corsi che non hanno ancora moduli: non tocca mai
  // moduli/argomenti creati o modificati dallo studente.
  "removeBooks": ["polito:book:14BHDYE:1"],
  "studyModules": [
    { "externalId": "polito:study:16ACFYE:02", "courseExternalId": "polito:course:16ACFYE",
      "name": "Cap. 2 – Limiti e continuità", "sort": 2,
      "topics": [
        { "name": "2.1 Definizione di limite", "notes": "Libro: Nicola cap. 2.1 (pp. 41–52) · Slide L05" },
        { "name": "2.2 Limiti notevoli", "notes": null }
      ],
      "source": "indice di F. Nicola, Analisi Matematica I + slide del corso" }
  ]
}
```

Categorie luogo predefinite (`categoryId`): `university`, `department`, `library`,
`study_room`, `study_room_edisu`, `canteen_edisu`, `residence_edisu`, `copy_shop`,
`bookshop`, `other`.

Categorie vantaggi (`category`): `email`, `back_to_school`, `software`,
`discount`, `service`, `external_offers`.

`removeBooks`: libri da togliere (es. sostituiti da un'altra edizione); vengono
eliminati solo se sono ancora «da procurare» e senza file copiato nell'app.

Libri e reimport: la scelta dello studente su un libro proposto (cerchio con
la spunta = tieni / con la X = rimuovi, colonna `books.catalog_choice`) non viene mai toccata, quindi un
libro rimosso non ricompare; un libro modificato a mano (`books.user_edited`)
non viene più aggiornato. Negli esami un campo `null` nel pack non cancella il
valore già presente (es. la data scelta dallo studente).
Un libro con `"downloaded": true` diventa «posseduto» anche se era già
nell'app come «da procurare».
