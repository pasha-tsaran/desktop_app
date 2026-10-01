# Desktop 2.3.4 (20)

- Adds direct Netherlands connections over AmneziaWG 3.1 on UDP/443.
- Keeps Armenia compatible with its existing AmneziaWG 2.0 profile; each
  location has a separate encrypted service profile and handle.
- Pins the official AmneziaWG Windows 3.1.0 engine and validates its published
  MSI and extracted executable hashes.
- Extends the typed IPC/profile vault format with the 3.1 header-protection,
  padding, rekey, timeout, trailer and cookie settings while retaining decoder
  compatibility with existing 2.0 vault records.
- Netherlands automatic mode prefers AmneziaWG, then VLESS/REALITY, then the
  legacy WireGuard fallback. Armenia keeps its previous preference order.

The installer is unsigned and must be installed manually. A live handshake and
data-plane check is still required on the target Windows network after update.
