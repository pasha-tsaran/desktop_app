# Desktop 2.3.3 (19)

- The Windows VLESS connection gate still tests UDP DNS through the selected
  tunnel first.
- If that service-owned UDP probe is unavailable, it now performs a bounded
  HTTP request/response check to fixed Cloudflare IPv4 endpoints through the
  already verified tunnel route. A TCP connect without a response is not
  enough to report the VPN as connected.
- The fallback prevents a working Netherlands VLESS tunnel from being torn
  down and reported as `SERVER_UNAVAILABLE` solely because the raw UDP probe
  is dropped on a particular Windows/network combination.
- Both checks remain fail-closed: if neither receives a valid response within
  the bounded deadlines, connection setup still fails as server unavailable.

The installer is unsigned and must be installed manually. Existing activation
keys and imported Armenia/Netherlands profiles remain valid across the update.
