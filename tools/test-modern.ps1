param(
  [string]$DevEcoHome = $env:DEVECO_STUDIO_HOME
)

$ErrorActionPreference = 'Stop'
if (-not $DevEcoHome) {
  throw 'Set DEVECO_STUDIO_HOME or pass -DevEcoHome with your DevEco Studio installation directory.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$nodePath = Join-Path $DevEcoHome 'tools\node\node.exe'
$env:NODE_PATH = Join-Path $DevEcoHome 'sdk\default\openharmony\ets\build-tools\ets-loader\node_modules'
if (-not (Test-Path -LiteralPath $nodePath)) {
  throw "Missing bundled Node: $nodePath"
}
$testNames = @(
  'test_broadcast_policy.cjs',
  'test_capture_feedback.cjs',
  'test_capture_interval.cjs',
  'test_minimap_tracker.cjs',
  'test_minimap_crop.cjs',
  'test_cloud_timing.cjs',
  'test_model_storage.cjs',
  'test_page_lifecycle.cjs',
  'test_local_voice.cjs',
  'test_battle_briefing.cjs',
  'test_rockchip_flow.cjs',
  'test_cloud_battle.cjs'
  'test_cloud_capture.cjs'
)
foreach ($testName in $testNames) {
  & $nodePath (Join-Path $projectRoot "tests\$testName")
  if ($LASTEXITCODE -ne 0) {
    throw "Test failed: $testName"
  }
}
