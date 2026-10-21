import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder/second_pass.dart';

Duration s(num v) => Duration(milliseconds: (v * 1000).round());
TranscriptSegment seg(num a, num b, String t) =>
    TranscriptSegment(s(a), s(b), t);

void main() {
  group('seconda passata con small', () {
    test('blocchi di ~30 s di segmenti interi già confermati', () {
      final pl = SecondPassPlanner();
      final segs = [
        for (var i = 0; i < 12; i++) seg(i * 5, i * 5 + 5, 'frase $i'),
      ];
      // confermato solo fino a 20 s: non basta per un blocco
      expect(pl.next(segs, stableUntil: s(20)), isNull);
      final b = pl.next(segs, stableUntil: s(60))!;
      expect(b.start, Duration.zero);
      expect(b.end, s(30));
      pl.markDone(b.end);
      final b2 = pl.next(segs, stableUntil: s(60))!;
      expect(b2.start, s(30));
      expect(b2.end, s(60));
      pl.markDone(b2.end);
      expect(pl.next(segs, stableUntil: s(60)), isNull);
      // a fine registrazione va bene anche un blocco corto
      final more = [...segs, seg(60, 64, 'ultima')];
      expect(pl.next(more, stableUntil: s(64)), isNull);
      expect(pl.next(more, stableUntil: s(64), all: true)!.end, s(64));
    });

    test('sostituzione: le frasi corrette a mano restano', () {
      final current = [
        seg(0, 5, 'prima'),
        seg(5, 10, 'corretta a mano'),
        seg(10, 15, 'terza'),
        seg(30, 35, 'dopo il blocco'),
      ];
      final better = [
        seg(0, 4.8, 'Prima migliore.'),
        seg(5.2, 9, 'sopra la correzione'),
        seg(10, 15, 'Terza migliore.'),
      ];
      final out = replaceRange(
        current,
        s(0),
        s(15),
        better,
        edited: (x) => x.text == 'corretta a mano',
      );
      expect(out.map((x) => x.text), [
        'Prima migliore.',
        'corretta a mano',
        'Terza migliore.',
        'dopo il blocco',
      ]);
      // small non ha trovato niente: resta il testo di prima
      expect(
        replaceRange(current, s(0), s(15), const [], edited: (_) => false),
        current,
      );
    });

    test('prova del primo uso, telefono che si scalda, batteria', () {
      final g = SecondPassGovernor(maxRtf: 0.5);
      expect(g.record(0.3), isTrue, reason: 'la prima è la prova');
      expect(g.active, isTrue);
      expect(g.record(0.35), isFalse);
      // due blocchi di fila molto più lenti della prova: si scalda
      g.record(0.6);
      expect(g.active, isTrue);
      g.record(0.62);
      expect(g.stopped, SecondPassStop.hot);

      final slow = SecondPassGovernor(maxRtf: 0.5)..record(0.8);
      expect(slow.stopped, SecondPassStop.slow);

      final bat = SecondPassGovernor(probe: 0.3);
      bat.checkBattery(level: 15, charging: false);
      expect(bat.stopped, SecondPassStop.battery);
      bat.checkBattery(level: 15, charging: true);
      expect(bat.active, isTrue);

      final behind = SecondPassGovernor(probe: 0.3)..checkBehind(s(200), s(60));
      expect(behind.stopped, SecondPassStop.behind);
      expect(secondPassStopLabel(SecondPassStop.battery), contains('20%'));
    });
  });
}
