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
#include <string>

// Sessione di concentrazione di Windows 11 durante una sessione Focus
// dell'app (canale "io.github.simomagnus.universitynotes/focus", vedi
// lib/features/study/focus/focus_system.dart):
// - "winFocusSupported": il sistema ha le sessioni di concentrazione;
// - "winFocusStart" {endMs, lafToken?, lafAttestation?}: avvia la sessione
//   fino a endMs (ms Unix). Risponde "ok", "negato" (Windows riserva la
//   funzione alle app autorizzate da Microsoft), "non_supportato" o
//   "errore";
// - "winFocusActive": la sessione avviata dall'app è ancora attiva;
// - "winFocusEnd": chiude la sessione avviata dall'app.
// Usa l'interfaccia ABI di Windows.UI.Shell.FocusSessionManager (niente
// eccezioni C++/WinRT). Verificato su Windows 11 25H2 (build 26200):
// IsSupported e GetDefault funzionano anche per un'app non pacchettizzata,
// ma TryStartFocusSession risponde «Access is denied. Feature
// com.microsoft.windows.focussessionmanager.1 is not available»: è una
// funzione ad accesso limitato (Limited Access Feature). Con un token
// ottenuto da Microsoft (--dart-define=WINDOWS_FOCUS_LAF_TOKEN e
// WINDOWS_FOCUS_LAF_ATTESTATION) l'app la sblocca prima di avviarla.
class FocusSessionChannel {
 public:
  explicit FocusSessionChannel(flutter::BinaryMessenger* messenger);
  ~FocusSessionChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  bool Supported();
  // "ok", "negato", "non_supportato" o "errore".
  std::string Start(int64_t end_ms, const std::wstring& token,
                    const std::wstring& attestation);
  bool Active();
  void End();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  Microsoft::WRL::ComPtr<ABI::Windows::UI::Shell::IFocusSession> session_;
};

#endif  // RUNNER_FOCUS_SESSION_H_
