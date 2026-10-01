[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineInstaller,
    [Parameter(Mandatory)][string]$SevenZip,
    [ValidateSet('1.1.8', '2.1.9', '2.2.0')][string]$BaselineVersion = '2.2.0',
    [ValidateSet('2.1.10', '2.2.1')][string]$Version = '2.2.1'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$buildNumber = if ($Version -eq '2.2.1') { 12 } else { 10 }
if ($Version -eq '2.2.1' -and $BaselineVersion -ne '2.2.0') {
    throw '2.2.1 requires the 2.2.0 system-function service.'
}
$baselineHashes = @{
    '1.1.8' = 'bb0a1f151a66a83432d3d5cabad3e2155fa701a9397af6debd260249084a122f'
    '2.1.9' = '61db69837bb40c7e7e1e55ca691c0db674ca22599d52959612e32add22fd80be'
    '2.2.0' = '21dc3046deefab7d4e57166b2f6f0bbf2467c2d9274ad9d59e1d6e34b858684c'
}
if ((Get-FileHash -LiteralPath $BaselineInstaller).Hash.ToLowerInvariant() -ne $baselineHashes[$BaselineVersion]) {
    throw 'Baseline installer differs from the audited release.'
}
$baseline = Join-Path $repo "build\ui-update\baseline-$BaselineVersion"
$stage = Join-Path $repo "build\ui-update\stage-$Version"
if (Test-Path $stage) { throw 'Use a fresh staging directory; an earlier build already exists.' }
New-Item -ItemType Directory -Force -Path $baseline,$stage | Out-Null
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
        & flutter clean
        if ($LASTEXITCODE -ne 0) { throw 'Flutter clean failed.' }
        & flutter build windows --release --dart-define=KENAI_API_BASE_URL=https://88.218.94.3:9443 "--dart-define=KENAI_APP_VERSION=$Version" "--dart-define=KENAI_APP_BUILD=$buildNumber"
        if ($LASTEXITCODE -ne 0) { throw 'Flutter release build failed.' }
    } finally { Pop-Location }
    Copy-Item -LiteralPath "$repo\apps\desktop\build\windows\x64\runner\Release" -Destination "$stage\app" -Recurse
    Move-Item -LiteralPath "$stage\app\kenai_vpn_desktop.exe" -Destination "$stage\app\KenaiVPN.exe"
    # Keep the service and every engine byte-identical to the chosen installer.
    Copy-Item -LiteralPath "$baseline\service","$baseline\licenses" -Destination $stage -Recurse
    if ($Version -eq '2.2.1') {
        Copy-Item -LiteralPath "$repo\third_party\pdfium" -Destination "$stage\licenses\pdfium" -Recurse
        $pdf = "$stage\app\data\flutter_assets\assets\legal\privacy-policy-ru.pdf"
        if ((Get-FileHash $pdf).Hash -ne (Get-FileHash "$repo\apps\desktop\assets\legal\privacy-policy-ru.pdf").Hash) {
            throw 'Policy PDF is missing or differs from source.'
        }
        if (-not (Get-ChildItem "$stage\app" -Recurse -File -Filter '*pdfium*.dll')) {
            throw 'Offline PDF renderer was not bundled.'
        }
    }
    Copy-Item -LiteralPath "$repo\apps\desktop\windows\runner\resources\app_icon.ico" -Destination "$stage\app_icon.ico"
    $manifest = foreach ($file in Get-ChildItem "$baseline\service" -Recurse -File) {
        $relative = [IO.Path]::GetRelativePath("$baseline\service", $file.FullName)
        $expected = (Get-FileHash -LiteralPath $file.FullName).Hash
        if ((Get-FileHash -LiteralPath (Join-Path "$stage\service" $relative)).Hash -ne $expected) {
            throw "VPN payload changed: $relative"
        }
        [pscustomobject]@{ File=$relative; SHA256=$expected }
    }
    $nsis = "$repo\build\installer\tools\nsis-3.12\makensis.exe"
    if (-not (Test-Path $nsis)) { throw 'Verified NSIS 3.12 toolchain is missing.' }
    $output = "$repo\dist\KenaiVPN-Setup-IP-MVP-$Version-UNSIGNED.exe"
    if (Test-Path $output) { throw 'New installer already exists; refusing to overwrite.' }
    & $nsis /WX /INPUTCHARSET UTF8 "/DSTAGE_ROOT=$stage" "/DOUTPUT_FILE=$output" "/DAPP_VERSION=$Version" "/DFILE_VERSION=$Version.0" "$repo\installer\KenaiVPN.nsi"
    if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
    $verified = "$repo\build\ui-update\verified-$Version"
    & $SevenZip x $output "-o$verified" -y -bso0 -bsp0
    if ($LASTEXITCODE -ne 0) { throw 'Final installer extraction failed.' }
    foreach ($entry in $manifest) {
        if ((Get-FileHash -LiteralPath (Join-Path "$verified\service" $entry.File)).Hash -ne $entry.SHA256) {
            throw "Packaged VPN payload changed: $($entry.File)"
        }
    }
    if ((Get-ChildItem "$verified\service" -Recurse -File).Count -ne $manifest.Count) {
        throw 'Packaged VPN payload file count changed.'
    }
    if ($Version -eq '2.2.1' -and
        (Get-FileHash "$verified\app\data\flutter_assets\assets\legal\privacy-policy-ru.pdf").Hash -ne (Get-FileHash $pdf).Hash) {
        throw 'Packaged policy PDF differs from source.'
    }
    [pscustomobject]@{ Artifact=$output; Baseline=$BaselineVersion; SHA256=(Get-FileHash $output).Hash; ServiceFilesVerified=$manifest.Count }
} finally {
    if ($drive) { & subst.exe $drive /D }
}
