#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "audio_transcoder.h"
#include "focus_session.h"
#include "live_speech.h"
#include "notification_identity.h"
#include "open_with.h"
#include "spell_check.h"
#include "win32_window.h"

// Proprietà della finestra principale letta da una seconda copia dell'app
// (main.cpp): 1 = X premuta, l'app sta decidendo (area di notifica o
// uscita); 2 = l'app si sta chiudendo. Senza: finestra aperta (o
// nell'area di notifica).
inline constexpr wchar_t kClosingProp[] = L"UniNotes.Chiusura";
inline constexpr ULONG_PTR kClosingAsked = 1;
inline constexpr ULONG_PTR kClosingQuit = 2;

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

  // «Apri con…»: scelta dell'app di Windows (SHOpenWithDialog).
  std::unique_ptr<OpenWithChannel> open_with_channel_;

  // Identità dei toast: passaggio una volta sola all'AUMID nuovo.
  std::unique_ptr<NotificationIdentityChannel> notification_identity_channel_;

  // Chiusura dalla X: com'è finita (`nascosta` nell'area di notifica o
  // `uscita`), detto dall'app (lib/core/services/desktop_window.dart).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Finestra tornata visibile (ripristinata, mostrata, di nuovo in primo
  // piano): frame forzati per un po' (vedi StartRedraws).
  void StartRedraws(HWND hwnd);
  int redraws_left_ = 0;

  // Ultima immagine della finestra prima di ridurla a icona o nasconderla,
  // mostrata al ritorno finché Flutter non ripresenta (vedi
  // flutter_window.cpp).
  void CaptureSnapshot(HWND hwnd);
  void DropSnapshot();
  bool PaintSnapshot(HWND hwnd, HDC dc);
  void KeepLastFrame(HWND hwnd);
  HBITMAP snapshot_ = nullptr;
  int snapshot_w_ = 0;
  int snapshot_h_ = 0;
  bool show_snapshot_ = false;

  // Finestra ridotta a icona (stato dell'app mandato da qui).
  bool iconic_ = false;

  // Manda a Flutter lo stato dell'app per la finestra [hwnd] (nascosta,
  // in primo piano o no).
  void SendLifecycleState(HWND hwnd);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
