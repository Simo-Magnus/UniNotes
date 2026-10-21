import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/services/app_services.dart';
import '../../../models/course.dart';
import '../../../repositories/settings_repository.dart';
import '../../links/whisper_device.dart';
import '../../links/whisper_models.dart';
import '../notes_actions.dart' show transcribeWithWhisper;
import '../notes_store.dart';
import 'recording_meta.dart';
import 'recording_overlay.dart' show appNavigatorKey;

/// Dopo il salvataggio di una registrazione: se l'utente ha scaricato un
/// modello Whisper più accurato del motore che ha fatto il testo
/// istantaneo (Parakeet su PC e Mac, il modello integrato sul telefono),
/// si propone di trascrivere di nuovo la lezione con quello, con il tempo
/// stimato.
///
/// Riquadro con due pulsanti, «Non ora» e «Trascrivi», e la casella «Fallo
/// sempre in automatico»: spuntata (con «Trascrivi») le volte successive la
/// trascrizione parte da sola, con un avviso. La scelta è l'impostazione
/// [kAutoBetterTranscriptionKey] (prefisso `dont_ask_`): si annulla da
/// Impostazioni → «Ripristina le domande».

/// Impostazione «Fallo sempre in automatico» ('1').
const String kAutoBetterTranscriptionKey = 'dont_ask_better_transcription';

/// Velocità misurata di un modello sul dispositivo (secondi di lavoro per
/// secondo di audio), aggiornata a ogni trascrizione con Whisper.
String whisperSpeedKey(String modelId) => 'whisper_speed_$modelId';

/// Secondi di lavoro per secondo di audio su un PC con 8 core (stima
/// iniziale, sostituita dalla velocità misurata dopo la prima trascrizione
/// con quel modello). Riferimenti: le misure del modello integrato in
/// docs/registratore.md e il rapporto fra le dimensioni dei modelli
/// (encoder di small ~5 volte quello di base, large ~4 volte small; turbo
/// ha lo stesso encoder di large ma un decoder di 4 strati).
double baseWhisperFactor(String id) {
  final family = id.replaceAll(RegExp(r'-q\d_\d$'), '');
  final f = switch (family) {
    'tiny' => 0.03,
    'base' || 'base-q5_1' => 0.06,
    'small' => 0.2,
    'medium' => 0.55,
    'large-v3-turbo' => 0.45,
    'large-v1' || 'large-v2' || 'large-v3' => 1.1,
    // misurato: 0,046 con 2 thread su un portatile a 8 core (VAD compreso)
    kParakeetId => 0.06,
    _ => 0.6,
  };
  // i quantizzati sono un po' più veloci sulla CPU
  final q = id.endsWith('q5_0') || id.endsWith('q5_1')
      ? 0.85
      : (id.endsWith('q8_0') ? 0.92 : 1.0);
  return f * q;
}

/// Tempo stimato per trascrivere [audio] con [model] su [device]; con
/// [measured] (velocità già vista su questo dispositivo) si usa quella.
Duration estimateWhisperTime(
  WhisperModelInfo model,
  Duration audio, {
  DeviceProfile? device,
  double? measured,
}) {
  var factor = measured;
  if (factor == null || factor <= 0) {
    factor = baseWhisperFactor(model.id);
    final cores = math.max(2, device?.cores ?? 4);
    // meno core, più lento (whisper.cpp usa fino a 4–8 thread)
    factor *= math.pow(8 / math.min(cores, 8), 0.7).toDouble();
    if (device?.phone ?? false) factor *= 2.5;
  }
  // caricamento del modello e conversione dell'audio
  final overhead = Duration(seconds: model.approxBytes > 500 << 20 ? 15 : 5);
  return Duration(milliseconds: (audio.inMilliseconds * factor).round()) +
      overhead;
}

/// «circa 6 minuti», «circa 1 ora e 20 minuti», «meno di un minuto».
String estimateLabel(Duration d) {
  final m = (d.inSeconds / 60).ceil();
  if (m <= 1) return 'meno di un minuto';
  if (m < 60) return 'circa $m minuti';
  final h = m ~/ 60, r = ((m % 60) / 5).round() * 5;
  final hours = h == 1 ? '1 ora' : '$h ore';
  return r == 0 || r == 60 ? 'circa $hours' : 'circa $hours e $r minuti';
}

/// Velocità misurata (null se il modello non è mai stato usato qui).
Future<double?> measuredWhisperFactor(
  SettingsRepository settings,
  String modelId,
) async {
  try {
    return double.tryParse(await settings.get(whisperSpeedKey(modelId)) ?? '');
  } catch (_) {
    return null;
  }
}

/// Registra la velocità di una trascrizione appena finita (media con le
/// precedenti, così una misura storta pesa poco).
Future<void> recordWhisperSpeed(
  SettingsRepository settings,
  String modelId, {
  required Duration took,
  required Duration audio,
}) async {
  if (audio.inSeconds < 20) return;
  final r = took.inMilliseconds / audio.inMilliseconds;
  final old = await measuredWhisperFactor(settings, modelId);
  final next = old == null ? r : old * 0.5 + r * 0.5;
  try {
    await settings.set(whisperSpeedKey(modelId), next.toStringAsFixed(4));
  } catch (_) {}
}

/// Il modello da proporre dopo una registrazione: quello che userebbe
/// «Trascrivi con Whisper», se è più accurato del modello integrato e non è
/// quello che ha già fatto il testo dal vivo ([liveModel]). null = niente
/// da proporre.
WhisperModelInfo? betterThanLive(WhisperModelInfo? best, String? liveModel) {
  if (best == null || best.id == kBuiltInWhisperModel.id) return null;
  if (best.id == liveModel) return null;
  // si confronta con il motore del testo dal vivo (Parakeet su PC e Mac),
  // se si sa, altrimenti con il modello integrato
  final ref = whisperModelById(liveModel) == null
      ? kBuiltInWhisperModel.id
      : liveModel!;
  if (whisperAccuracyRank(best.id) >= whisperAccuracyRank(ref)) return null;
  return best;
}

/// Dopo «Salva»: propone (o avvia, con «Fallo sempre in automatico») la
/// trascrizione di [saved] con il modello più accurato scaricato. Usa il
/// Navigator dell'app: funziona anche se nel frattempo la pagina è
/// cambiata.
Future<void> offerBetterTranscription(
  AppServices s,
  Course course,
  File saved,
) async {
  try {
    final live = await _liveModelOf(saved);
    final best = betterThanLive(await s.whisper.resolveModel(), live);
    if (best == null) return;
    final meta = await RecordingMeta.load(saved.path);
    final audio =
        meta.duration ??
        (meta.segments.isEmpty ? Duration.zero : meta.segments.last.end);
    DeviceProfile? device;
    try {
      device = await s.whisper.deviceProfile();
    } catch (_) {}
    final eta = estimateWhisperTime(
      best,
      audio,
      device: device,
      measured: await measuredWhisperFactor(s.settings, best.id),
    );
    final again = meta.segments.isNotEmpty;
    final auto = await s.settings.get(kAutoBetterTranscriptionKey) == '1';
    // la pagina del corso si apre intanto: il riquadro arriva sopra
    await WidgetsBinding.instance.endOfFrame;
    final nav = appNavigatorKey.currentContext;
    if (nav == null || !nav.mounted) return;
    final label = whisperModelLabel(best.id);
    final rec = NoteFile(
      saved,
      NoteFolder.recordings,
      DateTime.now(),
      await saved.length(),
    );
    if (!nav.mounted) return;
    if (auto) {
      transcribeWithWhisper(
        nav,
        course,
        rec,
        model: best.id,
        again: again,
        startedMessage:
            'Trascrivo di nuovo con $label (${estimateLabel(eta)}): puoi '
            'continuare a usare l\'app.',
      );
      return;
    }
    final choice = await showBetterTranscriptionDialog(
      nav,
      model: label,
      eta: eta,
      again: again,
      liveBy: live == kParakeetId ? 'di Parakeet' : 'del modello integrato',
    );
    if (choice == null || !choice.transcribe || !nav.mounted) return;
    if (choice.always) {
      try {
        await s.settings.set(kAutoBetterTranscriptionKey, '1');
      } catch (_) {}
    }
    if (!nav.mounted) return;
    transcribeWithWhisper(nav, course, rec, model: best.id, again: again);
  } catch (e) {
    debugPrint('Proposta di una trascrizione migliore: $e');
  }
}

/// Modello che ha fatto il testo dal vivo (dai dati della registrazione).
Future<String?> _liveModelOf(File saved) async {
  try {
    final src = (await RecordingMeta.load(saved.path)).transcriptSource ?? '';
    if (src.contains('Parakeet')) return kParakeetId;
    return RegExp(r'Whisper (\S+)').firstMatch(src)?.group(1);
  } catch (_) {
    return null;
  }
}

/// Il riquadro: «Trascrivi di nuovo con small?» con il tempo stimato, «Non
/// ora» e «Trascrivi», casella «Fallo sempre in automatico». null se si
/// chiude toccando fuori (come «Non ora»).
Future<({bool transcribe, bool always})?> showBetterTranscriptionDialog(
  BuildContext context, {
  required String model,
  required Duration eta,
  bool again = true,
  String liveBy = 'del modello integrato',
}) {
  var always = false;
  return showDialog<({bool transcribe, bool always})>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setLocal) => AlertDialog(
        icon: const Icon(Icons.graphic_eq),
        title: Text(
          again
              ? 'Trascrivere di nuovo con $model?'
              : 'Trascrivere con $model?',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              again
                  ? 'Il testo dal vivo è $liveBy, veloce ma meno preciso. '
                        'Con $model, che hai scaricato, la trascrizione è più '
                        'accurata.'
                  : 'Con $model, che hai scaricato, la lezione viene '
                        'trascritta in modo accurato.',
            ),
            const SizedBox(height: 8),
            Text(
              'Tempo stimato: ${estimateLabel(eta)}, in background (puoi '
              'continuare a usare l\'app).${again ? ' Il testo di adesso va '
                        'in «Eliminati di recente».' : ''}',
              style: Theme.of(c).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('better-transcription-always'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              dense: true,
              value: always,
              onChanged: (v) => setLocal(() => always = v ?? false),
              title: const Text('Fallo sempre in automatico'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () =>
                Navigator.pop(c, (transcribe: false, always: false)),
            child: const Text('Non ora'),
          ),
          FilledButton(
            key: const Key('better-transcription-go'),
            onPressed: () =>
                Navigator.pop(c, (transcribe: true, always: always)),
            child: const Text('Trascrivi'),
          ),
        ],
      ),
    ),
  );
}
