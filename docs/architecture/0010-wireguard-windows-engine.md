# WireGuard for Windows engine (stage 11)

## Upstream decision

Kenai uses the official WireGuard for Windows `embeddable-dll-service`, the
high-level embedding path recommended by WireGuard. Source is pinned to tag
`v1.1`, commit `378990476748b5038df433f73712bfde859f4d65`, under MIT. The
side-by-side WireGuardNT 1.1 binary comes from `download.wireguard.com`; its
archive and binary hashes and full redistribution license are recorded under
`third_party/wireguard`.

The locally reproducible `tunnel.dll` is not Authenticode-signed. Its exact
SHA-256 is enforced at runtime. `wireguard.dll` has a valid Authenticode
signature from WireGuard LLC and is also hash-pinned. The installer must place
both files under protected Program Files ACLs and sign the Kenai payload in
stage 13.

## Privilege boundary and lifecycle

The GUI cannot create services, load DLLs, edit routes/DNS, or choose paths.
The existing LocalSystem Kenai service performs an allow-listed operation:

1. Load and validate a DPAPI-protected profile by opaque handle.
2. Reject non-WireGuard protocols and the unverified kill-switch option.
3. Verify both payload hashes.
4. Materialize only `ProgramData/KenaiVPN/runtime/KenaiMvp.conf` under a
   SYSTEM/Administrators protected DACL.
5. Create the fixed `WireGuardTunnel$KenaiMvp` on-demand service with `Nsi` and
   `TcpIp` dependencies and `SERVICE_SID_TYPE_UNRESTRICTED`.
6. Wait at most 30 seconds for `Running`, then remove the plaintext config.
7. On disconnect or partial failure, stop/delete only that service and remove
   the fixed temporary files.

The service executable accepts `/wireguard-service` only with the exact fixed
runtime profile path. It verifies payloads again and loads `tunnel.dll` using
restricted DLL search flags. No shell or arbitrary command execution exists.

## State and observability

Successful SCM startup moves the state machine to `Connected`. Safe error codes
cover missing/tampered payloads, unavailable network/server and internal engine
failure without exposing Windows errors or profile content. The version-2 IPC
statistics operation reads Rx/Tx counters and last-handshake FILETIME from the
official WireGuardNT API. It never returns keys or the full driver structure.

Startup performs bounded stale-tunnel cleanup for crash recovery. The real
installer/VM connection tests remain stages 13–14; this stage does not contact
the production API or VPN server.

## Later protocols

AmneziaWG 2.0 and VLESS/REALITY remain separate adapters. They must not reuse
WireGuard DLLs or pretend to be available. Each needs a pinned upstream,
privilege review, protocol-specific health checks and an independent release
gate before the all-protocol minimal MVP is released.
