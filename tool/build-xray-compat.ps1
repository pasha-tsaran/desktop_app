[CmdletBinding()]
param([string]$GoExecutable)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$build = Join-Path $repo 'build\xray-ipv4-fix'
$source = Join-Path $build 'source'
if (-not $GoExecutable) { $GoExecutable = Join-Path $build 'toolchain\go\bin\go.exe' }
if ((& $GoExecutable version) -ne 'go version go1.27.1 windows/amd64') {
    throw 'This build requires the documented Go 1.27.1 Windows amd64 toolchain.'
}
if (-not (Test-Path -LiteralPath $source)) {
    git clone --depth 1 --branch v26.9.9 https://github.com/XTLS/Xray-core.git $source
    if ($LASTEXITCODE -ne 0) { throw 'Xray source clone failed.' }
}
if ((git -C $source rev-parse HEAD) -ne '52a412d9e2f5c2a5142b1b4e2ab3771dacb8b120') {
    throw 'Unexpected Xray source revision.'
}
$changed = @(git -C $source diff --name-only HEAD)
$untracked = @(git -C $source ls-files --others --exclude-standard)
foreach ($file in $changed + $untracked) {
    if ($file -notin @('proxy/tun/tun_windows.go', 'proxy/tun/kenai_windows_test.go')) {
        throw 'Unexpected local Xray changes; use a clean build directory.'
    }
}
Copy-Item -LiteralPath (Join-Path $repo 'third_party\xray\source\tun_windows.go'),
    (Join-Path $repo 'third_party\xray\source\kenai_windows_test.go') -Destination (Join-Path $source 'proxy\tun')
$previous = @{}
foreach ($name in @('CGO_ENABLED','GOOS','GOARCH','GOAMD64')) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    $env:CGO_ENABLED='0'; $env:GOOS='windows'; $env:GOARCH='amd64'; $env:GOAMD64='v1'
    Push-Location $source
    try {
        & $GoExecutable test ./proxy/tun -run '^TestKenaiFamilyRequested$' -count=1
        if ($LASTEXITCODE -ne 0) { throw 'Xray regression test failed.' }
        & $GoExecutable build -o (Join-Path $build 'xray.exe') -trimpath -buildvcs=false `
            '-gcflags=all=-l=4' '-ldflags=-X github.com/xtls/xray-core/core.build=kenai-ipv4-1 -s -w -buildid=' ./main
        if ($LASTEXITCODE -ne 0) { throw 'Xray build failed.' }
    } finally { Pop-Location }
} finally {
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
}
$binary = Join-Path $build 'xray.exe'
if ((Get-FileHash -LiteralPath $binary).Hash -ne '6B5CD540E3F4CE59F309863F0F1339B0BDA13AEB9451405ABFCA29BA873CCA20') {
    throw 'Rebuilt executable differs from the pin; payload was not replaced.'
}
Copy-Item -LiteralPath $binary -Destination (Join-Path $repo 'third_party\xray\windows\amd64\xray.exe')
Write-Output 'xray_compatibility_build=verified'
