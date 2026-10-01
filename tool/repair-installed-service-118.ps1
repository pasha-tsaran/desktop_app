# One-off repair of the already installed 1.1.8 candidate, with rollback copy.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'target\release\kenai_windows_vpn_service.exe'
$destination='C:\Program Files\Kenai VPN\service\KenaiVpnService.exe'
$backup=Join-Path $root 'local_data\KenaiVpnService-before-ipc-repair.exe'
$report=Join-Path $root 'local_data\service-repair-118.json'
$result=@{status='checking'}
$copied=$false
try {
    if ((Get-FileHash -LiteralPath $source).Hash -ne 'F03A8C907F6E752D827BF7FA3EBC4A5165881D9FA60E386DF9CAFB2AB1DCD6B8') {throw 'source_hash_mismatch'}
    if ((Get-FileHash -LiteralPath $destination).Hash -ne '03B31755D3E14425E4008FEB703626B5F1E6325F66553AF5A74222ED06454215') {throw 'installed_hash_mismatch'}
    if (Test-Path -LiteralPath $backup) {throw 'backup_exists'}
    if (Get-Process KenaiVPN,xray -ErrorAction SilentlyContinue) {throw 'application_or_tunnel_running'}
    $tunnel=Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
    if ($tunnel -and $tunnel.Status -ne 'Stopped') {throw 'kenai_tunnel_running'}
    Copy-Item -LiteralPath $destination -Destination $backup
    Stop-Service -Name KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(15))
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $copied=$true
    Start-Service -Name KenaiVpnService
    (Get-Service KenaiVpnService).WaitForStatus('Running',[TimeSpan]::FromSeconds(15))
    $result['status']='complete'
    $result['installed_hash']=(Get-FileHash -LiteralPath $destination).Hash
} catch {
    $result['status']='blocked'
    $result['error_type']=$_.Exception.GetType().Name
    $result['error_line']=$_.InvocationInfo.ScriptLineNumber
    if ($copied) {
        try {
            Stop-Service -Name KenaiVpnService -ErrorAction SilentlyContinue
            Copy-Item -LiteralPath $backup -Destination $destination -Force
            Start-Service -Name KenaiVpnService
            $result['rolled_back']=$true
        } catch { $result['rolled_back']=$false }
    }
}
$result|ConvertTo-Json|Set-Content -LiteralPath $report -Encoding UTF8
