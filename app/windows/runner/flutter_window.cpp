#include "flutter_window.h"

#include <flutter/standard_method_codec.h>

#include <optional>
#include <string>

#include "flutter/generated_plugin_registrant.h"
#include "window_trace.h"

namespace {

// Frame forzati dopo che la finestra torna visibile (vedi StartRedraws).
constexpr UINT_PTR kRedrawTimer = 0x51;
constexpr UINT kRedrawInterval = 33;
constexpr int kRedrawCount = 30;

// X premuta e nessuna risposta dall'app (né area di notifica né uscita):
// la finestra torna visibile invece di restare un processo invisibile.
constexpr UINT_PTR kCloseTimer = 0x53;
constexpr UINT kCloseTimeout = 10000;

// Stato dell'app (AppLifecycleState) dopo riduci a icona / ripristina.
constexpr UINT kLifecycleMessage = WM_APP + 0x51;
constexpr UINT_PTR kLifecycleTimer = 0x52;

// Traccia: registra il prossimo frame presentato (solo durante le misure).
constexpr UINT kTraceFrameMessage = WM_APP + 0x52;

constexpr char kWindowChannel[] =
    "io.github.simomagnus.universitynotes/finestra";

}  // namespace

// Ridotta a icona la vista di Flutter tiene la sua misura (vedi WM_SIZE in
// win32_window.cpp) e resta «visibile» per il motore, che quindi non manda
// «hidden»: lo stato (e al ripristino «inactive»/«resumed») si manda qui
// sul canale del ciclo di vita, come farebbe il motore. Le Sessioni Focus lo
// usano per gli avvisi con l'app in secondo piano.
void FlutterWindow::SendLifecycleState(HWND hwnd) {
  if (!flutter_controller_) {
    return;
  }
  std::string state = ::IsIconic(hwnd) ? "AppLifecycleState.hidden"
                      : ::GetForegroundWindow() == hwnd
                          ? "AppLifecycleState.resumed"
                          : "AppLifecycleState.inactive";
  TraceWindow("lifecycle %s", state.c_str());
  flutter_controller_->engine()->messenger()->Send(
      "flutter/lifecycle", reinterpret_cast<const uint8_t*>(state.data()),
      state.size());
}

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {
  // canali prima del motore, come in OnDestroy (che il distruttore della
  // classe base non può più chiamare)
  TraceWindow("distruttore: chiusura del motore");
  OnDestroy();
  TraceWindow("distruttore: motore chiuso");
}

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
  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannel,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HWND hwnd = GetHandle();
        if (hwnd == nullptr) {
          result->Success();
          return;
        }
        if (call.method_name() == "uscita") {
          // l'app si chiude: sparisce subito (anche da «Esci» nell'area di
          // notifica) e una copia avviata intanto aspetta la fine
          TraceWindow("canale: uscita");
          ::KillTimer(hwnd, kCloseTimer);
          ::SetPropW(hwnd, kClosingProp,
                     reinterpret_cast<HANDLE>(kClosingQuit));
          ::ShowWindow(hwnd, SW_HIDE);
          result->Success();
        } else if (call.method_name() == "nascosta") {
          // resta aperta nell'area di notifica (registrazione in corso)
          TraceWindow("canale: nascosta");
          ::KillTimer(hwnd, kCloseTimer);
          ::RemovePropW(hwnd, kClosingProp);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });
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
  TraceWindow("OnDestroy inizio");
  audio_channel_ = nullptr;
  focus_channel_ = nullptr;
  speech_channel_ = nullptr;
  spell_channel_ = nullptr;
  open_with_channel_ = nullptr;
  notification_identity_channel_ = nullptr;
  window_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  TraceWindow("OnDestroy motore chiuso");

  Win32Window::OnDestroy();
}

// Schermo nero riaprendo la finestra (misure in docs/registratore.md).
// Ridotta a icona o nascosta, Windows libera la superficie DirectX della
// vista di Flutter: al ripristino, durante l'animazione della barra delle
// applicazioni, si vedeva il fondo della finestra (nero o #02060F) finché
// Flutter non presentava un frame a finestra già visibile per il
// compositore; il frame chiesto subito al ripristino spesso arriva troppo
// presto (Present scartato) e, con l'app ferma, il successivo arrivava solo
// al primo movimento del mouse: nero anche per secondi. Due rimedi:
// - appena prima di ridurre o nascondere la finestra si copia la sua
//   immagine (CaptureSnapshot) e la si dipinge nella superficie GDI della
//   finestra, sotto la vista di Flutter: è quella che il compositore mostra
//   finché Flutter non ripresenta (stessa immagine, nessun salto);
// - al ritorno si forzano frame per circa un secondo (StartRedraws), così
//   uno arriva di sicuro a finestra visibile.

// Copia dell'area client dalla superficie della finestra (BitBlt dal DC
// della finestra, ~5-13 ms; PrintWindow con PW_RENDERFULLCONTENT dava la
// stessa immagine in 40-60 ms). Con la finestra ancora visibile: chiamata
// da WM_WINDOWPOSCHANGING verso la posizione ridotta e da WM_SHOWWINDOW.
void FlutterWindow::CaptureSnapshot(HWND hwnd) {
  DropSnapshot();
  RECT r;
  ::GetClientRect(hwnd, &r);
  const int w = r.right - r.left, h = r.bottom - r.top;
  if (w <= 0 || h <= 0) return;
  HDC wdc = ::GetDC(hwnd);
  HDC mdc = ::CreateCompatibleDC(wdc);
  HBITMAP bmp = ::CreateCompatibleBitmap(wdc, w, h);
  if (mdc == nullptr || bmp == nullptr) {
    if (bmp) ::DeleteObject(bmp);
    if (mdc) ::DeleteDC(mdc);
    ::ReleaseDC(hwnd, wdc);
    return;
  }
  HGDIOBJ old = ::SelectObject(mdc, bmp);
  bool ok = ::BitBlt(mdc, 0, 0, w, h, wdc, 0, 0, SRCCOPY) != FALSE;
  if (ok) {
    // con un'altra presentazione (scheda video, driver) la copia può non
    // vedere Flutter e risultare tutta nera: allora meglio il colore di
    // fondo
    bool any = false;
    for (int i = 1; i <= 4 && !any; ++i) {
      for (int j = 1; j <= 4 && !any; ++j) {
        any = (::GetPixel(mdc, w * i / 5, h * j / 5) & 0xFFFFFF) != 0;
      }
    }
    ok = any;
  }
  ::SelectObject(mdc, old);
  ::DeleteDC(mdc);
  ::ReleaseDC(hwnd, wdc);
  if (!ok) {
    ::DeleteObject(bmp);
    return;
  }
  snapshot_ = bmp;
  snapshot_w_ = w;
  snapshot_h_ = h;
  TraceWindow("istantanea %dx%d", w, h);
}

void FlutterWindow::DropSnapshot() {
  if (snapshot_) {
    ::DeleteObject(snapshot_);
    snapshot_ = nullptr;
  }
  show_snapshot_ = false;
}

// Dipinge l'immagine salvata se la finestra ha ancora la stessa misura.
bool FlutterWindow::PaintSnapshot(HWND hwnd, HDC dc) {
  if (!snapshot_ || !show_snapshot_) return false;
  RECT r;
  ::GetClientRect(hwnd, &r);
  if (r.right - r.left != snapshot_w_ || r.bottom - r.top != snapshot_h_) {
    return false;
  }
  HDC mdc = ::CreateCompatibleDC(dc);
  HGDIOBJ old = ::SelectObject(mdc, snapshot_);
  ::BitBlt(dc, 0, 0, snapshot_w_, snapshot_h_, mdc, 0, 0, SRCCOPY);
  ::SelectObject(mdc, old);
  ::DeleteDC(mdc);
  return true;
}

// Finestra che sta per sparire (ridotta a icona o nascosta): immagine
// copiata e dipinta subito nella superficie GDI, che Windows conserva.
void FlutterWindow::KeepLastFrame(HWND hwnd) {
  CaptureSnapshot(hwnd);
  if (snapshot_) {
    show_snapshot_ = true;
    HDC dc = ::GetDC(hwnd);
    PaintSnapshot(hwnd, dc);
    ::ReleaseDC(hwnd, dc);
  }
}

void FlutterWindow::StartRedraws(HWND hwnd) {
  if (!flutter_controller_) {
    return;
  }
  flutter_controller_->ForceRedraw();
  redraws_left_ = kRedrawCount;
  ::SetTimer(hwnd, kRedrawTimer, kRedrawInterval, nullptr);
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Prima dei plugin: window_manager ferma WM_SIZE con SIZE_MINIMIZED e il
  // runner non lo vedrebbe.
  switch (message) {
    case WM_SIZE:
      TraceWindow("WM_SIZE %u %ux%u", static_cast<unsigned>(wparam),
                  LOWORD(lparam), HIWORD(lparam));
      if (wparam == SIZE_MINIMIZED) {
        iconic_ = true;
        redraws_left_ = 0;
        ::KillTimer(hwnd, kRedrawTimer);
        // dopo i messaggi del fuoco che il sistema manda intanto
        ::PostMessage(hwnd, kLifecycleMessage, 0, 0);
        ::SetTimer(hwnd, kLifecycleTimer, 400, nullptr);
      } else if (wparam == SIZE_RESTORED || wparam == SIZE_MAXIMIZED) {
        if (iconic_) {
          iconic_ = false;
          ::PostMessage(hwnd, kLifecycleMessage, 0, 0);
          StartRedraws(hwnd);
        }
        if (WindowTraceFile() != nullptr) {
          // fuori da questo messaggio: può arrivare dentro la richiamata del
          // primo frame, che non va sostituita mentre è in corso
          ::PostMessage(hwnd, kTraceFrameMessage, 0, 0);
        }
      }
      break;
    case kLifecycleMessage:
      SendLifecycleState(hwnd);
      return 0;
    case WM_WINDOWPOSCHANGING: {
      // riduzione a icona (pulsante, barra delle applicazioni, Win+giù,
      // ShowWindow): la nuova posizione è quella delle finestre ridotte
      const auto* pos = reinterpret_cast<const WINDOWPOS*>(lparam);
      if (!iconic_ && !(pos->flags & SWP_NOMOVE) && pos->x <= -32000 &&
          pos->y <= -32000 && ::IsWindowVisible(hwnd)) {
        KeepLastFrame(hwnd);
      }
      break;
    }
    case WM_ERASEBKGND:
      // al ripristino l'ultima immagine invece del colore di fondo
      if (PaintSnapshot(hwnd, reinterpret_cast<HDC>(wparam))) {
        return 1;
      }
      break;
    case kTraceFrameMessage:
      if (flutter_controller_) {
        flutter_controller_->engine()->SetNextFrameCallback(
            []() { TraceWindow("frame presentato"); });
      }
      return 0;
    case WM_SHOWWINDOW:
      TraceWindow("WM_SHOWWINDOW %u", static_cast<unsigned>(wparam));
      if (wparam) {
        StartRedraws(hwnd);
      } else if (!iconic_ && ::IsWindowVisible(hwnd)) {
        // nascosta (area di notifica): stessa cosa al ritorno
        KeepLastFrame(hwnd);
      }
      break;
    case WM_ACTIVATEAPP:
      TraceWindow("WM_ACTIVATEAPP %u", static_cast<unsigned>(wparam));
      // di nuovo in primo piano (Alt+Tab, clic): un frame subito, anche se
      // nulla è cambiato (la superficie c'è ancora: niente serie di frame)
      if (wparam && flutter_controller_) {
        flutter_controller_->ForceRedraw();
      }
      break;
    case WM_TIMER:
      if (wparam == kRedrawTimer) {
        if (--redraws_left_ <= 0) {
          // Flutter ha ripresentato: l'immagine non serve più (non va
          // ridipinta sotto la vista a un ridimensionamento)
          ::KillTimer(hwnd, kRedrawTimer);
          DropSnapshot();
        }
        if (flutter_controller_ && !::IsIconic(hwnd) &&
            ::IsWindowVisible(hwnd)) {
          flutter_controller_->ForceRedraw();
        }
        return 0;
      }
      if (wparam == kLifecycleTimer) {
        // il motore manda «inactive» quando la finestra perde il fuoco, a
        // volte dopo «hidden»: si ripete
        ::KillTimer(hwnd, kLifecycleTimer);
        if (::IsIconic(hwnd)) {
          SendLifecycleState(hwnd);
        }
        return 0;
      }
      if (wparam == kCloseTimer) {
        ::KillTimer(hwnd, kCloseTimer);
        if (reinterpret_cast<ULONG_PTR>(::GetPropW(hwnd, kClosingProp)) ==
            kClosingAsked) {
          TraceWindow("chiusura senza risposta: finestra di nuovo visibile");
          ::RemovePropW(hwnd, kClosingProp);
          ::ShowWindow(hwnd, SW_SHOW);
        }
        return 0;
      }
      break;
    case WM_CLOSE:
      TraceWindow("WM_CLOSE");
      // La X (anche dall'anteprima della barra delle applicazioni) nasconde
      // subito la finestra; l'app decide poi se restare nell'area di
      // notifica (registrazione in corso) o uscire, e intanto salva, chiude
      // il database e il motore senza che la finestra resti sullo schermo.
      // Il motore rimanda un secondo WM_CLOSE dopo aver chiesto all'app se
      // uscire: la finestra è già nascosta e non cambia nulla.
      if (::IsWindowVisible(hwnd) && ::GetPropW(hwnd, kClosingProp) == nullptr) {
        ::SetPropW(hwnd, kClosingProp,
                   reinterpret_cast<HANDLE>(kClosingAsked));
        ::ShowWindow(hwnd, SW_HIDE);
        ::SetTimer(hwnd, kCloseTimer, kCloseTimeout, nullptr);
      }
      break;
    case WM_SYSCOMMAND:
      TraceWindow("WM_SYSCOMMAND %x", static_cast<unsigned>(wparam & 0xFFF0));
      break;
    case WM_DESTROY:
      TraceWindow("WM_DESTROY");
      ::KillTimer(hwnd, kRedrawTimer);
      ::KillTimer(hwnd, kCloseTimer);
      DropSnapshot();
      break;
    case WM_NCDESTROY:
      ::RemovePropW(hwnd, kClosingProp);
      break;
  }
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
      // dopo OnDestroy (finestra in chiusura) il motore non c'è più
      if (flutter_controller_ && flutter_controller_->engine()) {
        flutter_controller_->engine()->ReloadSystemFonts();
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
