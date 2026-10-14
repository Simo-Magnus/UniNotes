import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/academic/academic_year.dart';
import '../../core/academic/year_transition.dart';
import '../../core/catalog/path_setup.dart';
import '../../core/services/app_services.dart';
import '../../repositories/settings_repository.dart';
import '../../widgets/common.dart';
import 'year_grades_screen.dart';

/// Risposta alla domanda del nuovo anno accademico.
enum NewYearAnswer { yes, no, later }

/// Al primo avvio dopo il 1° settembre di un nuovo anno accademico chiede
/// "È iniziato il nuovo anno accademico 2027/28: sei al 3° anno?".
/// Sì → voti dell'anno appena finito (completato / in parte), passaggio
/// all'anno successivo e controllo degli aggiornamenti del database.
/// No → stesso anno del piano nel nuovo anno accademico. Chiudendo il
/// riquadro (tocco fuori o Indietro) → si richiede al prossimo avvio: due
/// soli pulsanti.
Future<NewYearAnswer?> checkNewAcademicYear(
  BuildContext context, {
  DateTime? now,
}) async {
  final s = context.read<AppServices>();
  final p = s.profile.value;
  if (p == null) return null;
  final t = pendingTransition(p, now ?? DateTime.now());
  if (t == null) return null;
  final answer = await showDialog<NewYearAnswer>(
    context: context,
    builder: (c) => AlertDialog(
      icon: const Icon(Icons.event_repeat_outlined),
      title: const Text('Nuovo anno accademico'),
      content: Text(
        '${t.question}\n\nSe non vuoi rispondere ora, chiudi: te lo chiedo '
        'al prossimo avvio.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, NewYearAnswer.no),
          child: Text(
            t.becomesFuoriCorso ? 'No, ho finito' : 'No, ripeto l\'anno',
          ),
        ),
        FilledButton(
          key: const Key('new-year-yes'),
          onPressed: () => Navigator.pop(c, NewYearAnswer.yes),
          child: const Text('Sì'),
        ),
      ],
    ),
  );
  // riquadro chiuso senza scegliere: «più tardi»
  if (answer == null || !context.mounted) return NewYearAnswer.later;
  if (answer == NewYearAnswer.yes && !t.becomesFuoriCorso) {
    await openYearGrades(
      context,
      t.currentYear,
      markYear: true,
      title: 'Com\'è andato il ${planYearLabel(t.currentYear)}?',
    );
  }
  final updated = applyTransition(p, t, advance: answer == NewYearAnswer.yes);
  await s.profiles.save(updated);
  s.profile.value = updated;
  s.selectedYear.value = updated.currentYear;
  s.revision.bump();
  // Nuovo anno: nuova offerta formativa e nuove date d'esame.
  try {
    final r = await PathSetupService(s).refresh();
    if (context.mounted) {
      showSnack(
        context,
        r.imported ? 'Piano di studi aggiornato.' : (r.message ?? ''),
      );
    }
  } catch (_) {
    // Offline: si potrà aggiornare da Impostazioni → Il mio percorso.
  }
  return answer;
}

/// All'avvio con internet confronta `meta.json.versione` con quella
/// importata e, se c'è una versione nuova, propone "Aggiorna database"
/// (una volta per versione). I dati personali non vengono toccati.
Future<void> checkCatalogUpdate(BuildContext context) async {
  final s = context.read<AppServices>();
  final p = s.profile.value;
  if (p == null) return;
  final meta = await s.catalog.remoteMeta();
  final v = meta?.versione;
  if (v == null || v == p.catalogVersion) return;
  if (await s.settings.get(SettingKeys.catalogOfferedVersion) == v) return;
  await s.settings.set(SettingKeys.catalogOfferedVersion, v);
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text('Nuova versione del database ($v).'),
      duration: const Duration(seconds: 8),
      action: SnackBarAction(
        label: 'Aggiorna',
        onPressed: () async {
          final r = await PathSetupService(s).refresh();
          if (context.mounted) {
            showSnack(
              context,
              r.imported ? 'Piano di studi aggiornato.' : (r.message ?? ''),
            );
          }
        },
      ),
    ),
  );
}
