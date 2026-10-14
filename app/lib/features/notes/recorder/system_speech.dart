import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Riconoscimento vocale del sistema in streaming, come Memo Vocali o la
/// digitazione vocale di Google Docs: il testo provvisorio si aggiorna mentre
/// si parla e quello definitivo si stabilizza a ogni frase.
///
/// Canale `io.github.simomagnus.universitynotes/speech`:
/// - iOS e macOS (ios/Runner/LiveSpeech.swift, macos/Runner/LiveSpeech.swift):
///   SpeechAnalyzer da iOS/macOS 26, altrimenti SFSpeechRecognizer con
///   SFSpeechAudioBufferRecognitionRequest (sul dispositivo quando c'è);
/// - Android 13+ (LiveSpeech.kt): SpeechRecognizer con risultati parziali,
///   sul dispositivo dove c'è, che riceve l'audio della registrazione da una
///   pipe (EXTRA_AUDIO_SOURCE) e non apre il microfono;
/// - Windows (windows/runner/live_speech.cpp): Windows.Media.SpeechRecognition,
///   dettatura continua (il microfono è condiviso con la registrazione).
///
/// Dove il sistema non offre nulla (Linux, Android prima del 13, lingua non
/// disponibile) [support] risponde «non disponibile» e la trascrizione dal
/// vivo usa Whisper a pezzi (recorder/live_transcriber.dart). Nessuna
/// chiamata lancia eccezioni verso il registratore: un errore del
/// riconoscitore non deve mai fermare la registrazione.
///
/// Dal sistema arrivano (metodi invocati su questo canale, con `session`):
/// `partial` {text}, `result` {text}, `error` {message, fatal} ed `ended`.
class SystemSpeech {
  SystemSpeech({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.simomagnus.universitynotes/speech';

  final MethodChannel _channel;
  final _events = StreamController<SpeechEvent>.broadcast();
  bool _listening = false;
  int _session = 0;

  /// Eventi della sessione in corso (quelli di sessioni chiuse si scartano).
  Stream<SpeechEvent> get events {
    _listen();
    return _events.stream;
  }

  void _listen() {
    if (_listening) return;
    _listening = true;
    try {
      _channel.setMethodCallHandler(_onCall);
    } catch (_) {
      // nessun binding (test puri)
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    final args = call.arguments is Map ? call.arguments as Map : const {};
    final session = args['session'];
    if (session is int && session != _session) return null;
    final text = '${args['text'] ?? ''}';
    final event = switch (call.method) {
      'partial' => SpeechEvent(SpeechEventKind.partial, text),
      'result' => SpeechEvent(SpeechEventKind.result, text),
      'error' => SpeechEvent(
        SpeechEventKind.error,
        '${args['message'] ?? ''}',
        fatal: args['fatal'] == true,
      ),
      'ended' => const SpeechEvent(SpeechEventKind.ended, ''),
      _ => null,
    };
    if (event != null && !_events.isClosed) _events.add(event);
    return null;
  }

  /// Cosa offre il sistema per [locale] (es. «it-IT»).
  Future<SpeechSupport> support(String locale) async {
    try {
      final r = await _channel.invokeMethod<Object?>('support', {
        'locale': locale,
      });
      if (r is! Map) return SpeechSupport.none;
      return SpeechSupport(
        available: r['available'] == true,
        onDevice: r['onDevice'] == true,
        feedsAudio: r['feedsAudio'] != false,
        engine: '${r['engine'] ?? ''}',
        reason: r['reason'] is String ? r['reason'] as String : null,
      );
    } catch (e) {
      // MissingPluginException (piattaforma senza riconoscitore) o errore
      // del sistema: si usa Whisper
      return SpeechSupport.none;
    }
  }

  /// Avvia una sessione per [locale] con audio PCM 16 bit mono a
  /// [sampleRate] Hz (passato con [feed] dove il sistema lo chiede). Su iOS
  /// e macOS la prima volta il sistema chiede il permesso. false se il
  /// riconoscitore non è partito ([lastStartError] dice perché, se il
  /// sistema lo indica, es. «privacy» su Windows).
  Future<bool> start({required String locale, int sampleRate = 16000}) async {
    _listen();
    _session++;
    _pending.clear();
    lastStartError = null;
    try {
      final r = await _channel.invokeMethod<Object?>('start', {
        'locale': locale,
        'sampleRate': sampleRate,
        'session': _session,
      });
      if (r is String) lastStartError = r;
      return r == true;
    } catch (e) {
      debugPrint('Riconoscimento vocale non avviato: $e');
      return false;
    }
  }

  /// Motivo dell'ultimo avvio non riuscito (codice di [speechUnavailableText]).
  String? lastStartError;

  final BytesBuilder _pending = BytesBuilder(copy: true);

  /// Audio da riconoscere (mono a 16 kHz): si manda a pezzi di ~0,1 s.
  void feed(Int16List mono) {
    if (mono.isEmpty) return;
    _pending.add(
      Uint8List.view(mono.buffer, mono.offsetInBytes, mono.lengthInBytes),
    );
    if (_pending.length < 3200) return;
    final bytes = _pending.takeBytes();
    _channel.invokeMethod<void>('feed', bytes).catchError((Object e) {
      // un pezzo perso non ferma niente
    });
  }

  /// Pausa e ripresa della registrazione (Windows ascolta il microfono da
  /// solo e va fermato; altrove l'audio semplicemente non arriva).
  Future<void> pause() => _quiet('pause');
  Future<void> resume() => _quiet('resume');

  /// Fine dell'audio: il sistema manda l'ultimo `result` e poi `ended`.
  Future<void> stop() async {
    if (_pending.length > 0) {
      final bytes = _pending.takeBytes();
      await _quiet('feed', bytes);
    }
    await _quiet('stop');
  }

  Future<void> _quiet(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {}
  }

  Future<void> dispose() async {
    try {
      _channel.setMethodCallHandler(null);
    } catch (_) {}
    await _events.close();
  }
}

enum SpeechEventKind { partial, result, error, ended }

class SpeechEvent {
  const SpeechEvent(this.kind, this.text, {this.fatal = false});
  final SpeechEventKind kind;

  /// Testo riconosciuto (o messaggio d'errore).
  final String text;

  /// Errore che ferma il riconoscitore: si ripiega su Whisper.
  final bool fatal;
}

/// Disponibilità del riconoscimento vocale del sistema.
class SpeechSupport {
  const SpeechSupport({
    required this.available,
    this.onDevice = false,
    this.feedsAudio = true,
    this.engine = '',
    this.reason,
  });

  static const none = SpeechSupport(available: false);

  final bool available;

  /// Il riconoscimento avviene sul dispositivo (niente internet).
  final bool onDevice;

  /// L'app passa l'audio della registrazione con [SystemSpeech.feed]
  /// (false su Windows, dove il riconoscitore condivide il microfono).
  final bool feedsAudio;

  /// `speechanalyzer`, `sfspeech`, `android` o `windows`.
  final String engine;

  /// Perché non è disponibile (codice del sistema, vedi [speechUnavailableText]).
  final String? reason;
}

/// Lingua del riconoscimento: quella dell'insegnamento se nota (es. «en»
/// per gli insegnamenti in inglese), altrimenti l'italiano.
String speechLocaleFor(String? language) {
  final raw = (language ?? '').trim().replaceAll('_', '-');
  if (raw.isEmpty) return 'it-IT';
  if (raw.contains('-')) return raw;
  return switch (raw.toLowerCase()) {
    'it' => 'it-IT',
    'en' => 'en-US',
    'fr' => 'fr-FR',
    'de' => 'de-DE',
    'es' => 'es-ES',
    'pt' => 'pt-PT',
    final l => l,
  };
}

/// Spiegazione in italiano di un [SpeechSupport.reason] (null se non serve
/// dire nulla).
String? speechUnavailableText(String? reason) => switch (reason) {
  null || '' => null,
  'android<13' =>
    'Il testo istantaneo del sistema richiede Android 13 o successivo (prima '
        'il riconoscitore userebbe il microfono della registrazione).',
  'no-service' =>
    'Sul dispositivo non c\'è un servizio di riconoscimento vocale (es. '
        '«Servizi di riconoscimento vocale di Google»).',
  'denied' =>
    'Il riconoscimento vocale non è autorizzato: abilitalo nelle impostazioni '
        'del sistema (Privacy → Riconoscimento vocale).',
  'locale' =>
    'Il riconoscimento vocale del sistema non supporta questa lingua.',
  'microphone' =>
    'Il riconoscimento vocale del sistema non riesce a usare il microfono.',
  'offline' =>
    'Il riconoscimento vocale del sistema ora non è disponibile (serve '
        'internet per questa lingua).',
  'privacy' =>
    'Su Windows attiva Impostazioni → Privacy e sicurezza → Voce → '
        '«Riconoscimento vocale online».',
  final r => r,
};
