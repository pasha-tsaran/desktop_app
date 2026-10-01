$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PayloadRoot = Join-Path $RepoRoot 'third_party\amneziawg\windows\amd64'
$Expected = @{
    'amneziawg.exe' = 'ba446f6e1a4093e43a65d6ff45f4b8c7b6485dc419327eedaa1a218549740e3a'
    'awg.exe' = '272badace73caeb26dc42656f318b3eb7f10028c2f76faad1f52d6fe1e0ced12'
    'wintun.dll' = 'e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
}
foreach ($Name in $Expected.Keys) {
    $Path = Join-Path $PayloadRoot $Name
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing AmneziaWG payload: $Name" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected[$Name]) {
        throw "AmneziaWG payload hash mismatch: $Name"
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Path
    $Signer = if ($Name -eq 'wintun.dll') { 'CN=WireGuard LLC' } else { 'Privacy Technologies OU' }
    if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch $Signer) {
        throw "AmneziaWG payload signature mismatch: $Name"
    }
}
function Require-Text([string]$Path, [string]$Pattern) {
    $Resolved = Join-Path $RepoRoot $Path
    if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) { throw "Missing stage 13 marker: $Path" }
}
Require-Text 'crates/vpn_contracts/src/lib.rs' 'CONTRACT_VERSION: u32 = [345]'
Require-Text 'services/windows_vpn_service/src/amneziawg_engine.rs' 'AmneziaWGTunnel\$KenaiAwg'
Require-Text 'services/windows_vpn_service/src/amneziawg_engine.rs' '"/tunnelservice"'
Require-Text 'services/windows_vpn_service/src/windows_backend.rs' 'self\.wireguard\.disconnect'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'VpnProtocol\.amneziaWg'
Require-Text 'packages/kenai_core/lib/src/application/secure_account_repository.dart' 'amneziaWgProfileHandle'
Require-Text 'docs/architecture/0011-amneziawg-2-windows-engine.md' 'does not translate the'
Write-Host 'Stage 13 AmneziaWG 2.0/3.1 verification passed.'
