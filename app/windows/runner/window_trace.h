#ifndef RUNNER_WINDOW_TRACE_H_
#define RUNNER_WINDOW_TRACE_H_

#include <windows.h>

#include <share.h>

#include <cstdarg>
#include <cstdio>

// Traccia dei tempi della finestra (ripristino, chiusura) per le misure con
// lo script di prova: scritta solo se la variabile d'ambiente
// UNINOTES_TRACCIA_FINESTRA indica un file, altrimenti non fa nulla. Una
// riga per evento: millisecondi dal 1/1/1970 (come time.time() di Python),
// processo, testo. Vedi docs/registratore.md.
inline FILE* WindowTraceFile() {
  static FILE* file = []() -> FILE* {
    wchar_t path[MAX_PATH];
    const DWORD n =
        ::GetEnvironmentVariableW(L"UNINOTES_TRACCIA_FINESTRA", path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return nullptr;
    // condiviso: ci scrive anche il lato Dart (desktop_window.dart)
    return _wfsopen(path, L"a", _SH_DENYNO);
  }();
  return file;
}

inline void TraceWindow(const char* format, ...) {
  FILE* f = WindowTraceFile();
  if (f == nullptr) return;
  FILETIME ft;
  ::GetSystemTimePreciseAsFileTime(&ft);
  ULARGE_INTEGER t;
  t.LowPart = ft.dwLowDateTime;
  t.HighPart = ft.dwHighDateTime;
  // da intervalli di 100 ns dal 1601 a millisecondi dal 1970
  const double ms = (t.QuadPart - 116444736000000000ULL) / 10000.0;
  char text[256];
  va_list args;
  va_start(args, format);
  vsnprintf(text, sizeof(text), format, args);
  va_end(args);
  fprintf(f, "%.3f %lu %s\n", ms, ::GetCurrentProcessId(), text);
  fflush(f);
}

#endif  // RUNNER_WINDOW_TRACE_H_
