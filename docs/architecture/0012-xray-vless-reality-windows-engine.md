# Xray VLESS + REALITY Windows engine

Stage 14 adds Xray-core as the third independent Windows VPN engine. It uses
Xray's Windows TUN inbound and a VLESS `xtls-rprx-vision` outbound protected by
REALITY. It is not represented as WireGuard or AmneziaWG.

## Data and privilege boundaries

The production activation response contains the server-issued VLESS URI. The
unprivileged Flutter adapter accepts only the server contract's exact fields:
`type=raw`, `security=reality`, `flow=xtls-rprx-vision`, `sni`, `fp=chrome`,
`pbk` and `sid`. UUID, hosts, port, REALITY password and short ID are validated
and sent through typed IPC v4. Arbitrary paths, commands, arguments and extra
query fields are rejected.

The elevated service validates the typed profile again, encrypts it with
machine DPAPI under the service-only profile directory and returns an opaque
`xray-...` handle. Activation and sign-out rollback delete the handle. The GUI
does not persist the VLESS URI after provisioning. Debug output redacts the
UUID and REALITY password; Xray logging is disabled.

The Windows IPC client opens the fixed local named pipe with Win32
`CreateFileW(OPEN_EXISTING)` and exchanges bounded frames through `WriteFile`
and `ReadFile` in a worker isolate. The earlier `dart:io File.open` attempt
timed out on the live Windows pipe even though a Win32 client connected; it
must not be used for this transport. A manual status-only probe is available
at `tool/probe-windows-pipe.dart` and sends no credentials.

## Process, routing and cleanup

The service verifies pinned SHA-256 hashes and starts only the fixed
side-by-side `xray/amd64/xray.exe` with constant `run -config` arguments. The
configuration path is service-selected under `%ProgramData%\KenaiVPN\runtime`
with a SYSTEM/Administrators ACL. Xray first validates it with `run -test`.

The default TUN policy supplies IPv4 and IPv6 gateways, Cloudflare DNS,
`0.0.0.0/0` and `::/0` system routes, and automatic outbound-interface
selection to avoid routing the proxy transport back into its own TUN. The
plaintext runtime configuration is deleted after startup and on every failure
or disconnect.

### DNS candidate update (2026-09-26; not yet installed)

DNS servers are now `1.1.1.1` and `1.0.0.1` in both IP modes. IPv4 DNS
transport answers both A and AAAA questions and does not depend on IPv6
connectivity at the exit server. Dual-stack capture of `::/0` remains intact;
this is not a claim that Armenia has IPv6 Internet connectivity.

Before reporting connected, the service acquires a dynamic WFP DNS guard
using the actual KenaiXray interface LUID. It blocks non-loopback outgoing
traffic on destination ports 53 and 853 on every other interface, on both
IPv4 and IPv6 transport layers. It installs all filters in one transaction,
checks their presence in status, and closes the dynamic session after Xray
stops. It does not edit adapter DNS, the registry, persistent firewall policy
or the independent kill-switch policy. DNS over HTTPS is not identified by
this port policy and still depends on correct tunnel routing. Local name
resolution through LAN DNS is intentionally unavailable while connected.

The selected Windows filtering conditions are documented in
[Microsoft's layer reference](https://learn.microsoft.com/en-us/windows/win32/fwp/filtering-conditions-available-at-each-filtering-layer).
The startup window before this guard is installed is not a protected state.
Hostname-based ingress bootstrap/reconnect and competing VPN software require
separate acceptance checks; the current Armenia ingress is an IPv4 literal.

The ignored `native_dns_policy_validates_without_changing_traffic` test asks
Windows to validate these filters in an explicitly aborted transaction: it
never commits traffic policy. It must pass with administrator rights before
installation. Actual DNS leak capture, enabled-policy cleanup, IPv6 behavior,
and post-update recovery remain acceptance gates, not inferred from unit tests.

Xray `v26.3.27` accepted these TUN fields but did not yet implement automatic
Windows routes. It could leave the adapter up while all traffic bypassed it.
The pinned `v26.9.9` supports those fields. The service now waits for Windows
to choose the Kenai adapter for both IPv4 and IPv6 destinations before it
reports a successful connection. Missing or competing routes fail closed with
`TUNNEL_ROUTE_UNAVAILABLE` and terminate the Xray process.

### OS-disabled IPv6 compatibility (2.1.9)

Before each connection the privileged service reads (never writes) Windows
`Tcpip6/Parameters/DisabledComponents`. Native-IPv6-disable bit 0x10 selects
IPv4-only mode, including 0xff and 0xffffffff. Prefer-IPv4 0x20 alone does not.
An absent value selects dual stack; malformed/unreadable values fail safely.
IPv4-only rendering omits the IPv6 gateway, DNS and route. It must not merely
ignore failed IPv6 route checks: upstream Xray unconditionally opens both Windows
IP families even when the config omits one. The narrowly patched Xray skips an
entirely unconfigured family; explicit IPv6 requests still fail if unavailable.

Before IPv4-only Xray starts, a dynamic WFP session blocks non-loopback IPv6
packets at OUTBOUND_IPPACKET_V6. IPv4 and ::1 are unaffected. Failure to install
the guard prevents connecting. Readiness and status require the correct IPv4
route AND readback of the guard filter. This also protects against native IPv6
being enabled while the IPv4-only session is running. On teardown Xray stops
before the session closes; Windows removes dynamic policy on process exit.
There are no persistent firewall edits, adapter rebindings or registry writes.
This guard is not a full IPv4 kill switch, and does not change that limitation.

Regression tests cover mode selection, both-family route checks, required guard,
IPv4-only rendering, and upstream family selection. Opt-in elevated tests cover
native filter creation/removal and a separate test TUN with only a benchmark
route (not the default route). Clean Windows with DisabledComponents=0xffffffff
and real-server connectivity still require the affected laptop acceptance test.

Xray is assigned to a Windows Job Object with `KILL_ON_JOB_CLOSE`. Explicit
disconnect terminates and waits for the job; service crash or shutdown closes
the last job handle and Windows terminates Xray. The common backend disconnects
WireGuard and AmneziaWG before starting Xray, so only one Kenai tunnel can be
active.

Kill switch remains unavailable until a separately leak-tested WFP policy is
implemented. The service reads receive/send byte counters from the Kenai
Windows adapter and subtracts the values at connect time; the handshake time
is still unavailable. Actual endpoint, external-IP, DNS and sleep/restart
tests remain part of the clean-VM MVP gate. A concurrently active third-party
VPN can win Windows route selection, so it must be disabled for a clean test.

## Supply chain

The Xray-core `v26.9.9` source commit is pinned with one documented Kenai Windows
compatibility patch; this is NOT an unmodified official binary. Rebuild script,
complete changed MPL source files and digest are under `third_party/xray` and
`tool/build-xray-compat.ps1`. Modified source ships with the installer licenses.
The executable is unsigned and hash-verified. The unchanged Wintun DLL retains
its valid WireGuard LLC signature. `tool/verify-stage14.ps1` enforces both pins.
