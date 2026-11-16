param(
  [string]$SdkRoot = 'D:\HarmonyOSsdk\openharmony\9'
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$cacheRoot = Join-Path $projectRoot 'build\phone-tts-modern'
$nativeRoot = Join-Path $SdkRoot 'native'
$llvmRoot = Join-Path $nativeRoot 'llvm\bin'
$cmakePath = Join-Path $nativeRoot 'build-tools\cmake\bin\cmake.exe'
$ninjaPath = Join-Path $nativeRoot 'build-tools\cmake\bin\ninja.exe'
$archivePath = Join-Path $cacheRoot 'sherpa-onnx-v1.12.39-ohos-arm64-v8a.tar.bz2'
$archiveHash = '554f96468c365e4e15d0270fcd5a31ac38648db713c62faf38fa94e1a79e719b'
$dependencyRoot = Join-Path $cacheRoot 'sherpa-onnx-v1.12.39-ohos-arm64-v8a'
$adapterRoot = Join-Path $cacheRoot 'adapter'
$tlsRoot = Join-Path $cacheRoot 'tls'
foreach ($requiredPath in @($cmakePath, $ninjaPath, (Join-Path $llvmRoot 'llvm-ar.exe'))) {
  if (-not (Test-Path -LiteralPath $requiredPath)) { throw "Missing native build tool: $requiredPath" }
}
New-Item -ItemType Directory -Path $cacheRoot, $tlsRoot -Force | Out-Null
if (-not (Test-Path -LiteralPath $archivePath)) {
  Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.39/sherpa-onnx-v1.12.39-ohos-arm64-v8a.tar.bz2' -OutFile $archivePath -TimeoutSec 60
}
if ((Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $archiveHash) {
  throw 'Pinned sherpa-onnx archive checksum mismatch'
}
if (-not (Test-Path -LiteralPath (Join-Path $dependencyRoot 'include\sherpa-onnx\c-api\c-api.h'))) {
  & tar.exe -xf $archivePath -C $cacheRoot
  if ($LASTEXITCODE -ne 0) { throw 'Failed to extract pinned sherpa-onnx archive' }
}
$compilerArchive = Get-ChildItem -LiteralPath (Join-Path $nativeRoot 'llvm\lib\clang') -Directory |
  ForEach-Object { Join-Path $_.FullName 'lib\aarch64-linux-ohos\libclang_rt.builtins.a' } |
  Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $compilerArchive) { throw 'Compiler TLS runtime archive is missing' }
Push-Location $tlsRoot
try {
  & (Join-Path $llvmRoot 'llvm-ar.exe') x $compilerArchive emutls.c.o
  if ($LASTEXITCODE -ne 0) { throw 'Failed to extract compiler TLS implementation' }
  & (Join-Path $llvmRoot 'llvm-objcopy.exe') '--redefine-sym=__emutls_get_address=GameVoicePrivateEmutls' 'emutls.c.o' 'emutls-private.o'
  if ($LASTEXITCODE -ne 0) { throw 'Failed to prepare private TLS implementation' }
} finally { Pop-Location }
$toolchainPath = (Join-Path $nativeRoot 'build\cmake\ohos.toolchain.cmake').Replace('\', '/')
$tlsObjectPath = (Join-Path $tlsRoot 'emutls-private.o').Replace('\', '/')
$dependencyCmakePath = $dependencyRoot.Replace('\', '/')
$ninjaCmakePath = $ninjaPath.Replace('\', '/')
& $cmakePath -S (Join-Path $projectRoot 'native\phone_tts') -B $adapterRoot -G Ninja '-DCMAKE_BUILD_TYPE=Release' "-DCMAKE_MAKE_PROGRAM=$ninjaCmakePath" "-DCMAKE_TOOLCHAIN_FILE=$toolchainPath" '-DOHOS_ARCH=arm64-v8a' '-DOHOS_STL=c++_shared' "-DSHERPA_ROOT=$dependencyCmakePath" "-DTLS_OBJECT=$tlsObjectPath"
if ($LASTEXITCODE -ne 0) { throw 'Failed to configure native TTS adapter' }
& $cmakePath --build $adapterRoot -j 4
if ($LASTEXITCODE -ne 0) { throw 'Failed to build native TTS adapter' }
$libraryPath = Join-Path $projectRoot 'entry\libs\arm64-v8a\libphonetts.so'
Copy-Item -LiteralPath (Join-Path $adapterRoot 'libphonetts.so') -Destination $libraryPath -Force
Get-FileHash -LiteralPath $libraryPath -Algorithm SHA256
