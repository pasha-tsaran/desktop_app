$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$installer = Join-Path $repo 'dist\KenaiVPN-Setup-2.1.2-UNSIGNED.exe'
$installedApp = 'C:\Program Files\Kenai VPN\app\KenaiVPN.exe'
$installedService = 'C:\Program Files\Kenai VPN\service\KenaiVpnService.exe'
$installerHash = '5480C1AD59CFEBD87A56674423961D35B07396E701DCF78DBE5C17C8E800A842'
$appHash = '9FD293267F53B3A0DFC3B61D8EDE6704682A5D833B74A6991CEAD2D09BF2C5DE'
$serviceHash = '3A031BECE7E107B33238B5A2B652A56E7261C61D9A5CC735AB1B069D19820932'

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    exit 1
}
if ((Get-FileHash -LiteralPath $installer -Algorithm SHA256).Hash -ne
    $installerHash) {
    exit 2
}

$process = Start-Process -FilePath $installer -ArgumentList '/S' -PassThru -Wait
if ($process.ExitCode -ne 0) {
    exit 3
}
if ((Get-FileHash -LiteralPath $installedApp -Algorithm SHA256).Hash -ne
    $appHash) {
    exit 4
}
if ((Get-FileHash -LiteralPath $installedService -Algorithm SHA256).Hash -ne
    $serviceHash) {
    exit 5
}
exit 0
