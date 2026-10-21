#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

// Ritorno dall'accesso nel browser (OneDrive, Google Drive): la pagina del
// server locale apre «uninotes://auth» e Windows avvia una seconda copia
// dell'app con l'indirizzo come argomento. Se UniNotes è già aperto la sua
// finestra torna in primo piano (questa copia, avviata dal browser in primo
// piano, ha il permesso di farlo) e la seconda copia si chiude senza aprire
// un altro database. Vedi lib/core/services/app_return.dart.
bool ReturnToRunningApp(const std::vector<std::string>& args) {
  bool from_link = false;
  for (const auto& a : args) {
    if (a.rfind("uninotes:", 0) == 0) from_link = true;
  }
  if (!from_link) return false;
  HWND window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"UniNotes");
  if (window == nullptr) {
    window = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  }
  if (window == nullptr) return false;  // app chiusa: si apre normalmente
  if (::IsIconic(window)) {
    ::ShowWindow(window, SW_RESTORE);
  } else if (!::IsWindowVisible(window)) {
    ::ShowWindow(window, SW_SHOW);
  }
  ::SetForegroundWindow(window);
  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (ReturnToRunningApp(GetCommandLineArguments())) {
    return EXIT_SUCCESS;
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
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
