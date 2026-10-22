#ifndef RUNNER_OPEN_WITH_H_
#define RUNNER_OPEN_WITH_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// «Apri con…» dell'app (canale "io.github.simomagnus.universitynotes/apri_con",
// vedi lib/core/services/external_launcher.dart):
// - "openWith" {path}: la finestra di Windows «Come vuoi aprire questo
//   file?» (SHOpenWithDialog con OAIF_ALLOW_REGISTRATION | OAIF_EXEC):
//   l'utente sceglie l'app (e, se vuole, la rende predefinita) e il file
//   si apre con quella. Risponde "ok", "annullato" o "errore".
// La finestra è modale rispetto a quella dell'app.
class OpenWithChannel {
 public:
  OpenWithChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~OpenWithChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_OPEN_WITH_H_
