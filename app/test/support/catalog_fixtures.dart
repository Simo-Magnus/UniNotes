import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:university_notes/core/catalog/catalog_service.dart';
import 'package:university_notes/repositories/settings_repository.dart';

/// Piccolo database pubblico per i test (stesso formato di `database/`).
const Map<String, Object?> kUniversitaFixture = {
  'schema': 1,
  'generato_il': '2026-10-04',
  'conteggi': {
    'statale': 3,
    'non_statale': 1,
    'ordinamento_speciale': 0,
    'telematica': 1,
  },
  'regioni': ['Campania', 'Lazio', 'Lombardia', 'Piemonte'],
  'universita': [
    {
      'id': 'polito',
      'nome': 'Politecnico di Torino',
      'sigla': 'PoliTO',
      'tipo': 'statale',
      'regioni': ['Piemonte'],
      'sedi': [
        {
          'regione': 'Piemonte',
          'citta': 'Torino',
          'sito': 'https://www.polito.it/',
        },
      ],
      'sito': 'https://www.polito.it/',
    },
    {
      'id': 'unimib',
      'nome': 'Università degli Studi di Milano “Bicocca”',
      'sigla': 'Bicocca',
      'tipo': 'statale',
      'regioni': ['Lombardia'],
      'sedi': [
        {'regione': 'Lombardia', 'citta': 'Milano'},
      ],
    },
    {
      'id': 'unina',
      'nome': 'Università degli Studi “Federico II”',
      'sigla': 'UniNA',
      'tipo': 'statale',
      'regioni': ['Campania'],
      'sedi': [
        {'regione': 'Campania', 'citta': 'Napoli'},
      ],
    },
    {
      'id': 'unilink',
      'nome': 'Link Campus University',
      'sigla': 'Link',
      'tipo': 'non_statale',
      'regioni': ['Campania', 'Lazio'],
      'sedi': [
        {'regione': 'Campania', 'citta': 'Napoli'},
        {'regione': 'Lazio', 'citta': 'Roma'},
      ],
    },
    {
      'id': 'unipegaso',
      'nome': 'Università telematica “Pegaso”',
      'sigla': 'Pegaso',
      'tipo': 'telematica',
      'regioni': <String>[],
      'sedi': [
        {'regione': 'Campania', 'citta': 'Napoli'},
      ],
    },
  ],
};

const Map<String, Object?> kIndiceFixture = {
  'schema': 1,
  'anno_accademico': '2026/27',
  'corsi': [
    [
      'polito',
      'polito-l8-ingegneria-informatica',
      'Ingegneria Informatica',
      'L',
      'L-8',
      3,
      'Torino',
      'it',
    ],
    [
      'polito',
      'polito-lm32-computer-engineering',
      'Computer Engineering',
      'LM',
      'LM-32',
      2,
      'Torino',
      'en',
    ],
    [
      'unimib',
      'unimib-l24-scienze-psicologiche',
      'Scienze psicologiche',
      'L',
      'L-24',
      3,
      'Milano',
      'it',
    ],
    [
      'unipegaso',
      'unipegaso-l18-economia-aziendale',
      'Economia aziendale',
      'L',
      'L-18',
      3,
      null,
      'it',
    ],
  ],
};

/// `corsi/polito.json`: 1° e 2° anno, con dati completi e mancanti.
Map<String, Object?> corsiPolitoFixture({
  List<Map<String, Object?>> extraBooks = const [],
}) => {
  'schema': 1,
  'universita_id': 'polito',
  'anno_accademico': '2026/27',
  'aggiornato_il': '2026-10-04',
  'corsi': [
    {
      'id': 'polito-l8-ingegneria-informatica',
      'nome': 'Ingegneria Informatica',
      'tipo': 'L',
      'classe': 'L-8',
      'durata_anni': 3,
      'sede': 'Torino',
      'lingua': 'it',
      'stato': 'parziale',
      'insegnamenti': [
        {
          'id': 'polito-l8-ingegneria-informatica-01rkcpl',
          'codice': '01RKCPL',
          'nome': 'Analisi matematica I',
          'anno': 1,
          'periodo': '1',
          'cfu': 10,
          'ssd': 'MAT/05',
          'obbligatorio': true,
          'docenti': ['Mario Rossi'],
          'libri': [
            {
              'titolo': 'Analisi Matematica 1',
              'autori': 'Bramanti, Pagani, Salsa',
              'editore': 'Zanichelli',
              'anno': 2014,
              'isbn': '9788808062543',
              'tipo': 'obbligatorio',
            },
            {'titolo': 'Esercizi di Analisi', 'tipo': 'consigliato'},
            ...extraBooks,
          ],
          'stato_libri': 'completo',
          'esami': [
            {
              'tipo': 'appello',
              'titolo': 'Appello invernale',
              'data': '2027-01-20',
              'ora': '09:00',
              'luogo': 'Aula 1',
              'modalita': 'scritto',
            },
            {
              'tipo': 'prova_in_itinere',
              'titolo': 'Prima prova in itinere',
              'data': '2026-11-12',
              'modalita': 'scritto',
            },
          ],
          'stato_esami': 'completo',
        },
        {
          'id': 'polito-l8-ingegneria-informatica-02fisica',
          'nome': 'Fisica I',
          'anno': 1,
          'periodo': '2',
          'cfu': 8,
          'libri': <Object>[],
          'stato_libri': 'da_aggiungere',
          'esami': <Object>[],
          'stato_esami': 'da_aggiungere',
        },
        {
          'id': 'polito-l8-ingegneria-informatica-03algo',
          'nome': 'Algoritmi e programmazione',
          'anno': 2,
          'cfu': 10,
          'stato_libri': 'da_aggiungere',
          'stato_esami': 'da_aggiungere',
        },
        {
          'id': 'polito-l8-ingegneria-informatica-04reti',
          'nome': 'Reti di calcolatori',
          'anno': 3,
          'cfu': 6,
          'stato_libri': 'nessun_libro',
          'stato_esami': 'da_aggiungere',
        },
      ],
    },
  ],
};

/// Servizio del catalogo con asset, rete e cache finti.
///
/// [remote]: percorso relativo → testo. Con [remote] vuoto (o [offline])
/// ogni richiesta fallisce come senza connessione; altrimenti un percorso
/// assente risponde 404 ([CatalogNotFoundException]). La mappa si legge a
/// ogni richiesta: un test può "tornare online" aggiungendo file. Gli asset
/// di default sono solo i file comuni, come nelle build pubblicate.
/// [cacheDir] di default una cartella temporanea. [attesa] (se restituisce
/// un Future) trattiene la risposta per quel percorso relativo, per
/// simulare un download lungo.
CatalogService fakeCatalog(
  SettingsRepository settings, {
  Map<String, String> remote = const {},
  Map<String, String>? assets,
  Directory? cacheDir,
  List<Uri>? requests,
  bool offline = false,
  Future<void>? Function(String relative)? attesa,
}) {
  final bundled =
      assets ??
      {
        'assets/database/universita.json': jsonEncode(kUniversitaFixture),
        'assets/database/indice_corsi.json': jsonEncode(kIndiceFixture),
      };
  final dir =
      cacheDir ?? Directory.systemTemp.createTempSync('catalog_cache_test');
  return CatalogService(
    settings,
    fetcher: (uri, {onProgress}) async {
      requests?.add(uri);
      final rel = uri.path.split('/database/').last;
      final gate = attesa?.call(rel);
      if (gate != null) await gate;
      if (offline || remote.isEmpty) throw const SocketException('offline');
      final text = remote[rel];
      if (text == null) throw CatalogNotFoundException();
      onProgress?.call(text.length, text.length);
      return text;
    },
    assetLoader: (path) async {
      final text = bundled[path];
      if (text == null) throw StateError('asset mancante: $path');
      return text;
    },
    assetBytesLoader: (path) async {
      final text = bundled[path];
      if (text == null) throw StateError('asset mancante: $path');
      return Uint8List.fromList(gzip.encode(utf8.encode(text)));
    },
    cacheDir: () async => dir,
  );
}
