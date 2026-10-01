# Xray-core Windows payload — Kenai compatibility build

This is a **Kenai compatibility build**, not an unmodified official binary.
Base: XTLS/Xray-core v26.9.9, commit 52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120.
Source: https://github.com/XTLS/Xray-core/tree/52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120

## Change and source availability

source/tun_windows.go is the complete modified MPL-2.0 source file. It skips
Windows configuration for an IP family only when that family has no requested
address, route or DNS server. This permits IPv4-only TUN setup with OS-disabled
IPv6. Explicit IPv6 configuration still requires successful IPv6 setup.
source/kenai_windows_test.go contains regression and opt-in native adapter tests.
Other upstream source files are unchanged and available at the pinned URL above.
The modified source and this notice ship in the installer's licenses/xray folder.

Kenai's service installs a temporary non-loopback IPv6 egress block BEFORE
starting an IPv4-only tunnel. Omitting IPv6 configuration alone is not protection.

## Rebuild and verification

Use tool/build-xray-compat.ps1 in the client source tree with Go 1.27.1 Windows
amd64. It verifies the source revision, applies the supplied files, tests and
builds with the official release flags. Build marker: kenai-ipv4-1.
The app never downloads or replaces its engines at runtime.

xray.exe SHA-256:
6b5cd540e3f4ce59f309863f0f1339b0bda13aeb9451405abfca29ba873cca20
This locally compiled executable is unsigned. Service and packaging verify the
exact digest; do not describe this binary as signed or an official release asset.

Go archive: https://go.dev/dl/go1.27.1.windows-amd64.zip
SHA-256: a3911b5e0e1b1053f25ed0675f4c1c6aad1e2bfcf253df2b9be4caabd2edd95d

The unchanged Wintun 0.14.1 DLL is signed by WireGuard LLC. SHA-256:
e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce
It comes from official v26.9.9 Xray-windows-64.zip, archive SHA-256:
244deaba2098c2964e49bba90df3707777e5f5f428a82d2f29604015f24beec2

LICENSE-xray-core.txt is MPL-2.0. LICENSE-wintun.txt contains Wintun's upstream
redistribution terms. Wintun is bundled only as an application component.
