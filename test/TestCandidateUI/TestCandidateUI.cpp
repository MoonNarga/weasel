#include "stdafx.h"
#include "WeaselTSF.h"
#include "CandidateList.h"
#include "ResponseParser.h"
#include "GameInputPosition.h"
#include <iostream>
#include <stdexcept>

static void Check(bool ok, const char* message) {
  if (!ok)
    throw std::runtime_error(message);
}

static RECT candidateRect = {};

static BOOL CALLBACK CountCandidateWindows(HWND window, LPARAM count) {
  DWORD process = 0;
  GetWindowThreadProcessId(window, &process);
  RECT rect = {};
  const auto style = GetWindowLongPtr(window, GWL_EXSTYLE);
  if (process == GetCurrentProcessId() && IsWindowVisible(window) &&
      (style & WS_EX_NOACTIVATE) && (style & WS_EX_TOOLWINDOW) &&
      GetWindowRect(window, &rect) && rect.right > rect.left &&
      rect.bottom > rect.top) {
    ++*reinterpret_cast<int*>(count);
    candidateRect = rect;
  }
  return TRUE;
}

static int VisibleCandidates() {
  int count = 0;
  EnumWindows(CountCandidateWindows, reinterpret_cast<LPARAM>(&count));
  return count;
}

int main(int argc, char** argv) {
  // Run once as dota2.exe with an argument and once under a different name
  // without one. No TSF UI manager is provided: only the compatibility path
  // may create a window. This test never sends input to the actual game.
  const bool game = argc > 1 && std::string(argv[1]) == "--game";
  CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  g_hInst = GetModuleHandle(nullptr);
  InitializeCriticalSection(&g_cs);
  try {
    if (argc > 1 && std::string(argv[1]) == "--ipc") {
      weasel::Client client;
      Check(client.Connect(), "cannot connect to installed server");
      client.StartSession();
      weasel::UIStyle style;
      weasel::Status status;
      weasel::ResponseParser parser(nullptr, nullptr, &status, nullptr, &style);
      const bool parsed = client.GetResponseData(std::ref(parser));
      client.EndSession();
      client.Disconnect();
      Check(parsed && style.font_point > 0,
            "installed server style cannot be deserialized");
      std::cout << "PASS: installed server IPC and style deserialization\n";
      return 0;
    }
    com_ptr<WeaselTSF> service;
    service.Attach(new WeaselTSF());
    HWND host = CreateWindowExW(0, L"STATIC", L"Candidate UI test",
                                WS_POPUP, 240, 160, 800, 600, nullptr, nullptr,
                                GetModuleHandle(nullptr), nullptr);
    Check(host != nullptr, "cannot create test host");
    HWND helper = CreateWindowExW(0, L"STATIC", L"Zero-sized IME helper",
                                  WS_POPUP, 0, 0, 0, 0, host, nullptr,
                                  GetModuleHandle(nullptr), nullptr);
    Check(helper != nullptr && !game_input::IsGameWindow(helper),
          "zero-sized IME helper accepted as game window");
    Check(game_input::FindGameWindow(host) == host,
          "game window not resolved from input context");
    SetFocus(host);
    Check(GetFocus() == host, "cannot focus test host");
    CCandidateList candidates(service);
    auto& style = candidates.style();
    style.font_face = style.label_font_face = style.comment_font_face =
        L"Microsoft YaHei";
    style.font_point = style.label_font_point = style.comment_font_point = 14;
    style.margin_x = style.margin_y = 8;
    style.min_width = 160;
    style.min_height = 40;
    style.back_color = 0xffffffff;
    style.text_color = style.candidate_text_color = 0xff000000;

    weasel::Context context;
    context.preedit.str = L"nihao";
    context.cinfo.candies = {weasel::Text(L"你好"), weasel::Text(L"您好")};
    context.cinfo.labels = {weasel::Text(L"1"), weasel::Text(L"2")};
    context.cinfo.comments.resize(2);
    weasel::Status status;
    status.composing = true;

    for (int cycle = 0; cycle < 4; ++cycle) {
      candidates.StartUI();
      candidates.StartUI();  // duplicate start must not create another HWND
      candidates.UpdateUI(context, status);
      BOOL shown = FALSE;
      candidates.IsShown(&shown);
      Check(!!shown == game, "unexpected candidate visibility");
      Check(VisibleCandidates() == (game ? 1 : 0),
            "candidate HWND missing, empty, or duplicated");
      if (game) {
        RECT hostRect = {};
        GetWindowRect(host, &hostRect);
        Check(candidateRect.left >= hostRect.left &&
                  candidateRect.top >= hostRect.top &&
                  candidateRect.right <= hostRect.right &&
                  candidateRect.bottom <= hostRect.bottom,
              "fallback position is outside the host window");
        RECT dummy = {};
        RECT before = candidateRect;
        candidates.UpdateInputPosition(dummy);
        VisibleCandidates();
        Check(EqualRect(&before, &candidateRect),
              "dummy text extent displaced fallback window");
        const RECT invalid[] = {
            {-1, -1, 0, 0},
            {1, 1, 2, 20},
            {hostRect.left + 1, hostRect.top + 1,
             hostRect.left + 2, hostRect.top + 20},
            {hostRect.left + 100, hostRect.top + 100,
             hostRect.left + 100, hostRect.top + 100},
            {hostRect.right + 20, hostRect.bottom + 20,
             hostRect.right + 21, hostRect.bottom + 40}};
        for (const auto& rect : invalid) {
          candidates.UpdateInputPosition(rect);
          candidates.UpdateUI(context, status);
          VisibleCandidates();
          Check(EqualRect(&before, &candidateRect),
                "invalid/nonzero text extent displaced fallback window");
        }
        RECT valid = {hostRect.left + 100, hostRect.top + 250,
                      hostRect.left + 100, hostRect.top + 270};
        candidates.UpdateGameTextExtent(S_OK, valid);
        candidates.UpdateUI(context, status);
        VisibleCandidates();
        Check(candidateRect.left == valid.left &&
                  candidateRect.top >= valid.bottom &&
                  candidateRect.top <= valid.bottom + 12,
              "valid TSF caret not followed");
        candidates.UpdateGameTextExtent(TF_E_NOLAYOUT, valid);
        VisibleCandidates();
        Check(EqualRect(&before, &candidateRect),
              "failed GetTextExt reused its output rectangle");

        HIMC input = ImmCreateContext();
        Check(input != nullptr, "cannot create test IMM context");
        HIMC previous = ImmAssociateContext(host, input);
        CANDIDATEFORM form = {0, CFS_EXCLUDE, {320, 300},
                              {320, 300, 322, 320}};
        Check(ImmSetCandidateWindow(input, &form), "cannot set test IMM position");
        candidates.UpdateGameTextExtent(TF_E_NOLAYOUT, {});
        candidates.UpdateUI(context, status);
        VisibleCandidates();
        Check(candidateRect.left == hostRect.left + form.ptCurrentPos.x &&
                  candidateRect.top >= hostRect.top + form.rcArea.bottom &&
                  candidateRect.top <= hostRect.top + form.rcArea.bottom + 12,
              "IMM exclusion-area caret not followed");
        ImmAssociateContext(host, previous);
        ImmDestroyContext(input);

        Check(CreateCaret(host, nullptr, 1, 20), "cannot create native test caret");
        Check(SetCaretPos(150, 220), "cannot position native test caret");
        candidates.UpdateGameTextExtent(TF_E_NOLAYOUT, {});
        VisibleCandidates();
        Check(candidateRect.left == hostRect.left + 150 &&
                  candidateRect.top >= hostRect.top + 240 &&
                  candidateRect.top <= hostRect.top + 252,
              "native caret not followed");
        DestroyCaret();

        SetWindowPos(host, nullptr, 280, 200, 900, 640,
                     SWP_NOACTIVATE | SWP_NOZORDER);
        candidates.UpdateUI(context, status);
        VisibleCandidates();
        RECT movedHost = {};
        GetWindowRect(host, &movedHost);
        Check(candidateRect.left > before.left && candidateRect.top > before.top &&
                  candidateRect.right <= movedHost.right &&
                  candidateRect.bottom <= movedHost.bottom,
              "fallback did not follow moved/resized host");
        SetWindowPos(host, nullptr, 240, 160, 800, 600,
                     SWP_NOACTIVATE | SWP_NOZORDER);
        candidates.UpdateUI(context, status);
      }
      UINT count = 0;
      candidates.GetCount(&count);
      Check(count == 2, "candidate data lost");
      DWORD flags = 0;
      candidates.GetUpdatedFlags(&flags);
      Check(flags & TF_CLUIE_PAGEINDEX, "page-index notification missing");
      if (cycle == 0)
        candidates.Destroy();
      else if (cycle == 1)
        candidates.EndUI();
      else
        candidates.DestroyAll();
      candidates.IsShown(&shown);
      Check(!shown && VisibleCandidates() == 0, "candidate window not closed");
    }
    RECT negativeMonitor = {-1920, -1080, 0, 0};
    RECT negativeCaret = {-1000, -500, -1000, -480};
    Check(game_input::UsableTextRect(negativeCaret, negativeMonitor),
          "valid caret on a negative-coordinate monitor rejected");
    DestroyWindow(helper);
    DestroyWindow(host);
    std::cout << "PASS: " << (game ? "Dota fallback" : "normal application")
              << ", lifecycle/data, invalid extents, TSF/IMM/native caret, "
                 "moved window, negative monitor coordinates\n";
  } catch (const std::exception& error) {
    std::cerr << "FAIL: " << error.what() << '\n';
    return 1;
  }
  DeleteCriticalSection(&g_cs);
  CoUninitialize();
  return 0;
}
