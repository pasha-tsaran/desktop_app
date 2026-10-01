$ErrorActionPreference = 'Stop'
$report = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data\kenai-service-start.json'
$result = @{status='starting'}
try {
    $service = Get-Service -Name 'KenaiVpnService'
    if ($service.Status -eq 'Stopped') { Start-Service -Name 'KenaiVpnService' }
    $service.WaitForStatus('Running', [TimeSpan]::FromSeconds(15))
    Start-Sleep -Seconds 2
    $service.Refresh()
    $result['service_status'] = [string]$service.Status
    $result['status']='complete'
} catch {
    $result['status']='blocked'
    $result['error_type']=$_.Exception.GetType().Name
}
$result | ConvertTo-Json | Set-Content -LiteralPath $report -Encoding UTF8
