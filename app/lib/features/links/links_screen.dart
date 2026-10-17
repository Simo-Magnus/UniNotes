import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/app_services.dart';
import '../../core/theme/app_tokens.dart';
import 'ai_reference_card.dart';
import 'gemini_card.dart';
import 'google_drive_card.dart';
import 'onedrive_card.dart';
import 'whisper_card.dart';

/// Collegamenti: tutto ciò che collega l'app a servizi esterni —
/// trascrizione (Whisper, Gemini), AI di riferimento, OneDrive e Google
/// Drive. Il resto dell'app funziona senza internet.
class LinksScreen extends StatefulWidget {
  const LinksScreen({super.key});

  @override
  State<LinksScreen> createState() => _LinksScreenState();
}

class _LinksScreenState extends State<LinksScreen> {
  late final AppServices _s = context.read<AppServices>();
  bool _onedrivePrimary = false;

  @override
  void initState() {
    super.initState();
    _updatePrimary();
  }

  /// Il prossimo passo suggerito (azione arancione): collegare OneDrive,
  /// se non è collegato nessun servizio cloud.
  Future<void> _updatePrimary() async {
    final next =
        !await _s.onedrive.connected() && !await _s.googleDrive.connected();
    if (mounted && next != _onedrivePrimary) {
      setState(() => _onedrivePrimary = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cards = <Widget>[
      const _SectionLabel('Trascrizione delle registrazioni'),
      const GeminiCard(),
      const WhisperCard(),
      const _SectionLabel('Studio con l\'AI'),
      const AiReferenceCard(),
      const _SectionLabel('Sincronizzazione'),
      const _SectionNote(
        'Google Drive: l\'app vede i file che salva lei e quelli che importi. '
        'OneDrive: vede tutto quello che metti nella cartella UniNotes, anche '
        'dal sito.',
      ),
      OneDriveCard(primary: _onedrivePrimary, onChanged: _updatePrimary),
      GoogleDriveCard(onChanged: _updatePrimary),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Collegamenti')),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: cards,
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 16, 20, 2),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
}

/// Riga di spiegazione sotto il titolo di una sezione.
class _SectionNote extends StatelessWidget {
  const _SectionNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
    child: Text(
      text,
      style: TextStyle(fontSize: 13, color: context.tokens.textSecondary),
    ),
  );
}
