import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../widgets/common.dart' show showSnack;
import 'ai_assistants.dart';
import 'link_status.dart' show aiChosenMessage;
import 'links_widgets.dart';
import 'link_settings.dart';

/// Pagina dell'offerta di Google per gli studenti (piano, prezzo e durata
/// cambiano: a ottobre 2026 Google AI Plus, gratis per un periodo con la
/// verifica dello status e poi a pagamento). La pagina ufficiale è la fonte:
/// la nota non nomina piano né costi e non dice che ci sia di sicuro,
/// così non diventa falsa quando l'offerta finisce.
const kGoogleStudentOffer = 'https://gemini.google/students/';

/// «AI di riferimento»: l'assistente con cui lo studente lavora sul
/// materiale (ChatGPT, Claude, Copilot, Perplexity, NotebookLM, Gemini).
/// Nelle sezioni Studio e Registra l'app propone il prompt e i file da
/// allegare nella sua chat.
class AiReferenceCard extends StatefulWidget {
  const AiReferenceCard({super.key});

  @override
  State<AiReferenceCard> createState() => _AiReferenceCardState();
}

class _AiReferenceCardState extends State<AiReferenceCard> {
  late final AppServices _s = context.read<AppServices>();
  late Future<ReferenceAi> _future = _s.settings.referenceAi();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ReferenceAi>(
      future: _future,
      builder: (context, snap) {
        final ai = snap.data;
        return LinksCard(
          title: 'AI di riferimento',
          icon: Icons.psychology_alt_outlined,
          subtitle:
              'Scegli l\'assistente che utilizzerai per lavorare sul materiale '
              'da studiare.',
          children: ai == null
              ? const [SizedBox(height: 48)]
              : [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final a in ReferenceAi.values)
                        ChoiceChip(
                          label: Text(a.label),
                          selected: a == ai,
                          onSelected: (_) async {
                            if (a == ai) return;
                            await _s.settings.setReferenceAi(a);
                            _s.revision.bump();
                            if (!context.mounted) return;
                            setState(() {
                              _future = Future.value(a);
                            });
                            showSnack(context, aiChosenMessage(a));
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      LinkText('Apri ${ai.label}', ai.web),
                      if (Platform.isAndroid)
                        LinkText(
                          'Installa l\'app',
                          '${ai.playStoreUri}',
                          icon: Icons.shop_outlined,
                        ),
                      if (Platform.isIOS)
                        LinkText(
                          'Installa l\'app',
                          '${ai.appStoreUri}',
                          icon: Icons.shop_outlined,
                        ),
                    ],
                  ),
                  StatusLine('In uso: ${ai.label}. ${ai.hint}', ok: true),
                  // Gemini (ex card «Gemini»): offerta studenti e
                  // trascrizione delle lezioni con l'account universitario
                  if (ai == ReferenceAi.gemini) ...[
                    const NoteText(
                      'Google a volte ha offerte per gli studenti '
                      'universitari: se ce ne sono, piano, durata ed '
                      'eventuali costi sono nella pagina di Google. '
                      'Sulle registrazioni «Trascrivi con Gemini» apre Gemini '
                      'con il file e il prompt pronti.',
                      icon: Icons.school_outlined,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: LinkText(
                        'Offerte di Google per studenti',
                        kGoogleStudentOffer,
                      ),
                    ),
                  ] else
                    const NoteText(
                      'Per trascrivere una lezione con Gemini usa «Trascrivi '
                      'con Gemini» sulla registrazione: si apre con il tuo '
                      'account Google.',
                      icon: Icons.info_outline,
                    ),
                  const NoteText(
                    'Privacy: i file che condividi vanno all\'AI scelta con il tuo '
                    'account e seguono le sue regole. Non condividere dati personali '
                    'di altre persone.',
                    icon: Icons.privacy_tip_outlined,
                  ),
                ],
        );
      },
    );
  }
}
