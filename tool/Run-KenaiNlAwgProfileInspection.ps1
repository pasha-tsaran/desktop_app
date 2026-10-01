[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Administrator rights are required.'
}

$encrypted = $null
$plain = $null
$taskName = 'Kenai-AwgProfile-Diagnostic-' + [guid]::NewGuid().ToString('N')
$registered = $false
$reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\nl-awg-profile-summary.json'
$started = Get-Date
try {
    $storagePath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) `
        'Kenai VPN\Kenai VPN\flutter_secure_storage.dat'
    $encrypted = [IO.File]::ReadAllBytes($storagePath)
    $plain = [Security.Cryptography.ProtectedData]::Unprotect(
        $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $storage = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($plain))
    $handle = [string]$storage.'vpn.amneziawg_profile_handle.netherlands-1'
    if ($handle -notmatch '^awg-[0-9a-f]{32}$') { throw 'Invalid NL profile handle.' }

    $worker = Join-Path $PSScriptRoot 'Inspect-KenaiNlAwgProfile.ps1'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $worker + '" -ProfileHandle ' + $handle
    $action = New-ScheduledTaskAction -Execute `
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument $arguments
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    [void](Register-ScheduledTask -TaskName $taskName -Action $action `
        -Settings $settings -User 'SYSTEM' -RunLevel Highest)
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if ((Test-Path -LiteralPath $reportPath) -and
            (Get-Item -LiteralPath $reportPath).LastWriteTime -ge $started) {
            Write-Output 'profile_inspection=report_ready'
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Write-Output 'profile_inspection=worker_timeout'
} finally {
    if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    if ($null -ne $encrypted) { [Array]::Clear($encrypted, 0, $encrypted.Length) }
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
