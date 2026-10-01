# Administrator-only, bounded test on this reported endpoint/interface.
# Does not stop/start VPN services, read stored credentials or change firewall.
$ErrorActionPreference='Stop'
$out=Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data\awg-route-probe.json'
$route=$null
$events=[System.Collections.Generic.List[object]]::new()
$result=@{status='waiting_for_kenai';route_added=$false}
function Save-Result { $result['events']=@($events.ToArray()); $result|ConvertTo-Json -Depth 5|Set-Content -LiteralPath $out -Encoding UTF8 }
function Peer-Status {
    $raw=@(& 'C:\Program Files\Kenai VPN\service\amneziawg\amd64\awg.exe' show KenaiAwg dump 2>$null)
    if($LASTEXITCODE -eq 0 -and $raw.Count -ge 2){
        $fields=$raw[1] -split "`t"
        if($fields.Count -ge 8){return @{handshake=[long]$fields[4];received=[long]$fields[5];sent=[long]$fields[6]}}
    }
    return @{unavailable=$true}
}
try {
    Save-Result
    $deadline=[DateTime]::UtcNow.AddSeconds(120)
    do {
        $service=Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
        if($service -and $service.Status -eq 'Running'){break}
        Start-Sleep -Milliseconds 200
    } while([DateTime]::UtcNow -lt $deadline)
    if(-not $service -or $service.Status -ne 'Running'){throw 'kenai_not_started'}
    $other=Get-Service -Name 'AmneziaWGTunnel$AmneziaVPN' -ErrorAction SilentlyContinue
    if($other -and $other.Status -eq 'Running'){throw 'other_vpn_running'}
    $result['status']='probing'
    $events.Add(@{phase='before_route';peer=(Peer-Status)})
    $adapter=Get-NetAdapter -Name 'Ethernet'
    if($adapter.InterfaceIndex -ne 17 -or $adapter.Status -ne 'Up'){throw 'physical_adapter_changed'}
    $gateway=@(Get-NetRoute -InterfaceIndex 17 -DestinationPrefix '0.0.0.0/0' | Where-Object NextHop -eq '192.168.0.1')
    if($gateway.Count -ne 1){throw 'physical_gateway_changed'}
    $existing=@(Get-NetRoute -DestinationPrefix '88.218.94.3/32' -ErrorAction SilentlyContinue)
    if($existing.Count){throw 'endpoint_route_already_present'}
    $route=New-NetRoute -DestinationPrefix '88.218.94.3/32' -InterfaceIndex 17 -NextHop '192.168.0.1' -RouteMetric 19 -PolicyStore ActiveStore
    $result['route_added']=$true
    Save-Result
    for($i=0;$i -lt 25;$i++){
        $peer=Peer-Status
        $events.Add(@{second=$i;peer=$peer})
        if($peer.handshake -gt 0){$result['handshake_confirmed']=$true}
        Save-Result
        $service=Get-Service -Name 'AmneziaWGTunnel$KenaiAwg' -ErrorAction SilentlyContinue
        if(-not $service -or $service.Status -ne 'Running'){break}
        Start-Sleep -Seconds 1
    }
    $result['status']='complete'
} catch {
    $result['status']='blocked'
    $result['error_type']=$_.Exception.GetType().Name
    $result['error_line']=$_.InvocationInfo.ScriptLineNumber
} finally {
    if($route){
        try {$route|Remove-NetRoute -Confirm:$false; $result['route_removed']=$true}
        catch {$result['route_removed']=$false}
    }
    Save-Result
}
