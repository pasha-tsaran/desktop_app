[CmdletBinding()]
param(
    [string]$ApiBaseUrl,
    [string]$Version = '2.1.9',
    [switch]$AllowUnconfigured,
    [string]$CertificateThumbprint,
    [string]$TimestampUrl = 'https://timestamp.digicert.com',
    [string]$InstallerFileName
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$physicalRepoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot)).TrimEnd('\')
$substDrive = $null
if ($physicalRepoRoot -match '[^\x00-\x7F]') {
    $usedDrives = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name.ToUpperInvariant() })
    foreach ($letter in 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z') {
        if ($usedDrives -notcontains $letter) {
            $substDrive = "${letter}:"
            & subst.exe $substDrive $physicalRepoRoot
            if ($LASTEXITCODE -ne 0) { throw 'Unable to create an ASCII build path.' }
            break
        }
    }
    if (-not $substDrive) { throw 'No free drive letter is available for the Windows build.' }
}

try {
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    throw 'Version must use major.minor.patch format.'
}
if (-not [string]::IsNullOrWhiteSpace($InstallerFileName) -and
    $InstallerFileName -notmatch '^[A-Za-z0-9._-]+\.exe$') {
    throw 'InstallerFileName must be a plain .exe file name.'
}
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -and
    $CertificateThumbprint -notmatch '^[0-9A-Fa-f]{40,64}$') {
    throw 'CertificateThumbprint must contain 40 to 64 hexadecimal characters.'
}
$timestampUri = [Uri]$TimestampUrl
if (-not $timestampUri.IsAbsoluteUri -or $timestampUri.Scheme -ne 'https') {
    throw 'TimestampUrl must be an absolute HTTPS URL.'
}
if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    if (-not $AllowUnconfigured) {
        throw 'ApiBaseUrl is required. Use -AllowUnconfigured only for packaging verification.'
    }
} else {
    $uri = [Uri]$ApiBaseUrl
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or
        -not [string]::IsNullOrEmpty($uri.UserInfo) -or
        -not [string]::IsNullOrEmpty($uri.Query) -or
        -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw 'ApiBaseUrl must be an absolute HTTPS origin without credentials, query or fragment.'
    }
}

$repoRoot = if ($substDrive) { "$substDrive\" } else { $physicalRepoRoot }
$repoRoot = [IO.Path]::GetFullPath($repoRoot).TrimEnd('\')
$desktopManifest = Join-Path $repoRoot 'apps\desktop\pubspec.yaml'
$manifestVersionLine = @(Get-Content -LiteralPath $desktopManifest | Where-Object { $_ -match '^version:' })
if ($manifestVersionLine.Count -ne 1 -or
    $manifestVersionLine[0] -notmatch '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$') {
    throw 'Desktop pubspec.yaml must declare one version in major.minor.patch+build format.'
}
$clientVersion = $Matches[1]
$clientBuild = $Matches[2]
if ($clientVersion -ne $Version) {
    throw "Installer version $Version does not match desktop client $clientVersion."
}
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build\installer'))
if (-not $buildRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer build directory escaped the repository.'
}
$stageRoot = Join-Path $buildRoot 'stage'
$distRoot = Join-Path $repoRoot 'dist'
if (Test-Path -LiteralPath $stageRoot) {
    $resolvedStageRoot = (Resolve-Path -LiteralPath $stageRoot).Path
    if (-not $resolvedStageRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Installer stage directory escaped the repository.'
    }
    Remove-Item -LiteralPath $resolvedStageRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $stageRoot, $distRoot -Force | Out-Null

$flutter = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutter) {
    $flutter = Join-Path $env:USERPROFILE 'development\flutter\bin\flutter.bat'
}
$cargo = (Get-Command cargo -ErrorAction SilentlyContinue).Source
if (-not $cargo) {
    $cargo = Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe'
}
if (-not (Test-Path -LiteralPath $flutter) -or -not (Test-Path -LiteralPath $cargo)) {
    throw 'Flutter and Rust toolchains are required.'
}

$flutterArguments = @(
    'build', 'windows', '--release',
    "--dart-define=KENAI_APP_VERSION=$clientVersion",
    "--dart-define=KENAI_APP_BUILD=$clientBuild"
)
if (-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    $flutterArguments += "--dart-define=KENAI_API_BASE_URL=$ApiBaseUrl"
}
Push-Location (Join-Path $repoRoot 'apps\desktop')
try {
    & $flutter clean
    if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
    & $flutter @flutterArguments
    if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
} finally {
    Pop-Location
}
Push-Location $repoRoot
try {
    & $cargo build --release --workspace
    if ($LASTEXITCODE -ne 0) { throw 'Rust release build failed.' }
    foreach ($stage in 11, 13, 14) {
        & powershell -NoProfile -File (Join-Path $repoRoot "tool\verify-stage$stage.ps1")
        if ($LASTEXITCODE -ne 0) { throw "Stage $stage payload verification failed." }
    }
} finally {
    Pop-Location
}

$appStage = Join-Path $stageRoot 'app'
$serviceStage = Join-Path $stageRoot 'service'
$licensesStage = Join-Path $stageRoot 'licenses'
New-Item -ItemType Directory -Path $appStage, $serviceStage, $licensesStage -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'apps\desktop\windows\runner\resources\app_icon.ico') `
    -Destination (Join-Path $stageRoot 'app_icon.ico')
$flutterOutput = Join-Path $repoRoot 'apps\desktop\build\windows\x64\runner\Release'
Copy-Item -Path (Join-Path $flutterOutput '*') -Destination $appStage -Recurse -Force
Move-Item -LiteralPath (Join-Path $appStage 'kenai_vpn_desktop.exe') `
    -Destination (Join-Path $appStage 'KenaiVPN.exe')
Copy-Item -LiteralPath (Join-Path $repoRoot 'target\release\kenai_windows_vpn_service.exe') `
    -Destination (Join-Path $serviceStage 'KenaiVpnService.exe')
foreach ($product in 'wireguard', 'amneziawg', 'xray') {
    $payloadDestination = Join-Path $serviceStage "$product\amd64"
    $licenseDestination = Join-Path $licensesStage $product
    New-Item -ItemType Directory -Path $payloadDestination, $licenseDestination -Force | Out-Null
    Copy-Item -Path (Join-Path $repoRoot "third_party\$product\windows\amd64\*") `
        -Destination $payloadDestination -Force
    Copy-Item -Path (Join-Path $repoRoot "third_party\$product\LICENSE*") `
        -Destination $licenseDestination -Force
}

# Ship modified MPL source alongside the patched executable's license.
Copy-Item -LiteralPath (Join-Path $repoRoot 'third_party\xray\source') `
    -Destination (Join-Path $licensesStage 'xray\source') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $repoRoot 'third_party\xray\README.md') `
    -Destination (Join-Path $licensesStage 'xray\README.md')

function Find-SignTool {
    $roots = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin' `
        -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending
    foreach ($root in $roots) {
        $candidate = Join-Path $root.FullName 'x64\signtool.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}
function Sign-FirstParty([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($CertificateThumbprint)) { return }
    $signTool = Find-SignTool
    if (-not $signTool) { throw 'signtool.exe is required when CertificateThumbprint is set.' }
    & $signTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $Path
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $Path" }
}

Sign-FirstParty (Join-Path $appStage 'KenaiVPN.exe')
Sign-FirstParty (Join-Path $serviceStage 'KenaiVpnService.exe')

$nsisVersion = '3.12'
$nsisSha256 = '56581f90db321581c5381193d796fffcf2d24b2f8fed2160a6c6a3baa67f2c4f'
$nsisMd5 = '757c22153dd8b90f5e297310d9966997'
$nsisRoot = Join-Path $buildRoot "tools\nsis-$nsisVersion"
$makeNsis = Join-Path $nsisRoot 'makensis.exe'
if (-not (Test-Path -LiteralPath $makeNsis)) {
    $archive = Join-Path $buildRoot "nsis-$nsisVersion.zip"
    if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force }
    & curl.exe -L --fail --silent --show-error --output $archive `
        "https://prdownloads.sourceforge.net/nsis/nsis-$nsisVersion.zip?download"
    if ($LASTEXITCODE -ne 0) { throw 'NSIS download failed.' }
    $actual = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $nsisSha256) { throw 'NSIS archive hash mismatch.' }
    $actualMd5 = (Get-FileHash -LiteralPath $archive -Algorithm MD5).Hash.ToLowerInvariant()
    if ($actualMd5 -ne $nsisMd5) { throw 'NSIS official-feed checksum mismatch.' }
    $toolsRoot = Split-Path -Parent $nsisRoot
    New-Item -ItemType Directory -Path $toolsRoot -Force | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $toolsRoot -Force
    Remove-Item -LiteralPath $archive -Force
}
if (-not (Test-Path -LiteralPath $makeNsis)) { throw 'NSIS compiler is unavailable.' }

$defaultOutputName = if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    'KenaiVPN-Setup-UNCONFIGURED.exe'
} else {
    'KenaiVPN-Setup.exe'
}
$outputName = if ([string]::IsNullOrWhiteSpace($InstallerFileName)) {
    $defaultOutputName
} else {
    $InstallerFileName
}
$outputPath = Join-Path $distRoot $outputName
$fileVersion = "$Version.0"
& $makeNsis /WX /INPUTCHARSET UTF8 "/DSTAGE_ROOT=$stageRoot" "/DOUTPUT_FILE=$outputPath" `
    "/DAPP_VERSION=$Version" "/DFILE_VERSION=$fileVersion" `
    (Join-Path $repoRoot 'installer\KenaiVPN.nsi')
if ($LASTEXITCODE -ne 0) { throw 'NSIS compilation failed.' }
Sign-FirstParty $outputPath

$signature = Get-AuthenticodeSignature -LiteralPath $outputPath
if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint) -and
    $signature.Status -ne 'Valid') {
    throw 'The signed installer failed Authenticode verification.'
}
$hash = (Get-FileHash -LiteralPath $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
[pscustomobject]@{
    Artifact = $outputPath
    Sha256 = $hash
    SignatureStatus = $signature.Status
    ApiConfigured = -not [string]::IsNullOrWhiteSpace($ApiBaseUrl)
}
} finally {
    if ($substDrive) { & subst.exe $substDrive /D }
}
