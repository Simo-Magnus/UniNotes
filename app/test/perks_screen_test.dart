import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/theme/app_theme.dart';
import 'package:university_notes/features/perks/perks.dart';
import 'package:university_notes/features/perks/perks_screen.dart';
import 'package:university_notes/widgets/section_active.dart';

/// Bundle di prova con i byte dell'asset.
class _Bundle extends CachingAssetBundle {
  _Bundle(this.bytes);
  final List<int> bytes;

  @override
  Future<ByteData> load(String key) async =>
      ByteData.sublistView(Uint8List.fromList(bytes));
}

/// I dati veri dell'app (l'asset), letti dal file come fa il bundle.
/// Giorno fisso delle prove (quello del controllo dell'elenco): con la data
/// vera le offerte a tempo sparirebbero e le prove fallirebbero da sole.
final _today = DateTime(2026, 10, 28);

PerksData _data() => PerksData.parse(
  File('assets/vantaggi/vantaggi.json').readAsStringSync(),
  now: _today,
);

Future<void> _pump(
  WidgetTester tester,
  PerksData d, {
  ThemeData? theme,
  Size size = const Size(412, 915),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme ?? AppTheme.dark(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: PerksScreen(data: d, clock: () => _today),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('dati dei vantaggi', () {
    final d = _data();

    test('solo vantaggi disponibili: per tutti e dal proprio ateneo', () {
      expect(d.forAll.length, greaterThan(50));
      expect(d.university, isNotEmpty);
      expect(d.updated, matches(RegExp(r'^\d\d/\d\d/\d{4}$')));
      // niente offerte scadute o non valide in Italia (erano nella sezione
      // «non disponibili», che nell'app non c'è)
      final names = [...d.forAll, ...d.university].map((p) => p.name);
      for (final gone in ['Headspace', 'Claude Pro', 'Cursor', 'Proton']) {
        expect(names.where((n) => n.startsWith(gone)), isEmpty, reason: gone);
      }
    });

    test('ogni vantaggio ha categoria, link https e testi per lo studente', () {
      final ids = d.categories.map((c) => c.id).toSet();
      for (final p in d.forAll) {
        expect(ids, contains(p.category), reason: p.name);
        expect(p.duration, isNotNull, reason: p.name);
      }
      for (final p in d.university) {
        expect(p.coverage, isNotNull, reason: p.name);
      }
      final work = RegExp(
        r'\[U\]|\[S\]|fonte secondaria|fonti secondarie|estratto|aggregatore|'
        r'\((?:vedi )?[A-C]\d?\)|\bvedi [A-E]\d?\b',
      );
      // link nei dati grezzi (prima della pulizia, che scarta quelli non
      // sicuri): tutti sicuri, e vuoti solo tra le offerte dell'ateneo
      final raw = jsonDecode(
        File(PerksData.asset).readAsStringSync(),
      ) as Map<String, dynamic>;
      for (final key in ['perTutti', 'ateneo']) {
        for (final e in (raw[key] as List).cast<Map<String, dynamic>>()) {
          final url = e['url'] as String;
          if (url.isEmpty) {
            expect(key, 'ateneo', reason: '${e['nome']}: link vuoto');
          } else {
            expect(safePerkUrl(url), url, reason: '${e['nome']}: $url');
          }
        }
      }
      for (final p in [...d.forAll, ...d.university]) {
        for (final s in [p.name, p.what, p.price, p.howTo, p.coverage ?? '']) {
          expect(work.hasMatch(s), isFalse, reason: '${p.name}: $s');
        }
      }
    });

    test('link: solo https con un host, mai credenziali o altri schemi', () {
      expect(safePerkUrl('https://www.adobe.com/it/'), isNotEmpty);
      expect(safePerkUrl('http://www.adobe.com/'), isEmpty);
      expect(safePerkUrl('tel:+390000000'), isEmpty);
      expect(safePerkUrl('mailto:a@b.it'), isEmpty);
      expect(safePerkUrl('https://www.adobe.com@altro.example/'), isEmpty);
      expect(safePerkUrl('https://www.adobe.com:8443/'), isEmpty);
      expect(safePerkUrl('https:///senza-host'), isEmpty);
      // nessun link generico alla home di UNiDAYS: ogni marchio la sua pagina
      for (final p in [...d.forAll, ...d.university]) {
        expect(
          p.url.endsWith('myunidays.com/IT/it-IT'),
          isFalse,
          reason: p.name,
        );
      }
    });

    test('pagine di un singolo ateneo: il pulsante dice che è un esempio', () {
      // domini degli atenei italiani (uniroma3.it, polimi.it, unipa.it…)
      final university = RegExp(r'(^|[.])(uni|poli)[a-z0-9]*[.]it$');
      final examples = [
        for (final p in [...d.forAll, ...d.university])
          if (university.hasMatch(Uri.parse(p.url).host)) p,
      ];
      expect(examples, isNotEmpty);
      for (final p in examples) {
        expect(
          p.linkLabel,
          'Esempio: pagina di un ateneo',
          reason: '${p.name}: ${p.url}',
        );
      }
    });

    test('il pulsante dice dove porta', () {
      expect(
        perkLinkLabel(
          'https://www.myunidays.com/IT/it-IT/partners/adidas/view',
        ),
        'Apri su UNiDAYS',
      );
      expect(
        perkLinkLabel(
          'https://www.studentbeans.com/student-discount/it/babbel',
        ),
        'Apri su Student Beans',
      );
      expect(
        perkLinkLabel('https://shop.sheerid.com/countries/italy'),
        'Apri su SheerID',
      );
      expect(perkLinkLabel('https://isic.it/card'), 'Apri su ISIC');
      expect(
        perkLinkLabel('https://www.spotify.com/it/student/'),
        "Pagina dell'offerta",
      );
      // un dominio che contiene il nome ma non è quello
      expect(
        perkLinkLabel('https://myunidays.com.example/'),
        "Pagina dell'offerta",
      );
    });

    testWidgets("l'asset sopra i 50 KB si legge anche con il tempo finto", (
      tester,
    ) async {
      // load() decodifica sul momento: con loadString sopra i 50 KB la
      // decodifica passerebbe a un isolate, che con il tempo finto delle
      // prove non finisce mai (la sezione resterebbe sul caricamento)
      final bytes = [
        ...File(PerksData.asset).readAsBytesSync(),
        ...List.filled(60 * 1024, 0x20), // spazi in coda: JSON valido
      ];
      expect(bytes.length, greaterThan(50 * 1024));
      PerksData? loaded;
      unawaited(PerksData.load(_Bundle(bytes), _today).then((v) => loaded = v));
      await tester.pump();
      expect(loaded, isNotNull);
      expect(loaded!.forAll.length, d.forAll.length);
    });

    test('le offerte a tempo spariscono dopo la scadenza', () {
      final text = File(PerksData.asset).readAsStringSync();
      final timed = d.forAll.where((p) => p.expires != null).toList();
      expect(timed, isNotEmpty);
      final last = timed
          .map((p) => p.expires!)
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final first = timed
          .map((p) => p.expires!)
          .reduce((a, b) => a.isBefore(b) ? a : b);
      // l'ultimo giorno si vede ancora, il giorno dopo no
      final onLastDay = PerksData.parse(text, now: first);
      expect(onLastDay.forAll.where((p) => p.expires == first), isNotEmpty);
      final after = PerksData.parse(
        text,
        now: last.add(const Duration(days: 1)),
      );
      expect(after.forAll.where((p) => p.expires != null), isEmpty);
      expect(after.forAll.length, d.forAll.length - timed.length);
    });

    test('ogni offerta con «entro il / fino al gg/mm/aaaa» ha la scadenza', () {
      // anche «dal … al gg/mm/aaaa»: una parte a tempo dentro un'offerta
      final dated = RegExp(r'(entro il|fino al|al) \d\d/\d\d/\d{4}');
      final all = PerksData.parse(
        File(PerksData.asset).readAsStringSync(),
        now: DateTime(2000),
      );
      for (final p in [...all.forAll, ...all.university]) {
        final text = [
          p.what,
          p.price,
          p.howTo,
          p.duration,
          // non la copertura: lì le date sono di atenei d'esempio, non
          // dell'offerta
        ].whereType<String>().join(' ');
        final dates = [
          for (final m in RegExp(
            r'(?:entro il|fino al|al) (\d\d/\d\d/\d{4})',
          ).allMatches(text))
            parseDmy(m.group(1))!,
        ];
        if (dated.hasMatch(text)) {
          expect(p.expires, isNotNull, reason: p.name);
          // la scadenza non va oltre nessuna data scritta nel testo: una
          // parte già finita non resta visibile
          for (final d in dates) {
            expect(p.expires!.isAfter(d), isFalse, reason: '${p.name}: $d');
          }
        }
        // codici stagionali («FALL2026»): scadono senza una data nel testo
        expect(
          RegExp(r'\b[A-Z]{3,}20\d\d\b').hasMatch(text),
          isFalse,
          reason: p.name,
        );
      }
    });

    test('ricerca senza maiuscole e accenti', () {
      final p = d.forAll.firstWhere((p) => p.name.startsWith('Babbel'));
      expect(p.matches('BABBEL'), isTrue);
      // apostrofo curvo (tastiera dell'iPhone) e spazi doppi
      final m = d.university.firstWhere((p) => p.name.startsWith('Microsoft'));
      expect(m.matches('microsoft 365  dell’ateneo'), isTrue);
      expect(p.matches('Babbèl'), isTrue);
    });
  });

  group('schermata', () {
    late PerksData d;
    setUpAll(() => d = _data());

    testWidgets('due schede, nessuna «Non disponibili» e nessun «Tutti»', (
      tester,
    ) async {
      await _pump(tester, d);
      expect(find.text('Per tutti'), findsOneWidget);
      expect(find.text('Dal tuo ateneo'), findsOneWidget);
      expect(find.textContaining('Non disponibili'), findsNothing);
      expect(find.textContaining('Tutti'), findsNothing);
      // prima categoria scelta: i vantaggi di sviluppo
      expect(find.text('GitHub Student Developer Pack'), findsOneWidget);
      await tester.tap(find.byKey(const Key('perks-cat-A2')));
      await tester.pumpAndSettle();
      expect(find.text('Google AI Plus per studenti'), findsOneWidget);
      expect(find.text('GitHub Student Developer Pack'), findsNothing);
    });

    testWidgets('toccando una card si vedono condizioni e link', (
      tester,
    ) async {
      await _pump(tester, d);
      const link = "Pagina dell'offerta";
      expect(find.text(link), findsNothing);
      await tester.tap(find.text('GitHub Student Developer Pack'));
      await tester.pumpAndSettle();
      expect(find.text('COME SI OTTIENE'), findsOneWidget);
      expect(find.text('DURATA'), findsOneWidget);
      expect(find.text(link), findsOneWidget);
      expect(find.textContaining('Condizioni controllate il'), findsOneWidget);
      // di nuovo: si chiude
      await tester.tap(find.text('GitHub Student Developer Pack'));
      await tester.pumpAndSettle();
      expect(find.text(link), findsNothing);
    });

    testWidgets('la card aperta resta quella toccata (categoria, ricerca)', (
      tester,
    ) async {
      await _pump(tester, d);
      await tester.tap(find.text('GitHub Student Developer Pack'));
      await tester.pumpAndSettle();
      expect(find.text('COME SI OTTIENE'), findsOneWidget);
      // un'altra categoria: nessuna card si apre da sola
      await tester.tap(find.byKey(const Key('perks-cat-A2')));
      await tester.pumpAndSettle();
      expect(find.text('COME SI OTTIENE'), findsNothing);
      // la ricerca: il primo risultato non si apre da solo
      await tester.enterText(find.byKey(const Key('perks-search')), 'babbel');
      await tester.pumpAndSettle();
      expect(find.text('COME SI OTTIENE'), findsNothing);
      // tornando a Sviluppo la card di GitHub è ancora aperta
      await tester.enterText(find.byKey(const Key('perks-search')), '');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('perks-cat-A1')));
      await tester.pumpAndSettle();
      expect(find.text('COME SI OTTIENE'), findsOneWidget);
    });

    testWidgets('offerte non confermate: «da confermare» anche a card chiusa', (
      tester,
    ) async {
      final unconfirmed = d.forAll.where((p) => !p.official).length;
      expect(unconfirmed, greaterThan(0));
      await _pump(tester, d);
      // la lista costruisce solo le card visibili: si controllano le prime
      // due, GitHub (confermata) e JetBrains (da confermare)
      String priceOf(String name) {
        final card = find.ancestor(
          of: find.text(name),
          matching: find.byType(PerkCard),
        );
        return tester
            .widgetList<RichText>(
              find.descendant(of: card, matching: find.byType(RichText)),
            )
            .map((r) => r.text.toPlainText())
            .join('|');
      }

      expect(
        d.forAll.firstWhere((p) => p.name.startsWith('GitHub')).official,
        isTrue,
      );
      expect(
        priceOf('GitHub Student Developer Pack'),
        isNot(contains('da confermare')),
      );
      expect(
        d.forAll.firstWhere((p) => p.name.startsWith('JetBrains')).official,
        isFalse,
      );
      // le offerte da confermare sono in fondo all'elenco
      await tester.scrollUntilVisible(
        find.text('JetBrains licenza educativa'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(priceOf('JetBrains licenza educativa'), contains('da confermare'));
    });

    testWidgets('prima le confermate, in fondo quelle da confermare', (
      tester,
    ) async {
      await _pump(tester, d, size: const Size(412, 20000));
      final names = d.forAll
          .where((p) => p.category == 'A1')
          .map((p) => p.name)
          .toList();
      final shown = [
        for (final n in names)
          if (find.text(n).evaluate().isNotEmpty)
            (n, tester.getTopLeft(find.text(n)).dy),
      ]..sort((a, b) => a.$2.compareTo(b.$2));
      expect(shown.length, names.length);
      final official = {for (final p in d.forAll) p.name: p.official};
      final flags = shown.map((s) => official[s.$1]!).toList();
      // nessuna confermata dopo la prima da confermare
      final firstUnconfirmed = flags.indexOf(false);
      expect(firstUnconfirmed, greaterThan(0));
      expect(flags.sublist(firstUnconfirmed).contains(true), isFalse);
    });

    testWidgets('si possono nascondere le offerte da confermare', (
      tester,
    ) async {
      await _pump(tester, d, size: const Size(412, 20000));
      expect(find.text('JetBrains licenza educativa'), findsOneWidget);
      await tester.tap(find.byKey(const Key('perks-show-unconfirmed')));
      await tester.pumpAndSettle();
      expect(find.text('JetBrains licenza educativa'), findsNothing);
      expect(find.text('GitHub Student Developer Pack'), findsOneWidget);
      // anche nella ricerca e nell'altra scheda
      await tester.tap(find.text('Dal tuo ateneo'));
      await tester.pumpAndSettle();
      expect(find.text('Overleaf (licenza istituzionale)'), findsNothing);
      // di nuovo visibili
      await tester.tap(find.byKey(const Key('perks-show-unconfirmed')));
      await tester.pumpAndSettle();
      expect(find.text('Overleaf (licenza istituzionale)'), findsOneWidget);
    });

    testWidgets('lettore di schermo: i dettagli non sono nel pulsante', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await _pump(tester, d);
      await tester.tap(find.text('GitHub Student Developer Pack'));
      await tester.pumpAndSettle();
      final header = tester.getSemantics(
        find.text('GitHub Student Developer Pack'),
      );
      expect(header.label, isNot(contains('COME SI OTTIENE')));
      expect(header.flagsCollection.isButton, isTrue);
      semantics.dispose();
    });

    testWidgets("sezione nascosta e riaperta dopo la scadenza: l'offerta "
        'sparisce', (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var today = DateTime(2026, 12, 31);
      final active = ValueNotifier(true);
      addTearDown(active.dispose);
      // la stessa istanza della schermata, come nella pila delle sezioni:
      // senza il ritorno nella sezione non si ricostruirebbe
      final screen = PerksScreen(data: d, clock: () => today);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: ValueListenableBuilder<bool>(
            valueListenable: active,
            builder: (_, a, _) => SectionActive(active: a, child: screen),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('perks-search')),
        'Google AI Plus',
      );
      await tester.pumpAndSettle();
      expect(find.text('Google AI Plus per studenti'), findsOneWidget);
      // un'altra sezione, poi due giorni dopo si torna in Vantaggi
      active.value = false;
      await tester.pump();
      today = DateTime(2027, 1, 2);
      active.value = true;
      await tester.pumpAndSettle();
      expect(find.text('Google AI Plus per studenti'), findsNothing);
    });

    testWidgets('offerta a tempo: la data è quella entro cui ottenerla', (
      tester,
    ) async {
      // per Google AI Plus il 31/12 è il riscatto, non la fine dell'anno
      // gratis: la riga parla dell'offerta, non del vantaggio
      await _pump(tester, d);
      await tester.tap(find.byKey(const Key('perks-cat-A2')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Google AI Plus per studenti'));
      await tester.pumpAndSettle();
      expect(find.text('OFFERTA DISPONIBILE FINO AL'), findsOneWidget);
      expect(find.text('31/12/2026'), findsOneWidget);
      expect(find.text('FINO AL'), findsNothing);
    });

    testWidgets("app in primo piano dopo la scadenza: l'offerta sparisce", (
      tester,
    ) async {
      // stessa schermata aperta, l'app torna in primo piano due giorni dopo
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var today = DateTime(2026, 12, 31);
      final screen = PerksScreen(data: d, clock: () => today);
      await tester.pumpWidget(
        MaterialApp(theme: AppTheme.dark(), home: screen),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('perks-search')),
        'Google AI Plus',
      );
      await tester.pumpAndSettle();
      expect(find.text('Google AI Plus per studenti'), findsOneWidget);
      // in background e di nuovo in primo piano, con i passaggi in ordine
      for (final st in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      today = DateTime(2027, 1, 2);
      for (final st in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(st);
      }
      await tester.pumpAndSettle();
      expect(find.text('Google AI Plus per studenti'), findsNothing);
    });

    testWidgets("risultati in tutte e due le schede: il pulsante per l'altra", (
      tester,
    ) async {
      await _pump(tester, d);
      await tester.enterText(find.byKey(const Key('perks-search')), 'Adobe');
      await tester.pumpAndSettle();
      expect(
        find.text('Adobe Creative Cloud Pro per studenti'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byKey(const Key('perks-also-other-tab')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byKey(const Key('perks-also-other-tab')));
      await tester.pumpAndSettle();
      expect(
        find.text('Adobe Creative Cloud (licenza campus)'),
        findsOneWidget,
      );
    });

    testWidgets("offerta dell'ateneo con pagina d'esempio: da confermare con "
        'il proprio ateneo', (tester) async {
      // il link è la pagina di un altro ateneo: quello che va confermato è
      // l'accordo del proprio, non la pagina del fornitore
      await _pump(tester, d);
      await tester.tap(find.text('Dal tuo ateneo'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('perks-search')), 'Overleaf');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Overleaf (licenza istituzionale)'));
      await tester.pumpAndSettle();
      expect(find.text('Esempio: pagina di un ateneo'), findsOneWidget);
      expect(
        find.textContaining('Da confermare con il tuo ateneo'),
        findsOneWidget,
      );
      expect(find.textContaining('pagina del fornitore'), findsNothing);
    });

    testWidgets('offerta senza pagina: da confermare con il proprio ateneo', (
      tester,
    ) async {
      await _pump(tester, d);
      await tester.tap(find.text('Dal tuo ateneo'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('perks-search')),
        'Biblioteca',
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.text(
          'Biblioteca digitale (JSTOR completo, MLOL, Scopus, Web of Science)',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Da confermare con il tuo ateneo'),
        findsOneWidget,
      );
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets("ricerca vuota qui ma non nell'altra scheda: si può passarci", (
      tester,
    ) async {
      await _pump(tester, d);
      await tester.enterText(find.byKey(const Key('perks-search')), 'Canva');
      await tester.pumpAndSettle();
      expect(find.text('Nessun servizio in questa scheda.'), findsOneWidget);
      await tester.tap(find.byKey(const Key('perks-other-tab')));
      await tester.pumpAndSettle();
      expect(find.text('Canva for Campus'), findsOneWidget);
    });

    testWidgets('la ricerca cerca in tutte le categorie', (tester) async {
      await _pump(tester, d);
      await tester.enterText(find.byKey(const Key('perks-search')), 'babbel');
      await tester.pumpAndSettle();
      expect(find.text('Babbel'), findsOneWidget);
      expect(find.text('Acquisti'), findsOneWidget);
      expect(find.text('GitHub Student Developer Pack'), findsNothing);
      await tester.enterText(find.byKey(const Key('perks-search')), 'zzzz');
      await tester.pumpAndSettle();
      expect(find.text('Nessun servizio trovato.'), findsOneWidget);
    });

    testWidgets('Dal tuo ateneo: come controllarlo e Microsoft 365', (
      tester,
    ) async {
      await _pump(tester, d, theme: AppTheme.light());
      await tester.tap(find.text('Dal tuo ateneo'));
      await tester.pumpAndSettle();
      expect(find.textContaining('solo se ha un accordo'), findsOneWidget);
      expect(find.byKey(const Key('perks-cat-A1')), findsNothing);
      // da confermare: in fondo all'elenco dell'ateneo
      await tester.scrollUntilVisible(
        find.text('Microsoft 365 dell\'ateneo'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Microsoft 365 dell\'ateneo'), findsOneWidget);
      await tester.tap(find.text('Microsoft 365 dell\'ateneo'));
      await tester.pumpAndSettle();
      expect(find.text('DOVE C\'È'), findsOneWidget);
    });

    testWidgets(
      'telefono stretto e caratteri grandi: nessun errore di layout',
      (tester) async {
        await _pump(tester, d, size: const Size(320, 640), textScale: 2);
        expect(tester.takeException(), isNull);
        // con i caratteri grandi la prima card è più in basso
        await tester.scrollUntilVisible(
          find.text('GitHub Student Developer Pack'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text('GitHub Student Developer Pack'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  });
}
