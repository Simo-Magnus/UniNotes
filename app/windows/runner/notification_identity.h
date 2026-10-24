#ifndef RUNNER_NOTIFICATION_IDENTITY_H_
#define RUNNER_NOTIFICATION_IDENTITY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <string>

// Identità dell'app nei toast e nella barra delle applicazioni
// (AppUserModelID, «AUMID»), vedi lib/core/reminders/windows_aumid.dart.
//
// Versione del sito (non pacchettizzata): l'AUMID è kUniNotesAumid, lo
// stesso del collegamento nel menu Start (installer/uninotes.iss) e dei
// toast; il processo lo dichiara all'avvio (ApplyProcessAumid), così
// finestra, collegamento e toast sono la stessa app. Nel pacchetto MSIX
// (Microsoft Store) l'AUMID lo decide il pacchetto: qui non si tocca nulla.
//
// Canale "io.github.simomagnus.universitynotes/notifiche":
// - "migraAumid" {vecchio}: toglie i toast pianificati e la cronologia
//   dell'AUMID vecchio ed elimina le sue chiavi del registro (registrazione
//   delle notifiche e impostazioni). Risponde {rimossi, pacchetto}; nel
//   pacchetto MSIX non fa nulla. Errori ignorati (si fa quel che si può).
//   L'app lo chiama una volta sola (flag nelle impostazioni).

// AUMID della versione non pacchettizzata.
extern const wchar_t kUniNotesAumid[];

// Il processo ha un'identità di pacchetto (MSIX)?
bool HasPackageIdentity();

// Dichiara l'AUMID del processo (solo senza identità di pacchetto): va
// chiamata prima di creare qualsiasi finestra.
void ApplyProcessAumid();

class NotificationIdentityChannel {
 public:
  explicit NotificationIdentityChannel(flutter::BinaryMessenger* messenger);
  ~NotificationIdentityChannel();

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_NOTIFICATION_IDENTITY_H_
