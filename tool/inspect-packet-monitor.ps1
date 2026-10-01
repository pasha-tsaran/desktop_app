$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$report = Join-Path (Split-Path $PSScriptRoot -Parent) 'local_data\packet-monitor-state.json'
$result = @{}
foreach ($operation in @('status', 'filters', 'components')) {
    switch ($operation) {
        'status' { $lines = @(& "$env:SystemRoot\System32\pktmon.exe" status 2>&1) }
        'filters' { $lines = @(& "$env:SystemRoot\System32\pktmon.exe" filter list 2>&1) }
        'components' { $lines = @(& "$env:SystemRoot\System32\pktmon.exe" list 2>&1) }
    }
    $result[$operation] = @{ exit_code = $LASTEXITCODE; output = ($lines -join "`n") }
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $report -Encoding UTF8
