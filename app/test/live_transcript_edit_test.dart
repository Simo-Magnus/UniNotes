import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/recording_meta.dart';
import 'package:university_notes/features/notes/recorder_screen.dart';

void main() {
  testWidgets(
    'testo dal vivo: un tocco corregge la frase, le formule si disegnano',
    (t) async {
      final edits = <(int, String)>[];
      var segs = const [
        TranscriptSegment(Duration.zero, Duration(seconds: 2), 'Prima frase.'),
        TranscriptSegment(
          Duration(seconds: 2),
          Duration(seconds: 4),
          r'Vale $\frac{2}{3}$.',
        ),
      ];
      late StateSetter update;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, set) {
                update = set;
                return EditableLiveTranscript(
                  segments: segs,
                  partial: 'in corso',
                  onEdit: (i, text) => edits.add((i, text)),
                );
              },
            ),
          ),
        ),
      );
      // formula disegnata, testo provvisorio in coda
      expect(find.byType(Math), findsOneWidget);
      expect(
        find.textContaining('in corso', findRichText: true),
        findsOneWidget,
      );

      // tocco sulla prima frase → campo di testo
      await t.tapAt(
        t.getTopLeft(find.byType(RichText).first) + const Offset(8, 8),
      );
      await t.pump();
      expect(find.byKey(const Key('live-edit')), findsOneWidget);
      // intanto arriva una frase nuova: la correzione continua
      update(
        () => segs = [
          ...segs,
          const TranscriptSegment(
            Duration(seconds: 4),
            Duration(seconds: 6),
            'Terza frase.',
          ),
        ],
      );
      await t.pump();
      expect(find.byKey(const Key('live-edit')), findsOneWidget);
      await t.enterText(
        find.byKey(const Key('live-edit')),
        'Prima frase corretta.',
      );
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(edits, [(0, 'Prima frase corretta.')]);
      expect(find.byKey(const Key('live-edit')), findsNothing);
    },
  );
}
