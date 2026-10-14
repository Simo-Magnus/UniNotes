import 'package:flutter/material.dart';

import 'links_widgets.dart';

/// Pagina dell'offerta Google AI Pro per gli studenti (gratuita per un
/// periodo, con verifica dello status di studente). Offerta e durata possono
/// cambiare: la pagina ufficiale è la fonte.
const kGoogleStudentOffer = 'https://gemini.google/students/';

/// Gemini con l'account (universitario) dell'utente, senza chiave API e
/// senza costi: «Trascrivi con Gemini» apre gemini.google.com e propone il
/// file da allegare e il prompt da inviare; la trascrizione copiata in
/// Gemini si salva da sola tornando nell'app. Niente chiave API.
class GeminiCard extends StatelessWidget {
  const GeminiCard({super.key});

  @override
  Widget build(BuildContext context) {
    return const LinksCard(
      title: 'Gemini',
      icon: Icons.auto_awesome_outlined,
      subtitle:
          'Usa Gemini con il tuo account universitario: sfrutti Google AI Pro '
          'senza chiavi API e senza costi.',
      children: [
        StepList([
          StepText(
            'Accedi a Gemini con il tuo account universitario e, se non l\'hai '
            'già fatto, attiva l\'offerta studenti di Google AI Pro.',
            actions: [LinkText('Offerta studenti', kGoogleStudentOffer)],
          ),
          StepText(
            'Sulla registrazione premi «Trascrivi con Gemini»: si apre Gemini e '
            'l\'app ti propone il file da allegare e il prompt da inviare.',
          ),
          StepText(
            'Quando Gemini ha finito, copia la trascrizione e torna in '
            'UniNotes: viene salvata da sola negli appunti del corso, con il '
            'colore viola di Gemini.',
          ),
        ]),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [LinkText('Apri Gemini', 'https://gemini.google.com/app')],
        ),
        NoteText(
          'Privacy: l\'audio viene caricato nel tuo account Google (Gemini) e '
          'resta nella cronologia finché non lo elimini.',
          icon: Icons.privacy_tip_outlined,
        ),
      ],
    );
  }
}
