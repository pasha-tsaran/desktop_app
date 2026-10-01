[CmdletBinding()]
param([switch]$Rollback)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$candidate = Join-Path $env:TEMP 'kenai-first-dns-validation\release\kenai_windows_vpn_service.exe'
$original = Join-Path $repo 'build\system-update\verified-2.2.2-final\service\KenaiVpnService.exe'
$installed = 'C:\Program Files\Kenai VPN\service\KenaiVpnService.exe'
$oldHash = '1D0818BC304D44620175DBC19CB7C042294102A4C6764FD8ADEE8A053C7EA70B'
$newHash = '63F8131F17AE15E17A78642078B764527BEF4C95409A9F218BB4F5C3C1F5E4FD'
$touched = $false
try {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ADMIN_REQUIRED' }
    if ((Get-FileHash $original).Hash -ne $oldHash) { throw 'EXISTING_ROLLBACK_ARTIFACT_MISMATCH' }
    if ((Get-FileHash $candidate).Hash -ne $newHash) { throw 'CANDIDATE_MISMATCH' }
    $current = (Get-FileHash $installed).Hash
    if ($Rollback -and $current -eq $oldHash) { exit 0 }
    if ($current -ne $(if ($Rollback) { $newHash } else { $oldHash })) { throw 'INSTALLED_MISMATCH' }
    # No new backup or report files. Only a previously verified release is used.
    $touched = $true
    Stop-Service KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))
    Copy-Item -LiteralPath $(if ($Rollback) { $original } else { $candidate }) -Destination $installed -Force
    if ((Get-FileHash $installed).Hash -ne $(if ($Rollback) { $oldHash } else { $newHash })) { throw 'COPY_CHECK_FAILED' }
    Start-Service KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    exit 0
} catch {
    if ($touched) {
        try {
            Stop-Service KenaiVpnService -ErrorAction SilentlyContinue
            (Get-Service KenaiVpnService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))
            Copy-Item -LiteralPath $original -Destination $installed -Force
            Start-Service KenaiVpnService
            (Get-Service KenaiVpnService).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
        } catch { exit 2 }
    }
    exit 1
}
