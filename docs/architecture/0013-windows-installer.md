# Windows installer

Stage 15 packages the Flutter GUI, privileged Rust service and all three pinned
VPN engines into one NSIS executable. NSIS 3.12 is downloaded from the official
SourceForge project as a portable build and checked against the pinned SHA-256
`56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f`.
The official feed publishes MD5 `757c22153dd8b90f5e297310d9966997`
for the same archive.

## Installation boundary

Only Setup and Uninstall request elevation. The installed Flutter GUI has no
elevation manifest and is never launched by the elevated installer. Setup
places first-party binaries under `%ProgramFiles%\Kenai VPN`, preserves the
fixed side-by-side payload layout expected by the service, creates
`KenaiVpnService` as LocalSystem with automatic startup, enables its unrestricted
service SID, configures bounded recovery restarts and starts it.
Service creation and repair use the executable's Windows 8.3 path. The resulting
service command contains no spaces, avoiding both an unquoted service-path
vulnerability and ambiguous nested quoting through the NSIS process plug-in.
Policy steps include their exact operation and sanitized output in the installer
details if Windows rejects one.

Rerunning the same installer is the repair/update path. It stops the existing
service, replaces the complete file set, reapplies the fixed service binary
path and policy, then starts the service. Neither the GUI nor API can provide a
path, command, service name or install action.

Uninstall stops the GUI and main service, removes the two fixed child tunnel
services if crash recovery left them behind, deletes the service-owned DPAPI
profile/runtime directory, current-user logs and current-user secure-storage
files/key, shortcuts, registry entry and installation directory. Explicitly
exported diagnostic ZIP files in Downloads are user-owned and are preserved.
If the running uninstaller temporarily retains its protected parent directory,
Windows schedules that final empty directory for deletion after process exit.
The uninstaller first moves its working directory to `%TEMP%`, so it never
prevents immediate removal of an installed payload directory itself.
Users should sign out before uninstalling on a shared PC; Windows does not let
one account erase another account's DPAPI-protected storage.

## Supply chain and signing

The build runs all three engine payload verifiers before staging. WireGuard,
AmneziaWG, Xray and Wintun license notices are included. The GUI and service
can be Authenticode-signed before packaging and the final Setup signed after
packaging by supplying an owner-controlled certificate thumbprint. The build
fails if a requested signature is not valid.

No owner code-signing certificate is currently available. Therefore the local
stage artifact is explicitly named `KenaiVPN-Setup-UNCONFIGURED.exe`, is
unsigned, and is not a publication candidate. A distributable
`KenaiVPN-Setup.exe` is produced only when an explicit HTTPS `ApiBaseUrl` is
provided. Code signing is still required before a public release to avoid an
untrusted-publisher warning.

## Verification boundary

Stage 15 checks deterministic composition, strict NSIS compilation, executable
shape, hashes, vendor signatures and release builds. It does not install or
alter the developer machine. Silent/interactive install, repair, uninstall,
service startup, three live tunnels and rollback are verified on a disposable
clean Windows VM in stage 16.
