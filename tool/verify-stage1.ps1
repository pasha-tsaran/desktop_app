[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$required = @(
    'README.md',
    'AGENTS.md',
    'analysis_options.yaml',
    'Cargo.toml',
    'proto/kenai_vpn_service.proto',
    'apps/desktop/lib/main.dart',
    'apps/desktop/lib/bootstrap.dart',
    'apps/desktop/.metadata',
    'apps/desktop/windows/CMakeLists.txt',
    'packages/kenai_core/lib/src/domain/models.dart',
    'packages/kenai_core/lib/src/ports/ports.dart',
    'packages/kenai_core/lib/src/mocks/mocks.dart',
    'services/windows_vpn_service/src/main.rs',
    'docs/architecture/0001-platform-and-technology.md',
    'docs/architecture/0002-stage-1-scaffold.md'
    'docs/server-api-boundary.md'
)

foreach ($relativePath in $required) {
    $path = Join-Path $repoRoot $relativePath
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing stage-1 file: $relativePath"
    }
}

$portsPath = Join-Path $repoRoot 'packages/kenai_core/lib/src/ports/ports.dart'
$ports = Get-Content -LiteralPath $portsPath -Raw
$requiredPorts = @(
    'ApiClient',
    'SecureStorage',
    'VpnEngine',
    'ServerRepository',
    'SubscriptionRepository',
    'PaymentProvider',
    'DiagnosticExporter'
)
foreach ($port in $requiredPorts) {
    if ($ports -notmatch "abstract interface class $port") {
        throw "Missing interface: $port"
    }
}

$requiredVpnMethods = @(
    'connect',
    'disconnect',
    'status',
    'statistics',
    'validateProfile',
    'collectDiagnostics'
)
foreach ($method in $requiredVpnMethods) {
    if ($ports -notmatch "\b$method\s*\(") {
        throw "Missing VpnEngine method: $method"
    }
}

$modelsPath = Join-Path $repoRoot 'packages/kenai_core/lib/src/domain/models.dart'
$models = Get-Content -LiteralPath $modelsPath -Raw
$requiredModels = @(
    'Account',
    'Subscription',
    'VpnServer',
    'ServerStatus',
    'Device',
    'VpnProfile',
    'ConnectionSession',
    'DiagnosticEvent',
    'Tariff',
    'AppSettings'
)
foreach ($model in $requiredModels) {
    if ($models -notmatch "(?:class|enum)\s+$model\b") {
        throw "Missing domain model: $model"
    }
}

$requiredPhases = @(
    'disconnected',
    'validating',
    'connecting',
    'connected',
    'reconnecting',
    'disconnecting',
    'blockedBySubscription',
    'noNetwork',
    'serverUnavailable',
    'error'
)
foreach ($phase in $requiredPhases) {
    if ($models -notmatch "\b$phase\b") {
        throw "Missing connection phase: $phase"
    }
}

$rustContracts = Get-Content -LiteralPath (
    Join-Path $repoRoot 'crates/vpn_contracts/src/lib.rs'
) -Raw
$proto = Get-Content -LiteralPath (
    Join-Path $repoRoot 'proto/kenai_vpn_service.proto'
) -Raw
$phaseContracts = @(
    @{ Dart = 'disconnected'; Rust = 'Disconnected'; Proto = 'DISCONNECTED' },
    @{ Dart = 'validating'; Rust = 'Validating'; Proto = 'VALIDATING' },
    @{ Dart = 'connecting'; Rust = 'Connecting'; Proto = 'CONNECTING' },
    @{ Dart = 'connected'; Rust = 'Connected'; Proto = 'CONNECTED' },
    @{ Dart = 'reconnecting'; Rust = 'Reconnecting'; Proto = 'RECONNECTING' },
    @{ Dart = 'disconnecting'; Rust = 'Disconnecting'; Proto = 'DISCONNECTING' },
    @{
        Dart = 'blockedBySubscription'
        Rust = 'BlockedBySubscription'
        Proto = 'BLOCKED_BY_SUBSCRIPTION'
    },
    @{ Dart = 'noNetwork'; Rust = 'NoNetwork'; Proto = 'NO_NETWORK' },
    @{
        Dart = 'serverUnavailable'
        Rust = 'ServerUnavailable'
        Proto = 'SERVER_UNAVAILABLE'
    },
    @{ Dart = 'error'; Rust = 'Error'; Proto = 'ERROR' }
)
foreach ($phase in $phaseContracts) {
    if ($models -notmatch "\b$($phase.Dart)\b") {
        throw "Dart phase contract is missing: $($phase.Dart)"
    }
    if ($rustContracts -notmatch "\b$($phase.Rust)\b") {
        throw "Rust phase contract is missing: $($phase.Rust)"
    }
    if ($proto -notmatch "CONNECTION_PHASE_$($phase.Proto)\b") {
        throw "Protobuf phase contract is missing: $($phase.Proto)"
    }
}

$clientRoots = @(
    (Join-Path $repoRoot 'apps'),
    (Join-Path $repoRoot 'packages')
)
$forbidden = 'CreateServiceW|StartServiceW|FwpmEngineOpen|WireGuardOpenAdapter|wintun\.dll|wireguard\.dll|xray\.exe|amneziawg\.exe|netsh\s|Set-DnsClient|New-NetRoute'
$matches = Get-ChildItem -LiteralPath $clientRoots -File -Recurse |
    Where-Object { $_.Extension -in '.dart', '.rs', '.cpp', '.h', '.ps1' } |
    Select-String -Pattern $forbidden
if ($matches) {
    $matches | ForEach-Object { Write-Error $_.Line }
    throw 'Forbidden system integration found outside the privileged service boundary.'
}

Write-Output 'Stage 1 structure, ports and system-integration boundary: OK'
