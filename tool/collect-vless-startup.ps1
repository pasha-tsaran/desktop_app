[CmdletBinding()]
param(
    [ValidateRange(1, 120)][int]$DurationSeconds = 60,
    [string]$OutputDirectory = (Join-Path $env:USERPROFILE 'Downloads'),
    [switch]$SkipNetworkChecks
)

# Portable, read-only startup observer. Only the final report is written.
# Never reads VPN profiles, secure storage, command lines, or raw engine logs.
# Client logs are projected to an explicit vocabulary: no messages/fields copied.
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    throw 'Output directory must already exist.'
}
$report = Join-Path $OutputDirectory ('Kenai-VLESS-Startup-{0}.txt' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'))
$lines = [System.Collections.Generic.List[string]]::new()
function Add-Line([string]$Text) { $lines.Add($Text) }
function Add-Json([string]$Label, $Value) {
    Add-Line ($Label + '=' + (ConvertTo-Json -InputObject $Value -Compress -Depth 4))
}

Add-Line 'format=Kenai-VLESS-Startup-1'
Add-Line ('utc=' + [DateTime]::UtcNow.ToString('o'))
Add-Line ('windows_version=' + [Environment]::OSVersion.Version.ToString())
Add-Line ('os_64bit=' + [Environment]::Is64BitOperatingSystem)
Add-Line ('powershell_major=' + $PSVersionTable.PSVersion.Major)
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    Add-Line ('elevated=' + $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
} catch { Add-Line 'elevated=unknown' }

$install = Join-Path $env:ProgramW6432 'Kenai VPN'
foreach ($relative in @('app\KenaiVPN.exe', 'service\KenaiVpnService.exe',
    'service\xray\amd64\xray.exe', 'service\xray\amd64\wintun.dll')) {
    $path = Join-Path $install $relative
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $item = Get-Item -LiteralPath $path
            Add-Json 'binary' @{name=$relative; bytes=$item.Length;
                version=$item.VersionInfo.ProductVersion; sha256=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash}
        } catch { Add-Line ('binary_unreadable=' + $relative) }
    } else { Add-Line ('binary_missing=' + $relative) }
}
try {
    $settings = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters'
    $disabled = $settings.DisabledComponents
    if ($null -eq $disabled) { $disabled = 0 }
    Add-Line ('ipv6_disabled_components=' + [uint32]$disabled)
} catch { Add-Line 'ipv6_disabled_components=unavailable' }
try {
    $bindings = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop | ForEach-Object {
        # Adapter display names can contain personal information: omit them.
        $adapter = Get-NetAdapter -Name $_.Name -ErrorAction SilentlyContinue
        [pscustomobject]@{index=$adapter.ifIndex; enabled=[bool]$_.Enabled}
    })
    Add-Json 'ipv6_bindings' $bindings
} catch { Add-Line 'ipv6_bindings=unavailable' }

if (-not $SkipNetworkChecks) {
    $tcp = [Net.Sockets.TcpClient]::new()
    try {
        $pending = $tcp.ConnectAsync('88.218.94.3', 443)
        $finished = $pending.Wait(3000)
        Add-Line ('server_tcp443_reachable=' + ($finished -and $tcp.Connected))
    } catch { Add-Line 'server_tcp443_reachable=False' }
    finally { $tcp.Dispose() }
}

Write-Host 'Now click Connect with VLESS in Kenai. Do not enable a second VPN.'
Write-Host ('Observing for {0} seconds; network settings will not be changed.' -f $DurationSeconds)
$timer = [Diagnostics.Stopwatch]::StartNew()
do {
    $sample = [ordered]@{second=[int]$timer.Elapsed.TotalSeconds}
    try { $sample.service = [string](Get-Service -Name KenaiVpnService).Status }
    catch { $sample.service = 'unavailable' }
    $sample.xray_processes = @(Get-Process -Name xray -ErrorAction SilentlyContinue).Count
    try {
        $tun = @(Get-NetAdapter -Name KenaiXray -ErrorAction SilentlyContinue)
        $sample.tun = @($tun | ForEach-Object {
            [pscustomobject]@{index=$_.ifIndex; status=[string]$_.Status}
        })
        foreach ($target in @('1.1.1.1', '2606:4700:4700::1111')) {
            $family = if ($target -eq '1.1.1.1') { 'ipv4' } else { 'ipv6' }
            try {
                $selected = @(Find-NetRoute -RemoteIPAddress $target -ErrorAction Stop)
                $indices = @($selected | ForEach-Object { [int]$_.InterfaceIndex } | Select-Object -Unique)
                $sample[$family + '_best_interface'] = $indices
                $sample[$family + '_uses_kenai'] = @($tun | Where-Object { $_.ifIndex -in $indices }).Count -gt 0
            } catch { $sample[$family + '_best_interface'] = 'unavailable' }
        }
        $sample.defaults = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0','::/0' -ErrorAction SilentlyContinue |
            ForEach-Object { [pscustomobject]@{prefix=$_.DestinationPrefix; index=$_.InterfaceIndex; metric=$_.RouteMetric} })
        $sample.interfaces = @(Get-NetIPInterface -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{index=$_.InterfaceIndex; family=[string]$_.AddressFamily;
                metric=$_.InterfaceMetric; mtu=$_.NlMtu; state=[string]$_.ConnectionState}
        })
        if ($tun.Count -gt 0) {
            $sample.tun_addresses = @(Get-NetIPAddress -InterfaceIndex $tun[0].ifIndex -ErrorAction SilentlyContinue |
                ForEach-Object { [pscustomobject]@{family=[string]$_.AddressFamily; state=[string]$_.AddressState} })
        }
    } catch { $sample.network_snapshot = 'unavailable' }
    Add-Json 'sample' $sample
    if ($timer.Elapsed.TotalSeconds -lt $DurationSeconds) { Start-Sleep -Milliseconds 750 }
} while ($timer.Elapsed.TotalSeconds -lt $DurationSeconds)

$safeCodes = @('OK','CONNECTED','DISCONNECTED','BUSY','DUPLICATE_REQUEST',
    'INVALID_REQUEST','PROFILE_NOT_FOUND','PROFILE_STORE_UNAVAILABLE','UNAUTHORIZED',
    'ENGINE_NOT_INSTALLED','NO_NETWORK','SERVER_UNAVAILABLE','TUNNEL_ROUTE_UNAVAILABLE',
    'INVALID_PROFILE','UNSUPPORTED_FEATURE','ENGINE_FAILED','TUNNEL_STOPPED',
    'UNSUPPORTED_PROTOCOL','SUBSCRIPTION_REQUIRED','SERVICE_UNAVAILABLE',
    'SERVICE_TIMEOUT','SERVICE_PROTOCOL_ERROR','CONNECTION_STATE_CHANGED')
$log = Join-Path $env:LOCALAPPDATA 'Kenai VPN\logs\client.jsonl'
if (Test-Path -LiteralPath $log -PathType Leaf) {
    try {
        foreach ($line in (Get-Content -LiteralPath $log -Tail 200)) {
            try {
                $entry = $line | ConvertFrom-Json
                $found = @()
                foreach ($value in @($entry.code) + @($entry.fields.PSObject.Properties.Value)) {
                    if ($value -is [string] -and $value -cin $safeCodes) { $found += $value }
                }
                if ($found.Count -gt 0) {
                    $stamp = [DateTimeOffset]::Parse($entry.occurred_at).UtcDateTime.ToString('o')
                    Add-Json 'client_event' @{utc=$stamp; codes=@($found | Select-Object -Unique)}
                }
            } catch { } # Malformed/unrecognized data is deliberately omitted.
        }
    } catch { Add-Line 'client_events=unavailable' }
} else { Add-Line 'client_events=missing' }
$lines | Set-Content -LiteralPath $report -Encoding UTF8
Write-Output ('Report saved: ' + $report)
