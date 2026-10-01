# Read-only: only firewall events addressed to the user's AWG endpoint.
param([switch]$WaitForKenai)
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data'
$netsh = Join-Path $env:SystemRoot 'System32\netsh.exe'
$report = Join-Path $root 'awg-filter-events.json'
$samples = [Collections.Generic.List[object]]::new()
$result = @{status='initializing'}
function Save-Report {
    $result['samples'] = @($samples.ToArray())
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report -Encoding UTF8
}
function Read-FilterSample {
    $events = @(& $netsh wfp show netevents file=- protocol=17 remoteaddr=88.218.94.3 remoteport=585 2>&1) -join "`n"
    $filters = @(& $netsh wfp show filters file=- protocol=17 remoteaddr=88.218.94.3 dir=out verbose=on 'appid=C:\Program Files\Kenai VPN\service\amneziawg\amd64\amneziawg.exe' 2>&1) -join "`n"
    $peer=@{available=$false}
    $raw=@(& 'C:\Program Files\Kenai VPN\service\amneziawg\amd64\awg.exe' show KenaiAwg dump 2>$null)
    if ($LASTEXITCODE -eq 0 -and $raw.Count -ge 2) {
        $fields=$raw[1] -split "`t"
        if ($fields.Count -ge 8) {
            $peer=@{available=$true;endpoint_matches=($fields[2] -eq '88.218.94.3:585');handshake=[long]$fields[4];received=[long]$fields[5];sent=[long]$fields[6]}
        }
    }
    $other=Get-Service -Name 'AmneziaWGTunnel$AmneziaVPN' -ErrorAction SilentlyContinue
    $samples.Add(@{utc=[DateTime]::UtcNow.ToString('o'); events=$events; filters=$filters;peer=$peer;other_vpn_running=([bool]($other -and $other.Status -eq 'Running'))})
    Save-Report
}
$result['options'] = @(& $netsh wfp show options optionsfor=NETEVENTS 2>&1) -join "`n"
if ($WaitForKenai) {
    $result['status']='waiting_for_kenai'
    Save-Report
    $deadline=[DateTime]::UtcNow.AddSeconds(180)
    do {
        $service=Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
        if ($service -and $service.Status -eq 'Running') { break }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    if (-not $service -or $service.Status -ne 'Running') {
        $result['status']='no_kenai_attempt'
        Save-Report
        exit
    }
    $result['status']='observing_kenai'
    for ($i=0; $i -lt 4; $i++) {
        Read-FilterSample
        Start-Sleep -Seconds 2
    }
} else { Read-FilterSample }
$result['status']='complete'
Save-Report
