[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$required = @(
    'apps/desktop/lib/src/screens/speed_test_screen.dart',
    'apps/desktop/lib/src/screens/app_settings_screen.dart',
    'packages/kenai_core/test/stage7_test.dart',
    'apps/desktop/test/stage7_screens_test.dart',
    'docs/release-audit-stage7.md'
)

foreach ($relative in $required) {
    $path = Join-Path $root $relative
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing stage 7 artifact: $relative"
    }
}

$appLib = Join-Path $root 'apps/desktop/lib'
$unsafe = Get-ChildItem -LiteralPath $appLib -Filter '*.dart' -Recurse |
    Select-String -Pattern 'Process\.(start|run|runSync|startSync)|powershell|cmd\.exe' -CaseSensitive
if ($unsafe) {
    throw 'UI/application code contains a forbidden process or shell invocation.'
}

$bootstrap = Get-Content -Raw -LiteralPath (Join-Path $root 'apps/desktop/lib/bootstrap.dart')
if ($bootstrap -notmatch 'kReleaseMode[\s\S]*UnavailableSpeedTestEngine' -or
    $bootstrap -notmatch 'kReleaseMode[\s\S]*UnavailableUpdateProvider') {
    throw 'Release fallbacks for mock speed/update providers are missing.'
}

$audit = Get-Content -Raw -LiteralPath (Join-Path $root 'docs/release-audit-stage7.md')
if ($audit -notmatch 'BLOCKED') {
    throw 'Release audit must explicitly prevent publication while blockers remain.'
}

Write-Output 'Stage 7 screens, release fallbacks and publication boundary: OK'
