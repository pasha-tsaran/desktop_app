#include "desktop_tray.h"
#include <cstdio>

int main() {
  const auto instance = GetModuleHandleW(nullptr);
  WNDCLASSW cls{};
  cls.hInstance = instance;
  cls.lpfnWndProc = DefWindowProcW;
  cls.lpszClassName = L"KenaiTrayIsolatedTest";
  if (!RegisterClassW(&cls)) return 1;
  const HWND window = CreateWindowW(cls.lpszClassName, L"Kenai tray isolated test",
      WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, nullptr, nullptr, instance, nullptr);
  if (!window) return 2;
  int failure = 0;
  {
    DesktopTray tray(window);
    if (tray.HandleMessage(WM_CLOSE, 0, 0).has_value()) failure = 3;
    if (!tray.SetEnabled(true)) failure = 4;
    if (!tray.SetEnabled(true)) failure = 5; // idempotent, no duplicate icon
    if (!tray.HandleMessage(WM_CLOSE, 0, 0).has_value()) failure = 6;
    if (IsWindowVisible(window)) failure = 7;
    // Simulate a click; this touches only our isolated test window.
    tray.HandleMessage(WM_APP + 42, 0, NIN_SELECT);
    if (!IsWindowVisible(window)) failure = 8;
    ShowWindow(window, SW_MINIMIZE);
    if (tray.HandleMessage(WM_SIZE, SIZE_MINIMIZED, 0).has_value()) failure = 9;
    if (!IsWindowVisible(window) || !IsIconic(window)) failure = 13;
    tray.HandleMessage(WM_APP + 42, 0, NIN_SELECT);
    if (!IsWindowVisible(window) || IsIconic(window)) failure = 14;
    tray.HandleMessage(WM_CLOSE, 0, 0);
    if (!tray.SetEnabled(false)) failure = 10;
    if (!IsWindowVisible(window)) failure = 11;
    if (tray.HandleMessage(WM_CLOSE, 0, 0).has_value()) failure = 12;
    ShowWindow(window, SW_MINIMIZE);
    tray.HandleMessage(WM_SIZE, SIZE_MINIMIZED, 0);
    if (!IsWindowVisible(window) || !IsIconic(window)) failure = 15;
  }
  DestroyWindow(window);
  UnregisterClassW(cls.lpszClassName, instance);
  std::printf("tray_native_test:%s (%d)\n", failure ? "FAILED" : "OK", failure);
  return failure;
}
