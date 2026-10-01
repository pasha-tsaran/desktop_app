$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Require-Text([string]$Path, [string]$Pattern) {
  $Resolved = Join-Path $RepoRoot $Path
  if (-not (Test-Path -LiteralPath $Resolved)) {
    throw "Required file is missing: $Path"
  }
  if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) {
    throw "Required stage 10 marker is missing in: $Path"
  }
}

Require-Text 'crates/vpn_contracts/src/lib.rs' 'ImportWireGuardProfile'
Require-Text 'crates/vpn_contracts/src/lib.rs' 'SecretKey\(\[REDACTED\]\)'
Require-Text 'crates/vpn_service_core/src/lib.rs' 'trait ProfileVault'
Require-Text 'services/windows_vpn_service/src/profile_vault.rs' 'CRYPTPROTECT_LOCAL_MACHINE'
Require-Text 'services/windows_vpn_service/src/profile_vault.rs' 'PROTECTED_DACL_SECURITY_INFORMATION'
Require-Text 'apps/desktop/lib/src/infrastructure/wireguard_config_parser.dart' 'UNSUPPORTED_PROFILE_FIELD'
Require-Text 'apps/desktop/test/wireguard_config_parser_test.dart' 'never renders key'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_profile_provisioner.dart' 'PROFILE_STORED'
Require-Text 'packages/kenai_core/lib/src/application/secure_account_repository.dart' 'deleteProfile\(profileHandle\)'

$Forbidden = @(
  'Process\.run',
  'badCertificateCallback',
  'cmd\.exe',
  'powershell\.exe'
)
foreach ($Pattern in $Forbidden) {
  $Matches = Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'apps/desktop/lib') -Recurse -File |
    Select-String -Pattern $Pattern
  if ($Matches) {
    throw "Forbidden GUI capability found: $Pattern"
  }
}

Write-Host 'Stage 10 boundary verification passed.'
