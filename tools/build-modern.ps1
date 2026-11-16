param(
  [string]$DevEcoHome = $env:DEVECO_STUDIO_HOME,
  [switch]$Release
)

$ErrorActionPreference = 'Stop'
if (-not $DevEcoHome) {
  throw 'Set DEVECO_STUDIO_HOME or pass -DevEcoHome with your DevEco Studio installation directory.'
}
$projectRoot = Split-Path -Parent $PSScriptRoot
$nodePath = Join-Path $DevEcoHome 'tools\node\node.exe'
$hvigorPath = Join-Path $DevEcoHome 'tools\hvigor\bin\hvigorw.js'
$ohpmPath = Join-Path $DevEcoHome 'tools\ohpm\bin\ohpm.bat'
foreach ($requiredPath in @($nodePath, $hvigorPath, $ohpmPath, (Join-Path $DevEcoHome 'sdk\default\sdk-pkg.json'))) {
  if (-not (Test-Path -LiteralPath $requiredPath)) {
    throw "Missing DevEco tool: $requiredPath. Pass -DevEcoHome with your DevEco Studio installation directory."
  }
}
$env:DEVECO_SDK_HOME = Join-Path $DevEcoHome 'sdk'
$env:JAVA_HOME = Join-Path $DevEcoHome 'jbr'
$env:NODE_HOME = Join-Path $DevEcoHome 'tools\node'
$env:PATH = "$env:NODE_HOME;$env:JAVA_HOME\bin;$(Join-Path $DevEcoHome 'tools\ohpm\bin');$env:PATH"
$buildMode = if ($Release) { 'release' } else { 'debug' }
Push-Location $projectRoot
try {
  & $ohpmPath install
  if ($LASTEXITCODE -ne 0) {
    throw "OHPM install failed with exit code $LASTEXITCODE"
  }
  & $nodePath $hvigorPath --mode module -p product=default -p module=entry@default -p "buildMode=$buildMode" assembleHap --no-daemon
  if ($LASTEXITCODE -ne 0) {
    throw "Hvigor build failed with exit code $LASTEXITCODE"
  }
} finally {
  Pop-Location
}
