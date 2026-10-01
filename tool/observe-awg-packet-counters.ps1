# Temporary diagnostic only: no packet payload logging, firewall or route changes.
# Refuses an existing packet-monitor session or filters. Never resets counters.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$root = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data'
$report = Join-Path $root 'awg-packet-counters.json'
$pktmon = Join-Path $env:SystemRoot 'System32\pktmon.exe'
$started = $false
$filterAdded = $false
$ownedFilters = $null
$samples = [Collections.Generic.List[object]]::new()
$result = @{status='initializing'; payload_logging=$false; filter_removed=$false; monitor_stopped=$false}
function Save-Report {
    $result['samples'] = @($samples.ToArray())
    $result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $report -Encoding UTF8
}
function Invoke-Monitor {
    param([string[]]$Arguments)
    # Windows PowerShell 5 turns native stderr (including pktmon status text)
    # into RemoteException records. Judge native commands by their exit code.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& $pktmon @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        $result['failed_command'] = $Arguments -join ' '
        $result['command_error'] = $lines -join "`n"
        throw 'packet_monitor_command_failed'
    }
    return ($lines -join "`n").Trim()
}
function Get-Counters {
    $json = Invoke-Monitor -Arguments @('counters','--json')
    return ($json | ConvertFrom-Json)
}
try {
    Save-Report
    $state = Invoke-Monitor -Arguments @('status')
    # Russian literals use code points to remain compatible with Windows PowerShell 5 UTF-8 handling.
    $notRunningRu = -join ([char[]](0x43D,0x435,0x20,0x437,0x430,0x43F,0x443,0x449,0x435,0x43D))
    $noneRu = -join ([char[]](0x41D,0x435,0x442))
    if ($state -notmatch "(?i)not running|$notRunningRu") { throw 'existing_or_unknown_monitor_session' }
    $filters = Invoke-Monitor -Arguments @('filter','list')
    if (($filters -split "`n")[-1].Trim() -notmatch "^(?i:none|$noneRu)\.?$") { throw 'existing_or_unknown_filters' }
    $null = Invoke-Monitor -Arguments @('filter','add','KenaiAwgReadOnlyProbe','-t','UDP','-i','88.218.94.3','-p','585')
    $filterAdded = $true
    $ownedFilters = Invoke-Monitor -Arguments @('filter','list')
    $null = Invoke-Monitor -Arguments @('start','--capture','--counters-only')
    $started = $true
    $result['status'] = 'waiting_for_kenai'
    Save-Report
    $deadline = [DateTime]::UtcNow.AddSeconds(180)
    $attemptStarted = $null
    do {
        $service = Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
        $other = Get-Service -Name 'AmneziaWGTunnel$AmneziaVPN' -ErrorAction SilentlyContinue
        $kenaiRunning = $service -and $service.Status -eq 'Running'
        $otherRunning = $other -and $other.Status -eq 'Running'
        if ($kenaiRunning -and -not $attemptStarted) {
            $attemptStarted = [DateTime]::UtcNow
            $deadline = $attemptStarted.AddSeconds(25)
            $result['status'] = 'observing_kenai'
        }
        $samples.Add(@{
            utc = [DateTime]::UtcNow.ToString('o')
            kenai_running = [bool]$kenaiRunning
            other_vpn_running = [bool]$otherRunning
            counters = (Get-Counters)
        })
        Save-Report
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    $result['status'] = if ($attemptStarted) {'complete'} else {'no_kenai_attempt'}
} catch {
    $result['status'] = 'blocked'
    $result['error_type'] = $_.Exception.GetType().Name
    $result['error_line'] = $_.InvocationInfo.ScriptLineNumber
    # Only locally defined error codes; no arbitrary system messages or credentials.
    if ($_.Exception.Message -match '^(packet_monitor_command_failed|existing_or_unknown_monitor_session|existing_or_unknown_filters)$') {
        $result['error_code'] = $_.Exception.Message
    }
} finally {
    if ($started) {
        try { $null = Invoke-Monitor -Arguments @('stop'); $result['monitor_stopped']=$true } catch { }
    }
    if ($filterAdded -and $ownedFilters) {
        try {
            # This Windows version removes all filters, so remove only if the list is
            # byte-for-byte the single filter we added to an initially empty list.
            if ((Invoke-Monitor -Arguments @('filter','list')) -ceq $ownedFilters) {
                $null = Invoke-Monitor -Arguments @('filter','remove')
                $result['filter_removed']=$true
            }
        } catch { }
    }
    Save-Report
}
