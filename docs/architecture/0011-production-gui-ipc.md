# Production GUI and typed VPN IPC (stage 12)

## Working release path

The release composition root now uses `WindowsVpnEngine` instead of the
unavailable fallback. The minimum WireGuard path is:

1. The user enters exactly 12 decimal digits.
2. `POST /api/v1/activate` returns the account and three bounded protocol
   credentials over HTTPS.
3. The unprivileged client parses the WireGuard profile and provisions it into
   the service-owned DPAPI vault, retaining only an opaque handle.
4. `WindowsVpnEngine` requires an active stored session and that handle before
   it sends `Connect` over the version-2 named pipe.
5. The service starts the verified WireGuard engine and returns authoritative
   state and counters. The activation key is never included in IPC.

The production API also retains bounded AmneziaWG and VLESS credentials in OS
secure storage so their independent engines can consume them in stages 13 and
14. They are not advertised by the production VPN engine yet.

## Safety and lifecycle

- The GUI emits local validating/connecting states but accepts the terminal
  connection state only from the privileged service.
- One in-flight operation is allowed. Identifiers are allow-listed and bounded.
- Status reconciles the GUI with the actual service/tunnel state.
- Account sign-out stops the tunnel first. If stopping fails, credentials are
  retained and the user receives a safe retry message.
- Kill switch remains disabled until a dedicated leak-test gate.
- Release navigation hides payment, speed-test and placeholder statistics
  sections that are outside the minimal MVP.
- Missing service, account, profile or API configuration fails closed; mocks
  remain development/test only.

## Remaining MVP work

Stage 12 makes the activation-to-WireGuard application path real, but it is not
an installer or an end-to-end server proof. Stages 13 and 14 add independently
verified AmneziaWG and Xray engines. Stage 15 packages all components, and stage
16 validates all three protocols on a clean Windows VM with a dedicated test
activation key.
