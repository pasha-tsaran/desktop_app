$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$RepoRoot = Split-Path -Parent $PSScriptRoot

function Require-Text([string]$Path, [string]$Pattern) {
    $Resolved = Join-Path $RepoRoot $Path
    if (-not (Test-Path -LiteralPath $Resolved)) {
        throw "Required file is missing: $Path"
    }
    if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) {
        throw "Required stage 12 marker is missing in: $Path"
    }
}

Require-Text 'apps/desktop/lib/bootstrap.dart' 'WindowsVpnEngine\(secureStorage: secureStorage\)'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'SecureAccountStorageKeys\.session'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'SecureAccountStorageKeys\.profileHandle'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'encodeVpnIpcFrame\(opcode, body\)'
Require-Text 'apps/desktop/lib/src/infrastructure/windows_vpn_engine.dart' 'VpnProtocol\.wireGuard'
Require-Text 'apps/desktop/lib/src/screens/servers_screen.dart' 'killSwitch: false'
Require-Text 'apps/desktop/lib/src/screens/account_screen.dart' 'if \(!vpnStopped\)'
Require-Text 'apps/desktop/lib/src/infrastructure/production_api.dart' "'amneziawg'"
Require-Text 'apps/desktop/lib/src/infrastructure/production_api.dart' "'vless'"
Require-Text 'apps/desktop/test/windows_vpn_engine_test.dart' 'never sends activation key'
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

Write-Host 'Stage 12 production GUI and typed IPC verification passed.'
