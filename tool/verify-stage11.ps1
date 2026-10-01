$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot
$PayloadRoot = Join-Path $RepoRoot 'third_party\wireguard\windows\amd64'
$Expected = @{
    'tunnel.dll' = '5533cf9cb741d5e9daa7f429aa1c56beba4a500934877c9d072f721f512583ca'
    'wireguard.dll' = 'b1b85e072c45d81358be29d94c599dc76652f912be8c0f0a41e2d5d89a6461d3'
}

foreach ($Name in $Expected.Keys) {
    $Path = Join-Path $PayloadRoot $Name
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing WireGuard payload: $Name"
    }
    $Actual = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected[$Name]) {
        throw "WireGuard payload hash mismatch: $Name"
    }
}

$Signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $PayloadRoot 'wireguard.dll')
if ($Signature.Status -ne 'Valid' -or
    $Signature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC') {
    throw 'wireguard.dll signature is not valid or signer is not WireGuard LLC.'
}

function Require-Text([string]$Path, [string]$Pattern) {
    $Resolved = Join-Path $RepoRoot $Path
    if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) {
        throw "Required stage 11 marker is missing in: $Path"
    }
}

Require-Text 'services/windows_vpn_service/src/wireguard_engine.rs' 'SERVICE_SID_TYPE_UNRESTRICTED|ServiceSidType::Unrestricted'
Require-Text 'services/windows_vpn_service/src/wireguard_engine.rs' 'LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR'
Require-Text 'services/windows_vpn_service/src/wireguard_engine.rs' 'WireGuardGetConfiguration'
Require-Text 'services/windows_vpn_service/src/wireguard_engine.rs' 'fn is_connected'
Require-Text 'crates/vpn_contracts/src/lib.rs' 'CONTRACT_VERSION: u32 = [2345]'
Require-Text 'docs/architecture/0010-wireguard-windows-engine.md' 'AmneziaWG 2.0 and VLESS/REALITY'
Require-Text 'docs/continuation-prompts.md' 'AmneziaWG 2\.0'
Require-Text 'docs/continuation-prompts.md' 'VLESS \+ REALITY/Xray'

$GuiRoot = Join-Path $RepoRoot 'apps\desktop\lib'
foreach ($Forbidden in @('CreateService', 'LoadLibrary', 'Process\.run', 'cmd\.exe', 'powershell\.exe')) {
    $Matches = @(Get-ChildItem -LiteralPath $GuiRoot -Recurse -File |
        Select-String -Pattern $Forbidden)
    if ($Matches.Count -gt 0) {
        throw "Forbidden privileged GUI capability found: $Forbidden"
    }
}

Write-Host 'Stage 11 WireGuard payload and privilege boundary verification passed.'
