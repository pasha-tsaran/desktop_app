[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineInstaller,
    [Parameter(Mandatory)][string]$SevenZip,
    [ValidateSet('2.2.0', '2.2.2')][string]$Version = '2.2.2'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildNumber = if ($Version -eq '2.2.2') { 13 } else { 11 }
$baselineVersion = if ($Version -eq '2.2.2') { '2.2.1' } else { '1.1.8' }
$baselineHash = if ($Version -eq '2.2.2') {
    'e323d74ebd9f347ff8c9e36c366923e3e059410edb4ef37177a2b9ebe3c7127f'
} else { 'bb0a1f151a66a83432d3d5cabad3e2155fa701a9397af6debd260249084a122f' }
if ((Get-FileHash -LiteralPath $BaselineInstaller).Hash.ToLowerInvariant() -ne
    $baselineHash) {
    throw "Expected the audited working $baselineVersion installer."
}
if ((Get-Content "$repo\apps\desktop\pubspec.yaml" -Raw) -notmatch "(?m)^version: $([regex]::Escape($Version))\+$buildNumber\s*$") {
    throw 'Package version mismatch.'
}
$root = Join-Path $repo 'build\system-update'
$baseline = Join-Path $root "baseline-$baselineVersion"
$stage = Join-Path $root "stage-$version"
$verified = Join-Path $root "verified-$version"
$output = Join-Path $repo "dist\KenaiVPN-Setup-IP-MVP-$version-UNSIGNED.exe"
if ((Test-Path $stage) -or (Test-Path $output) -or (Test-Path $verified)) {
    throw 'Refusing to overwrite a previous staged release.'
}
New-Item -ItemType Directory -Force -Path $baseline | Out-Null
& $SevenZip x $BaselineInstaller "-o$baseline" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw 'Baseline extraction failed.' }
$drive = $null
try {
    foreach ($letter in 'R','S','T','U','V','W','X','Y','Z') {
        if (-not (Test-Path "${letter}:\")) {
            $drive = "${letter}:"
            & subst.exe $drive $repo
            if ($LASTEXITCODE -ne 0) { throw 'ASCII build mapping failed.' }
            break
        }
    }
    if (-not $drive) { throw 'No free build drive.' }
    Push-Location "$drive\apps\desktop"
    try {
        # CMake stores the absolute drive of the previous build. Regenerate only
        # Flutter build products; no application/user settings are touched.
        & flutter clean
        if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
        & flutter build windows --release --dart-define=KENAI_API_BASE_URL=https://88.218.94.3:9443 "--dart-define=KENAI_APP_VERSION=$Version" "--dart-define=KENAI_APP_BUILD=$buildNumber"
        if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
    } finally { Pop-Location }
    Push-Location $repo
    try {
        & cargo build --release --locked -p kenai_windows_vpn_service
        if ($LASTEXITCODE -ne 0) { throw 'Service release build failed.' }
    } finally { Pop-Location }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item -LiteralPath "$repo\apps\desktop\build\windows\x64\runner\Release" -Destination "$stage\app" -Recurse
    Move-Item -LiteralPath "$stage\app\kenai_vpn_desktop.exe" -Destination "$stage\app\KenaiVPN.exe"
    Copy-Item -LiteralPath "$baseline\service","$baseline\licenses" -Destination $stage -Recurse
    if ($Version -eq '2.2.2') {
        $pdf = "$stage\app\data\flutter_assets\assets\legal\privacy-policy-ru.pdf"
        if ((Get-FileHash $pdf).Hash -ne (Get-FileHash "$repo\apps\desktop\assets\legal\privacy-policy-ru.pdf").Hash) {
            throw 'Policy PDF differs from source.'
        }
        if (-not (Get-ChildItem "$stage\app" -Recurse -File -Filter '*pdfium*.dll')) {
            throw 'Offline PDF renderer is missing.'
        }
    }
    # Only our first-party controller changes. AWG/Xray/Wintun/driver payloads
    # are preserved byte-for-byte from the working baseline, not third_party.
    Copy-Item -LiteralPath "$repo\target\release\kenai_windows_vpn_service.exe" -Destination "$stage\service\KenaiVpnService.exe" -Force
    Copy-Item -LiteralPath "$repo\apps\desktop\windows\runner\resources\app_icon.ico" -Destination "$stage\app_icon.ico"
    $manifest = foreach ($file in Get-ChildItem "$stage\service" -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath("$stage\service", $file.FullName)
        $hash = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ($relative -ne 'KenaiVpnService.exe' -and
            (Get-FileHash -LiteralPath (Join-Path "$baseline\service" $relative)).Hash -ne $hash) {
            throw "Baseline engine changed: $relative"
        }
        [pscustomobject]@{ File=$relative; SHA256=$hash }
    }
    $nsis = "$repo\build\installer\tools\nsis-3.12\makensis.exe"
    if (-not (Test-Path $nsis)) { throw 'Verified NSIS toolchain is missing.' }
    & $nsis /WX /INPUTCHARSET UTF8 "/DSTAGE_ROOT=$stage" "/DOUTPUT_FILE=$output" "/DAPP_VERSION=$version" "/DFILE_VERSION=$version.0" "$repo\installer\KenaiVPN.nsi"
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    & $SevenZip x $output "-o$verified" -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw 'Final installer extraction failed.' }
    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path "$verified\service" $entry.File)).Hash -ne $entry.SHA256) {
            throw "Packaged payload changed: $($entry.File)"
        }
    }
    if ((Get-ChildItem "$verified\service" -Recurse -File).Count -ne $manifest.Count) {
        throw 'Packaged service file count changed.'
    }
    if ((Get-FileHash "$verified\app\KenaiVPN.exe").Hash -ne (Get-FileHash "$stage\app\KenaiVPN.exe").Hash) {
        throw 'Packaged application differs from the fresh build.'
    }
    [pscustomobject]@{ Artifact=$output; SHA256=(Get-FileHash $output).Hash; ServiceFilesVerified=$manifest.Count }
} finally {
    if ($drive) { & subst.exe $drive /D }
}
