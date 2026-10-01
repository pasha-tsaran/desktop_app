# First-project readiness checkpoint — 2026-09-26

Scope: first Windows client and Armenia. Preserve the working connection.
Amsterdam and kill-switch acceptance are deferred by the operator.

## Observed before changes

- SSH access to Armenia works with the approved deployment public key.
- Live Xray configuration validation succeeded without service restart.
- VLESS/raw/REALITY/Vision parameters match the helper's issuance settings;
  private key/public key comparison was performed in server memory only.
- The target accepts TLS 1.3 with a verified certificate. Negotiated ALPN was
  HTTP/1.1, not HTTP/2; do not claim every recommended camouflage property.
- IPv4 probes exit through Armenia. Server has no default IPv6 route and
  IPv6 HTTPS probes fail. This alone is not evidence of a leak.
- Operator's temporary 15-second outbound block was removed successfully;
  the first post-removal IPv4 request exited through Armenia. No requests
  were deliberately sent during the block; this is not a kill-switch test.

## Candidate changes, NOT installed

- `xray_engine.rs`: both IP modes use IPv4 DNS transports (1.1.1.1/1.0.0.1).
  IPv6 capture routes remain present in dual-stack mode.
- `xray_dns_guard.rs`: transactionally installed dynamic DNS-only WFP policy,
  checked before connected/status and released after Xray teardown.
- `main.rs`: includes the DNS policy module. GUI and protocol contract unchanged.

The working tree already contained unrelated changes. They were preserved.
The candidate builds from this working tree; existing installed artifact matches
do not by themselves establish that the entire candidate equals installed source.

## Validation

- `cargo test --workspace --locked`: 54 passed, 4 elevated native tests ignored.
  Six named-pipe tests initially failed with sandbox access denied; all passed
  when rerun outside the sandbox. Production VPN was not manipulated by tests.
- `cargo clippy --workspace --all-targets --locked -- -D warnings`: passed.
- rustfmt check of the two changed Xray modules: passed.
- `cargo build --release --locked -p kenai_windows_vpn_service`: passed.
- PowerShell diagnostic parse and non-admin refusal: passed under PS 5.1.
- GUI tests/build were not run: no GUI changes in this checkpoint.

Build artifacts are isolated in `%TEMP%\kenai-first-dns-validation` because
the existing workspace target build lock was not writable in the sandbox.
Candidate service SHA256:
`63F8131F17AE15E17A78642078B764527BEF4C95409A9F218BB4F5C3C1F5E4FD`.
It has not replaced the installed executable.

## Next gate

Run `tool/test-first-vpn-dns-readiness.ps1` as administrator under the same
Windows account, with the first app connected to Armenia. It pins the test
binary hash and invokes only the DNS native test in an aborted transaction.
It then gathers route/DNS/IPv4/IPv6 results without changing installed files.
It does NOT commit filters, capture DNS leakage, or validate enabled-policy
behavior. A passing result permits further native acceptance, not a claim of
finished protection. Never deploy merely because compilation passed.

Remaining: enabled-policy DNS capture and cleanup, deliberate IPv6 policy for
IPv4-only exits, DNS bootstrap on hostname endpoints, verified install/rollback,
post-update recovery, sleep/network-change behavior, idle/stability measurement,
and installed build provenance. No ready-for-users claim yet.

## Operator result and next live gate

The operator ran DNS-1 elevated: native transaction validation passed, both IPv4
DNS servers returned A and AAAA records through the TUN, IPv6 DNS failed for
both types, IPv4 HTTPS exited via Armenia, and IPv6 HTTPS failed (curl 35).
No service files or live filtering policy were changed by that run.

`tool/test-first-vpn-dns-live.ps1` uses the standalone Cargo example
`services/windows_vpn_service/examples/dns_guard_probe.rs`, NOT the service
entrypoint. The binary pins the KenaiXray interface and a 45-second maximum
normal lifetime. It acquires the actual candidate dynamic DNS guard and then
drops it. Process termination also closes the dynamic WFP session. There is
no caller-selected rule/interface/timeout and no production profile access.

The elevated runner verifies the helper hash and IPv4 Armenia baseline, finds
a responding physical-interface DNS server with a physical route, and sends
only explicit example.com UDP probes (A/AAAA). These deliberate LAN baseline
queries are not observations of an application's spontaneous DNS leakage.
It tests the LAN DNS response becoming blocked, tunnel DNS still responding,
and Armenia HTTPS still working while the helper is alive. After natural
expiry it rechecks LAN DNS and Armenia HTTPS. No persistent firewall, adapter,
DNS, registry, service, or server settings are changed. An interrupted runner
kills only its own helper; the independent helper lifetime bounds recovery.

Helper SHA256: `32F58619B05B8CA4A4AC23B87EF0CBFF78A95FAF06D1D20BBA08480E2448C0C4`.
Build, strict Clippy, PS 5.1 packet self-test and non-admin refusal passed.
Live execution is pending operator administrator access. This checks selected
UDP/IPv4 flows, not full DNS/IPv6/DoH/TCP leak capture or a kill switch.

## Finalization update — 2026-09-26

The candidate described above was subsequently installed and accepted. This
section supersedes the earlier "not installed" and pending-live-test wording.

- Armenia remains an IPv4-only exit. Xray now omits its IPv6 gateway and route,
  while a dynamic, non-persistent WFP policy blocks non-loopback IPv6 for the
  lifetime of the VPN session. The policy affects IPv6 only and is checked
  before the service reports the tunnel as connected.
- After the tunnel route and DNS guard exist, connect performs one bounded DNS
  request/response exchange through the IPv4 tunnel. Failure tears Xray down and
  returns `SERVER_UNAVAILABLE`; there is no periodic connectivity traffic while
  idle.
- The release service passed 32 Windows-service tests; four administrator-only
  native tests remained intentionally ignored. The complete Rust workspace
  passed 55 tests and strict Clippy. The desktop app passed 80 tests and Flutter
  analyze. Sleep/resume and network-change policies are covered by deterministic
  application tests, but physical suspend and uplink-switch acceptance still
  require an operator-controlled Windows session.
- The service update and a same-version installer upgrade both completed with
  hash checks and rollback protection. Each reconnect returned `CONNECTED`,
  IPv4 HTTPS exited as `88.218.94.3`, IPv6 HTTPS failed under the selected
  policy, and kill-switch remained disabled.
- Configured unsigned installer:
  `dist/KenaiVPN-Setup-2.1.2-UNSIGNED.exe`, SHA-256
  `5480C1AD59CFEBD87A56674423961D35B07396E701DCF78DBE5C17C8E800A842`.
  Installed packaged service SHA-256:
  `3A031BECE7E107B33238B5A2B652A56E7261C61D9A5CC735AB1B069D19820932`.

Release blockers that cannot be closed in this working session: a clean-install
test on a disposable Windows machine, physical sleep/resume and uplink-switch
acceptance, and a trusted Authenticode certificate plus timestamped signatures.
Do not claim the package is ready for general distribution until those gates
are complete. Kill-switch acceptance remains explicitly out of scope.
