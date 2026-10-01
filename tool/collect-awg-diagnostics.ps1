[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Downloads'))

# Run as Administrator while Kenai AWG is connected. Never export full dumps,
# keys, profiles or application storage. Does not change VPN/network settings.
$ErrorActionPreference = 'Stop'
$lines = [System.Collections.Generic.List[string]]::new()
$report = Join-Path $OutputDirectory ('Kenai-AWG-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$awg = 'C:\Program Files\Kenai VPN\service\amneziawg\amd64\awg.exe'
function Get-Fingerprint([string]$Value) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}
function Add-Result([string]$Label, [scriptblock]$Read) {
    try { $lines.Add($Label + '=' + ((& $Read | ConvertTo-Json -Compress -Depth 5) -join '')) }
    catch { $lines.Add($Label + '=unavailable') }
}
Add-Result 'services' { Get-Service -Name 'KenaiVpnService','AmneziaWGTunnel*' | Select-Object Name,@{n='Status';e={$_.Status.ToString()}} }
Add-Result 'app_version' { (Get-Item 'C:\Program Files\Kenai VPN\app\KenaiVPN.exe').VersionInfo.ProductVersion }
Add-Result 'adapters' { Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object Name,InterfaceIndex,InterfaceDescription }
Add-Result 'tunnel_addresses' { Get-NetIPAddress -InterfaceAlias 'KenaiAwg' | Select-Object IPAddress,PrefixLength }
Add-Result 'tunnel_dns' { Get-DnsClientServerAddress -InterfaceAlias 'KenaiAwg' | Select-Object AddressFamily,ServerAddresses }
Add-Result 'default_routes' { Get-NetRoute | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','::/0','0.0.0.0/1','128.0.0.0/1') } | Select-Object DestinationPrefix,InterfaceAlias,NextHop,RouteMetric }
function Add-PeerStatus([string]$Label) {
    try {
        $dump = @(& $awg show KenaiAwg dump 2>$null)
        if ($LASTEXITCODE -ne 0 -or $dump.Count -lt 2) { throw 'unavailable' }
        foreach ($peer in $dump[1..($dump.Count-1)]) {
            $f = $peer -split "`t"
            if ($f.Count -lt 8) { throw 'invalid' }
            $lines.Add($Label + '=' + (@{ endpoint=$f[2]; allowed_ips=$f[3]; handshake_unix=[long]$f[4]; received=[long]$f[5]; sent=[long]$f[6] } | ConvertTo-Json -Compress))
        }
    } catch { $lines.Add($Label + '=unavailable_run_as_administrator') }
    finally { $dump = $null; $f = $null; $peer = $null }
}
Add-PeerStatus 'peer_before'
try {
    # Compare against server-side fingerprints without exporting key material
    # or obfuscation values. Configuration stays in memory only.
    $raw = @(& $awg showconf KenaiAwg 2>$null)
    if ($LASTEXITCODE -ne 0) { throw 'unavailable' }
    $iface = @{}; $peerSettings = @{}; $section = ''
    foreach ($line in $raw) {
        if ($line.Trim() -eq '[Interface]') { $section = 'interface'; continue }
        if ($line.Trim() -eq '[Peer]') { $section = 'peer'; continue }
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $key = $parts[0].Trim().ToLowerInvariant()
            if ($key -eq 'privatekey' -or $key -eq 'presharedkey') { continue }
            if ($section -eq 'interface') { $iface[$key] = $parts[1].Trim() }
            elseif ($section -eq 'peer') { $peerSettings[$key] = $parts[1].Trim() }
        }
    }
    $canonical = foreach ($key in @('s1','s2','s3','s4','h1','h2','h3','h4')) {
        $value = if ($iface.ContainsKey($key)) { $iface[$key] } else { '0' }
        $key + '=' + $value
    }
    $lines.Add('transport_fingerprint=' + (Get-Fingerprint ($canonical -join "`n")))
    $lines.Add('server_public_fingerprint=' + (Get-Fingerprint $peerSettings['publickey']))
    $public = ((& $awg show KenaiAwg public-key 2>$null) -join '').Trim()
    if ($LASTEXITCODE -eq 0) { $lines.Add('client_public_fingerprint=' + (Get-Fingerprint $public)) }
} catch { $lines.Add('profile_fingerprints=unavailable') }
finally { $raw=$null; $iface=$null; $peerSettings=$null; $public=$null; $canonical=$null; $parts=$null; $line=$null; $value=$null }
try {
    $engine = 'C:\Program Files\Kenai VPN\service\amneziawg\amd64\amneziawg.exe'
    $log = @(& $engine /dumplog 2>$null)
    $bindings = @($log | Select-String 'Binding v4 socket to interface (\d+) \(blackhole=(true|false)\)' | Select-Object -Last 3)
    foreach ($binding in $bindings) {
        $lines.Add('engine_binding=' + $binding.Matches[0].Value)
    }
    $lines.Add('engine_handshake_retries=' + @($log | Select-String 'Handshake.*did not complete').Count)
} catch { $lines.Add('engine_log_summary=unavailable') }
finally { $log=$null; $bindings=$null; $binding=$null }
# Fixed public connectivity checks, no credentials or user browsing history.
foreach ($url in @('https://1.1.1.1/cdn-cgi/trace','https://www.cloudflare.com/cdn-cgi/trace')) {
    $result = & curl.exe -4 --noproxy '*' --silent --max-time 6 --output NUL --write-out '%{http_code}' $url 2>$null
    $lines.Add('http=' + $url + ';status=' + $result + ';exit=' + $LASTEXITCODE)
}
Add-PeerStatus 'peer_after'
$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Host ('Report: ' + $report)
