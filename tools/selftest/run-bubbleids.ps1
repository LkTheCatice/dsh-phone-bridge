# Run BubbleIds assertions on Windows (no iOS SDK / Xcode needed).
#
# Core/BubbleIds.swift only imports Foundation, so the local Windows Swift
# toolchain can compile and execute it directly. This is the layer we CAN verify
# before spending a macOS build:
#   - bubble id shape (turn + segment) -> steering answers get their own bubble
#   - sameMessage() normalization     -> local placeholder matches server echo
#   - pageSize() clamp                -> enlarging a page cannot bring back jank
#
#   .\run-bubbleids.ps1
#
# NOTE: deliberately not using $ErrorActionPreference='Stop'. Under Stop, the
# linker chatter swiftc writes to stderr becomes a terminating NativeCommandError
# and the probe never runs. Failures are detected via $LASTEXITCODE instead.
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Resolve-Path (Join-Path $here '..\..')

$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs\Swift'
if (-not (Test-Path $swiftRoot)) { throw "Swift toolchain not found: $swiftRoot" }

$toolchain = Get-ChildItem (Join-Path $swiftRoot 'Toolchains') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$runtime = Get-ChildItem (Join-Path $swiftRoot 'Runtimes') -Directory | Sort-Object Name -Descending | Select-Object -First 1
$swiftBin = Join-Path $toolchain.FullName 'usr\bin'
$runtimeBin = Join-Path $runtime.FullName 'usr\bin'
$env:Path = "$swiftBin;$runtimeBin;$env:Path"

if (-not $env:SDKROOT) {
    $sdk = Get-ChildItem (Join-Path $swiftRoot 'Platforms') -Recurse -Directory -Filter 'Windows.sdk' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($sdk) { $env:SDKROOT = $sdk.FullName }
}

$out = Join-Path $here 'bubbleids.exe'
$swiftc = Join-Path $swiftBin 'swiftc.exe'
$swiftArgs = @(
    '-O',
    (Join-Path $here 'bubble\main.swift'),
    (Join-Path $repo 'ios\DSHRemote\Sources\Core\BubbleIds.swift'),
    '-o', $out
)
# swiftc on Windows prints linker chatter ("creating library ...") to stderr;
# keep it out of the verdict, but show it when the compile actually fails.
$compilerLog = & $swiftc @swiftArgs 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    Write-Host $compilerLog
    throw "compile failed (swiftc exit=$LASTEXITCODE)"
}

& $out
exit $LASTEXITCODE
