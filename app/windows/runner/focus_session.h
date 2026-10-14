#ifndef RUNNER_FOCUS_SESSION_H_
#define RUNNER_FOCUS_SESSION_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <windows.ui.shell.h>
#include <wrl/client.h>

#include <cstdint>
#include <memory>

// Sessione di concentrazione di Windows 11 durante una sessione Focus
// dell'app (canale "io.github.simomagnus.universitynotes/focus", vedi
// lib/features/study/focus/focus_system.dart):
// - "winFocusSupported": il sistema ha le sessioni di concentrazione;
// - "winFocusStart" {endMs}: avvia la sessione fino a endMs (ms Unix) e
//   restituisce true se Windows l'ha accettata;
// - "winFocusEnd": chiude la sessione avviata dall'app.
// Usa l'interfaccia ABI di Windows.UI.Shell.FocusSessionManager (niente
// eccezioni C++/WinRT). Verificato: IsSupported e GetDefault funzionano
// anche per un'app non pacchettizzata; se Windows rifiuta l'avvio (API ad
// accesso limitato), l'app spiega come attivare "Non disturbare" a mano.
class FocusSessionChannel {
 public:
  explicit FocusSessionChannel(flutter::BinaryMessenger* messenger);
  ~FocusSessionChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Supported();
  bool Start(int64_t end_ms);
  void End();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ABI::Windows::UI::Shell::IFocusSession> session_;
};

#endif  // RUNNER_FOCUS_SESSION_H_
