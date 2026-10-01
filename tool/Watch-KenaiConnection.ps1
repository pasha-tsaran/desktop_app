[CmdletBinding()]
param(
    [ValidateRange(5, 600)][int]$Seconds = 120,
    [string]$OutputDirectory = [Environment]::GetFolderPath('Desktop'),
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
# Read-only collector. Never opens profile storage, process command lines or raw logs.
if (-not ('KenaiReadOnlyProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Text;
using System.Text.RegularExpressions;
using System.Diagnostics;
public static class KenaiReadOnlyProbe {
    static byte[] Read(NamedPipeClientStream pipe, int count, Stopwatch clock) {
        byte[] buffer = new byte[count]; int offset = 0;
        while (offset < count) {
            int remaining = 1500 - (int)clock.ElapsedMilliseconds;
            if (remaining <= 0) throw new TimeoutException();
            IAsyncResult pending = pipe.BeginRead(buffer, offset, count-offset, null, null);
            try {
                if (!pending.AsyncWaitHandle.WaitOne(remaining)) throw new TimeoutException();
                int received = pipe.EndRead(pending);
                if (received == 0) throw new EndOfStreamException();
                offset += received;
            } finally { pending.AsyncWaitHandle.Close(); }
        }
        return buffer;
    }
    static string Text(BinaryReader reader) {
        int size = reader.ReadByte(); byte[] value = reader.ReadBytes(size);
        if (value.Length != size) throw new EndOfStreamException();
        return Encoding.ASCII.GetString(value);
    }
    public static string Decode(byte[] body, string request) {
        using (var reader = new BinaryReader(new MemoryStream(body))) {
            if (Text(reader) != request) throw new InvalidDataException();
            int phase = reader.ReadByte();
            string[] phases = {"DISCONNECTED","VALIDATING","CONNECTING","CONNECTED",
                "RECONNECTING","DISCONNECTING","SUBSCRIPTION_REQUIRED","NO_NETWORK",
                "SERVER_UNAVAILABLE","ERROR"};
            if (phase >= phases.Length) throw new InvalidDataException();
            int hasProfile = reader.ReadByte();
            if (hasProfile == 1) Text(reader); // deliberately discard opaque profile identifier
            else if (hasProfile != 0) throw new InvalidDataException();
            int protection = reader.ReadByte();
            if (protection > 1) throw new InvalidDataException();
            string code = Text(reader);
            if (!Regex.IsMatch(code, "^[A-Z][A-Z0-9_]{0,63}$")) throw new InvalidDataException();
            return "phase=" + phases[phase] + ";code=" + code + ";kill_switch=" + protection;
        }
    }
    public static string Status() {
        try {
            using (var pipe = new NamedPipeClientStream(".", "KenaiVpnControl-v4",
                PipeDirection.InOut, PipeOptions.Asynchronous)) {
                pipe.Connect(1000);
                string id = "diag-" + Guid.NewGuid().ToString("N");
                byte[] text = Encoding.ASCII.GetBytes(id);
                var packet = new MemoryStream();
                var writer = new BinaryWriter(packet);
                writer.Write(Encoding.ASCII.GetBytes("KVPN")); writer.Write((ushort)5);
                writer.Write((byte)1); writer.Write((byte)0); // Status only
                writer.Write((uint)(text.Length+1)); writer.Write((byte)text.Length); writer.Write(text);
                byte[] frame = packet.ToArray();
                var clock = Stopwatch.StartNew();
                IAsyncResult sent = pipe.BeginWrite(frame, 0, frame.Length, null, null);
                try {
                    if (!sent.AsyncWaitHandle.WaitOne(1000)) throw new TimeoutException();
                    pipe.EndWrite(sent);
                } finally { sent.AsyncWaitHandle.Close(); }
                byte[] header = Read(pipe, 12, clock);
                if (Encoding.ASCII.GetString(header,0,4) != "KVPN" ||
                    BitConverter.ToUInt16(header,4) != 5 || header[6] != 129 || header[7] != 0)
                    throw new InvalidDataException();
                uint length = BitConverter.ToUInt32(header,8);
                if (length == 0 || length > 4096) throw new InvalidDataException();
                return Decode(Read(pipe,(int)length,clock),id);
            }
        } catch (UnauthorizedAccessException) { return "probe=ACCESS_DENIED";
        } catch (TimeoutException) { return "probe=TIMEOUT_OR_BUSY";
        } catch (InvalidDataException) { return "probe=INVALID_RESPONSE";
        } catch (IOException) { return "probe=PIPE_UNAVAILABLE";
        } catch { return "probe=READ_FAILED"; }
    }
}
'@
}
if ($SelfTest) {
    # Synthetic service response includes a profile identifier that must never be returned.
    $fixture = [byte[]](1,120,8,1,6,115,101,99,114,101,116,0,2,79,75,0)
    $decoded = [KenaiReadOnlyProbe]::Decode($fixture, 'x')
    if ($decoded -ne 'phase=SERVER_UNAVAILABLE;code=OK;kill_switch=0') { throw 'Decode failed' }
    $rejected = $false
    try { [void][KenaiReadOnlyProbe]::Decode($fixture, 'wrong') } catch { $rejected = $true }
    if (-not $rejected) { throw 'Request mismatch was accepted' }
    $rejected = $false
    try { [void][KenaiReadOnlyProbe]::Decode([byte[]](1,120,8,1,6), 'x') } catch { $rejected = $true }
    if (-not $rejected) { throw 'Truncated response was accepted' }
    Write-Output 'PASS: status decoding, identifier exclusion, mismatch and truncation checks.'
    return
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = $PSScriptRoot }
$folder = (Resolve-Path -LiteralPath $OutputDirectory).Path
$report = Join-Path $folder ('Kenai-diagnostic-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.txt')
$utf8 = New-Object System.Text.UTF8Encoding($false)
$log = New-Object System.IO.StreamWriter($report, $false, $utf8)
$log.AutoFlush = $true
function Record([string]$Kind, $Data) {
    $line = [ordered]@{time=(Get-Date).ToString('o');kind=$Kind;data=$Data} | ConvertTo-Json -Depth 5 -Compress
    $log.WriteLine($line)
}
try {
    $version = 'unknown'
    $appPath = Join-Path $env:ProgramFiles 'Kenai VPN\app\KenaiVPN.exe'
    if (Test-Path -LiteralPath $appPath) { $version = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion }
    Record 'start' @{version=$version;duration_seconds=$Seconds;timezone=[TimeZoneInfo]::Local.Id;note='Read-only. No credentials, profiles or raw logs collected.'}
    Write-Host "Recording for $Seconds seconds. Now try Netherlands in Kenai VPN."
    Write-Host 'You may reconnect to Armenia after the error. Keep this window open.'
    Write-Host "Report: $report"
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $nextNetwork = 0
    $previous = ''
    while ($timer.Elapsed.TotalSeconds -lt $Seconds) {
        $state = [KenaiReadOnlyProbe]::Status()
        Record 'service_status' $state
        if ($state -ne $previous) { Write-Host ((Get-Date -Format HH:mm:ss) + ' ' + $state); $previous = $state }
        if ($timer.Elapsed.TotalSeconds -ge $nextNetwork) {
            try {
                $service = Get-Service KenaiVpnService -ErrorAction Stop
                Record 'service' ([string]$service.Status)
                $engines = @(Get-Process xray -ErrorAction SilentlyContinue)
                Record 'xray_process_count' $engines.Count
                if ($engines.Count -gt 0) {
                    $connections = @(Get-NetTCPConnection -ErrorAction Stop | Where-Object { $_.OwningProcess -in $engines.Id -and $_.RemotePort -ne 0 } | Select-Object RemoteAddress,RemotePort,State -Unique)
                    Record 'xray_connections' $connections
                }
                $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { $_.Name -match '^Kenai' } | Select-Object Name,Status,InterfaceIndex)
                Record 'vpn_adapters' $adapters
            } catch { Record 'network_snapshot_error' $_.Exception.GetType().Name }
            $nextNetwork = $timer.Elapsed.TotalSeconds + 3
        }
        Start-Sleep -Milliseconds 750
    }
    Record 'end' 'complete'
} finally {
    $log.Dispose()
    Write-Host "Saved: $report"
}
