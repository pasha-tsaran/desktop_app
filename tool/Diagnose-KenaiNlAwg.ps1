[CmdletBinding()]
param(
    [ValidateRange(45, 300)][int]$WindowSeconds = 150,
    [string]$SshKeyPath = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.ssh\kenai_vpn_codex_ed25519'),
    [ValidatePattern('^[a-f0-9]{32}$')][string]$ResumeRunId,
    [switch]$SkipPktMon,
    [switch]$SelfTest
)

# Diagnostic only. The user operates Kenai VPN; this script never connects,
# disconnects, changes routes, firewall rules, DNS, VPN services or profiles.
# Server tcpdump is detached from SSH and records only time, direction and size.
$ErrorActionPreference = 'Stop'
$server = '147.45.231.194'
$peerAddress = '10.67.67.19/32'
$ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
$pktmon = Join-Path $env:SystemRoot 'System32\pktmon.exe'
$awg = Join-Path $env:ProgramFiles 'Kenai VPN\service\amneziawg\amd64\awg.exe'
$root = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\nl-awg-diagnostics'
$runId = if ($ResumeRunId) { $ResumeRunId } else { [guid]::NewGuid().ToString('N') }
$runDirectory = Join-Path $root $runId
$reportPath = Join-Path $runDirectory 'report.json'
$remoteFile = '/tmp/kenai-awgdiag-' + $runId + '.jsonl'
$unit = 'kenai-awgdiag-' + $runId + '.service'
$report = $null
$packetMonitor = @{status='not_started';filter_added=$false;started=$false;owned_filters=$null;samples=@()}

function Save-Report {
    $json = $script:report | ConvertTo-Json -Depth 12
    [IO.File]::WriteAllText($script:reportPath, $json, [Text.UTF8Encoding]::new($false))
}

function Invoke-Remote([string]$Body) {
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Body))
    $command = "printf %s '$encoded' | base64 -d | bash"
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=5 `
            -i $script:SshKeyPath ('root@' + $script:server) $command 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0) { throw ('ssh_exit_' + $exitCode) }
    return ($output -join "`n").Trim()
}

function Get-ServerSnapshot {
    $body = @'
python3 - <<'PY'
import hashlib, json, subprocess, time

peer_address = '__PEER_ADDRESS__'
def run(*args):
    try:
        p = subprocess.run(args, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.DEVNULL, timeout=7)
        return p.stdout if p.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''
def digest(value):
    return hashlib.sha256(value.encode('ascii')).hexdigest() if value else None

result = {'epoch_ms': int(time.time() * 1000)}
inspect = run('docker', 'inspect', '--format', '{{.State.Status}} {{.RestartCount}}', 'kenai-awg31').split()
result['container_status'] = inspect[0] if inspect else 'unavailable'
result['container_restarts'] = int(inspect[1]) if len(inspect) > 1 and inspect[1].isdigit() else None
result['udp_443_listening'] = ':443' in run('ss', '-H', '-lun', 'sport = :443')
result['input_policy'] = run('iptables', '-S', 'INPUT').splitlines()[0:1]
result['ipv4_forwarding'] = run('sysctl', '-n', 'net.ipv4.ip_forward').strip()
result['server_public_sha256'] = digest(run('docker', 'exec', 'kenai-awg31', 'awg', 'show', 'awg0', 'public-key').strip())

dump = run('docker', 'exec', 'kenai-awg31', 'awg', 'show', 'awg0', 'dump').splitlines()
result['peer_count'] = max(0, len(dump) - 1)
result['target_peer'] = {'found': False}
for line in dump[1:]:
    fields = line.split('\t')
    if len(fields) >= 7 and peer_address in fields[3].split(','):
        try:
            result['target_peer'] = {
                'found': True, 'public_sha256': digest(fields[0]),
                'preshared_sha256': digest(fields[1]) if fields[1] not in ('', '(none)') else None,
                'last_handshake_unix': int(fields[4]),
                'received_bytes': int(fields[5]), 'sent_bytes': int(fields[6])}
        except ValueError:
            result['target_peer'] = {'found': True, 'counters': 'unavailable'}
        break

config = run('docker', 'exec', 'kenai-awg31', 'awg', 'showconf', 'awg0')
interface = {}
section = ''
for line in config.splitlines():
    line = line.strip()
    if line in ('[Interface]', '[Peer]'):
        section = line
    elif section == '[Interface]' and '=' in line:
        key, value = line.split('=', 1)
        interface[key.strip().lower()] = value.strip()
result['header_key_sha256'] = digest(interface.get('headerprotectionkey', ''))
result['obfuscation'] = {key: interface.get(key) for key in
    ('jc','jmin','jmax','s1','s2','s3','s4','h1','h2','h3','h4',
     'contentpaddingaddition','rekeyaftertime','rekeytimeout','rejectaftertime',
     'keepalivetimeout','maxhandshakeattempts','randomtrailers','disablecookies')}
result['i1_sha256'] = digest(interface.get('i1', ''))
result['special_junk_sha256'] = [digest(interface[key]) for key in ('i1','i2','i3','i4','i5') if key in interface]
print(json.dumps(result, separators=(',', ':')))
PY
'@.Replace('__PEER_ADDRESS__', $script:peerAddress)
    return (Invoke-Remote $body | ConvertFrom-Json)
}

function Start-ServerWatch {
    $duration = $WindowSeconds + 35
    $watch = @'
python3 - <<'PY'
import json, re, subprocess

path = '__REMOTE_FILE__'
server = '__SERVER__'
limit = __DURATION__
pattern = re.compile(r'^(\d+\.\d+)\s+IP\s+(\S+)\s+>\s+(\S+):\s+UDP,\s+length\s+(\d+)')
process = subprocess.Popen(
    ['timeout', str(limit), 'tcpdump', '-tt', '-n', '-q', '-l', '-i', 'eth0', 'udp', 'port', '443'],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
with open(path, 'w', encoding='utf-8') as output:
    count = 0
    for line in process.stdout:
        match = pattern.match(line)
        if not match:
            continue
        source, target = match.group(2), match.group(3)
        direction = 'in' if target == server + '.443' else 'out' if source == server + '.443' else None
        if direction is None:
            continue
        output.write(json.dumps({'epoch': float(match.group(1)),
                                 'direction': direction, 'bytes': int(match.group(4))}) + '\n')
        output.flush()
        count += 1
        if count >= 1000:
            process.terminate()
            break
process.wait()
PY
'@.Replace('__REMOTE_FILE__', $remoteFile).Replace('__SERVER__', $server).Replace('__DURATION__', [string]$duration)
    $watch64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($watch))
    $body = "systemd-run --collect --unit=$($unit.Substring(0, $unit.Length - 8)) " +
        "--property=RuntimeMaxSec=$($duration + 10) /bin/bash -lc 'printf %s $watch64 | base64 -d | bash'"
    [void](Invoke-Remote $body)
    Start-Sleep -Seconds 1
    $state = Invoke-Remote "systemctl is-active '$unit' || true; test -f '$remoteFile' && echo file_ready"
    if (($state -split "`n")[0].Trim() -ne 'active' -or $state -notmatch 'file_ready') {
        throw 'server_watch_not_ready'
    }
}

function Get-AwgPeer {
    if (-not (Test-Path -LiteralPath $script:awg)) { return @{status='engine_missing'} }
    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $script:awg show KenaiAwg dump 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($exitCode -ne 0 -or $lines.Count -lt 2) { return @{status='unavailable'} }
    $fields = ([string]$lines[1]) -split "`t"
    if ($fields.Count -lt 7) { return @{status='invalid_dump'} }
    try {
        return @{status='ok';last_handshake_unix=[long]$fields[4];received_bytes=[long]$fields[5];sent_bytes=[long]$fields[6]}
    } catch { return @{status='invalid_counters'} }
}

function Get-LocalSnapshot {
    $vpnService = Get-Service -Name KenaiVpnService -ErrorAction SilentlyContinue
    $tunnel = Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
    $xray = @(Get-Process -Name xray -ErrorAction SilentlyContinue)
    $routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1',($script:server + '/32')) } |
        Select-Object DestinationPrefix,InterfaceIndex,InterfaceAlias,RouteMetric)
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'Up' } |
        Select-Object Name,InterfaceIndex,InterfaceDescription)
    $effectiveRoute = @(Find-NetRoute -RemoteIPAddress $script:server -ErrorAction SilentlyContinue |
        Select-Object DestinationPrefix,InterfaceIndex,InterfaceAlias,RouteMetric)
    $awgProcesses = @(Get-Process -Name amneziawg -ErrorAction SilentlyContinue)
    $awgUdpPorts = @()
    if ($awgProcesses.Count -gt 0) {
        $awgUdpPorts = @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue |
            Where-Object { $_.OwningProcess -in $awgProcesses.Id } |
            Select-Object -ExpandProperty LocalPort)
    }
    $firewallServices = @(Get-Service -Name BFE,MpsSvc -ErrorAction SilentlyContinue |
        Select-Object Name,@{n='status';e={[string]$_.Status}})
    $firewallProfiles = @(Get-NetFirewallProfile -ErrorAction SilentlyContinue |
        Select-Object Name,Enabled,DefaultOutboundAction)
    return @{
        epoch_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        kenai_service = if ($vpnService) { [string]$vpnService.Status } else { 'missing' }
        awg_tunnel = if ($tunnel) { [string]$tunnel.Status } else { 'missing' }
        xray_process_count = $xray.Count
        awg_peer = Get-AwgPeer
        routes = $routes
        effective_endpoint_route = $effectiveRoute
        adapters = $adapters
        awg_udp_local_ports = $awgUdpPorts
        firewall_services = $firewallServices
        firewall_profiles = $firewallProfiles
    }
}

function Get-LocalInstallation {
    $app = Join-Path $env:ProgramFiles 'Kenai VPN\app\KenaiVPN.exe'
    $engine = Join-Path $env:ProgramFiles 'Kenai VPN\service\amneziawg\amd64\amneziawg.exe'
    $items = @{}
    foreach ($entry in @(@{name='app';path=$app},@{name='awg_engine';path=$engine},
            @{name='awg_tool';path=$script:awg})) {
        if (Test-Path -LiteralPath $entry.path) {
            $item = Get-Item -LiteralPath $entry.path
            $items[$entry.name] = @{
                version = $item.VersionInfo.ProductVersion
                sha256 = (Get-FileHash -LiteralPath $entry.path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        } else { $items[$entry.name] = @{status='missing'} }
    }
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    return @{files=$items;windows=if ($os) {
        @{caption=$os.Caption;version=$os.Version;build=$os.BuildNumber}
    } else { @{status='unavailable'} }}
}

function Get-EngineSummary([long]$FromEpochMs) {
    $reader = Join-Path $PSScriptRoot 'read-awg-engine-log.ps1'
    try {
        & $reader | Out-Null
        $path = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\awg-engine-summary.json'
        $data = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        if ($data.status -ne 'ok') { return @{status='unavailable';error_type=$data.error_type} }
        return @{status='ok';events=@($data.events | Where-Object { $_.unix_ms -ge ($FromEpochMs - 2000) })}
    } catch { return @{status='unavailable';error_type=$_.Exception.GetType().Name} }
}

function Get-ServiceEvents([datetime]$Since) {
    try {
        return @(Get-WinEvent -FilterHashtable @{LogName='System';Id=7045;StartTime=$Since} -ErrorAction Stop |
            Where-Object { $_.Message -match 'AmneziaWGTunnel\$KenaiAwg' } |
            Select-Object @{n='epoch_ms';e={([DateTimeOffset]$_.TimeCreated).ToUnixTimeMilliseconds()}},Id)
    } catch { return @() }
}

function Get-FirewallDropEvents([datetime]$Since) {
    try {
        $events = @(Get-WinEvent -FilterHashtable @{LogName='Security';Id=5152,5157;StartTime=$Since} `
            -ErrorAction Stop)
        $matches = [Collections.Generic.List[object]]::new()
        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $fields = @{}
            foreach ($item in $xml.Event.EventData.Data) { $fields[[string]$item.Name] = [string]$item.'#text' }
            if ($fields.DestAddress -eq $script:server -and $fields.DestPort -eq '443' -and
                $fields.Protocol -eq '17') {
                $matches.Add(@{epoch_ms=([DateTimeOffset]$event.TimeCreated).ToUnixTimeMilliseconds();id=$event.Id})
            }
        }
        return @{status='checked';matching_events=@($matches.ToArray())}
    } catch { return @{status='unavailable_or_audit_disabled';matching_events=@()} }
}

function Invoke-PktMon([string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $oldEncoding = [Console]::OutputEncoding
    try {
        $ErrorActionPreference = 'Continue'
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $output = @(& $script:pktmon @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        [Console]::OutputEncoding = $oldEncoding
        $ErrorActionPreference = $oldPreference
    }
    if ($exitCode -ne 0) { throw ('pktmon_exit_' + $exitCode) }
    return ($output -join "`n").Trim()
}

function Start-LocalPacketWatch {
    if ($SkipPktMon) { $script:packetMonitor.status = 'skipped_by_user'; return }
    if (-not (Test-Path -LiteralPath $script:pktmon)) { $script:packetMonitor.status = 'tool_missing'; return }
    try {
        # Windows PowerShell 5.1 may read UTF-8 without BOM as ANSI.
        $notRunningRu = -join ([char[]](0x43D,0x435,0x20,0x437,0x430,0x43F,0x443,0x449,0x435,0x43D))
        $noneRu = -join ([char[]](0x41D,0x435,0x442))
        $state = Invoke-PktMon @('status')
        if ($state -notmatch "(?i)not running|$notRunningRu") {
            $script:packetMonitor.status = 'skipped_existing_or_unknown_session'
            return
        }
        $filters = Invoke-PktMon @('filter','list')
        if (($filters -split "`n")[-1].Trim() -notmatch "(?i)^(none|$noneRu)\.?$") {
            $script:packetMonitor.status = 'skipped_existing_or_unknown_filters'
            return
        }
        $name = 'KenaiNlAwgDiag' + $script:runId.Substring(0,8)
        [void](Invoke-PktMon @('filter','add',$name,'-t','UDP','-i',$script:server,'-p','443'))
        $script:packetMonitor.filter_added = $true
        $script:packetMonitor.owned_filters = Invoke-PktMon @('filter','list')
        [void](Invoke-PktMon @('start','--capture','--counters-only'))
        $script:packetMonitor.started = $true
        $script:packetMonitor.status = 'running_counters_only'
    } catch {
        $script:packetMonitor.status = 'unavailable'
        $script:packetMonitor.error_type = $_.Exception.GetType().Name
    }
}

function Add-NumericCounterFields($Value, [string]$Path, [Collections.Generic.List[object]]$Output) {
    if ($Output.Count -ge 2048 -or $null -eq $Value) { return }
    if ($Value -is [pscustomobject]) {
        $index = 0
        foreach ($property in $Value.PSObject.Properties) {
            $part = if ($property.Name -match '^[A-Za-z][A-Za-z0-9_]{0,40}$') {
                $property.Name
            } else { 'field_' + $index }
            Add-NumericCounterFields $property.Value ($Path + '.' + $part) $Output
            $index++
        }
    } elseif ($Value -is [array]) {
        for ($index = 0; $index -lt $Value.Length; $index++) {
            Add-NumericCounterFields $Value[$index] ($Path + '[' + $index + ']') $Output
        }
    } elseif ($Value -is [byte] -or $Value -is [int] -or $Value -is [long] -or
        $Value -is [double] -or $Value -is [decimal]) {
        $Output.Add(@{path=$Path;value=$Value})
    }
}

function Add-LocalPacketSample {
    if (-not $script:packetMonitor.started) { return }
    try {
        $json = Invoke-PktMon @('counters','--json')
        $counters = $json | ConvertFrom-Json
        $numeric = [Collections.Generic.List[object]]::new()
        Add-NumericCounterFields $counters 'root' $numeric
        $script:packetMonitor.samples += @(@{
            epoch_ms = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            numeric_counters = @($numeric.ToArray())
            capped_at_2048 = ($numeric.Count -ge 2048)
        })
    } catch {
        $script:packetMonitor.sample_error_type = $_.Exception.GetType().Name
    }
}

function Stop-LocalPacketWatch {
    if (-not $script:packetMonitor.filter_added) { return }
    try {
        $currentFilters = Invoke-PktMon @('filter','list')
        if ($currentFilters -cne $script:packetMonitor.owned_filters) {
            $script:packetMonitor.status = 'cleanup_manual_check_needed_filters_changed'
            return
        }
        if ($script:packetMonitor.started) {
            [void](Invoke-PktMon @('stop'))
            $script:packetMonitor.started = $false
        }
        [void](Invoke-PktMon @('filter','remove'))
        $script:packetMonitor.filter_added = $false
        if ($script:packetMonitor.status -eq 'running_counters_only') {
            $script:packetMonitor.status = 'complete_and_cleaned'
        }
    } catch {
        $script:packetMonitor.status = 'cleanup_manual_check_needed'
        $script:packetMonitor.cleanup_error_type = $_.Exception.GetType().Name
    }
}

function Complete-ServerReport {
    $lastError = $null
    for ($attempt = 1; $attempt -le 6; $attempt++) {
      try {
        # This unit belongs to this run only. Stopping packet observation does not touch the VPN.
        [void](Invoke-Remote "systemctl stop '$unit' 2>/dev/null || true")
        $text = Invoke-Remote "cat -- '$remoteFile'"
        $packets = [Collections.Generic.List[object]]::new()
        foreach ($line in ($text -split "`n")) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $packet = $line | ConvertFrom-Json
            if ($packet.direction -notin @('in','out') -or [double]$packet.epoch -le 0 -or
                [int]$packet.bytes -lt 0 -or [int]$packet.bytes -gt 65535) { throw 'invalid_packet_record' }
            $packets.Add($packet)
        }
        $script:report.server_packets = @($packets.ToArray())
        $script:report.server_packet_counts = @{
            inbound = @($packets | Where-Object direction -eq 'in').Count
            outbound = @($packets | Where-Object direction -eq 'out').Count
        }
        try { $script:report.server_after = Get-ServerSnapshot }
        catch { $script:report.server_after = @{status='unavailable';error_type=$_.Exception.GetType().Name} }
        $script:report.server_capture_status = 'complete'
        Save-Report
        # Delete only our validated, uniquely named temporary observation file.
        try { [void](Invoke-Remote "rm -f -- '$remoteFile'") } catch { }
        return
      } catch {
        $lastError = $_.Exception.GetType().Name
        if ($attempt -lt 6) { Start-Sleep -Seconds 5 }
      }
    }
    $script:report.server_capture_status = 'pending_resume'
    $script:report.server_capture_error = $lastError
    Save-Report
}

if ($SelfTest) {
    $lines = @('private-interface-line', "SECRET_PUBLIC`t(none)`t147.45.231.194:443`t0.0.0.0/0`t0`t123`t456`t25")
    # The parser must keep only counters, never a peer public key or endpoint.
    $fields = $lines[1] -split "`t"
    $sample = @{last_handshake_unix=[long]$fields[4];received_bytes=[long]$fields[5];sent_bytes=[long]$fields[6]} | ConvertTo-Json -Compress
    if ($sample -match 'SECRET_PUBLIC|147.45' -or $sample -notmatch 'received_bytes') { throw 'sanitization_self_test_failed' }
    $fixture = '{"SourceAddress":"192.0.2.7","SECRET_PRIVATE":"must_not_export","InboundPackets":5,"components":[{"Drops":2}]}' | ConvertFrom-Json
    $numeric = [Collections.Generic.List[object]]::new()
    Add-NumericCounterFields $fixture 'root' $numeric
    $redacted = $numeric.ToArray() | ConvertTo-Json -Compress
    if ($redacted -match '192\.0\.2\.7|SECRET_PRIVATE|must_not_export' -or
        $redacted -notmatch 'InboundPackets' -or $redacted -notmatch 'Drops') {
        throw 'packet_counter_redaction_self_test_failed'
    }
    if ($runId -notmatch '^[a-f0-9]{32}$' -or $remoteFile -notmatch '^/tmp/kenai-awgdiag-[a-f0-9]{32}\.jsonl$') { throw 'run_id_self_test_failed' }
    Write-Output 'PASS: redacted peer counters and safe run identifier. No VPN or network access.'
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Open Windows PowerShell as Administrator and run this script again.'
}
if (-not (Test-Path -LiteralPath $ssh) -or -not (Test-Path -LiteralPath $SshKeyPath)) {
    throw 'SSH executable or key not found. Supply -SshKeyPath with the existing VPS key.'
}

if ($ResumeRunId) {
    if (-not (Test-Path -LiteralPath $reportPath)) { throw 'Report for this RunId was not found.' }
    $loaded = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $report = [ordered]@{}
    foreach ($property in $loaded.PSObject.Properties) { $report[$property.Name] = $property.Value }
    Complete-ServerReport
    Write-Output ('Saved: ' + $reportPath)
    Write-Output ('server_capture_status=' + $report.server_capture_status)
    return
}

[void][IO.Directory]::CreateDirectory($runDirectory)
$start = Get-Date
$report = [ordered]@{
    run_id = $runId
    status = 'starting'
    started_local = $start.ToString('o')
    window_seconds = $WindowSeconds
    privacy = 'No private keys, full profiles, raw logs, packet payloads or packet source IPs.'
    local_samples = @()
    server_capture_status = 'not_started'
}
Save-Report
try {
    Write-Host 'Checking profile and server. Do not switch VPN yet.'
    try {
        $inspectionResult = @(& (Join-Path $PSScriptRoot 'Run-KenaiNlAwgProfileInspection.ps1'))
        if ($inspectionResult -notcontains 'profile_inspection=report_ready') { throw 'profile_inspection_not_ready' }
        $profilePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\nl-awg-profile-summary.json'
        $report.profile = Get-Content -LiteralPath $profilePath -Raw | ConvertFrom-Json
    } catch { $report.profile = @{status='unavailable';error_type=$_.Exception.GetType().Name} }
    if ($report.profile.status -eq 'ok' -and $report.profile.address -match '^10\.(?:\d{1,3}\.){2}\d{1,3}/32$') {
        $script:peerAddress = [string]$report.profile.address
    }
    $report.installation = Get-LocalInstallation
    $report.local_before = Get-LocalSnapshot
    $serverRequestStart = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $report.server_before = Get-ServerSnapshot
    $serverRequestEnd = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $report.clock_comparison = @{
        ssh_round_trip_ms = $serverRequestEnd - $serverRequestStart
        server_minus_pc_ms = [long]$report.server_before.epoch_ms -
            [long](($serverRequestStart + $serverRequestEnd) / 2)
    }
    Start-ServerWatch
    Start-LocalPacketWatch
    $report.local_packet_monitor = $packetMonitor
    $report.server_capture_status = 'running'
    $report.status = 'waiting_for_user_attempt'
    Save-Report
    Write-Host 'READY: In Kenai VPN, select Netherlands + AmneziaWG and click Connect once.'
    Write-Host 'Wait for success or error. Do not close this PowerShell window.'
    Write-Host ('Run ID: ' + $runId)

    $samples = [Collections.Generic.List[object]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $sawTunnel = $false
    $tunnelStoppedAt = $null
    $nextSnapshot = 0
    $nextPacketSample = 0
    while ($clock.Elapsed.TotalSeconds -lt $WindowSeconds) {
        $tunnel = Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
        $running = [bool]($tunnel -and $tunnel.Status -eq 'Running')
        if ($running) {
            if (-not $sawTunnel) { $nextSnapshot = $clock.Elapsed.TotalSeconds }
            $sawTunnel = $true
            $tunnelStoppedAt = $null
        }
        elseif ($sawTunnel -and $null -eq $tunnelStoppedAt) { $tunnelStoppedAt = $clock.Elapsed.TotalSeconds }
        if ($clock.Elapsed.TotalSeconds -ge $nextSnapshot) {
            $samples.Add((Get-LocalSnapshot))
            if ($clock.Elapsed.TotalSeconds -ge $nextPacketSample -and
                ($running -or $packetMonitor.samples.Count -eq 0)) {
                Add-LocalPacketSample
                $nextPacketSample = $clock.Elapsed.TotalSeconds + 2
            }
            $nextSnapshot = $clock.Elapsed.TotalSeconds + $(if ($running) { 1 } else { 5 })
            $report.local_samples = @($samples.ToArray())
            $report.local_packet_monitor = $packetMonitor
            Save-Report
        }
        if ($null -ne $tunnelStoppedAt -and $clock.Elapsed.TotalSeconds -ge ($tunnelStoppedAt + 5)) { break }
        Start-Sleep -Milliseconds 300
    }
    $report.local_after = Get-LocalSnapshot
    Add-LocalPacketSample
    Stop-LocalPacketWatch
    $report.local_packet_monitor = $packetMonitor
    $report.local_attempt_seen = $sawTunnel
    $report.engine_log = Get-EngineSummary ([DateTimeOffset]$start).ToUnixTimeMilliseconds()
    $report.service_events = Get-ServiceEvents $start
    $report.firewall_drop_events = Get-FirewallDropEvents $start
    $report.status = if ($sawTunnel) { 'local_collection_complete' } else { 'no_awg_attempt_observed' }
    Save-Report
    Complete-ServerReport
} catch {
    Stop-LocalPacketWatch
    $report.local_packet_monitor = $packetMonitor
    $report.status = 'diagnostic_incomplete'
    $report.error_type = $_.Exception.GetType().Name
    $report.error_line = $_.InvocationInfo.ScriptLineNumber
    Save-Report
    if ($report.server_capture_status -eq 'running') { Complete-ServerReport }
    Write-Warning ('Diagnostic incomplete. Error type: ' + $report.error_type)
} finally {
    if ($packetMonitor.filter_added) {
        Stop-LocalPacketWatch
        $report.local_packet_monitor = $packetMonitor
    }
    if ($report.server_capture_status -eq 'running') {
        $report.server_capture_status = 'pending_resume'
    }
    Save-Report
    Write-Output ('Saved: ' + $reportPath)
    Write-Output ('Run ID: ' + $runId)
    Write-Output ('local_packet_monitor=' + $packetMonitor.status)
    if ($report.server_capture_status -eq 'pending_resume') {
        Write-Output ('If SSH was interrupted, rerun with -ResumeRunId ' + $runId)
    }
}
