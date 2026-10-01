[CmdletBinding()]
param([ValidatePattern('^awg-[0-9a-f]{32}$')][string]$ProfileHandle)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Security

$reportPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'local_data\nl-awg-profile-summary.json'
$report = [ordered]@{ status = 'unavailable'; stage = 'initialize' }
$userPlain = $null
$vaultPlain = $null
$privateKey = $null
$presharedKey = $null
$headerKey = $null

function Read-Exact([IO.BinaryReader]$Reader, [int]$Count) {
    $bytes = $Reader.ReadBytes($Count)
    if ($bytes.Length -ne $Count) { throw 'truncated_profile' }
    return ,$bytes
}

function Read-Text([IO.BinaryReader]$Reader) {
    $length = [int]$Reader.ReadByte()
    return [Text.Encoding]::UTF8.GetString((Read-Exact $Reader $length))
}

function Read-TextList([IO.BinaryReader]$Reader) {
    $count = [int]$Reader.ReadByte()
    if ($count -gt 32) { throw 'invalid_list' }
    $values = @()
    for ($index = 0; $index -lt $count; $index++) { $values += Read-Text $Reader }
    return ,$values
}

function Read-OptionalText([IO.BinaryReader]$Reader) {
    switch ($Reader.ReadByte()) {
        0 { return $null }
        1 { return Read-Text $Reader }
        default { throw 'invalid_optional_text' }
    }
}

function Hash-Base64([byte[]]$Bytes) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $encoded = [Text.Encoding]::ASCII.GetBytes([Convert]::ToBase64String($Bytes))
        return ([BitConverter]::ToString($sha.ComputeHash($encoded))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function Hash-Text([string]$Value) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString(
            $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if ($ProfileHandle) {
        if (-not $identity.IsSystem) { throw 'system_worker_required' }
        $handle = $ProfileHandle
    } else {
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'administrator_required'
        }
        $report.stage = 'read_user_handle'
        $storagePath = Join-Path ([Environment]::GetFolderPath('ApplicationData')) `
            'Kenai VPN\Kenai VPN\flutter_secure_storage.dat'
        $encrypted = [IO.File]::ReadAllBytes($storagePath)
        try {
            $userPlain = [Security.Cryptography.ProtectedData]::Unprotect(
                $encrypted, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        } finally { [Array]::Clear($encrypted, 0, $encrypted.Length) }
        $storage = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString($userPlain))
        $handle = [string]$storage.'vpn.amneziawg_profile_handle.netherlands-1'
    }
    if ($handle -notmatch '^awg-[0-9a-f]{32}$') { throw 'invalid_profile_handle' }

    $report.stage = 'read_profile_vault'
    $vaultPath = Join-Path $env:ProgramData ('KenaiVPN\profiles\' + $handle + '.bin')
    $encrypted = [IO.File]::ReadAllBytes($vaultPath)
    $report.stage = 'decrypt_profile_vault'
    try {
        $vaultPlain = [Security.Cryptography.ProtectedData]::Unprotect(
            $encrypted, [Text.Encoding]::ASCII.GetBytes('KenaiVPN.ProfileVault.v1'),
            [Security.Cryptography.DataProtectionScope]::LocalMachine)
    } finally { [Array]::Clear($encrypted, 0, $encrypted.Length) }

    $report.stage = 'parse_profile'
    $stream = [IO.MemoryStream]::new($vaultPlain, $false)
    $reader = [IO.BinaryReader]::new($stream)
    try {
        if ([Text.Encoding]::ASCII.GetString((Read-Exact $reader 4)) -ne 'KAP1') {
            throw 'invalid_profile_format'
        }
        $privateKey = Read-Exact $reader 32
        $addresses = Read-TextList $reader
        [void](Read-TextList $reader) # DNS
        $serverPublic = Read-Exact $reader 32
        switch ($reader.ReadByte()) {
            0 { $presharedKey = $null }
            1 { $presharedKey = Read-Exact $reader 32 }
            default { throw 'invalid_preshared_flag' }
        }
        $endpoint = Read-Text $reader
        $port = $reader.ReadUInt16()
        [void](Read-TextList $reader) # AllowedIPs
        if ($reader.ReadByte() -eq 1) { [void]$reader.ReadUInt16() }
        $jc = $reader.ReadUInt16()
        $jmin = $reader.ReadUInt16()
        $jmax = $reader.ReadUInt16()
        $s = @(1..4 | ForEach-Object { $reader.ReadUInt16() })
        $h = @(1..4 | ForEach-Object { Read-Text $reader })
        $specialCount = [int]$reader.ReadByte()
        if ($specialCount -gt 5) { throw 'invalid_special_count' }
        $specialHashes = @()
        for ($index = 0; $index -lt $specialCount; $index++) {
            $length = [int]$reader.ReadUInt16()
            if ($length -lt 1 -or $length -gt 4096) { throw 'invalid_special_length' }
            $specialHashes += Hash-Text ([Text.Encoding]::UTF8.GetString((Read-Exact $reader $length)))
        }
        switch ($reader.ReadByte()) {
            0 { $headerKey = $null }
            1 { $headerKey = Read-Exact $reader 32 }
            default { throw 'invalid_header_flag' }
        }
        $ranges = @()
        for ($index = 0; $index -lt 6; $index++) { $ranges += Read-OptionalText $reader }
        $randomTrailers = $reader.ReadByte()
        $disableCookies = $reader.ReadByte()
        $mtu = switch ($reader.ReadByte()) {
            0 { $null }
            1 { $reader.ReadUInt16() }
            default { throw 'invalid_mtu_flag' }
        }
        if ($stream.Position -ne $stream.Length) { throw 'trailing_profile_bytes' }

        $headerHash = $null
        $presharedHash = $null
        if ($null -ne $headerKey) { $headerHash = Hash-Base64 $headerKey }
        if ($null -ne $presharedKey) { $presharedHash = Hash-Base64 $presharedKey }
        $awg = Join-Path $env:ProgramFiles 'Kenai VPN\service\amneziawg\amd64\awg.exe'
        $clientPublic = [string](([Convert]::ToBase64String($privateKey) |
            & $awg pubkey 2>$null) -join '')
        if ($LASTEXITCODE -ne 0 -or $clientPublic -notmatch '^[A-Za-z0-9+/]{43}=$') {
            throw 'client_public_key_unavailable'
        }
        $clientPublicHash = Hash-Base64 ([Convert]::FromBase64String($clientPublic))

        $report = [ordered]@{
            status = 'ok'
            address = @($addresses) -join ','
            endpoint = $endpoint
            port = $port
            mtu = $mtu
            jc = $jc
            jmin = $jmin
            jmax = $jmax
            s = $s
            h = $h
            special_junk_count = $specialCount
            special_junk_sha256 = $specialHashes
            ranges = $ranges
            header_protection = $null -ne $headerKey
            random_trailers = $randomTrailers
            disable_cookies = $disableCookies
            server_public_sha256 = Hash-Base64 $serverPublic
            client_public_sha256 = $clientPublicHash
            header_key_sha256 = $headerHash
            preshared_key_sha256 = $presharedHash
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
} catch {
    $failure = $_.Exception
    while ($null -ne $failure.InnerException) { $failure = $failure.InnerException }
    $report = [ordered]@{
        status = 'unavailable'
        stage = $report.stage
        error_type = $failure.GetType().Name
        hresult = $failure.HResult
    }
} finally {
    foreach ($bytes in @($userPlain, $vaultPlain, $privateKey, $presharedKey, $headerKey)) {
        if ($null -ne $bytes) { [Array]::Clear($bytes, 0, $bytes.Length) }
    }
    $directory = Split-Path -Parent $reportPath
    [void](New-Item -ItemType Directory -Path $directory -Force)
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportPath -Encoding UTF8
}
