[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
$helper = $null

function New-DnsProbe([uint16]$id, [byte]$recordType) {
    $bytes = [Collections.Generic.List[byte]]::new()
    $bytes.AddRange([byte[]]@(($id -shr 8), ($id -band 255), 1, 0, 0, 1, 0, 0, 0, 0, 0, 0))
    foreach ($label in @('example','com')) {
        $bytes.Add([byte]$label.Length)
        $bytes.AddRange([Text.Encoding]::ASCII.GetBytes($label))
    }
    $bytes.AddRange([byte[]]@(0, 0, $recordType, 0, 1))
    return ,$bytes.ToArray()
}
function Test-DnsProbeReply([byte[]]$reply, [byte[]]$request) {
    return ($reply.Length -ge 12 -and $reply[0] -eq $request[0] -and
        $reply[1] -eq $request[1] -and ($reply[2] -band 128) -ne 0 -and
        ($reply[3] -band 15) -eq 0 -and ($reply[6] -ne 0 -or $reply[7] -ne 0))
}
function Test-UdpDns([string]$server, [string]$source = '0.0.0.0', [byte]$recordType = 1) {
    $udp = $null
    try {
        $request = New-DnsProbe ([uint16](Get-Random -Minimum 1 -Maximum 65535)) $recordType
        $bind = [Net.IPEndPoint]::new([Net.IPAddress]::Parse($source), 0)
        $udp = [Net.Sockets.UdpClient]::new($bind)
        $udp.Client.ReceiveTimeout = 2500
        $udp.Client.SendTimeout = 2500
        $udp.Connect($server, 53)
        [void]$udp.Send($request, $request.Length)
        $remote = [Net.IPEndPoint]::new([Net.IPAddress]::Any, 0)
        $reply = $udp.Receive([ref]$remote)
        return (Test-DnsProbeReply $reply $request)
    } catch { return $false }
    finally { if ($null -ne $udp) { $udp.Dispose() } }
}
function Test-ArmeniaHttp {
    $ErrorActionPreference = 'Continue'
    $result = @(& "$env:SystemRoot\System32\curl.exe" -q --noproxy '*' -4 --silent `
        --connect-timeout 4 --max-time 8 https://api.ipify.org 2>$null)
    $script:lastHttpTrace = 'IPIFY_EXIT=' + $LASTEXITCODE
    if ($LASTEXITCODE -eq 0 -and ($result -join '').Trim() -eq '88.218.94.3') { return $true }
    $trace = @(& "$env:SystemRoot\System32\curl.exe" -q --noproxy '*' -4 --silent `
        --connect-timeout 4 --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>$null)
    $script:lastHttpTrace += ' CLOUDFLARE_EXIT=' + $LASTEXITCODE
    return ($LASTEXITCODE -eq 0 -and @($trace | Where-Object { $_.Trim() -eq 'ip=88.218.94.3' }).Count -eq 1)
}

try {
    Write-Output 'DIAGNOSTIC_VERSION=FIRST-VPN-DNS-LIVE-1'
    if ($SelfTest) {
        $q = New-DnsProbe 4660 28
        if ($q.Length -ne 29 -or $q[0] -ne 18 -or $q[1] -ne 52 -or $q[26] -ne 28) { throw 'QUERY' }
        $reply = [byte[]]@(18,52,129,128,0,1,0,1,0,0,0,0)
        if (-not (Test-DnsProbeReply $reply $q)) { throw 'VALID_REPLY' }
        $reply[1] = 53
        if (Test-DnsProbeReply $reply $q) { throw 'WRONG_ID' }
        if (Test-DnsProbeReply ([byte[]]@(18,52)) $q) { throw 'SHORT_REPLY' }
        Write-Output 'SELF_TEST=True'
        return
    }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output 'RESULT=ADMIN_REQUIRED'; return
    }
    $binary = Join-Path $env:TEMP 'kenai-first-dns-validation\debug\examples\dns_guard_probe.exe'
    if ((Get-FileHash -LiteralPath $binary).Hash -ne '32F58619B05B8CA4A4AC23B87EF0CBFF78A95FAF06D1D20BBA08480E2448C0C4') {
        Write-Output 'RESULT=HELPER_HASH_MISMATCH'; return
    }
    if ((Get-NetAdapter -Name KenaiXray).Status -ne 'Up' -or -not (Test-ArmeniaHttp)) {
        Write-Output 'RESULT=CONNECT_FIRST_APP_TO_ARMENIA'; return
    }
    $lanDns = $null
    $lanSource = $null
    foreach ($nic in @(Get-NetAdapter -Physical | Where-Object Status -eq 'Up')) {
        foreach ($server in @((Get-DnsClientServerAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4).ServerAddresses)) {
            $routes = @(Find-NetRoute -RemoteIPAddress $server -ErrorAction SilentlyContinue)
            if (@($routes | Where-Object InterfaceIndex -eq $nic.ifIndex).Count -eq 0) { continue }
            $source = Get-NetIPAddress -InterfaceIndex $nic.ifIndex -AddressFamily IPv4 |
                Where-Object AddressState -eq 'Preferred' | Select-Object -First 1 -ExpandProperty IPAddress
            if ($source -and (Test-UdpDns $server $source)) { $lanDns=$server; $lanSource=$source; break }
        }
        if ($lanDns) { break }
    }
    Write-Output ('PHYSICAL_DNS_BASELINE_RESPONDS=' + [bool]$lanDns)
    if (-not $lanDns) { Write-Output 'RESULT=NO_PHYSICAL_DNS_CONTROL_TEST'; return }
    if (-not (Test-UdpDns '1.1.1.1') -or -not (Test-UdpDns '1.0.0.1')) {
        Write-Output 'RESULT=TUN_DNS_BASELINE_FAILED'; return
    }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $binary
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $helper = [Diagnostics.Process]::Start($start)
    $ready = $helper.StandardOutput.ReadLineAsync()
    if (-not $ready.Wait(8000) -or $ready.Result -ne 'DNS_GUARD_READY=True') {
        Write-Output 'RESULT=GUARD_START_FAILED'; return
    }
    Write-Output 'DNS_GUARD_ACTIVE=True'
    $blocked = -not (Test-UdpDns $lanDns $lanSource)
    Write-Output ('PHYSICAL_DNS_BLOCKED=' + $blocked)
    $tunDns = $true
    foreach ($server in @('1.1.1.1','1.0.0.1')) {
        foreach ($type in @([byte]1,[byte]28)) {
            $ok = Test-UdpDns $server '0.0.0.0' $type
            $tunDns = $tunDns -and $ok
            Write-Output ("TUN_DNS_SERVER=$server TYPE=$type ANSWER=$ok")
        }
    }
    $http = Test-ArmeniaHttp
    Write-Output ('GUARDED_HTTP_DIAGNOSTIC=' + $script:lastHttpTrace)
    Write-Output ('GUARDED_ARMENIA_HTTP=' + $http)
    $windowValid = -not $helper.HasExited
    Write-Output ('GUARD_WINDOW_VALID=' + $windowValid)
    # Wait for the helper's own 45-second expiry; the script never changes
    # firewall rules itself. Killing just this owned helper is safe recovery.
    if (-not $helper.WaitForExit(48000)) { $helper.Kill(); $helper.WaitForExit() }
    Write-Output ('GUARD_HELPER_EXIT=' + $helper.ExitCode)
    $restored = Test-UdpDns $lanDns $lanSource
    $afterHttp = Test-ArmeniaHttp
    Write-Output ('AFTER_HTTP_DIAGNOSTIC=' + $script:lastHttpTrace)
    Write-Output ('PHYSICAL_DNS_RESTORED=' + $restored)
    Write-Output ('AFTER_ARMENIA_HTTP=' + $afterHttp)
    Write-Output ('LIVE_DNS_CHECK=' + ($blocked -and $tunDns -and $http -and $windowValid -and $restored -and $afterHttp -and $helper.ExitCode -eq 0))
    Write-Output 'INSTALLED_SERVICE_CHANGED=False'
    Write-Output 'FULL_LEAK_CAPTURE=NOT_PERFORMED'
} catch {
    Write-Output ('ERROR_TYPE=' + $_.Exception.GetType().Name)
    Write-Output 'RESULT=TEST_INCOMPLETE'
} finally {
    if ($null -ne $helper) {
        try { if (-not $helper.HasExited) { $helper.Kill(); $helper.WaitForExit() } }
        catch { Write-Output 'CLEANUP=WAIT_FOR_45_SECOND_HELPER_EXPIRY' }
        $helper.Dispose()
    }
    Write-Output 'TEST_FINISHED'
}
