[CmdletBinding()]
param([switch]$Rollback)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$candidate = Join-Path $env:TEMP `
    'kenai-armenia-readiness-target\release\kenai_windows_vpn_service.exe'
$rollbackRoot = Join-Path $env:TEMP 'kenai-armenia-readiness-rollback'
$rollbackArtifact = Join-Path $rollbackRoot 'KenaiVpnService.exe'
$installed = 'C:\Program Files\Kenai VPN\service\KenaiVpnService.exe'
$oldHash = '63F8131F17AE15E17A78642078B764527BEF4C95409A9F218BB4F5C3C1F5E4FD'
$newHash = '1401C3D953A8F5DF80805165048B354D070CA6C7FD2C4AB2A59ABDDBFC7091B9'
$packagedHash = '3A031BECE7E107B33238B5A2B652A56E7261C61D9A5CC735AB1B069D19820932'
$touched = $false

function Assert-Hash([string]$Path, [string]$Expected, [string]$Code) {
    if (-not (Test-Path -LiteralPath $Path) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) {
        throw $Code
    }
}

function Set-ServiceBinary([string]$Source, [string]$Expected) {
    Stop-Service KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus(
        'Stopped', [TimeSpan]::FromSeconds(20))
    Copy-Item -LiteralPath $Source -Destination $installed -Force
    Assert-Hash $installed $Expected 'COPY_CHECK_FAILED'
    Start-Service KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus(
        'Running', [TimeSpan]::FromSeconds(20))
}

try {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'ADMIN_REQUIRED'
    }

    if ($Rollback) {
        $currentHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        if ($currentHash -notin @($newHash, $packagedHash)) {
            throw 'INSTALLED_NEW_MISMATCH'
        }
        Assert-Hash $rollbackArtifact $oldHash 'ROLLBACK_ARTIFACT_MISMATCH'
        $touched = $true
        Set-ServiceBinary $rollbackArtifact $oldHash
        exit 0
    }

    Assert-Hash $installed $oldHash 'INSTALLED_BASELINE_MISMATCH'
    Assert-Hash $candidate $newHash 'CANDIDATE_MISMATCH'
    New-Item -ItemType Directory -Path $rollbackRoot -Force | Out-Null
    Copy-Item -LiteralPath $installed -Destination $rollbackArtifact -Force
    Assert-Hash $rollbackArtifact $oldHash 'ROLLBACK_COPY_MISMATCH'
    $touched = $true
    Set-ServiceBinary $candidate $newHash
    exit 0
} catch {
    if ($touched -and -not $Rollback) {
        try {
            Assert-Hash $rollbackArtifact $oldHash 'ROLLBACK_ARTIFACT_MISMATCH'
            Set-ServiceBinary $rollbackArtifact $oldHash
        } catch {
            exit 2
        }
    }
    exit 1
}
