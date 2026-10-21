import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/core/database/app_database.dart';
import 'package:university_notes/features/links/whisper_device.dart';
import 'package:university_notes/features/links/whisper_models.dart';
import 'package:university_notes/features/notes/recorder/better_transcription.dart';
import 'package:university_notes/repositories/settings_repository.dart';

void main() {
  test('si propone solo un modello scaricato più accurato di quello '
      'integrato', () {
    final small = whisperModelById('small')!;
    expect(betterThanLive(small, 'base-q5_1')?.id, 'small');
    expect(betterThanLive(small, null)?.id, 'small');
    // il testo dal vivo l'ha già fatto small (PC senza AVX2)
    expect(betterThanLive(small, 'small'), isNull);
    expect(betterThanLive(kBuiltInWhisperModel, 'base-q5_1'), isNull);
    expect(betterThanLive(whisperModelById('tiny'), null), isNull);
    expect(betterThanLive(null, null), isNull);
  });

  test('tempo stimato: modello, core, telefono e velocità misurata', () {
    final turbo = whisperModelById('large-v3-turbo-q5_0')!;
    final small = whisperModelById('small')!;
    const hour = Duration(hours: 1);
    const pc = DeviceProfile(platform: WhisperPlatform.pc, cores: 8);
    const phone = DeviceProfile(platform: WhisperPlatform.phone, cores: 8);
    const slow = DeviceProfile(platform: WhisperPlatform.pc, cores: 2);
    final t = estimateWhisperTime(turbo, hour, device: pc);
    expect(t.inMinutes, inInclusiveRange(15, 30));
    expect(estimateWhisperTime(small, hour, device: pc), lessThan(t));
    expect(
      estimateWhisperTime(small, hour, device: phone),
      greaterThan(estimateWhisperTime(small, hour, device: pc)),
    );
    expect(
      estimateWhisperTime(small, hour, device: slow),
      greaterThan(estimateWhisperTime(small, hour, device: pc)),
    );
    // velocità già vista su questo dispositivo: vale quella
    expect(
      estimateWhisperTime(small, hour, device: pc, measured: 0.5).inMinutes,
      30,
    );
    expect(estimateLabel(const Duration(seconds: 40)), 'meno di un minuto');
    expect(
      estimateLabel(const Duration(minutes: 5, seconds: 10)),
      'circa 6 minuti',
    );
    expect(estimateLabel(const Duration(minutes: 60)), 'circa 1 ora');
    expect(
      estimateLabel(const Duration(minutes: 81)),
      'circa 1 ora e 20 minuti',
    );
  });

  test('la velocità misurata si ricorda (media con le precedenti)', () async {
    final db = await AppDatabase.openInMemory();
    addTearDown(db.close);
    final settings = SettingsRepository(db);
    await recordWhisperSpeed(
      settings,
      'small',
      took: const Duration(minutes: 10),
      audio: const Duration(minutes: 50),
    );
    expect(await measuredWhisperFactor(settings, 'small'), closeTo(0.2, 1e-6));
    await recordWhisperSpeed(
      settings,
      'small',
      took: const Duration(minutes: 20),
      audio: const Duration(minutes: 50),
    );
    expect(await measuredWhisperFactor(settings, 'small'), closeTo(0.3, 1e-6));
    // audio troppo corto: non conta
    await recordWhisperSpeed(
      settings,
      'small',
      took: const Duration(seconds: 10),
      audio: const Duration(seconds: 5),
    );
    expect(await measuredWhisperFactor(settings, 'small'), closeTo(0.3, 1e-6));
    expect(kAutoBetterTranscriptionKey, startsWith('dont_ask_'));
  });

  testWidgets('riquadro: due pulsanti e «Fallo sempre in automatico»', (
    t,
  ) async {
    ({bool transcribe, bool always})? out;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => out = await showBetterTranscriptionDialog(
              context,
              model: 'small',
              eta: const Duration(minutes: 6),
            ),
            child: const Text('apri'),
          ),
        ),
      ),
    );
    await t.tap(find.text('apri'));
    await t.pumpAndSettle();
    expect(find.text('Trascrivere di nuovo con small?'), findsOneWidget);
    expect(find.textContaining('circa 6 minuti'), findsOneWidget);
    expect(find.byType(TextButton), findsNWidgets(2)); // «apri» + «Non ora»
    expect(find.byType(FilledButton), findsOneWidget);
    await t.tap(find.text('Fallo sempre in automatico'));
    await t.pump();
    await t.tap(find.byKey(const Key('better-transcription-go')));
    await t.pumpAndSettle();
    expect(out, (transcribe: true, always: true));

    await t.tap(find.text('apri'));
    await t.pumpAndSettle();
    await t.tap(find.text('Non ora'));
    await t.pumpAndSettle();
    expect(out, (transcribe: false, always: false));
  });
}
