#ifndef RUNNER_LIVE_SPEECH_H_
#define RUNNER_LIVE_SPEECH_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <windows.media.speechrecognition.h>
#include <wrl/client.h>

#include <memory>
#include <string>

// Trascrizione istantanea durante la registrazione delle lezioni (canale
// "io.github.simomagnus.universitynotes/speech", vedi
// lib/features/notes/recorder/system_speech.dart) con
// Windows.Media.SpeechRecognition in dettatura continua: il testo
// provvisorio (HypothesisGenerated) si aggiorna mentre si parla, quello
// definitivo arriva a ogni frase (ResultGenerated).
//
// Il riconoscitore ascolta il microfono predefinito in modalità condivisa:
// la registrazione (che usa lo stesso microfono) non viene interrotta.
// - "support" {locale}: lingua tra quelle della dettatura di Windows;
// - "start" {locale, session}: true se la sessione è partita, altrimenti
//   il motivo (es. "privacy": «Riconoscimento vocale online» disattivato
//   nelle impostazioni di Windows) e l'app usa Whisper;
// - "pause", "resume", "stop".
// Verso Flutter (con "session"): "partial", "result", "error", "ended".
//
// Usa le interfacce ABI di WinRT con WRL (niente eccezioni C++/WinRT). Gli
// eventi arrivano su altri thread: diventano messaggi kLiveSpeechMessage
// alla finestra e si gestiscono nel thread della piattaforma.
constexpr UINT kLiveSpeechMessage = WM_APP + 0x42;

class LiveSpeechChannel {
 public:
  LiveSpeechChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~LiveSpeechChannel();

  // Da chiamare dal gestore dei messaggi della finestra: true se il
  // messaggio era un evento del riconoscitore.
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  using Result = flutter::MethodResult<flutter::EncodableValue>;

  void HandleMethodCall(const flutter::MethodCall<flutter::EncodableValue>& call,
                        std::unique_ptr<Result> result);

  flutter::EncodableValue Support(const std::string& locale);
  void Start(const std::string& locale, int session,
             std::unique_ptr<Result> result);
  void StartContinuous();
  void Stop();
  void Pause();
  void Resume();
  void Release();
  void ReplyStart(const flutter::EncodableValue& value);
  void Send(const char* method, flutter::EncodableMap args);
  void Fail(const std::string& message);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  int session_ = 0;
  bool running_ = false;
  bool stopping_ = false;
  int restarts_ = 0;
  ULONGLONG first_restart_ = 0;
  std::unique_ptr<Result> pending_start_;
  Microsoft::WRL::ComPtr<ABI::Windows::Media::SpeechRecognition::ISpeechRecognizer>
      recognizer_;
  Microsoft::WRL::ComPtr<
      ABI::Windows::Media::SpeechRecognition::ISpeechContinuousRecognitionSession>
      continuous_;
  EventRegistrationToken hypothesis_token_{};
  EventRegistrationToken result_token_{};
  EventRegistrationToken completed_token_{};
};

#endif  // RUNNER_LIVE_SPEECH_H_
