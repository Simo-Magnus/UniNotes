import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import 'ai_assistants.dart';
import 'links_widgets.dart';
import 'link_settings.dart';

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
                            await _s.settings.setReferenceAi(a);
                            _s.revision.bump();
                            setState(() {
                              _future = Future.value(a);
                            });
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
