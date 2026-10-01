# WireGuard Windows payload provenance

Architecture: `amd64` only for the first Windows MVP.

## tunnel.dll

- Upstream: `https://git.zx2c4.com/wireguard-windows`
- Tag: `v1.1`
- Commit: `378990476748b5038df433f73712bfde859f4d65`
- Source directory: `embeddable-dll-service`
- License: MIT; see `LICENSE-wireguard-windows.txt`
- Build: upstream `embeddable-dll-service/build.bat` with its pinned toolchain
- SHA-256: `5533cf9cb741d5e9daa7f429aa1c56beba4a500934877c9d072f721f512583ca`
- Authenticode: locally reproducible upstream build is unsigned. It must be
  distributed under protected Program Files ACLs and the Kenai payload
  verifier must enforce this exact hash. Product signing is a release-stage
  responsibility.

## wireguard.dll

- Upstream: `https://download.wireguard.com/wireguard-nt/wireguard-nt-1.1.zip`
- Archive SHA-256: `dceb30a9bc4be48cce0f74160fc88a585a2c2627366e8f846fc6658f9038dace`
- Binary SHA-256: `b1b85e072c45d81358be29d94c599dc76652f912be8c0f0a41e2d5d89a6461d3`
- Authenticode status at acquisition: `Valid`
- Signer: `WireGuard LLC`
- License: the prebuilt binary license in `LICENSE-wireguard-nt.txt` permits
  distribution alongside software using the permitted API. Do not modify it.

The acquisition/build script must verify all hashes and the WireGuard LLC
signature. Runtime code loads only the fixed side-by-side paths and verifies
both hashes before starting a tunnel service.
