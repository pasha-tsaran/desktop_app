[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Downloads'),
    [switch]$SkipNetworkChecks
)

# Read-only diagnostics for a connected Kenai VLESS tunnel. The only write is
# the report file. Never read application storage, VPN profiles or service logs.
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw "Output directory does not exist: $OutputDirectory"
}

$report = Join-Path $OutputDirectory (
    'Kenai-VLESS-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff')
)
$lines = [System.Collections.Generic.List[string]]::new()

function Add-Line([string]$value) {
    $lines.Add($value)
}

function Add-Section([string]$title) {
    Add-Line ''
    Add-Line ('=== ' + $title + ' ===')
}

function Add-Error([string]$label) {
    # Do not put raw exception text in the report: it may include local paths.
    Add-Line ($label + '=UNAVAILABLE')
}

function Get-KenaiCounters {
    try {
        $value = Get-NetAdapterStatistics -Name 'KenaiXray' -ErrorAction Stop
        return @{ Received = [uint64]$value.ReceivedBytes; Sent = [uint64]$value.SentBytes }
    } catch {
        return $null
    }
}

function Invoke-HttpCheck([string]$label, [string]$family, [string]$url) {
    try {
        $result = & curl.exe $family --noproxy '*' --silent --location --max-time 20 `
            --output NUL --write-out 'HTTP=%{http_code};seconds=%{time_total}' `
            $url 2>$null
        $code = $LASTEXITCODE
        Add-Line ("$label exit=$code $result")
    } catch {
        Add-Error $label
    }
}

function Get-StunMappedAddress([byte[]]$response, [byte[]]$request) {
    if ($response.Length -lt 20 -or $response[0] -ne 1 -or $response[1] -ne 1) {
        return $null
    }
    for ($i = 4; $i -lt 20; $i++) {
        if ($response[$i] -ne $request[$i]) { return $null }
    }
    $messageLength = ([int]$response[2] -shl 8) -bor [int]$response[3]
    $limit = [Math]::Min($response.Length, 20 + $messageLength)
    $offset = 20
    while ($offset + 4 -le $limit) {
        $type = ([int]$response[$offset] -shl 8) -bor [int]$response[$offset + 1]
        $length = ([int]$response[$offset + 2] -shl 8) -bor [int]$response[$offset + 3]
        $valueOffset = $offset + 4
        if ($valueOffset + $length -gt $limit) { break }
        if ($type -eq 0x0020 -and $length -ge 8 -and $response[$valueOffset + 1] -eq 1) {
            $bytes = [byte[]]::new(4)
            for ($i = 0; $i -lt 4; $i++) {
                $bytes[$i] = $response[$valueOffset + 4 + $i] -bxor $request[4 + $i]
            }
            return ([System.Net.IPAddress]::new($bytes)).ToString()
        }
        $offset = $valueOffset + (4 * [Math]::Ceiling($length / 4.0))
    }
    return $null
}

function Test-Stun([string]$hostname, [int]$port) {
    try {
        $address = [System.Net.Dns]::GetHostAddresses($hostname) |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
            Select-Object -First 1
        if ($null -eq $address) { return @{ Status = 'DNS_FAILED'; Address = $null } }
    } catch {
        return @{ Status = 'DNS_FAILED'; Address = $null }
    }
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $client = $null
        try {
            $request = [byte[]]::new(20)
            $request[0] = 0
            $request[1] = 1
            $request[4] = 0x21
            $request[5] = 0x12
            $request[6] = 0xa4
            $request[7] = 0x42
            $nonce = [byte[]]::new(12)
            $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
            try { $rng.GetBytes($nonce) } finally { $rng.Dispose() }
            [Array]::Copy($nonce, 0, $request, 8, 12)
            $client = [System.Net.Sockets.UdpClient]::new(
                [System.Net.Sockets.AddressFamily]::InterNetwork)
            $client.Client.ReceiveTimeout = 4000
            $client.Connect($address, $port)
            $started = [System.Diagnostics.Stopwatch]::StartNew()
            [void]$client.Send($request, $request.Length)
            $remote = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
            $response = $client.Receive([ref]$remote)
            $started.Stop()
            $mapped = Get-StunMappedAddress $response $request
            if ($null -eq $mapped) {
                return @{ Status = 'INVALID_RESPONSE'; Address = $null }
            }
            return @{
                Status = ('RESPONSE;attempt={0};milliseconds={1}' -f
                    $attempt, $started.ElapsedMilliseconds)
                Address = $mapped
            }
        } catch [System.Net.Sockets.SocketException] {
            if ($attempt -eq 2) {
                return @{ Status = ('SOCKET_ERROR_' + $_.Exception.ErrorCode); Address = $null }
            }
        } catch {
            return @{ Status = 'ERROR'; Address = $null }
        } finally {
            if ($null -ne $client) { $client.Dispose() }
        }
    }
}

Add-Line 'Kenai VPN VLESS diagnostic report'
Add-Line ('Captured=' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz'))
Add-Line 'The script makes no network or VPN configuration changes.'

Add-Section 'Application and service'
try {
    $exe = Get-Item -LiteralPath 'C:\Program Files\Kenai VPN\app\KenaiVPN.exe' -ErrorAction Stop
    Add-Line ('ClientVersion=' + $exe.VersionInfo.ProductVersion)
} catch { Add-Error 'ClientVersion' }
try {
    $service = Get-Service -Name 'KenaiVpnService' -ErrorAction Stop
    Add-Line ('KenaiService=' + $service.Status)
} catch { Add-Error 'KenaiService' }
try {
    $processes = @(Get-Process -Name 'xray' -ErrorAction Stop)
    Add-Line ('XrayProcessCount=' + $processes.Count)
} catch { Add-Line 'XrayProcessCount=0' }

Add-Section 'VPN adapters and Kenai addresses'
try {
    $adapters = @(Get-NetAdapter -ErrorAction Stop |
        Where-Object { $_.Name -match 'Kenai|Amnezia' })
    foreach ($adapter in $adapters) {
        Add-Line ('Adapter={0};Status={1};Index={2}' -f
            $adapter.Name, $adapter.Status, $adapter.ifIndex)
    }
    if ($adapters.Count -eq 0) { Add-Line 'Adapters=NONE' }
} catch { Add-Error 'Adapters' }
try {
    $addresses = @(Get-NetIPAddress -InterfaceAlias 'KenaiXray' -ErrorAction Stop)
    foreach ($address in $addresses) {
        Add-Line ('KenaiAddress={0}/{1};Family={2}' -f
            $address.IPAddress, $address.PrefixLength, $address.AddressFamily)
    }
    if ($addresses.Count -eq 0) { Add-Line 'KenaiAddress=NONE' }
} catch { Add-Error 'KenaiAddress' }

Add-Section 'Default routes and interface metrics'
try {
    $routes = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0','::/0' -ErrorAction Stop)
    foreach ($route in $routes) {
        Add-Line ('Route={0};Via={1};Index={2};Metric={3}' -f
            $route.DestinationPrefix, $route.InterfaceAlias,
            $route.InterfaceIndex, $route.RouteMetric)
    }
    if ($routes.Count -eq 0) { Add-Line 'Routes=NONE' }
} catch { Add-Error 'Routes' }
try {
    $metrics = @(Get-NetIPInterface -ErrorAction Stop |
        Where-Object { $_.InterfaceAlias -match 'Kenai|Amnezia' -or
            $_.InterfaceIndex -in @($routes | ForEach-Object { $_.InterfaceIndex }) })
    foreach ($metric in $metrics) {
        Add-Line ('Interface={0};Family={1};Index={2};Metric={3}' -f
            $metric.InterfaceAlias, $metric.AddressFamily,
            $metric.InterfaceIndex, $metric.InterfaceMetric)
    }
} catch { Add-Error 'InterfaceMetrics' }
try {
    $dns = @(Get-DnsClientServerAddress -InterfaceAlias 'KenaiXray' -ErrorAction Stop)
    foreach ($entry in $dns) {
        Add-Line ('KenaiDNS={0};Family={1}' -f
            ($entry.ServerAddresses -join ','), $entry.AddressFamily)
    }
} catch { Add-Error 'KenaiDNS' }

$before = Get-KenaiCounters
Add-Section 'Network checks through the current Windows route'
if ($SkipNetworkChecks) {
    Add-Line 'NetworkChecks=SKIPPED'
} elseif (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Add-Line 'NetworkChecks=CURL_MISSING'
} else {
    Invoke-HttpCheck 'CloudflareIPv4' '--ipv4' 'https://www.cloudflare.com/cdn-cgi/trace'
    Invoke-HttpCheck 'CloudflareIPv6' '--ipv6' 'https://www.cloudflare.com/cdn-cgi/trace'
    Invoke-HttpCheck 'YouTubeIPv4' '--ipv4' 'https://www.youtube.com/generate_204'
    try {
        $trace = & curl.exe --ipv4 --noproxy '*' --silent --max-time 20 `
            'https://www.cloudflare.com/cdn-cgi/trace' 2>$null
        $code = $LASTEXITCODE
        $country = (($trace -join "`n") -split "`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^loc=[A-Z]{2}$' } |
            Select-Object -First 1)
        if (-not $country) { $country = 'loc=UNKNOWN' }
        Add-Line ("ExitCountry=$country;exit=$code")
        # Deliberately discard the trace's public IP and other fields.
    } catch { Add-Error 'ExitCountry' }

    Add-Section 'UDP STUN checks through the current Windows route'
    $httpsExit = $null
    try {
        $exitTrace = & curl.exe --ipv4 --noproxy '*' --silent --max-time 10 `
            'https://www.cloudflare.com/cdn-cgi/trace' 2>$null
        if ($LASTEXITCODE -eq 0) {
            $ipLine = (($exitTrace -join "`n") -split "`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -match '^ip=([0-9]{1,3}\.){3}[0-9]{1,3}$' } |
                Select-Object -First 1)
            if ($ipLine) { $httpsExit = $ipLine.Substring(3) }
        }
    } catch { }
    foreach ($server in @(
        @{ Hostname = 'stun.cloudflare.com'; Port = 3478 },
        @{ Hostname = 'stun.l.google.com'; Port = 19302 }
    )) {
        $hostname = $server.Hostname
        $result = Test-Stun $hostname $server.Port
        Add-Line ('STUN_{0}={1}' -f $hostname, $result.Status)
        if ($null -ne $result.Address -and $null -ne $httpsExit) {
            $comparison = if ($result.Address -eq $httpsExit) { 'SAME' } else { 'DIFFERENT' }
            Add-Line ('STUN_{0}_versus_HTTPS_exit={1}' -f $hostname, $comparison)
        } else {
            Add-Line ('STUN_{0}_versus_HTTPS_exit=UNKNOWN' -f $hostname)
        }
        # Public IPs returned by STUN and HTTPS are never written to the report.
    }
}

Add-Section 'Kenai tunnel byte counters'
$after = Get-KenaiCounters
if ($null -eq $before -or $null -eq $after) {
    Add-Line 'KenaiCounters=UNAVAILABLE'
} else {
    Add-Line ('ReceivedBefore={0};ReceivedAfter={1};ReceivedDelta={2}' -f
        $before.Received, $after.Received,
        [math]::Max(0, [long]$after.Received - [long]$before.Received))
    Add-Line ('SentBefore={0};SentAfter={1};SentDelta={2}' -f
        $before.Sent, $after.Sent,
        [math]::Max(0, [long]$after.Sent - [long]$before.Sent))
}

$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Output "Report saved: $report"
