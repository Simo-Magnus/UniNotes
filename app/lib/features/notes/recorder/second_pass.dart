import 'recording_meta.dart';

/// Seconda passata sul telefono: mentre si registra, i tratti già
/// confermati del testo istantaneo (Whisper base) si ritrascrivono in
/// blocchi da ~30 s con small q5_1, più accurato, e lo sostituiscono; le
/// frasi corrette a mano restano. Logica pura (test in
/// test/second_pass_test.dart); il lavoro lo fa LiveTranscriber.

/// Sceglie il prossimo blocco: segmenti interi già confermati, da dove era
/// arrivata la seconda passata, per almeno [block] di audio.
class SecondPassPlanner {
  SecondPassPlanner({
    this.block = const Duration(seconds: 30),
    this.maxBlock = const Duration(seconds: 45),
  });

  final Duration block;

  /// Un blocco non va oltre (whisper.cpp lavora su 30 s alla volta).
  final Duration maxBlock;

  /// Fin dove la seconda passata ha già lavorato.
  Duration done = Duration.zero;

  /// Prossimo blocco fra [segments] (ordinati), fra quelli che finiscono
  /// entro [stableUntil] (prima di lì il testo istantaneo non cambia più).
  /// null se non c'è ancora abbastanza audio. Con [all] (fine
  /// registrazione) va bene anche un blocco più corto.
  ({Duration start, Duration end})? next(
    List<TranscriptSegment> segments, {
    required Duration stableUntil,
    bool all = false,
  }) {
    Duration? start;
    Duration? end;
    for (final s in segments) {
      if (s.end <= done) continue;
      if (s.end > stableUntil) break;
      start ??= s.start < done ? done : s.start;
      if (s.end - start > maxBlock && end != null) break;
      end = s.end;
      if (end - start >= block) break;
    }
    if (start == null || end == null) return null;
    if (!all && end - start < block) return null;
    return (start: start, end: end);
  }

  /// Il blocco fino a [end] è fatto (anche se il risultato è stato scartato).
  void markDone(Duration end) {
    if (end > done) done = end;
  }
}

/// I segmenti di [current] fra [start] e [end] diventano [better], tranne
/// quelli corretti a mano ([edited]): restano com'erano e il testo nuovo
/// che cade nel loro tratto si scarta. Gli altri segmenti non cambiano (il
/// testo nuovo che li tocca si scarta, così non ci sono doppioni). Senza
/// testo nuovo resta tutto com'era.
List<TranscriptSegment> replaceRange(
  List<TranscriptSegment> current,
  Duration start,
  Duration end,
  List<TranscriptSegment> better, {
  required bool Function(TranscriptSegment) edited,
}) {
  final fresh0 = [
    for (final b in better)
      if (b.text.trim().isNotEmpty) b,
  ];
  if (fresh0.isEmpty) return [...current];
  bool replaced(TranscriptSegment s) =>
      s.start >= start && s.end <= end && !edited(s);
  final remaining = [
    for (final s in current)
      if (!replaced(s)) s,
  ];
  bool overlaps(TranscriptSegment b) =>
      remaining.any((k) => b.start < k.end && b.end > k.start);
  final fresh = [
    for (final b in fresh0)
      if (b.copyWith(
            start: b.start < start ? start : b.start,
            end: b.end > end ? end : b.end,
            text: b.text.trim(),
          )
          case final c when c.end > c.start && !overlaps(c))
        c,
  ];
  return [...remaining, ...fresh]..sort((a, b) => a.start.compareTo(b.start));
}

/// Quando la seconda passata si ferma.
enum SecondPassStop {
  /// Il telefono è troppo lento (prova del primo uso).
  slow,

  /// Resta indietro rispetto alla registrazione.
  behind,

  /// Sempre più lento: probabilmente si scalda e rallenta.
  hot,

  /// Batteria sotto il 20% senza caricabatterie.
  battery,
}

/// Decide se la seconda passata può continuare: velocità di ogni blocco
/// (secondi di lavoro per secondo di audio), ritardo e batteria.
class SecondPassGovernor {
  SecondPassGovernor({
    this.probe,
    this.maxRtf = 0.5,
    this.hotFactor = 1.6,
    this.maxBehind = const Duration(seconds: 90),
  });

  /// Velocità della prova del primo uso (null = da misurare adesso, con il
  /// primo blocco).
  double? probe;

  /// Velocità massima accettata alla prova.
  final double maxRtf;

  /// Due blocchi di fila così più lenti della prova = il telefono si scalda.
  final double hotFactor;

  /// Ritardo massimo dalla registrazione.
  final Duration maxBehind;

  SecondPassStop? stopped;
  int _slowRun = 0;

  bool get active => stopped == null;

  /// Primo blocco (prova) o blocco successivo, durato [rtf]. true = era la
  /// prova (da salvare nelle impostazioni).
  bool record(double rtf) {
    final p = probe;
    if (p == null) {
      probe = rtf;
      if (rtf > maxRtf) stopped = SecondPassStop.slow;
      return true;
    }
    if (rtf > p * hotFactor && rtf > maxRtf * 0.6) {
      _slowRun++;
      if (_slowRun >= 2) stopped = SecondPassStop.hot;
    } else {
      _slowRun = 0;
    }
    if (rtf > 1) stopped = SecondPassStop.behind;
    return false;
  }

  /// La registrazione è a [recorded], la seconda passata a [done].
  void checkBehind(Duration recorded, Duration done) {
    if (stopped == null && recorded - done > maxBehind) {
      stopped = SecondPassStop.behind;
    }
  }

  /// Batteria: sotto il 20% senza caricabatterie ci si ferma; con il
  /// caricabatterie si riprende.
  void checkBattery({required int? level, required bool charging}) {
    final low = level != null && level < 20 && !charging;
    if (low && stopped == null) stopped = SecondPassStop.battery;
    if (!low && stopped == SecondPassStop.battery) stopped = null;
  }
}

/// Perché la seconda passata si è fermata, per la card «Trascrizione».
String secondPassStopLabel(SecondPassStop s) => switch (s) {
  SecondPassStop.slow =>
    'Seconda passata con small spenta: questo telefono è troppo lento.',
  SecondPassStop.behind =>
    'Seconda passata con small sospesa: era troppo indietro.',
  SecondPassStop.hot =>
    'Seconda passata con small sospesa: il telefono sta rallentando '
        '(si scalda).',
  SecondPassStop.battery =>
    'Seconda passata con small sospesa: batteria sotto il 20%.',
};
