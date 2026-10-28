import 'dart:convert';

import 'package:flutter/material.dart' show DateUtils;
import 'package:flutter/services.dart';

import '../../core/catalog/catalog_search.dart' show normalizeText;

/// Vantaggi da studente: offerte gratuite o scontate che si ottengono con
/// l'email universitaria o con la verifica dello status di studente.
/// I dati sono in `assets/vantaggi/vantaggi.json`, controllati a mano sulle
/// pagine dei fornitori (data in [PerksData.updated]); le offerte non valide
/// in Italia non ci sono e quelle a tempo spariscono dopo [Perk.expires].
class PerksData {
  const PerksData({
    required this.updated,
    required this.categories,
    required this.forAll,
    required this.university,
  });

  /// Data dell'ultimo controllo (gg/mm/aaaa).
  final String updated;
  final List<PerkCategory> categories;

  /// Per tutti gli studenti degli atenei italiani, senza accordo dell'ateneo.
  final List<Perk> forAll;

  /// Solo se l'ateneo ha un accordo con il fornitore.
  final List<Perk> university;

  static const asset = 'assets/vantaggi/vantaggi.json';

  /// Solo le offerte ancora valide il giorno [today]: la sezione resta viva
  /// nascosta anche per giorni (app aperta), quindi si filtra a ogni
  /// costruzione, non solo alla lettura.
  PerksData activeOn(DateTime today) => PerksData(
    updated: updated,
    categories: categories,
    forAll: [
      for (final p in forAll)
        if (!p.expiredOn(today)) p,
    ],
    university: [
      for (final p in university)
        if (!p.expiredOn(today)) p,
    ],
  );

  /// Decodifica sempre sul momento: `loadString` sopra i 50 KB passa a un
  /// isolate, che nelle prove con il tempo finto non finisce mai (la
  /// sezione resterebbe sul cerchio di caricamento senza essere provata).
  static Future<PerksData> load([AssetBundle? bundle, DateTime? now]) async {
    final b = await (bundle ?? rootBundle).load(asset);
    return parse(
      utf8.decode(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes)),
      now: now,
    );
  }

  /// [now]: oggi (le prove lo fissano); le offerte scadute non si mostrano.
  static PerksData parse(String text, {DateTime? now}) {
    final j = jsonDecode(text) as Map<String, dynamic>;
    final today = DateUtils.dateOnly(now ?? DateTime.now());
    List<Perk> perks(String key) => [
      for (final p in j[key] as List)
        if (Perk.fromJson(p as Map<String, dynamic>) case final perk
            when !perk.expiredOn(today))
          perk,
    ];
    return PerksData(
      updated: j['aggiornato'] as String,
      categories: [
        for (final c in (j['categorie'] as List).cast<Map<String, dynamic>>())
          PerkCategory(
            id: c['id'] as String,
            name: c['nome'] as String,
            icon: c['icona'] as String,
          ),
      ],
      forAll: perks('perTutti'),
      university: perks('ateneo'),
    );
  }
}

class PerkCategory {
  const PerkCategory({
    required this.id,
    required this.name,
    required this.icon,
  });
  final String id;
  final String name;

  /// Nome dell'icona (vedi `perkIcon`).
  final String icon;
}

class Perk {
  const Perk({
    required this.name,
    required this.what,
    required this.price,
    required this.shortPrice,
    required this.howTo,
    required this.url,
    required this.official,
    required this.checked,
    this.category,
    this.duration,
    this.who,
    this.coverage,
    this.linkLabel,
    this.expires,
  });

  factory Perk.fromJson(Map<String, dynamic> j) => Perk(
    category: j['cat'] as String?,
    name: j['nome'] as String,
    what: j['cosa'] as String,
    price: j['prezzo'] as String,
    shortPrice: j['breve'] as String,
    howTo: j['verifica'] as String,
    duration: j['durata'] as String?,
    who: j['chi'] as String?,
    coverage: j['copertura'] as String?,
    linkLabel: j['etichetta'] as String?,
    expires: parseDmy(j['scade'] as String?),
    url: safePerkUrl(j['url'] as String),
    official: j['ufficiale'] as bool,
    checked: j['data'] as String,
  );

  /// Categoria (solo per i vantaggi per tutti gli studenti).
  final String? category;
  final String name;
  final String what;
  final String price;

  /// Prezzo in breve, mostrato sotto il nome.
  final String shortPrice;
  final String howTo;
  final String? duration;
  final String? who;

  /// Atenei che lo offrono (solo per i vantaggi dell'ateneo).
  final String? coverage;

  /// Pagina ufficiale (https), vuota se non c'è una pagina unica.
  final String url;

  /// Testo del pulsante quando il link non è la pagina del fornitore (es.
  /// «Esempio: pagina di un ateneo»); altrimenti lo si ricava dal dominio.
  final String? linkLabel;

  /// Ultimo giorno dell'offerta a tempo (es. riscatto entro il 31/12):
  /// dal giorno dopo non si mostra più.
  final DateTime? expires;

  bool expiredOn(DateTime today) => expires != null && today.isAfter(expires!);

  /// Condizioni lette tutte sulla pagina ufficiale del fornitore.
  final bool official;

  /// Data del controllo (gg/mm/aaaa).
  final String checked;

  /// Ricerca per nome, descrizione e atenei, senza maiuscole, accenti e
  /// punteggiatura (anche l'apostrofo curvo della tastiera dell'iPhone).
  bool matches(String query) {
    if (query.isEmpty) return true;
    final q = normalizeText(query);
    return normalizeText('$name $what ${coverage ?? ''}').contains(q);
  }
}

/// Il link di un'offerta solo se è una pagina web sicura: `https`, con un
/// host e senza credenziali nell'indirizzo (`https://sito@altro.host`);
/// altrimenti vuoto, cioè nessun pulsante. L'elenco è dentro l'app, ma
/// anche un dato modificato per errore non apre mai altri schemi
/// (`tel:`, `mailto:`, `market:`…) che ExternalLauncher accetterebbe.
String safePerkUrl(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null || u.scheme != 'https' || u.host.isEmpty) return '';
  if (u.userInfo.isNotEmpty || u.hasPort) return '';
  return url.trim();
}

/// «gg/mm/aaaa» → data; null se assente o non valida.
DateTime? parseDmy(String? s) {
  final m = RegExp(r'^(\d{2})/(\d{2})/(\d{4})$').firstMatch(s ?? '');
  if (m == null) return null;
  return DateTime(
    int.parse(m.group(3)!),
    int.parse(m.group(2)!),
    int.parse(m.group(1)!),
  );
}
