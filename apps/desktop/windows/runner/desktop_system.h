#pragma once
#include <flutter/method_channel.h>
#include <flutter/encodable_value.h>
#include <windows.h>
#include <memory>
#include "desktop_tray.h"

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
CreateDesktopSystem(flutter::BinaryMessenger* messenger, HWND window, DesktopTray* tray);
