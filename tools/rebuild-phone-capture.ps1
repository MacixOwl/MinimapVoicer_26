param(
  [string]$SdkRoot = 'D:\HarmonyOSsdk\openharmony\9'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$cacheRoot = Join-Path $projectRoot 'build\phone-capture-modern'
$includeRoot = Join-Path $cacheRoot 'include'
$headerPath = Join-Path $includeRoot 'nlohmann\json.hpp'
$headerHash = '9bea4c8066ef4a1c206b2be5a36302f8926f7fdc6087af5d20b417d0cf103ea6'
$nativeRoot = Join-Path $SdkRoot 'native'
$cmakePath = Join-Path $nativeRoot 'build-tools\cmake\bin\cmake.exe'
$ninjaPath = Join-Path $nativeRoot 'build-tools\cmake\bin\ninja.exe'
if (-not (Test-Path -LiteralPath $cmakePath)) { throw "Missing native SDK: $SdkRoot" }
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $headerPath) | Out-Null
if (-not (Test-Path -LiteralPath $headerPath)) {
  Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/nlohmann/json/v3.11.3/single_include/nlohmann/json.hpp' -OutFile $headerPath -TimeoutSec 45
}
if ((Get-FileHash -LiteralPath $headerPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $headerHash) {
  throw 'Pinned nlohmann JSON header checksum mismatch'
}
$adapterRoot = Join-Path $cacheRoot 'adapter'
$toolchainPath = (Join-Path $nativeRoot 'build\cmake\ohos.toolchain.cmake').Replace('\', '/')
& $cmakePath -S (Join-Path $projectRoot 'native\phone_capture') -B $adapterRoot -G Ninja '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_MAKE_PROGRAM=$($ninjaPath.Replace('\', '/'))" "-DCMAKE_TOOLCHAIN_FILE=$toolchainPath" '-DOHOS_ARCH=arm64-v8a' '-DOHOS_STL=c++_shared' "-DJSON_INCLUDE=$($includeRoot.Replace('\', '/'))"
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure the rotation-aware screen capture adapter' }
& $cmakePath --build $adapterRoot -j 4
if ($LASTEXITCODE -ne 0) { throw 'Failed to build the rotation-aware screen capture adapter' }
$libraryPath = Join-Path $projectRoot 'entry\libs\arm64-v8a\libphonecapture.so'
Copy-Item -LiteralPath (Join-Path $adapterRoot 'libphonecapture.so') -Destination $libraryPath -Force
Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256
