# Export stills from shots.json using local Chrome only (no npm / playwright).
# ASCII-only on purpose: Windows PowerShell 5.1 parses .ps1 as ANSI unless it has a BOM.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File export-shots.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File export-shots.ps1 -OutDir D:\material
param(
  [string]$OutDir = (Join-Path $PSScriptRoot "out"),
  [string]$Chrome = "C:\Program Files\Google\Chrome\Application\chrome.exe"
)

$ErrorActionPreference = "Continue"
if (-not (Test-Path $Chrome)) {
  $alt = "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe"
  if (Test-Path $alt) { $Chrome = $alt } else { throw "chrome.exe not found" }
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

$manifestPath = Join-Path $PSScriptRoot "shots.json"
$manifest = Get-Content $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json

$base = "file:///" + ($PSScriptRoot -replace '\\', '/') + "/shots.html"

$count = 0
foreach ($shot in $manifest.shots) {
  if (-not $shot.stills) { continue }
  foreach ($s in $shot.stills) {
    $url = "$base`?shot=$($shot.id)&t=$($s.t)"
    if ($shot.id -eq "11") { $url += "&wide=1" }
    $target = Join-Path $OutDir $s.file
    $chromeArgs = @(
      "--headless=new", "--disable-gpu", "--hide-scrollbars",
      "--window-size=1920,1080", "--screenshot=$target", $url
    )
    Remove-Item $target -ErrorAction SilentlyContinue
    & $Chrome @chromeArgs *> $null
    # Chrome 在进程退出后才把 PNG 落盘，这里轮询等它（最多 5 秒）
    $waited = 0
    while (-not (Test-Path $target) -and $waited -lt 50) {
      Start-Sleep -Milliseconds 100
      $waited++
    }
    if (Test-Path $target) {
      $kb = [math]::Round((Get-Item $target).Length / 1KB)
      Write-Output ("OK   shot {0}  t={1}  ->  {2}  ({3} KB)" -f $shot.id, $s.t, $s.file, $kb)
      $count++
    } else {
      Write-Output ("FAIL shot {0}  t={1}  ->  {2}" -f $shot.id, $s.t, $s.file)
    }
  }
}

Write-Output ""
Write-Output ("done: {0} stills -> {1}" -f $count, $OutDir)
Write-Output "For motion clips: open shots.html?shot=NN&play=1 in a browser and screen-record at 60fps."
