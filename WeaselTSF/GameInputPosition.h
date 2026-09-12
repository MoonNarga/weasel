#pragma once

#include <windows.h>
#include <imm.h>
#include <cstdio>

#pragma comment(lib, "imm32.lib")

namespace game_input {

inline bool ClientBounds(HWND window, RECT& bounds) {
  if (!window || !GetClientRect(window, &bounds) ||
      bounds.right <= 32 || bounds.bottom <= 32)
    return false;
  POINT start = {bounds.left, bounds.top};
  POINT end = {bounds.right, bounds.bottom};
  if (!ClientToScreen(window, &start) || !ClientToScreen(window, &end))
    return false;
  bounds = {start.x, start.y, end.x, end.y};
  return true;
}

inline bool IsGameWindow(HWND window) {
  DWORD process = 0;
  RECT bounds = {};
  GetWindowThreadProcessId(window, &process);
  return process == GetCurrentProcessId() && ClientBounds(window, bounds) &&
         !(GetWindowLongPtr(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW);
}

inline HWND FindGameWindow(HWND contextWindow) {
  HWND window = GetForegroundWindow();
  if (IsGameWindow(window))
    return window;
  window = GetAncestor(contextWindow, GA_ROOT);
  if (IsGameWindow(window))
    return window;
  // TSF can give us VALVEIME001, a zero-sized helper, rather than SDL_app.
  struct Search {
    HWND window = nullptr;
    LONGLONG area = 0;
  } search;
  EnumWindows([](HWND candidate, LPARAM param) -> BOOL {
    auto& result = *reinterpret_cast<Search*>(param);
    RECT bounds = {};
    if (IsWindowVisible(candidate) && !IsIconic(candidate) &&
        IsGameWindow(candidate) && ClientBounds(candidate, bounds)) {
      LONGLONG area = LONGLONG(bounds.right - bounds.left) *
                      (bounds.bottom - bounds.top);
      if (area > result.area) {
        result.window = candidate;
        result.area = area;
      }
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&search));
  return search.window;
}

inline bool UsableTextRect(const RECT& text, const RECT& client) {
  // Zero-width carets are valid. Empty/reversed extents, coordinates outside
  // the game, and dummy extents at its top-left corner are not chat carets.
  return text.right >= text.left && text.bottom > text.top &&
         text.left >= client.left && text.top >= client.top &&
         text.left < client.right && text.right <= client.right &&
         text.bottom <= client.bottom &&
         (text.left >= client.left + 16 || text.top >= client.top + 16);
}

inline bool ToScreen(HWND window, RECT& rect) {
  POINT start = {rect.left, rect.top};
  POINT end = {rect.right, rect.bottom};
  if (!ClientToScreen(window, &start) || !ClientToScreen(window, &end))
    return false;
  rect = {start.x, start.y, end.x, end.y};
  return true;
}

inline bool NativeCaret(HWND window, const RECT& bounds, RECT& rect) {
  GUITHREADINFO info = {sizeof(info)};
  if (!GetGUIThreadInfo(GetWindowThreadProcessId(window, nullptr), &info) ||
      !info.hwndCaret || GetAncestor(info.hwndCaret, GA_ROOT) != window)
    return false;
  rect = info.rcCaret;
  return ToScreen(info.hwndCaret, rect) && UsableTextRect(rect, bounds);
}

inline bool ImmPosition(HWND window, const RECT& bounds, RECT& rect) {
  HIMC context = ImmGetContext(window);
  if (!context)
    return false;
  bool found = false;
  CANDIDATEFORM candidate = {};
  if (ImmGetCandidateWindow(context, 0, &candidate) &&
      (candidate.dwStyle == CFS_CANDIDATEPOS ||
       candidate.dwStyle == CFS_EXCLUDE)) {
    const POINT& point = candidate.ptCurrentPos;
    rect = {point.x, point.y, point.x, point.y + 1};
    if (candidate.dwStyle == CFS_EXCLUDE &&
        candidate.rcArea.bottom > rect.bottom)
      rect.bottom = candidate.rcArea.bottom;
    found = ToScreen(window, rect) && UsableTextRect(rect, bounds);
  }
  COMPOSITIONFORM composition = {};
  if (!found && ImmGetCompositionWindow(context, &composition) &&
      (composition.dwStyle & (CFS_POINT | CFS_FORCE_POSITION | CFS_RECT))) {
    const POINT& point = composition.ptCurrentPos;
    rect = {point.x, point.y, point.x, point.y + 1};
    found = ToScreen(window, rect) && UsableTextRect(rect, bounds);
  }
  ImmReleaseContext(window, context);
  return found;
}

inline void Trace(HWND window, HRESULT result, const RECT& raw,
                  const RECT& selected, const char* source) {
  static const bool enabled = [] {
    DWORD value = 0, size = sizeof(value);
    return RegGetValueW(HKEY_CURRENT_USER, L"Software\\Rime\\Weasel",
                        L"TraceDotaPosition", RRF_RT_REG_DWORD, nullptr,
                        &value, &size) == ERROR_SUCCESS && value != 0;
  }();
  static thread_local unsigned count = 0;
  if (!enabled || count++ >= 256)
    return;
  // Only coordinates and API status are recorded; no input or candidates.
  char line[384] = {};
  int length = _snprintf_s(line, _TRUNCATE,
      "tick=%lu thread=%lu window=%p GetTextExt=0x%08lx "
      "raw=(%ld,%ld,%ld,%ld) source=%s selected=(%ld,%ld,%ld,%ld)\r\n",
      GetTickCount(), GetCurrentThreadId(), window, result,
      raw.left, raw.top, raw.right, raw.bottom, source,
      selected.left, selected.top, selected.right, selected.bottom);
  if (length <= 0)
    return;
  wchar_t temp[MAX_PATH] = {}, directory[MAX_PATH] = {}, path[MAX_PATH] = {};
  DWORD size = GetTempPathW(_countof(temp), temp);
  if (!size || size >= _countof(temp) ||
      _snwprintf_s(directory, _TRUNCATE, L"%srime.weasel", temp) < 0 ||
      _snwprintf_s(path, _TRUNCATE, L"%s\\dota2-position-%lu.log",
                   directory, GetCurrentProcessId()) < 0)
    return;
  CreateDirectoryW(directory, nullptr);
  HANDLE file = CreateFileW(path, FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    DWORD written = 0;
    WriteFile(file, line, length, &written, nullptr);
    CloseHandle(file);
  }
}

}  // namespace game_input
