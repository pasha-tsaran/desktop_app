[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$ProfileCheckOnly,
    [switch]$SystemWorker,
    [string]$ReportPath,
    [ValidateSet('firefox','chrome')][string]$TestFingerprint = 'firefox'
)
$ErrorActionPreference = 'Stop'
# Separate loopback SOCKS probe; no TUN, route, DNS or service changes.
# Credentials stay in memory and are sent to the installed engine through stdin.
Add-Type -AssemblyName System.Security
$child = $null
$plain = $null
$started = $false
$stage = 'INITIALIZE'
function Read-Field($Reader) {
    $size = $Reader.ReadByte()
    $bytes = $Reader.ReadBytes($size)
    if ($bytes.Length -ne $size) { throw 'Truncated profile' }
    return [Text.Encoding]::UTF8.GetString($bytes)
}
if ($SelfTest) {
    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new([byte[]](3,97,98,99)))
    try { if ((Read-Field $reader) -ne 'abc') { throw 'Field decode failed' } } finally { $reader.Dispose() }
    $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new([byte[]](3,97)))
    $rejected = $false
    try { [void](Read-Field $reader) } catch { $rejected = $true } finally { $reader.Dispose() }
    if (-not $rejected) { throw 'Truncated field accepted' }
    Write-Output 'PASS: profile field decoding and truncated data rejection. No network or vault access.'
    return
}
$folder = [Environment]::GetFolderPath('Desktop')
if ([string]::IsNullOrWhiteSpace($folder)) { $folder = $PSScriptRoot }
$report = Join-Path $folder ('Kenai-NL-test-' + (Get-Date -Format yyyyMMdd-HHmmss) + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.txt')
if ($SystemWorker) {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'System worker requires SYSTEM' }
    if ([string]::IsNullOrWhiteSpace($ReportPath)) { throw 'Report path required' }
    $report = $ReportPath
} else {
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output 'Run this script from PowerShell as administrator.'
        return
    }
    if (-not $ProfileCheckOnly -and @(Get-Process xray -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Output 'VPN_MUST_BE_DISCONNECTED: disconnect VPN, then run again.'
        return
    }
    $taskName = 'Kenai-Transport-Diagnostic-' + [guid]::NewGuid().ToString('N')
    $taskRegistered = $false
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -SystemWorker -ReportPath "' + $report + '"'
        $arguments += ' -TestFingerprint ' + $TestFingerprint
        if ($ProfileCheckOnly) { $arguments += ' -ProfileCheckOnly' }
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument $arguments
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        [void](Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest)
        $taskRegistered = $true
        Write-Output 'Running isolated diagnostic. Keep this window open (up to one minute).'
        Start-ScheduledTask -TaskName $taskName
        $deadline = [DateTime]::UtcNow.AddSeconds(65)
        do {
            Start-Sleep -Milliseconds 500
            $info = Get-ScheduledTaskInfo -TaskName $taskName
            $state = (Get-ScheduledTask -TaskName $taskName).State
            if ((Test-Path -LiteralPath $report) -and $state -ne 'Running' -and $state -ne 'Queued') { break }
        } while ([DateTime]::UtcNow -lt $deadline)
        if (Test-Path -LiteralPath $report) { Get-Content -LiteralPath $report }
        if ($state -eq 'Running' -or $state -eq 'Queued') { Write-Output 'probe=WORKER_TIMEOUT' }
        else { Write-Output ('worker_exit=' + $info.LastTaskResult) }
        Write-Output ('Saved: ' + $report)
    } catch {
        $failure = $_.Exception
        while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
        Write-Output ('probe=WORKER_START_FAILED;type=' + $failure.GetType().Name + ';hresult=' + $failure.HResult)
    } finally {
        if ($taskRegistered) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        }
    }
    return
}
$log = [IO.StreamWriter]::new($report,$false,[Text.UTF8Encoding]::new($false))
$log.AutoFlush = $true
function Report([string]$Message) {
    $line = (Get-Date).ToString('o') + ' ' + $Message
    $log.WriteLine($line)
    Write-Output $line
}
try {
    Report ('probe=START;revision=4;profile_check_only=' + [bool]$ProfileCheckOnly + ';fingerprint=' + $TestFingerprint + ';routes_unchanged=true')
    $stage = 'CHECK_ADMIN'
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Report 'probe=RUN_POWERSHELL_AS_ADMINISTRATOR'
        return
    }
    $stage = 'CHECK_ACTIVE_VPN'
    if (-not $ProfileCheckOnly -and @(Get-Process xray -ErrorAction SilentlyContinue).Count -gt 0) {
        Report 'probe=VPN_MUST_BE_DISCONNECTED'
        return
    }
    $engine = Join-Path $env:ProgramFiles 'Kenai VPN\service\xray\amd64\xray.exe'
    $stage = 'VERIFY_ENGINE'
    $hash = (Get-FileHash -LiteralPath $engine -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne '6b5cd540e3f4ce59f309863f0f1339b0bda13aeb9451405abfca29ba873cca20') { throw 'Unverified engine' }
    $chosen = $null
    $vault = Join-Path $env:ProgramData 'KenaiVPN\profiles'
    $stage = 'LIST_PROFILES'
    foreach ($file in (Get-ChildItem -LiteralPath $vault -Filter 'xray-*.bin' | Sort-Object LastWriteTimeUtc -Descending)) {
        $stage = 'READ_PROFILE'
        $encrypted = [IO.File]::ReadAllBytes($file.FullName)
        $stage = 'DECRYPT_PROFILE'
        $plain = [Security.Cryptography.ProtectedData]::Unprotect($encrypted, [Text.Encoding]::UTF8.GetBytes('KenaiVPN.ProfileVault.v1'), [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $stage = 'PARSE_PROFILE'
        $reader = [IO.BinaryReader]::new([IO.MemoryStream]::new($plain))
        try {
            if ([Text.Encoding]::ASCII.GetString($reader.ReadBytes(4)) -ne 'KXP1') { throw 'Invalid profile format' }
            $identifier = Read-Field $reader
            $endpoint = Read-Field $reader
            $port = $reader.ReadUInt16()
            $serverName = Read-Field $reader
            $fingerprint = Read-Field $reader
            $password = Read-Field $reader
            $shortId = Read-Field $reader
            if ($endpoint -eq '147.45.231.194' -and $port -eq 443) {
                $chosen = @{address=$endpoint;port=$port;id=$identifier;serverName=$serverName;password=$password;shortId=$shortId}
                break
            }
        } finally { $reader.Dispose(); [Array]::Clear($plain,0,$plain.Length); $plain=$null }
    }
    if ($null -eq $chosen) { Report 'probe=NO_LOCAL_NL_PROFILE'; return }
    Report 'profile=most_recent_local_netherlands;credentials_not_exported=true'
    if ($ProfileCheckOnly) { Report 'probe=PROFILE_CHECK_OK;network_test_not_run=true'; return }
    $stage = 'ALLOCATE_LOOPBACK_PORT'
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
    $listener.Start()
    $probePort = $listener.LocalEndpoint.Port
    $listener.Stop()
    $config = @{
        log=@{loglevel='none'}
        inbounds=@(@{listen='127.0.0.1';port=$probePort;protocol='socks';settings=@{auth='noauth';udp=$false}})
        outbounds=@(@{protocol='vless';settings=@{address=$chosen.address;port=$chosen.port;id=$chosen.id;encryption='none';flow='xtls-rprx-vision'};streamSettings=@{network='raw';security='reality';realitySettings=@{serverName=$chosen.serverName;password=$chosen.password;shortId=$chosen.shortId;fingerprint=$TestFingerprint}}})
    }
    $info = New-Object Diagnostics.ProcessStartInfo
    $stage = 'START_ISOLATED_ENGINE'
    $info.FileName = $engine
    $info.Arguments = 'run -format json -config stdin:'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $child = New-Object Diagnostics.Process
    $child.StartInfo = $info
    [void]$child.Start()
    $started = $true
    $discardOutput = $child.StandardOutput.ReadToEndAsync()
    $discardError = $child.StandardError.ReadToEndAsync()
    $stage = 'SUPPLY_MEMORY_CONFIG'
    $child.StandardInput.Write(($config | ConvertTo-Json -Depth 12 -Compress))
    $child.StandardInput.Close()
    Start-Sleep -Seconds 1
    if ($child.HasExited) { Report ('probe=ISOLATED_ENGINE_EXITED;exit=' + $child.ExitCode); return }
    foreach ($url in @('http://1.1.1.1/cdn-cgi/trace','https://www.cloudflare.com/cdn-cgi/trace')) {
        $stage = 'HTTP_PROBE'
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $curlInfo = [Diagnostics.ProcessStartInfo]::new()
        $curlInfo.FileName = Join-Path $env:SystemRoot 'System32\curl.exe'
        $curlInfo.Arguments = '-q --noproxy localhost --silent --max-time 12 --socks5-hostname 127.0.0.1:' + $probePort + ' --output NUL --write-out %{http_code} ' + $url
        $curlInfo.UseShellExecute = $false
        $curlInfo.CreateNoWindow = $true
        $curlInfo.RedirectStandardOutput = $true
        $curlInfo.RedirectStandardError = $true
        $curl = [Diagnostics.Process]::new()
        $curl.StartInfo = $curlInfo
        $curlStarted = $false
        try {
            [void]$curl.Start(); $curlStarted = $true
            $outputTask = $curl.StandardOutput.ReadToEndAsync()
            $errorTask = $curl.StandardError.ReadToEndAsync()
            if (-not $curl.WaitForExit(15000)) {
                Report ('target=' + $url + ';probe=REQUEST_TIMEOUT')
            } else {
                $result = $outputTask.GetAwaiter().GetResult().Trim()
                if ($result -notmatch '^\d{3}$') { $result = 'unknown' }
                Report ('target=' + $url + ';curl_exit=' + $curl.ExitCode + ';http=' + $result + ';seconds=' + [Math]::Round($timer.Elapsed.TotalSeconds,2))
            }
        } finally {
            if ($curlStarted -and -not $curl.HasExited) { $curl.Kill(); [void]$curl.WaitForExit(3000) }
            $curl.Dispose()
        }
    }
} catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    Report ('probe=DIAGNOSTIC_FAILED;stage=' + $stage + ';type=' + $failure.GetType().Name + ';hresult=' + $failure.HResult)
} finally {
    if ($null -ne $plain) { [Array]::Clear($plain,0,$plain.Length) }
    if ($null -ne $child) {
        if ($started -and -not $child.HasExited) { $child.Kill(); [void]$child.WaitForExit(3000) }
        $child.Dispose()
    }
    $chosen = $null; $config = $null; $identifier = $null; $password = $null; $shortId = $null
    $log.Dispose()
    Write-Output ('Saved: ' + $report)
}
