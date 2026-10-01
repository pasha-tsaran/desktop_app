param([Parameter(Mandatory)][string]$VerifiedInstaller)
$ErrorActionPreference = 'Stop'
$expectedRoot = 'C:\Users\tsara\OneDrive\Desktop\Проекты\VPN\установщик'
$root = (Resolve-Path -LiteralPath $expectedRoot).Path.TrimEnd('\')
if ($root -ne $expectedRoot) { throw 'Unexpected installer directory' }
if ((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Installer directory must not be a link'
}
$source = Get-Item -LiteralPath $VerifiedInstaller
if ($source.VersionInfo.ProductVersion -ne '2.1.2') { throw 'Unexpected installer version' }
$hash = (Get-FileHash -LiteralPath $source.FullName).Hash
$destination = Join-Path $root 'KenaiVPN-Setup-2.1.2-UNSIGNED.exe'
Copy-Item -LiteralPath $source.FullName -Destination $destination
if ((Get-FileHash -LiteralPath $destination).Hash -ne $hash) { throw 'Copy verification failed' }
# User explicitly requested removal of all previous installers and their directories.
$obsolete = @(Get-ChildItem -LiteralPath $root -Force | Where-Object FullName -ne $destination)
foreach ($entry in $obsolete) {
    $resolved = (Resolve-Path -LiteralPath $entry.FullName).Path
    if (-not $resolved.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Cleanup target escaped installer directory'
    }
    $members = @($entry)
    if ($entry.PSIsContainer) { $members += @(Get-ChildItem -LiteralPath $resolved -Recurse -Force) }
    foreach ($member in $members) {
        if ($member.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Refusing recursive cleanup across a filesystem link'
        }
    }
}
foreach ($entry in $obsolete) { Remove-Item -LiteralPath $entry.FullName -Recurse -Force }
$remaining = @(Get-ChildItem -LiteralPath $root -Force)
if ($remaining.Count -ne 1 -or $remaining[0].FullName -ne $destination) {
    throw 'Installer directory verification failed'
}
if ((Get-FileHash -LiteralPath $destination).Hash -ne $hash) { throw 'Final checksum mismatch' }
Write-Output "installer=$destination"
Write-Output "sha256=$hash"
Write-Output "remaining_files=1; old_entries_removed=$($obsolete.Count)"
