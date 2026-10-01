[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    throw 'Flutter SDK is required. Install Flutter stable, then run this script again.'
}

$appPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'apps/desktop'
$runnerPath = Join-Path $appPath 'windows'
if (Test-Path -LiteralPath $runnerPath) {
    Write-Output 'Windows runner already exists; nothing changed.'
    exit 0
}

flutter create --platforms=windows --project-name=kenai_vpn_desktop $appPath
Write-Output 'Generated the standard Flutter Windows host. Review generated files before commit.'
