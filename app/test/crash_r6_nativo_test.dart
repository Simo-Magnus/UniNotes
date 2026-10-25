import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:university_notes/features/notes/recorder/live_transcriber.dart';
import 'package:university_notes/features/notes/recorder/system_speech.dart';

/// Caccia ai crash, sesto giro, «codice nativo cambiato di recente» (R6-C):
/// risposte che non arrivano, riconoscitori lasciati aperti, copie sul filo
/// principale. Il codice Swift non si compila su Windows: qui si controllano
/// i sorgenti; Kotlin e C++ sono compilati a parte (vedi
/// docs/avvio_ed_errori.md, «Sesto giro: codice nativo»).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SystemSpeech.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  String read(String path) =>
      File(path).readAsStringSync().replaceAll('\r\n', '\n');

  /// Corpo della funzione che inizia con [start] fino a [end] (escluso).
  String between(String src, String start, String end) {
    final from = src.indexOf(start);
    expect(from, greaterThanOrEqualTo(0), reason: start);
    final to = src.indexOf(end, from + start.length);
    expect(to, greaterThan(from), reason: end);
    return src.substring(from, to);
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('riconoscitore del sistema che non risponde a «support»', () {
    test('support finisce entro il limite con «non disponibile»', () async {
      messenger.setMockMethodCallHandler(channel, (c) {
        // iOS/macOS 26: le lingue di SpeechAnalyzer chieste al sistema
        // senza risposta
        if (c.method == 'support') return Completer<Object?>().future;
        return Future.value(null);
      });
      final speech = SystemSpeech(
        supportTimeout: const Duration(milliseconds: 50),
      );
      final sup = await speech
          .support('it-IT', prepare: true)
          .timeout(const Duration(seconds: 5));
      expect(sup.available, isFalse);
      await speech.dispose();
    });

    test('il testo dal vivo non resta «in avvio»', () async {
      messenger.setMockMethodCallHandler(channel, (c) {
        if (c.method == 'support') return Completer<Object?>().future;
        return Future.value(null);
      });
      final live = LiveTranscriber(
        null,
        speech: SystemSpeech(supportTimeout: const Duration(milliseconds: 50)),
      );
      await live
          .begin(File('x.wav'), sampleRate: 16000, channels: 1)
          .timeout(const Duration(seconds: 5));
      expect(live.state, isNot(LiveState.starting));
      expect(live.engine, isNot(LiveEngine.system));
      await live.close();
    });

    test('il limite predefinito c\'è ed è breve', () {
      expect(SystemSpeech().supportTimeout, SystemSpeech.kSupportTimeout);
      expect(
        SystemSpeech.kSupportTimeout,
        lessThan(const Duration(minutes: 1)),
      );
    });
  });

  group('iOS e macOS: riconoscitore di Apple (SpeechAnalyzer)', () {
    const ios = 'ios/Runner/LiveSpeech.swift';
    const mac = 'macos/Runner/LiveSpeech.swift';

    test('lo stesso file su iPhone e Mac', () {
      expect(read(ios), read(mac));
    });

    test('fermato durante il download del modello: nessun analizzatore '
        'orfano', () {
      final s = read(mac);
      final begin = between(s, 'func begin(_ done:', 'func append(');
      // dopo il download e dopo il formato si controlla lo «stop»
      final download = begin.indexOf('downloadAndInstall()');
      final create = begin.indexOf('SpeechAnalyzer(modules:');
      expect(download, greaterThan(0));
      expect(
        begin.substring(download, create),
        contains('guard !self.finishing else'),
      );
      final start = begin.indexOf('analyzer.start(inputSequence:');
      expect(
        begin.substring(create, start),
        contains('guard !self.finishing else'),
      );
      // fermato mentre partiva: si chiude subito
      final after = begin.substring(start, begin.indexOf('self.ready = true'));
      expect(after, contains('if self.finishing'));
      expect(after, contains('await analyzer.cancelAndFinishNow()'));
      // avvio non riuscito: flusso e risultati chiusi
      final failed = begin.substring(begin.lastIndexOf('} catch {'));
      expect(failed, contains('self.input?.finish()'));
      expect(failed, contains('self.results?.cancel()'));
      expect(failed, contains('cancelAndFinishNow()'));
    });

    test(
      'cancel chiude davvero l\'analisi (la fine dell\'audio non basta)',
      () {
        final s = read(mac);
        final cancel = between(
          s,
          'func cancel() {\n      finishing = true\n      input?.finish()',
          '\n    }\n',
        );
        expect(cancel, contains('a.cancelAndFinishNow()'));
      },
    );

    test('dopo uno «stop» durante la preparazione niente riconoscitore di '
        'riserva', () {
      final s = read(mac);
      final start = between(
        s,
        'private func start(',
        '/// Permesso del riconoscimento',
      );
      expect(start, contains('guard ses == self.session, !e.finishing else'));
      expect(start, contains('if self.engine === e { self.engine = nil }'));
      // la fallback (SFSpeechRecognizer) viene dopo quel controllo
      expect(
        start.indexOf('!e.finishing'),
        lessThan(start.indexOf('SFSpeechEngine(locale: loc, emit: emit)')),
      );
      // «start» ha sempre una risposta, anche senza l'oggetto del canale
      expect(
        start,
        contains('guard let self = self else {\n        result(false)'),
      );
    });

    test('ogni ramo di start risponde (nessun return senza result)', () {
      final s = read(mac);
      final start = between(
        s,
        'authorize { [weak self] ok in',
        '/// Permesso del riconoscimento',
      );
      // ogni «return» dentro i rami di start è preceduto da un result(...)
      final lines = start.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trim() != 'return') continue;
        final prev = lines
            .sublist(0, i)
            .reversed
            .firstWhere((l) => l.trim().isNotEmpty);
        expect(
          prev.contains('result(') || prev.trim() == '}',
          isTrue,
          reason: 'riga ${i + 1}: «$prev»',
        );
      }
    });
  });

  group('iOS: AppDelegate', () {
    const path = 'ios/Runner/AppDelegate.swift';

    test('un solo osservatore dei pulsanti della Live Activity', () {
      final s = read(path);
      final add = s.indexOf(
        'recordingObserver = NotificationCenter.default.addObserver(',
      );
      expect(add, greaterThan(0));
      final remove = s.indexOf(
        'if let old = recordingObserver { NotificationCenter.default.removeObserver(old) }',
      );
      expect(remove, greaterThan(0));
      expect(remove, lessThan(add));
      // nessun altro addObserver senza il token
      expect(
        RegExp(
          r'^\s*NotificationCenter\.default\.addObserver\(',
          multiLine: true,
        ).hasMatch(s),
        isFalse,
      );
    });

    test('file aperti con «Apri in UniNotes»: la copia (anche il download da '
        'iCloud) fuori dal filo principale', () {
      final s = read(path);
      final receive = between(
        s,
        'private func receive(_ contexts: Set<UIOpenURLContext>) -> Bool {',
        'private static func copy(',
      );
      final bg = receive.indexOf('DispatchQueue.global(');
      expect(bg, greaterThan(0));
      // la copia solo dentro il blocco in background
      expect(receive.indexOf('IncomingFiles.copy('), greaterThan(bg));
      // pending e il canale si toccano sul filo principale
      final main = receive.indexOf('DispatchQueue.main.async');
      expect(main, greaterThan(bg));
      expect(receive.indexOf('self.pending.append'), greaterThan(main));
      expect(receive.indexOf('invokeMethod("available"'), greaterThan(main));
      // la copia non legge lo stato dell'oggetto (gira su un altro filo)
      final copy = between(
        s,
        'private static func copy(',
        'static func shortName(',
      );
      expect(RegExp(r'\bpending\b').hasMatch(copy), isFalse);
      expect(copy, contains('NSFileCoordinator()'));
    });
  });

  group('Android', () {
    const kt =
        'android/app/src/main/kotlin/io/github/simomagnus/universitynotes';

    test('richiesta del permesso del calendario aperta mentre l\'attività si '
        'chiude: Dart riceve comunque una risposta', () {
      final cal = read('$kt/UniNotesCalendar.kt');
      final dispose = between(cal, 'fun dispose() {', 'private class NotFound');
      expect(dispose, contains('pendingRequest = null'));
      expect(dispose, contains('pending.success(granted())'));
      final main = read('$kt/MainActivity.kt');
      final clean = main.substring(
        main.indexOf('override fun cleanUpFlutterEngine'),
      );
      final d = clean.indexOf('calendar?.dispose()');
      expect(d, greaterThan(0));
      expect(d, lessThan(clean.indexOf('calendar = null')));
    });

    String upload() => between(
      read('$kt/UniNotesCalendar.kt'),
      'private fun requestUpload(',
      'fun deleteCalendarIfEmpty',
    );

    test('caricamento urgente del calendario: un rifiuto del sistema non '
        'esce da requestUpload', () {
      final u = upload();
      expect(u.contains('addPeriodicSync'), isFalse);
      // costante dell'API 31: solo da Android 12
      expect(
        u.indexOf('SDK_INT >= 31'),
        lessThan(u.indexOf('SYNC_EXTRAS_SCHEDULE_AS_EXPEDITED_JOB')),
      );
      // tutto dentro un try: la scrittura dell'evento non fallisce mai per
      // la sincronizzazione
      expect(u, contains('{\n        try {'));
      expect(u, contains('} catch (e: Exception) {'));
    });

    test(
      'caricamento urgente: il lavoro urgente non porta anche '
      'SYNC_EXTRAS_EXPEDITED (SyncRequest.Builder.build() lo rifiuta con '
      'IllegalArgumentException e si ripiega sempre sulla richiesta normale)',
      () {
        final u = upload();
        final urgent = between(
          u,
          'val urgent = ',
          'ContentResolver.requestSync(account',
        );
        expect(urgent, contains('SYNC_EXTRAS_SCHEDULE_AS_EXPEDITED_JOB'));
        // copia di un Bundle con EXPEDITED: va tolto
        if (urgent.contains('Bundle(extras)')) {
          expect(
            urgent,
            contains('remove(ContentResolver.SYNC_EXTRAS_EXPEDITED)'),
          );
        } else {
          expect(urgent.contains('SYNC_EXTRAS_EXPEDITED,'), isFalse);
        }
        expect(urgent.contains('REQUIRE_CHARGING'), isFalse);
      },
    );

    test('requestSync arriva al sistema: adattatori di sincronizzazione '
        'visibili (queries del manifest)', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      final queries = between(manifest, '<queries>', '</queries>');
      expect(
        queries,
        contains('<action android:name="android.content.SyncAdapter"/>'),
      );
    });

    test(
      'conferma dell\'account del calendario: finestra del sistema solo '
      'con quell\'account, una risposta sola anche con l\'attività chiusa',
      () {
        final cal = read('$kt/UniNotesCalendar.kt');
        final confirm = between(
          cal,
          'private fun confirmAccount(',
          'fun onActivityResult(',
        );
        expect(confirm, contains('AccountManager.newChooseAccountIntent('));
        expect(confirm, contains('listOf(account)'));
        expect(confirm, contains('arrayOf(type)'));
        expect(
          confirm,
          contains('startActivityForResult(intent, ACCOUNT_REQUEST_CODE)'),
        );
        // API 26 e solo con l'app davanti (da dietro la finestra non si apre
        // e la risposta non arriverebbe)
        expect(confirm, contains('SDK_INT >= 26'));
        expect(confirm, contains('!foreground()'));
        // la richiesta di prima risponde prima di essere sostituita
        expect(
          confirm.indexOf('pendingAccount?.success(null)'),
          lessThan(confirm.indexOf('pendingAccount = result')),
        );
        // avvio fallito: risposta subito
        expect(confirm, contains('} catch (e: Exception) {'));

        final result = between(
          cal,
          'fun onActivityResult(',
          'private class NotFound',
        );
        expect(result, contains('pendingAccount = null'));
        expect(result, contains('pending.success(ok)'));
        final dispose = between(
          cal,
          'fun dispose() {',
          'private fun accountNeeded',
        );
        expect(dispose, contains('pendingAccount = null'));
        expect(dispose, contains('account.success('));

        // controllo solo da Android 13 (prima requestSync funziona senza)
        final needed = between(
          cal,
          'private fun accountNeeded(',
          'private fun confirmAccount(',
        );
        expect(needed, contains('SDK_INT < 33'));
        expect(needed, contains('getAccountsByType(type)'));
        expect(needed, contains('ACCOUNT_TYPE_LOCAL'));

        final main = read('$kt/MainActivity.kt');
        final onResult = between(
          main,
          'override fun onActivityResult(',
          'override fun onCreate(',
        );
        expect(onResult, contains('super.onActivityResult('));
        expect(onResult, contains('calendar?.onActivityResult(requestCode)'));
        expect(
          main,
          contains('UniNotesCalendar(applicationContext) { inForeground }'),
        );
      },
    );
  });

  group('Windows: dettatura', () {
    test('eventi arrivati dopo la chiusura del riconoscitore non ripartono e '
        '«start» ha sempre una risposta', () {
      final cpp = read('windows/runner/live_speech.cpp');
      final handle = cpp.substring(
        cpp.indexOf('bool LiveSpeechChannel::HandleMessage'),
      );
      for (final kind in const ['kCompiled', 'kStarted']) {
        final body = between(
          handle,
          'case EventKind::$kind:',
          'case EventKind::',
        );
        expect(body, contains('if (!continuous_) {'), reason: kind);
        expect(
          body.indexOf('if (!continuous_) {'),
          lessThan(
            body.indexOf('ReplyStart(flutter::EncodableValue(false));') + 1,
          ),
          reason: kind,
        );
      }
      final completed = handle.substring(
        handle.indexOf('case EventKind::kCompleted:'),
      );
      final stopping = between(
        completed,
        'if (stopping_) {',
        'Send("ended", {});',
      );
      expect(stopping, contains('ReplyStart(flutter::EncodableValue(false));'));
    });
  });
}
