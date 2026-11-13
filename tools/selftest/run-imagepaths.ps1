# Local selftest for ToolSummary.imagePaths (Foundation only).
# ASCII-only on purpose: Windows PowerShell 5.1 parses .ps1 as ANSI unless it has a BOM.
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Split-Path -Parent (Split-Path -Parent $here)
$src = Join-Path $project 'ios\DSHRemote\Sources\ToolSummary.swift'

$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
$toolchain = Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$runtime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$swiftBin = Join-Path $toolchain.FullName 'usr\bin'

$main = Join-Path $here 'imagepaths\main.swift'
$exe = Join-Path $here 'imagepaths\ip.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }

# swiftc prints linker chatter to stderr; relax so it does not throw
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& (Join-Path $swiftBin 'swiftc.exe') $main $src -o $exe 2>&1 | Out-Null
$code = $LASTEXITCODE
$ErrorActionPreference = $prev

if ($code -ne 0 -or -not (Test-Path $exe)) {
    Write-Host 'compile failed' -ForegroundColor Red
    exit 1
}

$out = & $exe
$out | ForEach-Object { Write-Host $_ }

if ($out -match 'PASS') {
    Write-Host 'imagePaths: OK' -ForegroundColor Green
    exit 0
}

Write-Host 'imagePaths: FAIL' -ForegroundColor Red
exit 1
