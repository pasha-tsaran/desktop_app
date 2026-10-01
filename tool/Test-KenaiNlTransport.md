# Isolated Netherlands transport diagnostic

Run `Test-KenaiNlTransport.ps1` with Windows PowerShell 5.1 as administrator,
after disconnecting VPN. It refuses to start while any Xray process is running.
Revision 3 runs the worker using a uniquely named temporary SYSTEM scheduled task
because stored profile files can reject reads even from an elevated administrator.
The wrapper removes its own task in `finally`; it never relaxes profile ACLs.
`-ProfileCheckOnly` validates profile access and parsing without starting Xray or
making network requests, and is allowed while the normal VPN is active.
Revision 4 accepts `-TestFingerprint chrome` or `firefox` (default) for a
controlled comparison using the same local profile, destinations and deadlines.
Changing this option affects only the temporary diagnostic process, not the app.
The script selects the newest locally stored Netherlands VLESS profile, decrypts
it in memory with the existing machine DPAPI entropy, and supplies it through
stdin to the hash-verified installed Xray executable. It does not print credentials
or write a plaintext profile. This may differ from the active application's handle
if multiple accounts were provisioned on the machine.

Only a temporary loopback SOCKS listener is started; no TUN interface, Windows
proxy setting, route, DNS setting or installed service is changed. Two bounded
HTTP/HTTPS requests test transport with the Firefox fingerprint used by the
client. The child is stopped in `finally`. Keep the console open until `Saved:`;
forced termination of PowerShell can prevent cleanup. The text report on the
Desktop contains timestamps, fixed test destinations, HTTP codes and process
error codes, not raw Xray output. It does not test UDP or the Windows TUN path.

`curl_exit=0` with an HTTP response confirms the tested request returned through
the isolated proxy. `curl_exit=28` indicates a timeout, not its root cause.
`VPN_MUST_BE_DISCONNECTED` or `RUN_POWERSHELL_AS_ADMINISTRATOR` is a precondition
failure. The script never changes the activation key or replaces a profile.

Verification: `powershell.exe -NoProfile -File tool/Test-KenaiNlTransport.ps1 -SelfTest`
tests field decoding and truncation without network or profile-store access.
The installed engine also accepts JSON via stdin in configuration-test mode.
Live authenticated testing is left to the user while VPN is disconnected.
