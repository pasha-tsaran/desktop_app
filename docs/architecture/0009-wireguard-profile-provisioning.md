# WireGuard profile provisioning boundary (stage 10)

## Decision

The activation response remains in the interactive, unprivileged process only
long enough to be parsed. `WireGuardConfigParser` accepts one `[Interface]` and
one `[Peer]`, rejects unknown directives, bounds list sizes, decodes 32-byte
keys, and validates IP prefixes, DNS addresses, endpoint and port. Its debug
representation redacts keys and endpoint.

The named-pipe contract carries typed fields, never a caller-selected path or
command. The service repeats validation before storage. Secret keys use a
redacted wrapper in Rust so derived debug output cannot expose their bytes.

## Privilege and data flow

```text
HTTPS activation response
  -> unprivileged parser
  -> bounded local named-pipe frame
  -> caller/session authorization
  -> privileged validation
  -> versioned profile serialization
  -> DPAPI LocalMachine encryption
  -> %ProgramData%/KenaiVPN/profiles/<opaque-handle>.bin
```

The profile directory has a protected DACL granting full access only to
`SYSTEM` and Administrators. The service generates a 128-bit random handle;
the GUI cannot choose a filesystem path. Files are created with `create_new`
and flushed before success is returned.

`DeleteProfile` accepts only an allow-listed opaque handle and removes the
corresponding encrypted file. Release activation uses the profile-only Windows
IPC adapter, stores the returned handle instead of the raw configuration, and
calls deletion before clearing local account data on logout. If deletion fails,
logout reports a safe failure and preserves the handle so cleanup can be
retried. The release VPN engine itself remains fail-closed.

## Deliberate exclusions

- No WireGuard driver or tunnel is started in this stage.
- No production server or VPN host is contacted.
- No profile plaintext is logged, exported, or returned by IPC.
- Connection/status/statistics IPC remains stage 12 work.
