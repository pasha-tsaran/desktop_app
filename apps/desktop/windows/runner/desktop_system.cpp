#include <winsock2.h>
#include <iphlpapi.h>
#include <flutter/standard_method_codec.h>
#include <algorithm>
#include <sstream>
#include <optional>
#include <string>
#include <vector>
#include "desktop_system.h"

namespace {
LONG SetStartup(bool enabled) {
  HKEY key = nullptr;
  LONG status = RegCreateKeyExW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0, nullptr, 0,
      KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) return status;
  if (enabled) {
    std::vector<wchar_t> path(32768);
    const DWORD length = GetModuleFileNameW(nullptr, path.data(),
        static_cast<DWORD>(path.size()));
    if (length == 0 || length >= path.size()) {
      RegCloseKey(key);
      return ERROR_INVALID_NAME;
    }
    const std::wstring command = L"\"" + std::wstring(path.data(), length) + L"\"";
    status = RegSetValueExW(key, L"KenaiVPN", 0, REG_SZ,
        reinterpret_cast<const BYTE*>(command.c_str()),
        static_cast<DWORD>((command.size() + 1) * sizeof(wchar_t)));
  } else {
    status = RegDeleteValueW(key, L"KenaiVPN");
    if (status == ERROR_FILE_NOT_FOUND) status = ERROR_SUCCESS;
  }
  RegCloseKey(key);
  return status;
}

std::optional<std::string> NetworkState() {
  ULONG size = 16384;
  std::vector<unsigned char> buffer(size);
  ULONG status = ERROR_BUFFER_OVERFLOW;
  for (int attempt = 0; attempt < 3 && status == ERROR_BUFFER_OVERFLOW; ++attempt) {
    buffer.resize(size);
    status = GetAdaptersAddresses(AF_UNSPEC, GAA_FLAG_INCLUDE_GATEWAYS,
        nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
  }
  if (status == ERROR_NO_DATA) return std::string();
  if (status != NO_ERROR) return std::nullopt;
  std::vector<std::string> entries;
  for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
      adapter != nullptr; adapter = adapter->Next) {
    // Only physical uplinks; tunnel address/route changes must not trigger a
    // reconnect loop. The fixed Kenai aliases are excluded explicitly too.
    if (adapter->IfType != IF_TYPE_ETHERNET_CSMACD &&
        adapter->IfType != IF_TYPE_IEEE80211) continue;
    const std::wstring name = adapter->FriendlyName ? adapter->FriendlyName : L"";
    if (name.find(L"Kenai") != std::wstring::npos) continue;
    std::ostringstream entry;
    entry << adapter->AdapterName << ':' << adapter->OperStatus << ':';
    for (auto* address = adapter->FirstUnicastAddress; address; address = address->Next) {
      const auto* bytes = reinterpret_cast<const unsigned char*>(address->Address.lpSockaddr);
      for (int i = 0; i < address->Address.iSockaddrLength; ++i) entry << static_cast<int>(bytes[i]) << ',';
    }
    for (auto* gateway = adapter->FirstGatewayAddress; gateway; gateway = gateway->Next) {
      const auto* bytes = reinterpret_cast<const unsigned char*>(gateway->Address.lpSockaddr);
      for (int i = 0; i < gateway->Address.iSockaddrLength; ++i) entry << static_cast<int>(bytes[i]) << ',';
    }
    const auto* guid = reinterpret_cast<const unsigned char*>(&adapter->NetworkGuid);
    for (size_t i = 0; i < sizeof(GUID); ++i) entry << static_cast<int>(guid[i]) << ',';
    entries.push_back(entry.str());
  }
  std::sort(entries.begin(), entries.end());
  std::string result;
  for (const auto& entry : entries) result += entry + ';';
  return result;
}
}  // namespace

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateDesktopSystem(flutter::BinaryMessenger* messenger, HWND window, DesktopTray* tray) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "kenai/system", &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([window, tray](const auto& call, auto result) {
    if (call.method_name() == "trayEnabled") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("INVALID_ARGUMENT"); return; }
      if (!tray->SetEnabled(*enabled)) { result->Error("TRAY_FAILED"); return; }
      result->Success();
      return;
    }
    if (call.method_name() == "launchAtLogin") {
      const auto* enabled = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
      if (!enabled) { result->Error("INVALID_ARGUMENT"); return; }
      if (SetStartup(*enabled) != ERROR_SUCCESS) { result->Error("STARTUP_FAILED"); return; }
      result->Success();
    } else if (call.method_name() == "minimize") {
      ShowWindow(window, SW_MINIMIZE);
      result->Success();
    } else if (call.method_name() == "networkState") {
      const auto state = NetworkState();
      if (!state) { result->Error("NETWORK_QUERY_FAILED"); return; }
      result->Success(flutter::EncodableValue(*state));
    } else { result->NotImplemented(); }
  });
  return channel;
}
