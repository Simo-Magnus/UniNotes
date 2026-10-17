import AVFoundation
import Foundation
import Speech

#if os(iOS)
  import Flutter
#else
  import FlutterMacOS
#endif

// Trascrizione istantanea durante la registrazione delle lezioni, come Memo
// Vocali (canale "io.github.simomagnus.universitynotes/speech", vedi
// lib/features/notes/recorder/system_speech.dart). Lo stesso file è in
// ios/Runner e macos/Runner.
//
// L'audio è quello della registrazione: l'app lo passa con "feed" (PCM 16
// bit mono a 16 kHz), il riconoscitore non apre il microfono.
// - iOS/macOS 26 o successivi: SpeechAnalyzer + SpeechTranscriber (risultati
//   provvisori «volatili» e definitivi, modelli sul dispositivo scaricati
//   dal sistema);
// - prima: SFSpeechRecognizer con SFSpeechAudioBufferRecognitionRequest,
//   sul dispositivo quando la lingua lo permette. Una richiesta si chiude a
//   una pausa dopo ~30 s (al massimo dopo 55 s: il riconoscimento in rete
//   ha un limite di un minuto) e se ne apre subito un'altra.
//
// Verso Flutter (con "session"): "partial" {text}, "result" {text},
// "error" {message, fatal}, "ended". Un errore non ferma mai la
// registrazione: con fatal = true l'app passa a Whisper.
// Info.plist: NSSpeechRecognitionUsageDescription e
// NSMicrophoneUsageDescription.

protocol LiveSpeechEngine: AnyObject {
  func append(_ data: Data)
  func finish()
  func cancel()
}

final class LiveSpeech: NSObject {
  static let channelName = "io.github.simomagnus.universitynotes/speech"

  private let channel: FlutterMethodChannel
  private var session = 0
  private var engine: LiveSpeechEngine?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: LiveSpeech.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result: result)
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch call.method {
    case "support":
      support(locale: args["locale"] as? String ?? "it-IT", result: result)
    case "start":
      let ses = (args["session"] as? NSNumber)?.intValue ?? session + 1
      start(
        locale: args["locale"] as? String ?? "it-IT",
        session: ses,
        result: result)
    case "feed":
      if let data = call.arguments as? FlutterStandardTypedData {
        engine?.append(data.data)
      }
      result(nil)
    case "pause", "resume":
      // in pausa l'audio semplicemente non arriva
      result(nil)
    case "stop":
      if let e = engine {
        e.finish()
      } else {
        send("ended", [:])
      }
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func support(locale: String, result: @escaping FlutterResult) {
    let status = SFSpeechRecognizer.authorizationStatus()
    if status == .denied || status == .restricted {
      result(["available": false, "reason": "denied"])
      return
    }
    guard let rec = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
      result(["available": false, "reason": "locale"])
      return
    }
    var engine = "sfspeech"
    #if compiler(>=6.2)
      if #available(iOS 26.0, macOS 26.0, *) { engine = "speechanalyzer" }
    #endif
    let onDevice = rec.supportsOnDeviceRecognition
    if !onDevice && !rec.isAvailable && engine == "sfspeech" {
      result(["available": false, "reason": "offline"])
      return
    }
    result([
      "available": true,
      "onDevice": onDevice || engine == "speechanalyzer",
      "feedsAudio": true,
      "engine": engine,
    ])
  }

  private func start(locale: String, session ses: Int, result: @escaping FlutterResult) {
    engine?.cancel()
    engine = nil
    session = ses
    authorize { [weak self] ok in
      guard let self = self else { return }
      guard ses == self.session else {
        result(false)
        return
      }
      guard ok else {
        // permesso negato: l'app lo spiega e usa Whisper
        result("denied")
        return
      }
      let loc = Locale(identifier: locale)
      let emit: (String, [String: Any]) -> Void = { [weak self] method, payload in
        guard let self = self, ses == self.session else { return }
        self.send(method, payload)
      }
      #if compiler(>=6.2)
        if #available(iOS 26.0, macOS 26.0, *) {
          let e = AnalyzerSpeechEngine(locale: loc, emit: emit)
          self.engine = e
          e.begin { started in
            if started {
              result(true)
              return
            }
            // SpeechAnalyzer non disponibile per la lingua: SFSpeechRecognizer
            guard ses == self.session else {
              result(false)
              return
            }
            let fallback = SFSpeechEngine(locale: loc, emit: emit)
            self.engine = fallback
            result(fallback?.begin() ?? false)
          }
          return
        }
      #endif
      let e = SFSpeechEngine(locale: loc, emit: emit)
      self.engine = e
      result(e?.begin() ?? false)
    }
  }

  /// Permesso del riconoscimento vocale (chiesto la prima volta).
  private func authorize(_ done: @escaping (Bool) -> Void) {
    switch SFSpeechRecognizer.authorizationStatus() {
    case .authorized:
      done(true)
    case .notDetermined:
      SFSpeechRecognizer.requestAuthorization { status in
        DispatchQueue.main.async { done(status == .authorized) }
      }
    default:
      done(false)
    }
  }

  private func send(_ method: String, _ payload: [String: Any]) {
    var args = payload
    args["session"] = session
    let run = { self.channel.invokeMethod(method, arguments: args) }
    if Thread.isMainThread {
      run()
    } else {
      DispatchQueue.main.async(execute: run)
    }
  }
}

/// PCM 16 bit mono (little endian) → buffer Float32 nel formato [format].
private func pcmBuffer(_ data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
  let frames = data.count / 2
  guard frames > 0,
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
    let out = buf.floatChannelData?[0]
  else { return nil }
  buf.frameLength = AVAudioFrameCount(frames)
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let samples = raw.bindMemory(to: Int16.self)
    for i in 0..<frames {
      out[i] = Float(Int16(littleEndian: samples[i])) / 32768
    }
  }
  return buf
}

/// Livello medio (0–1) di un pezzo PCM 16 bit: per chiudere le richieste
/// nelle pause.
private func pcmLevel(_ data: Data) -> Float {
  let n = data.count / 2
  if n == 0 { return 0 }
  var sum: Float = 0
  data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
    let s = raw.bindMemory(to: Int16.self)
    for i in 0..<n {
      let v = Float(Int16(littleEndian: s[i])) / 32768
      sum += v * v
    }
  }
  return (sum / Float(n)).squareRoot()
}

/// Errore «Siri e Dettatura sono disattivate» (kLSRErrorDomain 201).
private func isDictationOff(_ error: Error) -> Bool {
  let e = error as NSError
  return e.domain == "kLSRErrorDomain" && e.code == 201
}

/// SFSpeechRecognizer con richieste a buffer che si susseguono.
final class SFSpeechEngine: LiveSpeechEngine {
  private let recognizer: SFSpeechRecognizer
  private let emit: (String, [String: Any]) -> Void
  private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
  private let onDevice: Bool
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var startedAt = Date()
  private var lastPartial = ""
  private var finishing = false
  private var errors = 0
  private var lastErrorAt = Date.distantPast

  init?(locale: Locale, emit: @escaping (String, [String: Any]) -> Void) {
    guard let r = SFSpeechRecognizer(locale: locale) else { return nil }
    recognizer = r
    self.emit = emit
    onDevice = r.supportsOnDeviceRecognition
  }

  func begin() -> Bool {
    guard onDevice || recognizer.isAvailable else { return false }
    newRequest()
    return true
  }

  private func newRequest() {
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    req.taskHint = .dictation
    if onDevice { req.requiresOnDeviceRecognition = true }
    if #available(iOS 16.0, macOS 13.0, *) { req.addsPunctuation = true }
    request = req
    startedAt = Date()
    lastPartial = ""
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      DispatchQueue.main.async { self?.handle(req, result: result, error: error) }
    }
  }

  private func handle(
    _ req: SFSpeechAudioBufferRecognitionRequest,
    result: SFSpeechRecognitionResult?,
    error: Error?
  ) {
    let current = req === request
    if let r = result {
      let text = r.bestTranscription.formattedString
      if r.isFinal {
        if !text.isEmpty { emit("result", ["text": text]) }
        if current { lastPartial = "" }
        errors = 0
        if finishing && current {
          emit("ended", [:])
        } else if current {
          newRequest()
        }
      } else if current, text != lastPartial {
        lastPartial = text
        emit("partial", ["text": text])
      }
      return
    }
    guard let err = error, current else { return }
    // Siri e Dettatura disattivate (macOS): nessuna richiesta può riuscire,
    // inutile riprovare; l'app lo spiega e usa Whisper
    if isDictationOff(err) {
      if !lastPartial.isEmpty {
        emit("result", ["text": lastPartial])
        lastPartial = ""
      }
      emit("error", ["message": "dictation", "fatal": true])
      cancel()
      return
    }
    // la richiesta si è chiusa con un errore (anche «nessun parlato»):
    // il testo provvisorio resta e se ne apre un'altra
    if !lastPartial.isEmpty {
      emit("result", ["text": lastPartial])
      lastPartial = ""
    }
    if finishing {
      emit("ended", [:])
      return
    }
    if Date().timeIntervalSince(lastErrorAt) > 60 { errors = 0 }
    errors += 1
    lastErrorAt = Date()
    if errors >= 5 {
      emit(
        "error",
        ["message": err.localizedDescription, "fatal": true])
      cancel()
      return
    }
    newRequest()
  }

  func append(_ data: Data) {
    guard !finishing, let req = request, let buf = pcmBuffer(data, format: format) else { return }
    req.append(buf)
    // si chiude la richiesta in una pausa dopo 30 s, al massimo dopo 55 s
    let age = Date().timeIntervalSince(startedAt)
    if age > 55 || (age > 30 && pcmLevel(data) < 0.01) {
      rotate()
    }
  }

  /// Chiude la richiesta in corso (il suo testo definitivo arriva dopo) e
  /// ne apre subito un'altra per l'audio che segue.
  private func rotate() {
    let old = request
    newRequest()
    old?.endAudio()
  }

  func finish() {
    finishing = true
    if request == nil {
      emit("ended", [:])
      return
    }
    request?.endAudio()
  }

  func cancel() {
    finishing = true
    task?.cancel()
    task = nil
    request = nil
  }
}

#if compiler(>=6.2)
  /// SpeechAnalyzer (iOS/macOS 26): trascrizione sul dispositivo con
  /// risultati provvisori e definitivi.
  @available(iOS 26.0, macOS 26.0, *)
  final class AnalyzerSpeechEngine: LiveSpeechEngine {
    private let locale: Locale
    private let emit: (String, [String: Any]) -> Void
    private let source = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private var ready = false
    private var finishing = false

    init(locale: Locale, emit: @escaping (String, [String: Any]) -> Void) {
      self.locale = locale
      self.emit = emit
    }

    /// Prepara il modello della lingua (scaricandolo se serve) e avvia
    /// l'analisi; [done] false se la lingua non è supportata.
    func begin(_ done: @escaping (Bool) -> Void) {
      Task { @MainActor in
        do {
          let supported = await SpeechTranscriber.supportedLocales
          let wanted = self.locale.identifier(.bcp47)
          guard
            let loc = supported.first(where: { $0.identifier(.bcp47) == wanted })
              ?? supported.first(where: {
                $0.language.languageCode == self.locale.language.languageCode
              })
          else {
            done(false)
            return
          }
          let transcriber = SpeechTranscriber(
            locale: loc,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [])
          if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber])
          {
            try await request.downloadAndInstall()
          }
          let analyzer = SpeechAnalyzer(modules: [transcriber])
          let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber])
          let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
          self.analyzer = analyzer
          self.input = continuation
          self.format = format
          if let f = format, f != self.source {
            self.converter = AVAudioConverter(from: self.source, to: f)
          }
          self.results = Task { @MainActor [weak self] in
            do {
              for try await r in transcriber.results {
                let text = String(r.text.characters)
                if r.isFinal {
                  if !text.isEmpty { self?.emit("result", ["text": text]) }
                } else {
                  self?.emit("partial", ["text": text])
                }
              }
            } catch {
              if self?.finishing == false {
                self?.emit(
                  "error", ["message": error.localizedDescription, "fatal": true])
              }
            }
            self?.emit("ended", [:])
          }
          try await analyzer.start(inputSequence: stream)
          self.ready = true
          done(true)
        } catch {
          done(false)
        }
      }
    }

    func append(_ data: Data) {
      guard ready, !finishing, let buf = pcmBuffer(data, format: source) else { return }
      guard let conv = converter, let target = format else {
        input?.yield(AnalyzerInput(buffer: buf))
        return
      }
      let ratio = target.sampleRate / source.sampleRate
      let capacity = AVAudioFrameCount(Double(buf.frameLength) * ratio) + 32
      guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
      var given = false
      var err: NSError?
      conv.convert(to: out, error: &err) { _, status in
        if given {
          status.pointee = .noDataNow
          return nil
        }
        given = true
        status.pointee = .haveData
        return buf
      }
      if err == nil, out.frameLength > 0 {
        input?.yield(AnalyzerInput(buffer: out))
      }
    }

    func finish() {
      finishing = true
      input?.finish()
      guard let a = analyzer else {
        emit("ended", [:])
        return
      }
      Task { try? await a.finalizeAndFinishThroughEndOfInput() }
    }

    func cancel() {
      finishing = true
      input?.finish()
      results?.cancel()
      analyzer = nil
    }
  }
#endif
