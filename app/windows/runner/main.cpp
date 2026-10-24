#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "notification_identity.h"
#include "utils.h"

namespace {

// Ritorno dall'accesso nel browser (OneDrive, Google Drive): la pagina del
// server locale apre «uninotes://auth» e Windows avvia una seconda copia
// dell'app con l'indirizzo come argomento. Se UniNotes è già aperto la sua
// finestra torna in primo piano (questa copia, avviata dal browser in primo
// piano, ha il permesso di farlo) e la seconda copia si chiude senza aprire
// un altro database. Vedi lib/core/services/app_return.dart.
// Porta in primo piano la finestra di UniNotes già aperta; false se non
// c'è.
bool FocusRunningWindow() {
  HWND window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"UniNotes");
  if (window == nullptr) {
    window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  }
  if (window == nullptr) return false;
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
  return true;
}

bool ReturnToRunningApp(const std::vector<std::string>& args) {
  bool from_link = false;
  for (const auto& a : args) {
    if (a.rfind("uninotes:", 0) == 0) from_link = true;
  }
  if (!from_link) return false;
  return FocusRunningWindow();  // app chiusa: si apre normalmente
}

bool HasArg(const std::vector<std::string>& args, const char* arg) {
  for (const auto& a : args) {
    if (a == arg) return true;
  }
  return false;
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

  const std::vector<std::string> launch_args = GetCommandLineArguments();
  if (ReturnToRunningApp(launch_args)) {
    return EXIT_SUCCESS;
  }

  // Una sola copia dell'app: una seconda (es. l'icona cliccata di nuovo
  // mentre UniNotes è nell'area di notifica) aprirebbe lo stesso database,
  // la stessa sincronizzazione e lo stesso registratore insieme alla prima
  // («database is locked», file scritti da due processi). Riporta in primo
  // piano la finestra già aperta e si chiude. La pulizia avviata dal
  // disinstallatore (--disinstalla, vedi uninstall_mode.dart) è esclusa.
  HANDLE single_instance = nullptr;
  if (!HasArg(launch_args, "--disinstalla")) {
    single_instance =
        ::CreateMutexW(nullptr, FALSE, L"Local\\UniNotes.UnaSolaCopia");
    if (single_instance != nullptr &&
        ::GetLastError() == ERROR_ALREADY_EXISTS) {
      FocusRunningWindow();
      ::CloseHandle(single_instance);
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

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

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

  ::CoUninitialize();
  if (single_instance != nullptr) ::CloseHandle(single_instance);
  return EXIT_SUCCESS;
}
