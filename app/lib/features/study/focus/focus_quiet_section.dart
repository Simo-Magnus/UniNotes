import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/feedback/feedback_service.dart';
import '../../../core/services/app_services.dart';
import '../../settings/widgets/settings_card.dart';
import 'focus_service.dart';
import 'focus_system.dart';

/// Impostazioni → «Focus e Non disturbare»: durante le sessioni Focus il
/// sistema blocca le notifiche di tutte le app tranne quelle vitali, come
/// il Non disturbare. Interruttore, spiegazione e (Android) permesso;
/// su iOS e macOS il comando da creare nell'app Comandi.
///
/// Sezione pronta da mettere nella pagina delle impostazioni:
/// `const FocusQuietSection()`. [kind] serve solo ai test.
class FocusQuietSection extends StatefulWidget {
  const FocusQuietSection({super.key, this.kind});

  final FocusSystemKind? kind;

  @override
  State<FocusQuietSection> createState() => _FocusQuietSectionState();
}

class _FocusQuietSectionState extends State<FocusQuietSection> {
  late final FocusService _focus = context.read<AppServices>().focus;
  late final FocusSystemKind _kind = widget.kind ?? _focus.system.kind;
  AppLifecycleListener? _lifecycle;

  /// Android: «Accesso a Non disturbare» concesso (null = non ancora letto).
  bool? _access;

  @override
  void initState() {
    super.initState();
    if (_kind == FocusSystemKind.androidDnd) {
      _readAccess();
      // tornando dalla pagina del sistema il permesso si rilegge
      _lifecycle = AppLifecycleListener(onResume: _readAccess);
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }

  Future<void> _readAccess() async {
    final v = await _focus.system.hasDndAccess();
    if (mounted) setState(() => _access = v);
  }

  Future<void> _set(bool on) async {
    AppFeedback.of(context).toggle();
    await _focus.setDnd(on ? DndChoice.always : DndChoice.never);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final on = systemQuietOn(_kind, _focus.dnd);
    final children = switch (_kind) {
      FocusSystemKind.androidDnd => _android(on, small),
      FocusSystemKind.windowsFocus => _windows(on, small),
      FocusSystemKind.appleFocus => _apple(on, small),
      FocusSystemKind.none => [
        Text(
          'Su questo sistema l\'app non può silenziare le altre app: durante '
          'una sessione Focus aspettano solo gli avvisi non urgenti di '
          'UniNotes.',
          style: small,
        ),
      ],
    };
    return SettingsCard(
      title: 'Focus e Non disturbare',
      icon: Icons.do_not_disturb_on_outlined,
      subtitle:
          'Durante una sessione Focus (Studio → Sessioni Studio → Timer) si '
          'fermano le notifiche di tutte le app, tranne quelle vitali, come '
          'con il Non disturbare. Gli avvisi non urgenti di UniNotes '
          'arrivano a fine sessione.',
      children: children,
    );
  }

  List<Widget> _android(bool on, TextStyle? small) {
    final access = _access;
    return [
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Silenzia il telefono durante Focus'),
        subtitle: const Text(
          'Si attiva da solo all\'inizio della sessione e torna come prima '
          'alla fine, anche se chiudi l\'app.',
        ),
        value: on,
        onChanged: _set,
      ),
      const SizedBox(height: 4),
      Text('Passano solo:', style: small),
      for (final l in const [
        'sveglie e timer;',
        'chiamate ripetute (la stessa persona entro 15 minuti);',
        'chiamate dai contatti preferiti;',
        'l\'audio di video, musica e lezioni che fai partire tu.',
      ])
        Padding(
          padding: const EdgeInsets.only(left: 8, top: 2),
          child: Text('• $l', style: small),
        ),
      const SizedBox(height: 4),
      Text(
        'Messaggi, social, email ed eventi restano nella tendina senza '
        'suonare né comparire sullo schermo.',
        style: small,
      ),
      if (on && access != null) ...[
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            access ? Icons.verified_user_outlined : Icons.lock_outline,
            color: access
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.error,
          ),
          title: Text(
            access
                ? 'Accesso a Non disturbare concesso'
                : 'Serve l\'«Accesso a Non disturbare»',
          ),
          subtitle: Text(
            access
                ? 'UniNotes può attivare e spegnere il Non disturbare solo '
                      'durante le tue sessioni Focus.'
                : 'È il permesso di Android che lascia a un\'app attivare il '
                      'Non disturbare. Si apre la pagina del sistema: scegli '
                      'UniNotes, attiva e torna qui.',
          ),
          trailing: access
              ? null
              : FilledButton.tonal(
                  key: const Key('focus-dnd-access'),
                  onPressed: _focus.system.openDndAccessSettings,
                  child: const Text('Concedi'),
                ),
        ),
      ],
    ];
  }

  List<Widget> _windows(bool on, TextStyle? small) => [
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: const Text('Avvia la sessione di concentrazione di Windows'),
      subtitle: const Text(
        'Windows attiva «Non disturbare»: niente notifiche né badge delle '
        'altre app fino alla fine della sessione. Sveglie e notifiche che '
        'hai segnato come prioritarie passano.',
      ),
      value: on,
      onChanged: _set,
    ),
    Text(
      'Windows 11 riserva questa funzione alle app autorizzate da '
      'Microsoft: se la rifiuta, la sessione lo dice e offre il pulsante per '
      'le impostazioni delle notifiche, dove attivare «Non disturbare» a '
      'mano.',
      style: small,
    ),
  ];

  List<Widget> _apple(bool on, TextStyle? small) => [
    Text(
      'Apple non permette alle app di attivare una Full immersion. Si può '
      'fare con un comando dell\'app Comandi, una volta sola:',
      style: small,
    ),
    const SizedBox(height: 6),
    for (final (i, l) in const [
      'apri Comandi e crea un nuovo comando di nome «$kAppleFocusShortcut»;',
      'aggiungi l\'azione «Ottieni date da input» (input: Input comando);',
      'aggiungi «Imposta Full immersion»: Non disturbare, Attiva, «Fino a: '
          'Ora», e come ora scegli le Date del passo 2.',
    ].indexed)
      Padding(
        padding: const EdgeInsets.only(left: 8, top: 2),
        child: Text('${i + 1}. $l', style: small),
      ),
    SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text('Avvia «$kAppleFocusShortcut» con la sessione'),
      subtitle: const Text(
        'All\'avvio l\'app apre Comandi con l\'ora di fine: il Non disturbare '
        'resta fino ad allora (chiamate ripetute e sveglie passano) e '
        'Comandi torna da solo su UniNotes con l\'esito.',
      ),
      value: on,
      onChanged: _set,
    ),
  ];
}
