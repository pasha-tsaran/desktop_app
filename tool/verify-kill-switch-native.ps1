$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repo
$test = Join-Path $repo 'target\debug\deps\kenai_windows_vpn_service-d2387f625cfbe524.exe'
$log = Join-Path $repo 'build\kill-switch-native-result.log'
# The test NEVER commits its WFP transaction, so current traffic is unaffected.
& $test --exact windows_service_host::kill_switch::tests::native_policy_validates_without_changing_traffic --ignored --nocapture *> $log
exit $LASTEXITCODE
