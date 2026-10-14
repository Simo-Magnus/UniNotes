#include "flutter_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  audio_channel_ = std::make_unique<AudioTranscoderChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
  focus_channel_ = std::make_unique<FocusSessionChannel>(
      flutter_controller_->engine()->messenger());
  speech_channel_ = std::make_unique<LiveSpeechChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  audio_channel_ = nullptr;
  focus_channel_ = nullptr;
  speech_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Esito di una conversione audio fatta in un altro thread.
  if (audio_channel_ &&
      audio_channel_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }
  // Eventi del riconoscimento vocale (arrivano da altri thread).
  if (speech_channel_ &&
      speech_channel_->HandleMessage(message, wparam, lparam)) {
    return 0;
  }
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_SIZE: {
      // Riaprendo la finestra dalla barra delle applicazioni (ripristinata o
      // a tutto schermo) si ridisegna subito alla nuova misura: senza, per un
      // attimo si vede la superficie vuota (nera).
      const LRESULT r =
          Win32Window::MessageHandler(hwnd, message, wparam, lparam);
      if (flutter_controller_ &&
          (wparam == SIZE_RESTORED || wparam == SIZE_MAXIMIZED)) {
        flutter_controller_->ForceRedraw();
      }
      return r;
    }
    case WM_SHOWWINDOW:
      if (wparam && flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
