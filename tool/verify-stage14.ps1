$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = Split-Path -Parent $PSScriptRoot
$PayloadRoot = Join-Path $RepoRoot 'third_party\xray\windows\amd64'
$Expected = @{
    'xray.exe' = '6b5cd540e3f4ce59f309863f0f1339b0bda13aeb9451405abfca29ba873cca20'
    'wintun.dll' = 'e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
}
foreach ($Name in $Expected.Keys) {
    $Path = Join-Path $PayloadRoot $Name
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing Xray payload: $Name" }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $Expected[$Name]) {
        throw "Xray payload hash mismatch: $Name"
    }
}
$Signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $PayloadRoot 'wintun.dll')
if ($Signature.Status -ne 'Valid' -or $Signature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC') {
    throw 'Xray Wintun signature mismatch.'
}
function Require-Text([string]$Path, [string]$Pattern) {
    $Resolved = Join-Path $RepoRoot $Path
    if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) { throw "Missing stage 14 marker: $Path" }
}
Require-Text 'crates/vpn_contracts/src/lib.rs' 'CONTRACT_VERSION: u32 = [45]'
Require-Text 'services/windows_vpn_service/src/xray_engine.rs' 'JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'
Require-Text 'services/windows_vpn_service/src/xray_engine.rs' 'autoSystemRoutingTable'
Require-Text 'services/windows_vpn_service/src/xray_engine.rs' '"run", "-test", "-config"'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'VpnProtocol\.vlessReality'
Require-Text 'packages/kenai_core/lib/src/application/secure_account_repository.dart' 'vlessProfileHandle'
Require-Text 'third_party/xray/README.md' 'Kenai compatibility build'
Write-Host 'Stage 14 VLESS + REALITY/Xray verification passed.'
