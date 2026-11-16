param(
  [string]$CacheRoot = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$projectRoot = Split-Path -Parent $PSScriptRoot
if (-not $CacheRoot) { $CacheRoot = Join-Path $projectRoot 'build\phone-tts-modern' }
New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
$downloads = @(
  @('tts-models', 'matcha-icefall-zh-baker.tar.bz2', 75455267,
    'ae70096b19c6e283ea351a26b8a718ce6427c8bde8c1da22eb46a5478d39a69b'),
  @('vocoder-models', 'vocos-22khz-univ.onnx', 53884024,
    '0574a135aa1db2de6e181050db2ec528496cacd4a4701fc5d7faf9f9804c0081')
)
foreach ($download in $downloads) {
  $archivePath = Join-Path $CacheRoot $download[1]
  if (-not (Test-Path -LiteralPath $archivePath)) {
    $partialPath = "$archivePath.part"
    Invoke-WebRequest -UseBasicParsing -Uri ('https://github.com/k2-fsa/sherpa-onnx/releases/download/' +
      $download[0] + '/' + $download[1]) -OutFile $partialPath -TimeoutSec 300
    if ((Get-Item -LiteralPath $partialPath).Length -ne $download[2] -or
        (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $download[3]) {
      throw 'Downloaded TTS asset checksum mismatch'
    }
    Move-Item -LiteralPath $partialPath -Destination $archivePath -Force
  }
  if ((Get-Item -LiteralPath $archivePath).Length -ne $download[2] -or
      (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $download[3]) {
    throw "Pinned TTS asset checksum mismatch: $($download[1])"
  }
}
& tar.exe -xf (Join-Path $CacheRoot 'matcha-icefall-zh-baker.tar.bz2') -C $CacheRoot
if ($LASTEXITCODE -ne 0) { throw 'Failed to extract Matcha model' }
$modelRoot = Join-Path $CacheRoot 'matcha-icefall-zh-baker'
$destination = Join-Path $projectRoot 'entry\src\main\resources\rawfile\local-tts'
New-Item -ItemType Directory -Path $destination -Force | Out-Null
$sources = [ordered]@{
  'model.onnx' = (Join-Path $modelRoot 'model-steps-3.onnx')
  'vocoder.onnx' = (Join-Path $CacheRoot 'vocos-22khz-univ.onnx')
  'tokens.txt' = (Join-Path $modelRoot 'tokens.txt')
  'lexicon.txt' = (Join-Path $modelRoot 'lexicon.txt')
  'phone.fst' = (Join-Path $modelRoot 'phone.fst')
  'date.fst' = (Join-Path $modelRoot 'date.fst')
  'number.fst' = (Join-Path $modelRoot 'number.fst')
}
$files = @()
foreach ($filename in $sources.Keys) {
  Copy-Item -LiteralPath $sources[$filename] -Destination (Join-Path $destination $filename) -Force
  $files += [pscustomobject][ordered]@{ filename = $filename; size = (Get-Item -LiteralPath $sources[$filename]).Length;
    sha256 = (Get-FileHash -LiteralPath $sources[$filename] -Algorithm SHA256).Hash.ToLowerInvariant() }
}
$obsoleteRule = Join-Path $destination 'new_heteronym.fst'
if (Test-Path -LiteralPath $obsoleteRule) { Remove-Item -LiteralPath $obsoleteRule }
$manifest = [ordered]@{
  id = 'matcha-icefall-zh-baker'; runtime = 'sherpa-onnx 1.12.39'; speaker = 0; threads = 2;
  speed = 1.08; supported_speeds = @(1.0, 1.08, 1.18); sample_rate = 22050;
  noise_scale = 1.0; silence_scale = 1.0; comma_pause_ms = 140; sentence_pause_ms = 220;
  model_license = 'DataBaker dataset: non-commercial use only; see licenses/Matcha-Baker-NOTICE.txt';
  files = $files; total_bytes = ($files | Measure-Object -Property size -Sum).Sum
}
$manifestPath = Join-Path $projectRoot 'entry\src\main\resources\rawfile\local-tts.json'
[System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 6) + "`n",
  (New-Object System.Text.UTF8Encoding($false)))
Write-Output "Prepared Matcha/Vocos: $($files.Count) verified assets, $($manifest.total_bytes) bytes"
