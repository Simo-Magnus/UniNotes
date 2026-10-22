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
///   Funziona solo con «Riconoscimento vocale online» attivo (l'audio passa
///   dai servizi Microsoft): senza, [support] risponde `privacy` e la card
///   lo spiega con il pulsante per le impostazioni ([speechNotice]).
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
  SystemSpeech({MethodChannel? channel, this.startTimeout = kStartTimeout})
    : _channel = channel ?? const MethodChannel(channelName);

  static const channelName = 'io.github.simomagnus.universitynotes/speech';

  /// Attesa massima della risposta a `start`. Il lato nativo può non
  /// rispondere per molto (iOS 26: modello della lingua scaricato al primo
  /// uso, senza rete anche per sempre; Windows: dettatura che non finisce
  /// di prepararsi): senza limite il testo dal vivo restava «in avvio» per
  /// tutta la lezione, senza mai passare a Whisper.
  static const kStartTimeout = Duration(seconds: 45);
  final Duration startTimeout;

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
        languageOk: r['languageOk'] != false,
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
    final session = _session;
    try {
      final r = await _channel
          .invokeMethod<Object?>('start', {
            'locale': locale,
            'sampleRate': sampleRate,
            'session': session,
          })
          .timeout(startTimeout);
      if (r is String) lastStartError = r;
      return r == true;
    } on TimeoutException {
      // nessuna risposta: la sessione si chiude (gli eventi che arrivassero
      // dopo hanno il numero vecchio e si scartano) e si passa a Whisper
      debugPrint('Riconoscimento vocale: nessuna risposta all\'avvio.');
      if (_session == session) _session++;
      unawaited(_quiet('stop'));
      return false;
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
    this.languageOk = true,
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

  /// La lingua chiesta è fra quelle del riconoscitore (Windows:
  /// `SpeechRecognizer.SupportedTopicLanguages`).
  final bool languageOk;
}

/// Lingua del riconoscimento: sempre fissata, «en-US» (o la variante
/// inglese indicata, es. «en-GB») per gli insegnamenti in inglese,
/// altrimenti «it-IT». La trascrizione resta in italiano o in inglese:
/// mai altre lingue né il rilevamento automatico.
String speechLocaleFor(String? language) {
  final raw = (language ?? '').trim().replaceAll('_', '-');
  final l = raw.toLowerCase();
  if (!l.startsWith('en')) return 'it-IT';
  final parts = raw.split('-');
  return parts.length == 2 && parts[1].length == 2
      ? 'en-${parts[1].toUpperCase()}'
      : 'en-US';
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
  'dictation' =>
    'Sul Mac il riconoscimento vocale richiede la Dettatura: attivala in '
        'Impostazioni di Sistema → Tastiera → Dettatura.',
  final r => r,
};

/// Avviso della card «Trascrizione» sul riconoscitore del sistema: cosa
/// fare, eventuale nota sulla privacy e impostazioni da aprire.
class SpeechNotice {
  const SpeechNotice(this.text, {this.note, this.settings, this.action});
  final String text;

  /// Nota (es. dove passa l'audio).
  final String? note;

  /// Pagina delle impostazioni del sistema (es. `ms-settings:privacy-speech`).
  final Uri? settings;

  /// Etichetta del pulsante che apre [settings].
  final String? action;
}

/// Impostazioni di Windows: Privacy e sicurezza → Voce.
final kWindowsSpeechPrivacy = Uri.parse('ms-settings:privacy-speech');

/// Impostazioni di Windows: Ora e lingua → Lingua e area geografica.
final kWindowsLanguages = Uri.parse('ms-settings:regionlanguage');

/// Nome della lingua per gli avvisi («l'italiano», «l'inglese»…).
String languageName(String locale) =>
    switch (locale.split('-').first.toLowerCase()) {
      'it' => 'l\'italiano',
      'en' => 'l\'inglese',
      'fr' => 'il francese',
      'de' => 'il tedesco',
      'es' => 'lo spagnolo',
      'pt' => 'il portoghese',
      _ => 'la lingua della lezione',
    };

/// Avviso per il motivo [reason] ([SpeechSupport.reason]) per cui il
/// riconoscitore del sistema non trascrive; null se non c'è niente da dire.
/// [whisper]: intanto trascrive Whisper sul dispositivo.
SpeechNotice? speechNotice(
  String? reason, {
  bool windows = false,
  bool mac = false,
  bool languageMissing = false,
  String locale = 'it-IT',
  bool whisper = false,
}) {
  final lang = languageName(locale);
  final addLanguage =
      'Aggiungi $lang in Impostazioni → Ora e lingua → Lingua e area '
      'geografica → Aggiungi una lingua, con «Riconoscimento vocale».';
  if (windows && reason == 'privacy') {
    return SpeechNotice(
      'Per il testo istantaneo attiva «Riconoscimento vocale online» in '
      'Windows.${languageMissing ? ' $addLanguage' : ''}',
      note:
          'Con questa opzione l\'audio passa dai servizi Microsoft. '
          '${whisper ? 'Finché è spenta il testo arriva da Whisper, sul PC e senza internet, con un paio di secondi di ritardo. ' : ''}'
          'Vale dalla prossima registrazione.',
      settings: kWindowsSpeechPrivacy,
      action: 'Apri impostazioni',
    );
  }
  if (windows && reason == 'locale') {
    return SpeechNotice(
      'Il riconoscimento vocale di Windows non ha $lang. $addLanguage',
      note: 'Vale dalla prossima registrazione.',
      settings: kWindowsLanguages,
      action: 'Apri impostazioni',
    );
  }
  final text = speechUnavailableText(reason);
  if (text == null) return null;
  if (mac && (reason == 'denied' || reason == 'dictation')) {
    return SpeechNotice(
      text,
      settings: Uri.parse(
        reason == 'denied'
            ? 'x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition'
            : 'x-apple.systempreferences:com.apple.preference.keyboard?Dictation',
      ),
      action: 'Apri impostazioni',
    );
  }
  return SpeechNotice(text);
}
