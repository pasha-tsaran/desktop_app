[CmdletBinding()]
param([string]$ArtifactPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$RepoRoot = Split-Path -Parent $PSScriptRoot

function Require-Text([string]$Path, [string]$Pattern) {
    $Resolved = Join-Path $RepoRoot $Path
    if (-not (Select-String -LiteralPath $Resolved -Pattern $Pattern -Quiet)) {
        throw "Missing stage 15 marker: $Path"
    }
}

Require-Text 'installer/KenaiVPN.nsi' 'RequestExecutionLevel admin'
Require-Text 'installer/KenaiVPN.nsi' 'File /r "\$\{STAGE_ROOT\}\\service\\\*"'
Require-Text 'installer/KenaiVPN.nsi' 'GetFullPathName /SHORT'
Require-Text 'installer/KenaiVPN.nsi' 'sc\.exe.*create.*binPath='
Require-Text 'installer/KenaiVPN.nsi' 'sidtype.*unrestricted'
Require-Text 'installer/KenaiVPN.nsi' 'icacls.*S-1-5-32-545.*\(OI\)\(CI\)RX'
Require-Text 'installer/KenaiVPN.nsi' 'WireGuardTunnel\$\$Kenai'
Require-Text 'installer/KenaiVPN.nsi' 'AmneziaWGTunnel\$\$KenaiAwg'
Require-Text 'installer/KenaiVPN.nsi' 'CredDeleteW'
if (Select-String -LiteralPath (Join-Path $RepoRoot 'installer/KenaiVPN.nsi') `
        -Pattern 'CreateServiceW|OpenSCManagerW' -Quiet) {
    throw 'Installer must not register the service through an unsafe raw System plug-in call.'
}
Require-Text 'installer/KenaiVPN.nsi' 'RMDir /r "\$APPDATA\\KenaiVPN"'
Require-Text 'installer/KenaiVPN.nsi' 'RMDir /r /REBOOTOK "\$INSTDIR"'
Require-Text 'installer/KenaiVPN.nsi' 'SetOutPath "\$TEMP"'
Require-Text 'tool/build-windows-installer.ps1' 'ApiBaseUrl is required'
Require-Text 'tool/build-windows-installer.ps1' 'AllowUnconfigured only for packaging verification'
Require-Text 'tool/build-windows-installer.ps1' '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'
Require-Text 'tool/build-windows-installer.ps1' '757c22153dd8b90f5e297310d9966997'
Require-Text 'tool/build-windows-installer.ps1' '/INPUTCHARSET UTF8'
Require-Text 'tool/build-windows-installer.ps1' 'CertificateThumbprint'
Require-Text 'tool/build-windows-installer.ps1' 'InstallerFileName must be a plain \.exe file name'

foreach ($relative in @(
    'third_party/wireguard/windows/amd64/wireguard.dll',
    'third_party/wireguard/windows/amd64/tunnel.dll',
    'third_party/amneziawg/windows/amd64/amneziawg.exe',
    'third_party/amneziawg/windows/amd64/awg.exe',
    'third_party/xray/windows/amd64/xray.exe'
)) {
    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $relative) -PathType Leaf)) {
        throw "Missing installer payload: $relative"
    }
}

if (-not [string]::IsNullOrWhiteSpace($ArtifactPath)) {
    $Artifact = (Resolve-Path -LiteralPath $ArtifactPath).Path
    $Bytes = [IO.File]::ReadAllBytes($Artifact)
    if ($Bytes.Length -lt 10MB -or $Bytes[0] -ne 0x4D -or $Bytes[1] -ne 0x5A) {
        throw 'Installer artifact is not a plausible Windows executable.'
    }
    $Signature = Get-AuthenticodeSignature -LiteralPath $Artifact
    [pscustomobject]@{
        Artifact = $Artifact
        Size = $Bytes.Length
        Sha256 = (Get-FileHash -LiteralPath $Artifact -Algorithm SHA256).Hash.ToLowerInvariant()
        SignatureStatus = $Signature.Status
    }
}

Write-Host 'Stage 15 installer structure and artifact verification passed.'
