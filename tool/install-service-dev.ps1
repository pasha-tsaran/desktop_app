[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$BinaryPath
)

$ErrorActionPreference = 'Stop'
$serviceName = 'KenaiVpnService'
$resolvedBinary = (Resolve-Path -LiteralPath $BinaryPath).Path
if ([System.IO.Path]::GetExtension($resolvedBinary) -ne '.exe') {
    throw 'BinaryPath must point to a Windows executable.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$payloadSource = Join-Path $repoRoot 'third_party\wireguard\windows\amd64'
$payloadDestination = Join-Path (Split-Path -Parent $resolvedBinary) 'wireguard\amd64'
$awgPayloadSource = Join-Path $repoRoot 'third_party\amneziawg\windows\amd64'
$awgPayloadDestination = Join-Path (Split-Path -Parent $resolvedBinary) 'amneziawg\amd64'
$xrayPayloadSource = Join-Path $repoRoot 'third_party\xray\windows\amd64'
$xrayPayloadDestination = Join-Path (Split-Path -Parent $resolvedBinary) 'xray\amd64'
$expectedHashes = @{
    'tunnel.dll' = '5533cf9cb741d5e9daa7f429aa1c56beba4a500934877c9d072f721f512583ca'
    'wireguard.dll' = 'b1b85e072c45d81358be29d94c599dc76652f912be8c0f0a41e2d5d89a6461d3'
}
$expectedAwgHashes = @{
    'amneziawg.exe' = 'ba446f6e1a4093e43a65d6ff45f4b8c7b6485dc419327eedaa1a218549740e3a'
    'awg.exe' = '272badace73caeb26dc42656f318b3eb7f10028c2f76faad1f52d6fe1e0ced12'
    'wintun.dll' = 'e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
}
$expectedXrayHashes = @{
    'xray.exe' = '0d0fc0ea2b05641acb78c01fc36ad694e7b029861b2d5eb93da0e3e9fda9a98f'
    'wintun.dll' = 'e5da8447dc2c320edc0fc52fa01885c103de8c118481f683643cacc3220dafce'
}
foreach ($name in $expectedHashes.Keys) {
    $source = Join-Path $payloadSource $name
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedHashes[$name]) {
        throw "WireGuard payload hash mismatch: $name"
    }
}
$driverSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $payloadSource 'wireguard.dll')
if ($driverSignature.Status -ne 'Valid' -or
    $driverSignature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC') {
    throw 'wireguard.dll does not have the expected valid WireGuard LLC signature.'
}
foreach ($name in $expectedAwgHashes.Keys) {
    $source = Join-Path $awgPayloadSource $name
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedAwgHashes[$name]) { throw "AmneziaWG payload hash mismatch: $name" }
    $signature = Get-AuthenticodeSignature -LiteralPath $source
    $expectedSigner = if ($name -eq 'wintun.dll') { 'CN=WireGuard LLC' } else { 'Privacy Technologies OU' }
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $expectedSigner) {
        throw "AmneziaWG payload signature mismatch: $name"
    }
}
foreach ($name in $expectedXrayHashes.Keys) {
    $source = Join-Path $xrayPayloadSource $name
    $actual = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expectedXrayHashes[$name]) { throw "Xray payload hash mismatch: $name" }
}
$xrayWintunSignature = Get-AuthenticodeSignature -LiteralPath (Join-Path $xrayPayloadSource 'wintun.dll')
if ($xrayWintunSignature.Status -ne 'Valid' -or
    $xrayWintunSignature.SignerCertificate.Subject -notmatch 'CN=WireGuard LLC') {
    throw 'Xray wintun.dll does not have the expected valid WireGuard LLC signature.'
}

$principal = New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent()
)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this development installation script from an elevated PowerShell session.'
}

if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
    throw "$serviceName already exists. Remove it explicitly before reinstalling."
}

if ($PSCmdlet.ShouldProcess($serviceName, "Install service from $resolvedBinary")) {
    New-Item -ItemType Directory -Path $payloadDestination -Force | Out-Null
    foreach ($name in $expectedHashes.Keys) {
        Copy-Item -LiteralPath (Join-Path $payloadSource $name) `
            -Destination (Join-Path $payloadDestination $name) -Force
    }
    New-Item -ItemType Directory -Path $awgPayloadDestination -Force | Out-Null
    foreach ($name in $expectedAwgHashes.Keys) {
        Copy-Item -LiteralPath (Join-Path $awgPayloadSource $name) `
            -Destination (Join-Path $awgPayloadDestination $name) -Force
    }
    New-Item -ItemType Directory -Path $xrayPayloadDestination -Force | Out-Null
    foreach ($name in $expectedXrayHashes.Keys) {
        Copy-Item -LiteralPath (Join-Path $xrayPayloadSource $name) `
            -Destination (Join-Path $xrayPayloadDestination $name) -Force
    }
    New-Service `
        -Name $serviceName `
        -DisplayName 'Kenai VPN Service (Development)' `
        -Description 'Typed local control boundary for Kenai VPN engines.' `
        -BinaryPathName ('"{0}"' -f $resolvedBinary) `
        -StartupType Manual | Out-Null
    Write-Output "$serviceName installed with Manual startup. It was not started."
}
