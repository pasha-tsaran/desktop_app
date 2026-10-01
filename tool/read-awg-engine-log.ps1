[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$outputRoot = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data'
$null = New-Item -ItemType Directory -Force -Path $outputRoot
$report = Join-Path $outputRoot 'awg-engine-summary.json'
$events = [System.Collections.Generic.List[object]]::new()
try {
    $path = 'C:\Program Files\AmneziaWG\Data\log.bin'
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -ne 1064968) { throw 'unexpected_log_size' }
        $data = New-Object byte[] 1064968
        $read = 0
        while ($read -lt $data.Length) {
            $count = $stream.Read($data, $read, $data.Length-$read)
            if ($count -eq 0) { throw 'short_read' }
            $read += $count
        }
    } finally { $stream.Dispose() }
    if ([BitConverter]::ToUInt32($data, 0) -ne 0x0badbabe) { throw 'bad_magic' }
    for ($index=0; $index -lt 2048; $index++) {
        $offset=8+$index*520
        $time=[BitConverter]::ToInt64($data,$offset)
        if ($time -eq 0) { continue }
        $line=[Text.Encoding]::UTF8.GetString($data,$offset+8,512).Split([char]0)[0]
        $code=$null
        if ($line -match 'Binding v[46] socket to interface \d+ \(blackhole=(true|false)\)') { $code=$Matches[0] }
        elseif ($line -match 'Sending handshake initiation') { $code='sending_handshake' }
        elseif ($line -match 'Receiving handshake response') { $code='received_handshake_response' }
        elseif ($line -match 'Handshake.*did not complete') { $code='handshake_timeout' }
        elseif ($line -match 'Failed to send handshake') { $code='handshake_send_failed' }
        elseif ($line -match 'invalid MAC|Invalid MAC') { $code='invalid_mac' }
        elseif ($line -match 'forbidden by its access permissions|Access is denied|permission denied') { $code='socket_access_denied' }
        elseif ($line -match 'network is unreachable|network unreachable|no route to host') { $code='network_unreachable' }
        elseif ($line -match 'Startup complete') { $code='startup_complete' }
        elseif ($line -match 'Shutting down') { $code='shutdown' }
        if ($code) { $events.Add([pscustomobject]@{unix_ms=[long]($time/1000000); event=$code}) }
    }
    @{status='ok'; events=@($events | Sort-Object unix_ms | Select-Object -Last 100)} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $report -Encoding UTF8
} catch {
    @{status='unavailable'; error_type=$_.Exception.GetType().Name} | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
} finally { $data=$null; $line=$null }
