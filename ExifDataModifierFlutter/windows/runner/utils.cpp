#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>

// Redirects stdout/stderr to the currently attached console.
// Must be called AFTER a successful AttachConsole or AllocConsole.
static void RedirectIOToConsole() {
  FILE *unused;
  freopen_s(&unused, "CONOUT$", "w", stdout);
  freopen_s(&unused, "CONOUT$", "w", stderr);
  freopen_s(&unused, "CONIN$",  "r", stdin);
  std::ios::sync_with_stdio(true);
  FlutterDesktopResyncOutputStreams();
}

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    RedirectIOToConsole();
  }
}

bool AttachParentConsole() {
  // If stdout is already a Pipe, Flutter CLI is capturing our output for its
  // log reader (to detect the Dart VM Service port). Calling AttachConsole()
  // would reassign the stdout handle to the console buffer and break the pipe,
  // causing: "Error waiting for a debug connection: The log reader stopped
  // unexpectedly, or never started."
  // In that case, do NOT attach to the parent console at all.
  HANDLE hStdOut = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (hStdOut != INVALID_HANDLE_VALUE && hStdOut != nullptr) {
    DWORD fileType = ::GetFileType(hStdOut);
    if (fileType == FILE_TYPE_PIPE) {
      // Already connected to Flutter CLI pipe — leave it alone.
      return true;
    }
  }

  if (::AttachConsole(ATTACH_PARENT_PROCESS)) {
    RedirectIOToConsole();
    return true;
  }
  return false;
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length <= 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
