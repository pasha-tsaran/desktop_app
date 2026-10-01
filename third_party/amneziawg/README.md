# AmneziaWG Windows payload

Kenai VPN pins the official AmneziaWG Windows 3.1.0 amd64 payload. The
application does not download or replace these files at runtime.

- Upstream: https://github.com/amnezia-vpn/amneziawg-windows-client
- Tag and source commit: `3.1.0` / `ca5dd3b983bd19c335ab095ccd21fc2f804ec968`
- Release asset: `amneziawg-amd64-3.1.0.msi`
- Published and locally verified MSI SHA-256:
  `a1b48ea8699cd347832a3691d832004574ef8ad65bcf887611ac8acb99b7de8b`
- MSI Authenticode signer: `Privacy Technologies OU` (valid when acquired)

Pinned extracted files:

| File | SHA-256 | Authenticode signer |
| --- | --- | --- |
| `amneziawg.exe` | `ba446f6e1a4093e43a65d6ff45f4b8c7b6485dc419327eedaa1a218549740e3a` | Privacy Technologies OU |
| `awg.exe` | `272badace73caeb26dc42656f318b3eb7f10028c2f76faad1f52d6fe1e0ced12` | Privacy Technologies OU |
| `wintun.dll` | `e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce` | WireGuard LLC |

`LICENSE-amneziawg-windows.txt` is the upstream MIT license. `LICENSE-wintun.txt`
is the license shipped with the pinned Wintun binary. Redistribution of Wintun
is only as a component used through its permitted API; do not redistribute it
as a standalone payload.

The 3.1.0 Windows release embeds `amneziawg-go/v3` and
`amneziawg-windows/v3` at `v3.1.20260814`. Kenai accepts both legacy 2.0
profiles and the additional 3.1 obfuscation fields; Armenia can therefore
remain on 2.0 while the Netherlands uses 3.1. Live connectivity must still be
checked after installation.
