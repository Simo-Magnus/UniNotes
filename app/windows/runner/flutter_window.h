#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "audio_transcoder.h"
#include "focus_session.h"
#include "live_speech.h"
#include "spell_check.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Conversioni audio delle registrazioni (Media Foundation).
  std::unique_ptr<AudioTranscoderChannel> audio_channel_;

  // Sessione di concentrazione di Windows durante le sessioni Focus.
  std::unique_ptr<FocusSessionChannel> focus_channel_;

  // Trascrizione istantanea delle lezioni (riconoscimento vocale).
  std::unique_ptr<LiveSpeechChannel> speech_channel_;

  // Controllo ortografico di Windows nei campi di testo (ISpellChecker).
  std::unique_ptr<SpellCheckChannel> spell_channel_;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
