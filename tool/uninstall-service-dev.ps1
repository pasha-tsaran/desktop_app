[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param()

$ErrorActionPreference = 'Stop'
$serviceName = 'KenaiVpnService'
$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if (-not $service) {
    Write-Output "$serviceName is not installed."
    exit 0
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this development removal script from an elevated PowerShell session.'
}

if ($PSCmdlet.ShouldProcess($serviceName, 'Stop and remove development service')) {
    if ($service.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
        Stop-Service -Name $serviceName -Force
        $service.WaitForStatus(
            [System.ServiceProcess.ServiceControllerStatus]::Stopped,
            [TimeSpan]::FromSeconds(15)
        )
    }
    & sc.exe delete $serviceName | Out-Null
    Write-Output "$serviceName removal requested. The executable was not deleted."
}
