# Desktop 2.3.2 (18)

- Connected Netherlands uses a code-rendered stylized regional map, country outline and label. Armenia keeps its existing artwork.
- Both production exits support manual TCP latency measurement to port 443. This is TCP connection latency over the current network route, not ICMP or a throughput/health guarantee.
- Public IPv4 is measured on initial state and transitions into connected/disconnected. Old responses are discarded after state changes. There is no periodic IP polling, no hardcoded exit IP and no network configuration change.
- IP lookup uses HTTPS api.ipify.org, with ipv4.icanhazip.com as fallback. These services necessarily see the current public IP; no account identifiers or VPN profiles are sent. Each request has a five-second deadline and a bounded response. Failure displays an em dash.
- Unknown health text is hidden; actual unavailable/maintenance states remain visible.

Installer is unsigned and must be installed manually. Source tests do not switch the live VPN; end-to-end checks on both exits remain a manual post-install step.
