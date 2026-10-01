$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$report = Join-Path $repo 'local_data\vless-native-219.txt'
$results = [Collections.Generic.List[string]]::new()
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Elevation is required.'
    }
    # These fixed test binaries contain no account/profile credentials.
    $serviceTest = Join-Path $repo 'target\debug\deps\kenai_windows_vpn_service-d2387f625cfbe524.exe'
    $tunTest = Join-Path $repo 'build\xray-ipv4-fix\tun-test.exe'
    if ((Get-FileHash -LiteralPath $serviceTest).Hash -ne '22F6C04E05A296DA9D0987E8E9E788C137B60EEF9C9BC856882C20E0441E2B7B' -or
        (Get-FileHash -LiteralPath $tunTest).Hash -ne '16F9A99469ACBFDC0FDCD9682D5F8D0A1FEF6FED6E96B0442565A86A0E2EF95D') {
        throw 'Test binary hash mismatch.'
    }
    Copy-Item -LiteralPath (Join-Path $repo 'third_party\xray\windows\amd64\wintun.dll') `
        -Destination (Join-Path $repo 'build\xray-ipv4-fix\wintun.dll')
    Push-Location $repo
    try {
        $guardOutput = & $serviceTest native_guard_exists_only_while_dynamic_session_is_open --ignored 2>&1
        $results.Add(($guardOutput -join "`n"))
        if ($LASTEXITCODE -ne 0) { throw 'Native IPv6 guard test failed.' }
        $results.Add('ipv6_guard_create_and_cleanup=pass')
        $env:KENAI_NATIVE_TEST = '1'
        # Windows PowerShell treats native stderr log lines as ErrorRecords.
        # Judge the test by its exit code, not Wintun's informational logging.
        $ErrorActionPreference = 'Continue'
        $tunOutput = & $tunTest '-test.run=^TestKenaiNativeIPv4Tun$' '-test.v' 2>&1
        $tunExit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $results.Add(($tunOutput -join "`n"))
        if ($tunExit -ne 0) { throw 'Native IPv4-only adapter test failed.' }
        $results.Add('ipv4_only_tun_setup=pass')
    } finally { Pop-Location }
} catch {
    $results.Add('native_checks=failed')
    $results.Add([string]$_.Exception.Message)
} finally {
    $results | Set-Content -LiteralPath $report -Encoding UTF8
}
