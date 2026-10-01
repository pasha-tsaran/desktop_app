# AmneziaWG 2.0 Windows engine

Stage 13 adds AmneziaWG as a distinct engine. It does not translate the
profile to WireGuard and does not reuse the WireGuard tunnel implementation.

## Trust and privilege boundary

The Flutter GUI parses the server profile into a bounded, typed IPC v3
message. It cannot select an executable, service name, path, command, route or
DNS command. The elevated `KenaiVpnService` validates the profile again,
encrypts it with machine DPAPI, and returns only an opaque `awg-...` handle.
Activation keys, private keys and complete profiles are never logged.

On connect, the Windows service loads the encrypted profile and renders a
short-lived fixed `%ProgramData%\KenaiVPN\runtime\KenaiAwg.conf`. It verifies
the pinned hashes, creates only `AmneziaWGTunnel$KenaiAwg`, and starts the
official signed `amneziawg.exe /tunnelservice` process through SCM. The config
is deleted after the service reaches Running. Disconnect, startup recovery and
failed-connect cleanup stop/delete that exact service and remove fixed runtime
files. WireGuard and AmneziaWG are mutually exclusive in the service backend.

Since 0.1.6, connect also waits up to 15 seconds for an authenticated peer
handshake. Outbound counters alone are not success. If no handshake arrives,
the service removes the Kenai tunnel (including its routes/WFP filters) and
returns `SERVER_UNAVAILABLE`. This proves peer reachability, not DNS/NAT or
end-to-end Internet access; those still need a live test. Control IPC allows
90 seconds for SCM start, handshake and failure cleanup; activation keeps its
separate 25-second deadline.

Since 1.1.8, the service expands its executable's Windows 8.3 aliases before
deriving the AWG payload path. The official engine builds its WFP app-ID rule
from its own executable path; on the investigated host, `netsh wfp show appid`
returned different IDs for the short and long names of the same engine.
The full-path fix retains the engine's existing firewall protections. On the
affected Windows host on 2026-09-15, live observation confirmed a handshake
and increasing RX/TX counters with the other VPN off; the user confirmed
Internet/Discord operation. This single-network check is not a DPI guarantee.

Statistics come from the fixed, hash-verified `awg.exe show KenaiAwg dump`
query. Arguments are constants; no GUI or caller-selected process invocation
is accepted. Output is bounded and only counters/handshake time cross IPC.

## Supported AWG 2.0 and 3.1 fields

The v3 contract extends WireGuard network fields only with `Jc`, `Jmin`,
`Jmax`, `S1`-`S4`, `H1`-`H4` and optional `I1`-`I5`. Unknown directives,
duplicate scalar fields, invalid ranges, control characters and oversized
values are rejected at both boundaries. The configurable application kill
switch is unsupported. Independently, the official AWG engine applies its own
WFP leak protection for a single peer with `/0` AllowedIPs. We preserve those
routes; splitting them into `/1` would remove that protection. IPv6 is not
disabled globally; profiles with only an IPv4 tunnel address do not provide
working IPv6 egress.

The current contract also carries the allow-listed AWG 3.1 header-protection,
padding, rekey, handshake and trailer directives. An optional numeric `MTU`
is validated at both boundaries and rendered into the engine configuration;
legacy Armenia profiles without it remain valid. This keeps the Netherlands
client interface at the server's explicit MTU instead of silently falling back
to the engine default.

## Supply chain

The committed amd64 files are extracted from the official 2.0.2 MSI. Their
release, source commit, hashes, signatures and licenses are recorded in
`third_party/amneziawg/README.md` and checked by `tool/verify-stage13.ps1`.
The installer must preserve this side-by-side directory; clean-machine
installation testing remains stage 16.
