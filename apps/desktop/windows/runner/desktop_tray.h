#pragma once
#include <windows.h>
#include <shellapi.h>
#include <optional>

// Window lifecycle only. This class never sends VPN service commands.
class DesktopTray {
 public:
  explicit DesktopTray(HWND window);
  ~DesktopTray();
  bool SetEnabled(bool enabled);
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);
 private:
  bool AddIcon();
  void ShowWindowAgain();
  void ShowMenu();
  HWND window_;
  NOTIFYICONDATAW icon_{};
  UINT taskbar_created_;
  bool enabled_ = false;
  bool registered_ = false;
};
