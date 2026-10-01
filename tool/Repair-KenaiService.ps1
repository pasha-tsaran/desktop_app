[CmdletBinding()]
param(
    [string]$ReplacementServiceBinary
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$serviceName = 'KenaiVpnService'
$guiPath = "$env:ProgramFiles\Kenai VPN\app\KenaiVPN.exe"

# Keep the GUI closed while the service is restarted. Otherwise it can send a
# request before the clean service state has been verified.
Get-Process -Name 'KenaiVPN' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $guiPath } |
    Stop-Process -Force

$service = Get-Service -Name $serviceName -ErrorAction Stop
if ($service.Status -ne 'Stopped') {
    Stop-Service -Name $serviceName -Force
    $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(20))
}

# A worker-thread failure can orphan a LocalSystem Xray child and its default
# route even though the GUI reports disconnected. Limit cleanup to engines
# installed and owned by Kenai; they are recreated on the next connection.
$enginePaths = @(
    "$env:ProgramFiles\Kenai VPN\service\xray\amd64\xray.exe",
    "$env:ProgramFiles\Kenai VPN\service\amneziawg\amd64\amneziawg.exe"
)
Get-Process -Name 'xray', 'amneziawg' -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -in $enginePaths } |
    Stop-Process -Force

if ($ReplacementServiceBinary) {
    $replacement = (Resolve-Path -LiteralPath $ReplacementServiceBinary).Path
    if ([IO.Path]::GetFileName($replacement) -ne 'kenai_windows_vpn_service.exe') {
        throw 'Unexpected replacement service filename.'
    }
    Copy-Item -LiteralPath $replacement `
        -Destination "$env:ProgramFiles\Kenai VPN\service\KenaiVpnService.exe" `
        -Force
}

Start-Service -Name $serviceName
(Get-Service -Name $serviceName).WaitForStatus(
    'Running',
    [TimeSpan]::FromSeconds(20)
)
Write-Output 'kenai_service_repair=complete'
