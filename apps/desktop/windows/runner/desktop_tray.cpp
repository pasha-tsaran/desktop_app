#include "desktop_tray.h"
#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 42;
constexpr UINT kOpen = 1;
constexpr UINT kExit = 2;
}

DesktopTray::DesktopTray(HWND window)
    : window_(window), taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")) {
  icon_.cbSize = sizeof(icon_);
  icon_.hWnd = window_;
  icon_.uID = 1;
  icon_.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  icon_.uCallbackMessage = kTrayMessage;
  icon_.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  wcscpy_s(icon_.szTip, L"Kenai VPN - открыть приложение");
}

DesktopTray::~DesktopTray() {
  if (registered_) Shell_NotifyIconW(NIM_DELETE, &icon_);
}

bool DesktopTray::AddIcon() {
  registered_ = Shell_NotifyIconW(NIM_ADD, &icon_) != FALSE;
  if (registered_) {
    icon_.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &icon_);
  }
  return registered_;
}

bool DesktopTray::SetEnabled(bool enabled) {
  if (enabled) {
    if (!registered_ && !AddIcon()) return false;
    enabled_ = true;
  } else {
    enabled_ = false;
    // Restore a hidden window before removing its only visible entry point.
    if (!IsWindowVisible(window_)) ShowWindowAgain();
    if (registered_) Shell_NotifyIconW(NIM_DELETE, &icon_);
    registered_ = false;
  }
  return true;
}

void DesktopTray::ShowWindowAgain() {
  ShowWindow(window_, IsIconic(window_) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(window_);
}

void DesktopTray::ShowMenu() {
  HMENU menu = CreatePopupMenu();
  if (!menu) return;
  AppendMenuW(menu, MF_STRING, kOpen, L"Открыть Kenai VPN");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kExit, L"Выйти из приложения");
  SetMenuDefaultItem(menu, kOpen, FALSE);
  POINT position{};
  GetCursorPos(&position);
  SetForegroundWindow(window_);
  const UINT selected = static_cast<UINT>(TrackPopupMenu(menu,
      TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      position.x, position.y, 0, window_, nullptr));
  DestroyMenu(menu);
  PostMessageW(window_, WM_NULL, 0, 0);
  if (selected == kOpen) ShowWindowAgain();
  if (selected == kExit) {
    if (MessageBoxW(window_,
        L"Закрыть приложение? VPN-служба и текущее соединение продолжат работу. "
        L"Автоматическое переподключение требует запущенного приложения.",
        L"Kenai VPN", MB_YESNO | MB_ICONQUESTION | MB_DEFBUTTON2) == IDYES) {
      SetEnabled(false);
      PostMessageW(window_, WM_CLOSE, 0, 0);
    }
  }
}

std::optional<LRESULT> DesktopTray::HandleMessage(UINT message, WPARAM, LPARAM lparam) {
  if (taskbar_created_ != 0 && message == taskbar_created_ && enabled_) {
    registered_ = false;
    // Explorer restarted: recreate the icon, or make the app accessible again.
    if (!AddIcon()) ShowWindowAgain();
    return 0;
  }
  if (message == kTrayMessage && enabled_) {
    switch (LOWORD(lparam)) {
      case NIN_SELECT:
      case NIN_KEYSELECT:
      case WM_LBUTTONDBLCLK:
        ShowWindowAgain();
        break;
      case WM_CONTEXTMENU:
      case WM_RBUTTONUP:
        ShowMenu();
        break;
    }
    return 0;
  }
  if (enabled_ && registered_) {
    if (message == WM_CLOSE) {
      ShowWindow(window_, SW_HIDE);
      return 0;
    }
    // Normal minimization must retain the taskbar entry. Only Close hides to tray.
  }
  return std::nullopt;
}
