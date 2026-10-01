[CmdletBinding()]
param(
    [switch]$Worker,
    [ValidatePattern('^[a-f0-9]{32}$')][string]$RunId,
    [ValidatePattern('^xray-[a-f0-9]{32}$')][string]$VlessHandle,
    [ValidatePattern('^awg-[a-f0-9]{32}$')][string]$AwgHandle
)

# Read-only profile audit. Never prints or saves private keys, UUIDs, Reality
# public keys, full profiles, activation keys, or packet contents. The parent
# creates one temporary SYSTEM task to read service-only DPAPI vault files.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$reportRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\armenia-profile-audit'
$userCiphertext = $null
$userPlaintext = $null

function Hash-Text([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Read-Exact([IO.BinaryReader]$Reader, [int]$Count) {
    if ($Count -lt 0 -or $Count -gt 4096) { throw 'invalid_length' }
    $value = $Reader.ReadBytes($Count)
    if ($value.Length -ne $Count) { throw 'truncated_profile' }
    return ,$value
}

function Read-Text([IO.BinaryReader]$Reader) {
    $length = [int]$Reader.ReadByte()
    if ($length -lt 1 -or $length -gt 253) { throw 'invalid_text_length' }
    return [Text.UTF8Encoding]::new($false, $true).GetString((Read-Exact $Reader $length))
}

function Read-OptionalText([IO.BinaryReader]$Reader) {
    $length = [int]$Reader.ReadByte()
    if ($length -gt 253) { throw 'invalid_text_length' }
    return [Text.UTF8Encoding]::new($false, $true).GetString((Read-Exact $Reader $length))
}

function Read-TextList([IO.BinaryReader]$Reader) {
    $count = [int]$Reader.ReadByte()
    if ($count -gt 32) { throw 'invalid_list_length' }
    $items = @()
    for ($i = 0; $i -lt $count; $i++) { $items += Read-Text $Reader }
    return ,$items
}

function Read-Vault([string]$Handle) {
    $path = Join-Path $env:ProgramData ('KenaiVPN\profiles\' + $Handle + '.bin')
    $ciphertext = [IO.File]::ReadAllBytes($path)
    try {
        $plaintext = [Security.Cryptography.ProtectedData]::Unprotect(
            $ciphertext, [Text.Encoding]::ASCII.GetBytes('KenaiVPN.ProfileVault.v1'),
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return ,$plaintext
    } finally { [Array]::Clear($ciphertext, 0, $ciphertext.Length) }
}

function Inspect-Vless([string]$Handle) {
    $plain = $null
    try {
        $plain = Read-Vault $Handle
        $stream = [IO.MemoryStream]::new($plain, $false)
        $reader = [IO.BinaryReader]::new($stream)
        try {
            if ([Text.Encoding]::ASCII.GetString((Read-Exact $reader 4)) -ne 'KXP1') {
                throw 'wrong_vless_format'
            }
            $clientId = Read-Text $reader
            $endpoint = Read-Text $reader
            $port = $reader.ReadUInt16()
            $serverName = Read-Text $reader
            $fingerprint = Read-Text $reader
            $realityPublic = Read-Text $reader
            $shortId = Read-OptionalText $reader
            $spiderLength = [int]$reader.ReadUInt16()
            if ($spiderLength -lt 1 -or $spiderLength -gt 4096) { throw 'invalid_spider_length' }
            [void](Read-Exact $reader $spiderLength)
            if ($stream.Position -ne $stream.Length) { throw 'trailing_profile_bytes' }
            return [ordered]@{
                status = 'ok'
                client_id_sha256 = Hash-Text $clientId.ToLowerInvariant()
                endpoint = $endpoint
                port = $port
                server_name = $serverName
                fingerprint = $fingerprint
                reality_public_sha256 = Hash-Text $realityPublic
                short_id_sha256 = Hash-Text $shortId.ToLowerInvariant()
            }
        } finally { $reader.Dispose(); $stream.Dispose() }
    } finally { if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) } }
}

function Inspect-Awg([string]$Handle) {
    $plain = $null
    $private = $null
    $serverPublic = $null
    try {
        $plain = Read-Vault $Handle
        $stream = [IO.MemoryStream]::new($plain, $false)
        $reader = [IO.BinaryReader]::new($stream)
        try {
            if ([Text.Encoding]::ASCII.GetString((Read-Exact $reader 4)) -ne 'KAP1') {
                throw 'wrong_awg_format'
            }
            $private = Read-Exact $reader 32
            $addresses = Read-TextList $reader
            [void](Read-TextList $reader)
            $serverPublic = Read-Exact $reader 32
            switch ($reader.ReadByte()) {
                0 { }
                1 { [void](Read-Exact $reader 32) }
                default { throw 'invalid_preshared_flag' }
            }
            $endpoint = Read-Text $reader
            $port = $reader.ReadUInt16()
            [void](Read-TextList $reader) # AllowedIPs
            switch ($reader.ReadByte()) {
                0 { }
                1 { [void]$reader.ReadUInt16() }
                default { throw 'invalid_keepalive_flag' }
            }
            $jc = $reader.ReadUInt16()
            $jmin = $reader.ReadUInt16()
            $jmax = $reader.ReadUInt16()
            $s = @(1..4 | ForEach-Object { $reader.ReadUInt16() })
            $h = @(1..4 | ForEach-Object { Read-Text $reader })
            $specialCount = [int]$reader.ReadByte()
            if ($specialCount -gt 5) { throw 'invalid_special_count' }
            $script:auditCursor = [ordered]@{
                special_count = $specialCount
                offset = $stream.Position
                total = $stream.Length
                item_index = -1
            }
            $special = @()
            for ($index = 0; $index -lt $specialCount; $index++) {
                $script:auditCursor.item_index = $index
                $script:auditCursor.offset = $stream.Position
                $length = [int]$reader.ReadUInt16()
                $script:auditCursor.item_length = $length
                if ($length -lt 1 -or $length -gt 4096) { throw 'invalid_special_length' }
                $special += [Text.UTF8Encoding]::new($false, $true).GetString(
                    (Read-Exact $reader $length))
            }
            $extendedOptionsPresent = $stream.Position -lt $stream.Length
            if ($extendedOptionsPresent) {
                switch ($reader.ReadByte()) {
                    0 { }
                    1 { [void](Read-Exact $reader 32) }
                    default { throw 'invalid_header_flag' }
                }
                for ($index = 0; $index -lt 6; $index++) {
                    switch ($reader.ReadByte()) {
                        0 { }
                        1 { [void](Read-Text $reader) }
                        default { throw 'invalid_range_flag' }
                    }
                }
                foreach ($flag in @($reader.ReadByte(), $reader.ReadByte())) {
                    if ($flag -gt 2) { throw 'invalid_toggle_flag' }
                }
                if ($stream.Position -lt $stream.Length) {
                    switch ($reader.ReadByte()) {
                        0 { }
                        1 { [void]$reader.ReadUInt16() }
                        default { throw 'invalid_mtu_flag' }
                    }
                }
            }
            if ($stream.Position -ne $stream.Length) { throw 'trailing_profile_bytes' }
            $transport = @()
            $junk = @("jc=$jc", "jmin=$jmin", "jmax=$jmax")
            for ($index = 0; $index -lt 4; $index++) {
                $transport += ('s' + ($index + 1) + '=' + $s[$index])
            }
            for ($index = 0; $index -lt 4; $index++) {
                $transport += ('h' + ($index + 1) + '=' + $h[$index])
            }
            for ($index = 0; $index -lt 5; $index++) {
                $value = if ($index -lt $special.Count) { $special[$index] } else { '' }
                $junk += ('i' + ($index + 1) + '=' + $value)
            }
            $awg = Join-Path $env:ProgramFiles 'Kenai VPN\service\amneziawg\amd64\awg.exe'
            $clientPublic = [string](([Convert]::ToBase64String($private) |
                & $awg pubkey 2>$null) -join '')
            if ($LASTEXITCODE -ne 0 -or $clientPublic -notmatch '^[A-Za-z0-9+/]{43}=$') {
                throw 'client_public_key_unavailable'
            }
            return [ordered]@{
                status = 'ok'
                client_public_sha256 = Hash-Text $clientPublic
                address = @($addresses) -join ','
                endpoint = $endpoint
                port = $port
                server_public_sha256 = Hash-Text ([Convert]::ToBase64String($serverPublic))
                transport_fingerprint = Hash-Text ($transport -join "`n")
                junk_fingerprint = Hash-Text ($junk -join "`n")
                full_profile_parsed = $true
                extended_options_present = $extendedOptionsPresent
            }
        } finally { $reader.Dispose(); $stream.Dispose() }
    } finally {
        foreach ($bytes in @($plain, $private, $serverPublic)) {
            if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
        }
    }
}

if ($Worker) {
    if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        throw 'system_worker_required'
    }
    if (-not $RunId -or -not $VlessHandle -or -not $AwgHandle) {
        throw 'worker_parameters_required'
    }
    $report = [ordered]@{ status = 'unavailable'; stage = 'start' }
    try {
        $report.stage = 'vless'
        $vless = Inspect-Vless $VlessHandle
        $report.stage = 'amneziawg'
        $awg = Inspect-Awg $AwgHandle
        $report = [ordered]@{ status = 'ok'; vless = $vless; amneziawg = $awg }
    } catch {
        $report.error_type = $_.Exception.GetType().Name
        $report.error_line = $_.InvocationInfo.ScriptLineNumber
        if ($null -ne $script:auditCursor) { $report.audit_cursor = $script:auditCursor }
        $inner = $_.Exception
        while ($null -ne $inner.InnerException) { $inner = $inner.InnerException }
        $report.error_inner_type = $inner.GetType().Name
    } finally {
        [void](New-Item -ItemType Directory -Path $reportRoot -Force)
        $path = Join-Path $reportRoot ($RunId + '.json')
        $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path -Encoding UTF8
    }
    return
}

$principal = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'administrator_required'
}
$storagePath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) `
    'Kenai VPN\Kenai VPN\flutter_secure_storage.dat'
$taskName = 'Kenai-Armenia-Profile-Audit-' + [guid]::NewGuid().ToString('N')
$registered = $false
try {
    $userCiphertext = [IO.File]::ReadAllBytes($storagePath)
    $userPlaintext = [Security.Cryptography.ProtectedData]::Unprotect(
        $userCiphertext, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    $storage = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($userPlaintext))
    $vless = [string]$storage.'vpn.vless_profile_handle'
    $awg = [string]$storage.'vpn.amneziawg_profile_handle'
    if ($vless -notmatch '^xray-[a-f0-9]{32}$' -or $awg -notmatch '^awg-[a-f0-9]{32}$') {
        throw 'stored_handles_unavailable'
    }
    $id = [guid]::NewGuid().ToString('N')
    $reportPath = Join-Path $reportRoot ($id + '.json')
    $scriptPath = $MyInvocation.MyCommand.Path
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $scriptPath +
        '" -Worker -RunId ' + $id + ' -VlessHandle ' + $vless + ' -AwgHandle ' + $awg
    $action = New-ScheduledTaskAction -Execute `
        'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' -Argument $arguments
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
    [void](Register-ScheduledTask -TaskName $taskName -Action $action `
        -Settings $settings -User 'SYSTEM' -RunLevel Highest)
    $registered = $true
    Start-ScheduledTask -TaskName $taskName
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $reportPath) {
            Write-Output ('REPORT=' + $reportPath)
            return
        }
        Start-Sleep -Milliseconds 500
    }
    throw 'worker_timeout'
} finally {
    foreach ($bytes in @($userCiphertext, $userPlaintext)) {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    if ($registered) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}
