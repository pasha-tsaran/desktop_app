[CmdletBinding()]
param()

# Read-only network probes plus an ABORTED WFP transaction. No live filters,
# installation, profile reads, service restarts, DNS/route edits or disconnects.
$ErrorActionPreference = 'Stop'
$expectedHash = 'E21DB52B252338A67993F661BC45B4ABCDBB887905ED592C15F8684BF2A459E8'
# Exact Cargo test artifact from this reviewed build.
$testBinary = Join-Path $env:TEMP 'kenai-first-dns-validation\debug\deps\kenai_windows_vpn_service-d2387f625cfbe524.exe'
$testName = 'windows_service_host::xray_dns_guard::tests::native_dns_policy_validates_without_changing_traffic'
try {
    Write-Output 'DIAGNOSTIC_VERSION=FIRST-VPN-DNS-1'
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Output 'RESULT=ADMIN_REQUIRED'
        return
    }
    if ((Get-FileHash -LiteralPath $testBinary -Algorithm SHA256).Hash -ne $expectedHash) {
        Write-Output 'RESULT=TEST_BINARY_MISMATCH'
        return
    }
    $nativeOutput = @(& $testBinary --exact $testName --ignored --test-threads=1 2>&1)
    $nativeCode = $LASTEXITCODE
    $nativePassed = $nativeCode -eq 0 -and
        ($nativeOutput -join "`n") -match 'test result: ok\. 1 passed;'
    Write-Output ('DNS_POLICY_NATIVE_VALIDATION=' + $nativePassed)
    Write-Output 'DNS_POLICY_COMMITTED=False'
    if (-not $nativePassed) { Write-Output 'RESULT=NATIVE_VALIDATION_FAILED'; return }

    $tun = Get-NetAdapter -Name KenaiXray -ErrorAction SilentlyContinue
    Write-Output ('TUN_UP=' + ($null -ne $tun -and $tun.Status -eq 'Up'))
    if ($null -eq $tun -or $tun.Status -ne 'Up') {
        Write-Output 'RESULT=CONNECT_FIRST_APP_TO_ARMENIA'
        return
    }
    foreach ($family in @('IPv4','IPv6')) {
        $ipInterface = Get-NetIPInterface -InterfaceAlias KenaiXray -AddressFamily $family -ErrorAction SilentlyContinue
        if ($ipInterface) {
            Write-Output ("TUN_$($family)_MTU=" + $ipInterface.NlMtu)
            Write-Output ("TUN_$($family)_METRIC=" + $ipInterface.InterfaceMetric)
        }
    }
    foreach ($entry in @(Get-DnsClientServerAddress -InterfaceAlias KenaiXray -ErrorAction SilentlyContinue)) {
        Write-Output ('TUN_DNS_FAMILY=' + $entry.AddressFamily + ' SERVERS=' + ($entry.ServerAddresses -join ','))
    }
    foreach ($address in @('1.1.1.1','1.0.0.1','2606:4700:4700::1111')) {
        try {
            $route = @(Find-NetRoute -RemoteIPAddress $address -ErrorAction Stop)
            $throughTun = @($route | Where-Object { $_.InterfaceIndex -eq $tun.ifIndex }).Count -gt 0
            Write-Output ("ROUTE_TARGET=$address VIA_TUN=$throughTun")
        } catch { Write-Output ("ROUTE_TARGET=$address RESULT=UNAVAILABLE") }
        foreach ($record in @('A','AAAA')) {
            try {
                $answer = @(Resolve-DnsName -Name 'example.com' -Type $record -Server $address `
                    -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop)
                $ok = @($answer | Where-Object { $_.Type -eq $record }).Count -gt 0
                Write-Output ("DNS_SERVER=$address TYPE=$record ANSWER=$ok")
            } catch { Write-Output ("DNS_SERVER=$address TYPE=$record ANSWER=False") }
        }
    }
    # Native stderr is a normal result under Windows PowerShell 5.1.
    $ErrorActionPreference = 'Continue'
    foreach ($family in @('-4','-6')) {
        $result = @(& "$env:SystemRoot\System32\curl.exe" -q --noproxy '*' $family `
            --silent --connect-timeout 4 --max-time 8 https://api64.ipify.org 2>$null)
        $code = $LASTEXITCODE
        Write-Output ("HTTP_FAMILY=$family CURL_EXIT=$code")
        if ($family -eq '-4') {
            Write-Output ('IPV4_ARMENIA_EXIT=' + ($code -eq 0 -and ($result -join '').Trim() -eq '88.218.94.3'))
        }
    }
    Write-Output 'LEAK_CAPTURE=NOT_PERFORMED'
    Write-Output 'INSTALLED_SERVICE_CHANGED=False'
    Write-Output 'RESULT=DIAGNOSTICS_COMPLETE'
} catch {
    Write-Output ('ERROR_TYPE=' + $_.Exception.GetType().Name)
    Write-Output 'RESULT=DIAGNOSTICS_INCOMPLETE'
} finally {
    Write-Output 'TEST_FINISHED'
}
