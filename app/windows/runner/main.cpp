#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "notification_identity.h"
#include "utils.h"
#include "window_trace.h"

namespace {

// Ritorno dall'accesso nel browser (OneDrive, Google Drive): la pagina del
// server locale apre «uninotes://auth» e Windows avvia una seconda copia
// dell'app con l'indirizzo come argomento. Se UniNotes è già aperto la sua
// finestra torna in primo piano (questa copia, avviata dal browser in primo
// piano, ha il permesso di farlo) e la seconda copia si chiude senza aprire
// un altro database. Vedi lib/core/services/app_return.dart.
// Finestra di UniNotes già aperta (anche nascosta), o nullptr.
HWND FindRunningWindow() {
  HWND window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"UniNotes");
  if (window == nullptr) {
    window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  }
  return window;
}

// Stato di chiusura della finestra (kClosingProp in flutter_window.h): 0 =
// aperta, kClosingAsked = X premuta, kClosingQuit = in uscita.
ULONG_PTR ClosingState(HWND window) {
  return reinterpret_cast<ULONG_PTR>(::GetPropW(window, kClosingProp));
}

// Porta in primo piano la finestra di UniNotes già aperta; false se non
// c'è o se si sta chiudendo (non le si passa nulla: sparirebbe subito).
bool FocusRunningWindow() {
  HWND window = FindRunningWindow();
  if (window == nullptr || ClosingState(window) != 0) return false;
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
  return true;
}

// Avvio dallo schema uninotes: (comando del registro `"uninotes.exe" "%1"`):
// il primo argomento è l'indirizzo, scritto da chi apre il collegamento (una
// pagina web, un'altra app). Lo schema si confronta senza distinguere le
// maiuscole, come fa Windows.
bool FromLink(const std::vector<std::string>& args) {
  if (args.empty()) return false;
  const std::string& a = args.front();
  static const char kScheme[] = "uninotes:";
  const size_t n = sizeof(kScheme) - 1;
  if (a.size() < n) return false;
  for (size_t i = 0; i < n; ++i) {
    char c = a[i];
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    if (c != kScheme[i]) return false;
  }
  return true;
}

bool HasArg(const std::vector<std::string>& args, const char* arg) {
  for (const auto& a : args) {
    if (a == arg) return true;
  }
  return false;
}

constexpr wchar_t kSingleInstanceMutex[] = L"Local\\UniNotes.UnaSolaCopia";

// C'è già una copia dell'app ([mutex] esisteva). Se si sta chiudendo (X
// appena premuta, uscita in corso, finestra già distrutta) si aspetta che
// finisca, fino a 15 s: true = questa copia può partire ([mutex] è ora il
// suo). false = la copia aperta resta: le si passa il primo piano. Prima
// la nuova copia la portava in primo piano e si chiudeva anche mentre
// quella si stava chiudendo: non restava aperto niente.
bool WaitForClosingCopy(HANDLE& mutex) {
  const ULONGLONG deadline = ::GetTickCount64() + 15000;
  while (true) {
    HWND window = FindRunningWindow();
    const ULONG_PTR state = window != nullptr ? ClosingState(window) : 0;
    if (window != nullptr && state == 0) return false;
    if (::GetTickCount64() > deadline) {
      // X premuta e l'app non ha ancora deciso: resta quella; ferma in
      // uscita (o senza finestra): si parte comunque
      return state != kClosingAsked;
    }
    ::Sleep(25);
    ::CloseHandle(mutex);
    mutex = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (mutex == nullptr) return true;
    if (::GetLastError() != ERROR_ALREADY_EXISTS) {
      TraceWindow("copia precedente chiusa: avvio");
      return true;
    }
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Prima di tutto (prima di qualsiasi finestra, anche dell'avviso di
  // errore e della schermata di --disinstalla): l'AUMID del processo è
  // quello del collegamento nel menu Start e dei toast, così la barra delle
  // applicazioni li tratta come la stessa app. Solo senza identità di
  // pacchetto: nel pacchetto MSIX l'AUMID lo decide il pacchetto. Le copie
  // che si chiudono subito (ritorno dal browser, seconda copia) non creano
  // finestre: per loro non cambia nulla.
  ApplyProcessAumid();

  // Avviata da un collegamento uninotes: con l'app già aperta: torna in
  // primo piano quella e questa copia si chiude; con l'app chiusa si apre
  // normalmente, ma senza argomenti. Un indirizzo con le virgolette
  // (`uninotes:x" --disinstalla`, aperto da un'app che non le codifica)
  // diventerebbe più argomenti e avvierebbe la schermata di
  // disinstallazione: l'app non usa mai gli argomenti di un collegamento.
  const bool from_link = FromLink(GetCommandLineArguments());
  if (from_link && FocusRunningWindow()) {
    return EXIT_SUCCESS;
  }
  const std::vector<std::string> launch_args =
      from_link ? std::vector<std::string>() : GetCommandLineArguments();

  // Una sola copia dell'app: una seconda (es. l'icona cliccata di nuovo
  // mentre UniNotes è nell'area di notifica) aprirebbe lo stesso database,
  // la stessa sincronizzazione e lo stesso registratore insieme alla prima
  // («database is locked», file scritti da due processi). Riporta in primo
  // piano la finestra già aperta e si chiude; se quella si sta chiudendo
  // (X appena premuta) aspetta che finisca e si apre al suo posto. La
  // pulizia avviata dal disinstallatore (--disinstalla, vedi
  // uninstall_mode.dart) è esclusa.
  HANDLE single_instance = nullptr;
  if (!HasArg(launch_args, "--disinstalla")) {
    single_instance = ::CreateMutexW(nullptr, FALSE, kSingleInstanceMutex);
    if (single_instance != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS &&
        !WaitForClosingCopy(single_instance)) {
      FocusRunningWindow();
      if (single_instance != nullptr) ::CloseHandle(single_instance);
      return EXIT_SUCCESS;
    }
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments = launch_args;

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  {
    FlutterWindow window(project);
    Win32Window::Point origin(10, 10);
    Win32Window::Size size(1280, 800);
    if (!window.Create(L"UniNotes", origin, size)) {
      // motore di Flutter non creato (file dell'app mancanti o danneggiati,
      // es. data\app.so o flutter_assets): un avviso invece di chiudersi
      // senza dire nulla
      ::MessageBoxW(nullptr,
                    L"UniNotes non si è avviato: alcuni file dell'app "
                    L"mancano o sono danneggiati. Reinstalla UniNotes.",
                    L"UniNotes", MB_OK | MB_ICONERROR);
      if (single_instance != nullptr) ::CloseHandle(single_instance);
      return EXIT_FAILURE;
    }
    window.SetQuitOnClose(true);

    ::MSG msg;
    while (::GetMessage(&msg, nullptr, 0, 0)) {
      ::TranslateMessage(&msg);
      ::DispatchMessage(&msg);
    }
    TraceWindow("fine del ciclo dei messaggi");
    // in uscita: niente finestra sullo schermo mentre si chiude il motore,
    // e una copia avviata adesso aspetta invece di passarle gli argomenti
    if (HWND hwnd = window.GetHandle()) {
      ::SetPropW(hwnd, kClosingProp, reinterpret_cast<HANDLE>(kClosingQuit));
      ::ShowWindow(hwnd, SW_HIDE);
    }
  }
  // motore chiuso e finestra distrutta: solo ora una nuova copia può
  // partire (prima la copia unica si liberava con il motore ancora aperto)

  ::CoUninitialize();
  if (single_instance != nullptr) ::CloseHandle(single_instance);
  if (WindowTraceFile() != nullptr) {
    atexit([]() { TraceWindow("uscita del processo"); });
  }
  return EXIT_SUCCESS;
}
