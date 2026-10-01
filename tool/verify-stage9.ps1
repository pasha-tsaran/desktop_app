[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$required = @(
    'apps/desktop/lib/src/infrastructure/production_api.dart',
    'apps/desktop/test/production_api_test.dart',
    'packages/kenai_core/lib/src/application/production_fallbacks.dart',
    'docs/architecture/0008-production-activation.md',
    'docs/continuation-prompts.md'
)
foreach ($relative in $required) {
    if (-not (Test-Path -LiteralPath (Join-Path $root $relative))) {
        throw "Missing stage 9 artifact: $relative"
    }
}

$api = Get-Content -Raw -LiteralPath (
    Join-Path $root 'apps/desktop/lib/src/infrastructure/production_api.dart'
)
foreach ($requiredText in @(
    "uri.scheme != 'https'",
    "path: '/api/v1/activate'",
    'ProductionActivationApiClient',
    '_maximumResponseBytes'
)) {
    if (-not $api.Contains($requiredText)) {
        throw "Production API invariant is missing: $requiredText"
    }
}
if ($api -match 'badCertificateCallback|activation_key.*(print|log)') {
    throw 'Production API weakens TLS or risks logging an activation key.'
}

$bootstrap = Get-Content -Raw -LiteralPath (
    Join-Path $root 'apps/desktop/lib/bootstrap.dart'
)
if ($bootstrap -notmatch 'if \(kReleaseMode\)[\s\S]*ProductionActivationApiClient' -or
    $bootstrap -notmatch 'if \(kReleaseMode\)[\s\S]*WindowsVpnEngine' -or
    $bootstrap -notmatch 'else \{[\s\S]*MockActivationApiClient') {
    throw 'Release/development composition boundary is incomplete.'
}

$serversScreen = Get-Content -Raw -LiteralPath (
    Join-Path $root 'apps/desktop/lib/src/screens/servers_screen.dart'
)
if ($serversScreen -match "'mock-(connect|disconnect|windows-device)") {
    throw 'Production-facing connection identifiers still contain mock values.'
}

if (Test-Path -LiteralPath (Join-Path $root 'docs/remaining-prompts.md')) {
    throw 'Superseded roadmap was not removed.'
}

Write-Output 'Stage 9 production activation and fail-closed release boundary: OK'
