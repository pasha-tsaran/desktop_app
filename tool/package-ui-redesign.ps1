[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BaselineInstaller,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [ValidateSet('Redesign', 'Support', 'Sphere')][string]$ReleaseLabel = 'Redesign',
    [ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version = '2.2.2'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$baselineHash = '365d359f9a1203ddb0ba384cb05b12b7389e672cc7ab956eb0f531f2a280d177'
if ((Get-FileHash -LiteralPath $BaselineInstaller).Hash.ToLowerInvariant() -ne $baselineHash) {
    throw 'Expected the existing Kenai VPN 2.2.2 baseline installer.'
}
$release = Join-Path $repo 'apps\desktop\build\windows\x64\runner\Release'
$sevenZip = Join-Path $repo 'build\release-audit\tools\7zip\Files\7-Zip\7z.exe'
$nsis = Join-Path $repo 'build\installer\tools\nsis-3.12\makensis.exe'
foreach ($required in @($sevenZip, $nsis, "$release\kenai_vpn_desktop.exe", "$release\data\app.so")) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing build dependency: $required" }
}
$builtVersion = (Get-Item -LiteralPath "$release\kenai_vpn_desktop.exe").VersionInfo.ProductVersion
if (-not $builtVersion.StartsWith($Version + '+') -and $builtVersion -ne $Version -and
    -not $builtVersion.StartsWith($Version + '.')) {
    throw "Application version $builtVersion differs from installer version $Version"
}
if ($ReleaseLabel -eq 'Sphere') {
    foreach ($asset in Get-ChildItem -LiteralPath "$repo\apps\desktop\assets\branding" -File) {
        $bundled = Join-Path "$release\data\flutter_assets\assets\branding" $asset.Name
        if ((Get-FileHash -LiteralPath $bundled).Hash -ne (Get-FileHash -LiteralPath $asset.FullName).Hash) {
            throw "Branding asset differs: $($asset.Name)"
        }
    }
}
foreach ($asset in 'globe.png', 'armenia-map.png', 'orb.png') {
    if ((Get-FileHash -LiteralPath "$release\data\flutter_assets\assets\visual\$asset").Hash -ne
        (Get-FileHash -LiteralPath "$repo\apps\desktop\assets\visual\$asset").Hash) {
        throw "Artwork not bundled correctly: $asset"
    }
}
$work = Join-Path $repo ("build\package-$ReleaseLabel-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$baseline = Join-Path $work 'baseline'
$stage = Join-Path $work 'stage'
$verified = Join-Path $work 'verified'
$output = [IO.Path]::GetFullPath($OutputDirectory)
$appOutput = Join-Path $output 'KenaiVPN'
$installer = Join-Path $output "KenaiVPN-Setup-$Version-$ReleaseLabel-UNSIGNED.exe"
if ((Test-Path -LiteralPath $work) -or (Test-Path -LiteralPath $appOutput) -or (Test-Path -LiteralPath $installer)) {
    throw 'A build or output already exists; refusing to overwrite it.'
}
New-Item -ItemType Directory -Path $baseline, $stage, $output -Force | Out-Null
& $sevenZip x $BaselineInstaller "-o$baseline" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw 'Baseline extraction failed.' }
Copy-Item -LiteralPath $release -Destination "$stage\app" -Recurse
Move-Item -LiteralPath "$stage\app\kenai_vpn_desktop.exe" -Destination "$stage\app\KenaiVPN.exe"
Copy-Item -LiteralPath "$baseline\service", "$baseline\licenses" -Destination $stage -Recurse
Copy-Item -LiteralPath "$repo\apps\desktop\windows\runner\resources\app_icon.ico" -Destination "$stage\app_icon.ico"
$serviceFiles = @(Get-ChildItem -LiteralPath "$baseline\service" -Recurse -File)
foreach ($file in $serviceFiles) {
    $relative = [IO.Path]::GetRelativePath("$baseline\service", $file.FullName)
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path "$stage\service" $relative)).Hash) {
        throw "VPN payload differs from baseline: $relative"
    }
}
& $nsis /WX /INPUTCHARSET UTF8 "/DSTAGE_ROOT=$stage" "/DOUTPUT_FILE=$installer" "/DAPP_VERSION=$Version" "/DFILE_VERSION=$Version.0" "$repo\installer\KenaiVPN.nsi"
if ($LASTEXITCODE -ne 0) { throw 'Installer compilation failed.' }
& $sevenZip x $installer "-o$verified" -y -bso0 -bsp0
if ($LASTEXITCODE -ne 0) { throw 'Installer verification extraction failed.' }
$verifiedCount = 0
foreach ($component in 'app', 'service', 'licenses') {
    $files = @(Get-ChildItem -LiteralPath "$stage\$component" -Recurse -File)
    if ((@(Get-ChildItem -LiteralPath "$verified\$component" -Recurse -File)).Count -ne $files.Count) {
        throw "Packaged file count differs: $component"
    }
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($stage, $file.FullName)
        if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne
            (Get-FileHash -LiteralPath (Join-Path $verified $relative)).Hash) {
            throw "Packaged file differs: $relative"
        }
        $verifiedCount++
    }
}
Copy-Item -LiteralPath "$stage\app" -Destination $appOutput -Recurse
Copy-Item -LiteralPath "$stage\licenses" -Destination "$appOutput\licenses" -Recurse
foreach ($file in Get-ChildItem -LiteralPath "$stage\app" -Recurse -File) {
    $relative = [IO.Path]::GetRelativePath("$stage\app", $file.FullName)
    if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $appOutput $relative)).Hash) {
        throw "Copied application file differs: $relative"
    }
}
$installerHash = (Get-FileHash -LiteralPath $installer).Hash
@(
    "Installer SHA256: $installerHash",
    "Baseline SHA256: $baselineHash",
    "Packaged files verified: $verifiedCount",
    "Unchanged VPN service/engine files: $($serviceFiles.Count)"
) | Set-Content -LiteralPath (Join-Path $output 'SHA256.txt') -Encoding utf8
@"
Kenai VPN $Version — $ReleaseLabel

Установка / обновление:
  KenaiVPN-Setup-$Version-$ReleaseLabel-UNSIGNED.exe

Готовое приложение:
  KenaiVPN\KenaiVPN.exe
  Для VPN нужна установленная служба Kenai VPN. Установщик включает её.
  Папку KenaiVPN переносите целиком: DLL и каталог data обязательны.

В светлой теме использованы бирюзовые и сиреневые оттенки.
Изображения и геометрия общие для обеих тем; планета не растягивается.
VPN-служба и движки совпадают с существующим установщиком 2.2.2.

Содержимое установщика распаковано и сверено по SHA256.
Реальное подключение к VPN-серверу во время этих проверок не запускалось.
"@ | Set-Content -LiteralPath (Join-Path $output 'ПРОЧИТАЙТЕ.txt') -Encoding utf8
if ($ReleaseLabel -eq 'Support') {
    @'

Добавлен раздел «Поддержка»: заявки, история, чат и статусы.
Для работы чата необходимо обновление сервера и настройка Telegram-бота.
Заполнение токена в .env без миграции и запуска worker недостаточно.
Инструкция: НАСТРОЙКА-ПОДДЕРЖКИ.md рядом с установщиком.
Токен, ID чата и ID операторов указываются только в серверном окружении.
Рабочий сервер этой сборкой автоматически не обновляется.
'@ | Add-Content -LiteralPath (Join-Path $output 'ПРОЧИТАЙТЕ.txt') -Encoding utf8
}
[pscustomobject]@{
    Installer = $installer
    Application = "$appOutput\KenaiVPN.exe"
    VerifiedFiles = $verifiedCount
    UnchangedVpnFiles = $serviceFiles.Count
    SHA256 = $installerHash
}
