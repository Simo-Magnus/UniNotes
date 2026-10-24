#include "flutter_window.h"

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Stato dell'app (AppLifecycleState) dopo riduci a icona / ripristina.
constexpr UINT kLifecycleMessage = WM_APP + 0x51;
constexpr UINT_PTR kLifecycleTimer = 0x51;

}  // namespace

// Ridotta a icona la vista di Flutter tiene la sua misura (vedi WM_SIZE in
// win32_window.cpp), quindi il motore non si accorge più che l'app è
// nascosta: lo stato «hidden» (e al ripristino «inactive»/«resumed») si
// manda qui sul canale del ciclo di vita, come farebbe il motore. Le
// Sessioni Focus lo usano per gli avvisi con l'app in secondo piano.
void FlutterWindow::SendLifecycleState(HWND hwnd) {
  if (!flutter_controller_) {
    return;
  }
  std::string state = ::IsIconic(hwnd) ? "AppLifecycleState.hidden"
                      : ::GetForegroundWindow() == hwnd
                          ? "AppLifecycleState.resumed"
                          : "AppLifecycleState.inactive";
  flutter_controller_->engine()->messenger()->Send(
      "flutter/lifecycle", reinterpret_cast<const uint8_t*>(state.data()),
      state.size());
}

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
  spell_channel_ = std::make_unique<SpellCheckChannel>(
      flutter_controller_->engine()->messenger());
  open_with_channel_ = std::make_unique<OpenWithChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
  notification_identity_channel_ =
      std::make_unique<NotificationIdentityChannel>(
          flutter_controller_->engine()->messenger());
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
  spell_channel_ = nullptr;
  open_with_channel_ = nullptr;
  notification_identity_channel_ = nullptr;
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
  if (message == kLifecycleMessage) {
    SendLifecycleState(hwnd);
    return 0;
  }
  if (message == WM_TIMER && wparam == kLifecycleTimer) {
    // il motore manda «inactive» quando la finestra perde il fuoco, a volte
    // dopo «hidden»: si ripete
    ::KillTimer(hwnd, kLifecycleTimer);
    if (::IsIconic(hwnd)) {
      SendLifecycleState(hwnd);
    }
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
      // dopo OnDestroy (finestra in chiusura) il motore non c'è più
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
    case WM_SIZE: {
      // Riaprendo la finestra dalla barra delle applicazioni (ripristinata o
      // a tutto schermo) si ridisegna subito alla nuova misura: senza, per un
      // attimo si vede la superficie vuota (nera).
      if (wparam == SIZE_MINIMIZED ||
          (minimized_ &&
           (wparam == SIZE_RESTORED || wparam == SIZE_MAXIMIZED))) {
        minimized_ = wparam == SIZE_MINIMIZED;
        // dopo i messaggi del fuoco che il sistema manda intanto
        ::PostMessage(hwnd, kLifecycleMessage, 0, 0);
        if (minimized_) {
          ::SetTimer(hwnd, kLifecycleTimer, 400, nullptr);
        }
      }
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
    case WM_ACTIVATEAPP:
      // di nuovo in primo piano (barra delle applicazioni, Alt+Tab): un
      // frame subito, anche se nulla è cambiato
      if (wparam && flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
