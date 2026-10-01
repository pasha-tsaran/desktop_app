[CmdletBinding()]
param([switch]$PreflightOnly)

# Operator-only, elevated diagnostic. No server, profile, route or DNS changes.
# The sole mutation is an exact, temporary outbound block for the first app.
$ErrorActionPreference = 'Stop'
$engine = 'C:\Program Files\Kenai VPN\service\xray\amd64\xray.exe'
$endpoint = '88.218.94.3'
$ruleName = 'KenaiRecoveryTest-' + [guid]::NewGuid().ToString('N')
$eventName = 'Local\' + $ruleName
$ready = $null
$attemptedRule = $false

function Test-ArmeniaExit {
    # Windows PowerShell 5.1 maps native stderr to ErrorRecord; a timeout is
    # a probe result, not a reason to abort cleanup or the recovery loop.
    $ErrorActionPreference = 'Continue'
    $result = & "$env:SystemRoot\System32\curl.exe" -q --noproxy '*' -4 `
        --silent --connect-timeout 4 --max-time 8 https://api.ipify.org 2>$null
    $code = $LASTEXITCODE
    Write-Output ('CURL_EXIT=' + $code)
    return ($code -eq 0 -and (($result -join '').Trim() -eq $endpoint))
}

try {
    Write-Output 'TEST_VERSION=ARMENIA-RECOVERY-1'
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'ADMIN_REQUIRED'
    }
    if (-not (Test-Path -LiteralPath $engine -PathType Leaf)) { throw 'ENGINE_NOT_FOUND' }
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='xray.exe'" |
        Where-Object { $_.ExecutablePath -eq $engine })
    if ($processes.Count -ne 1) { throw 'EXPECTED_ONE_FIRST_APP_ENGINE' }
    $connections = @(Get-NetTCPConnection -RemoteAddress $endpoint -RemotePort 443 `
        -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.OwningProcess -eq $processes[0].ProcessId })
    if ($connections.Count -eq 0) { throw 'ARMENIA_CONNECTION_NOT_FOUND' }
    if ((Get-NetAdapter -Name KenaiXray).Status -ne 'Up') { throw 'TUN_NOT_UP' }
    if (@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -gt 0) {
        throw 'FIREWALL_PROFILE_DISABLED'
    }
    Write-Output ('INGRESS_ESTABLISHED=' + $connections.Count)
    $before = @(Test-ArmeniaExit)
    $before | Select-Object -SkipLast 1 | Write-Output
    if ($before[-1] -ne $true) { throw 'BASELINE_FAILED_NO_CHANGES' }
    Write-Output 'BEFORE_ARMENIA_EXIT=True'
    if ($PreflightOnly) { Write-Output 'PREFLIGHT_OK_NO_CHANGES'; return }

    # Independent elevated process survives failure/closure of this console.
    # It is armed before any rule is created and removes only this random name.
    $watchdogCode = @"
`$ErrorActionPreference = 'Stop'
Import-Module NetSecurity
`$signal = [Threading.EventWaitHandle]::OpenExisting('$eventName')
[void]`$signal.Set()
`$signal.Dispose()
Start-Sleep -Seconds 40
for (`$i = 0; `$i -lt 5; `$i++) {
    try {
        Get-NetFirewallRule -Name '$ruleName' -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction Stop
    } catch { }
    Start-Sleep -Seconds 2
}
"@
    $ready = [Threading.EventWaitHandle]::new($false,
        [Threading.EventResetMode]::ManualReset, $eventName)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($watchdogCode))
    $watchdog = Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden -PassThru
    if (-not $ready.WaitOne(8000) -or $watchdog.HasExited) { throw 'WATCHDOG_NOT_READY' }
    Write-Output 'AUTO_CLEANUP_ARMED=True'
    Write-Output ('TEMPORARY_RULE=' + $ruleName)
    $attemptedRule = $true
    try {
        New-NetFirewallRule -Name $ruleName -DisplayName $ruleName -Direction Outbound `
            -Action Block -Program $engine -Protocol TCP -RemoteAddress $endpoint `
            -RemotePort 443 -Profile Any -Enabled True | Out-Null
        if (-not (Get-NetFirewallRule -Name $ruleName -PolicyStore ActiveStore)) {
            throw 'BLOCK_NOT_ACTIVE'
        }
        Write-Output 'INTERRUPTION_WINDOW_SECONDS=15'
        Write-Output 'NO_PUBLIC_REQUESTS_DURING_INTERRUPTION=True'
        Start-Sleep -Seconds 15
    } finally {
        Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule -ErrorAction Stop
    }
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) {
        throw 'RULE_REMOVAL_NOT_CONFIRMED'
    }
    Write-Output 'BLOCK_REMOVED=True'
    $recovered = $false
    foreach ($attempt in 1..4) {
        Start-Sleep -Seconds 3
        $probe = @(Test-ArmeniaExit)
        $probe | Select-Object -SkipLast 1 | Write-Output
        $recovered = ($probe[-1] -eq $true)
        Write-Output ("RECOVERY_ATTEMPT=$attempt ARMENIA_EXIT=$recovered")
        if ($recovered) { break }
    }
    Write-Output ('AUTOMATIC_RECOVERY=' + $recovered)
    if (-not $recovered) { Write-Output 'NEXT_STEP=DISCONNECT_THEN_CONNECT_IN_FIRST_APP' }
} catch {
    # No raw exception text, VPN profiles or credentials in diagnostic output.
    Write-Output ('TEST_ERROR_TYPE=' + $_.Exception.GetType().Name)
    $known = @('ADMIN_REQUIRED', 'ENGINE_NOT_FOUND', 'EXPECTED_ONE_FIRST_APP_ENGINE',
        'ARMENIA_CONNECTION_NOT_FOUND', 'TUN_NOT_UP', 'FIREWALL_PROFILE_DISABLED',
        'BASELINE_FAILED_NO_CHANGES', 'WATCHDOG_NOT_READY', 'BLOCK_NOT_ACTIVE',
        'RULE_REMOVAL_NOT_CONFIRMED')
    if ($_.Exception.Message -in $known) { Write-Output ('TEST_ERROR=' + $_.Exception.Message) }
} finally {
    if ($attemptedRule) {
        try {
            Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue |
                Remove-NetFirewallRule -ErrorAction Stop
            Write-Output ('CLEANUP_CONFIRMED=' + (-not [bool](
                Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)))
        } catch { Write-Output 'CLEANUP_PENDING_WATCHDOG=True' }
    }
    if ($null -ne $ready) { $ready.Dispose() }
    Write-Output 'TEST_FINISHED'
}
