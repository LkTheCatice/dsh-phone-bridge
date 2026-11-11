# 本地自测：编译并运行 main.swift（连同项目的 MarkdownModel.swift 一起）
#
# 为什么需要它：这台机器是 Windows，没有 Xcode / iOS 模拟器。
# 但今晚两次崩溃（重复 key、NSRange 越界）都在 Foundation 层，
# 这一层在 Windows 上能编译也能跑 —— 所以把验证前移到这里。

$ErrorActionPreference = "Stop"

$swiftRoot = Join-Path $env:LOCALAPPDATA "Programs\Swift"
if (-not (Test-Path $swiftRoot)) {
    Write-Host "✗ 未找到 Swift 工具链（$swiftRoot）" -ForegroundColor Red
    Write-Host "  安装：winget install --id Swift.Toolchain --accept-package-agreements --accept-source-agreements"
    exit 2
}

$toolchain = Get-ChildItem (Join-Path $swiftRoot "Toolchains") -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
$runtime = Get-ChildItem (Join-Path $swiftRoot "Runtimes") -Directory |
    Sort-Object Name -Descending | Select-Object -First 1
if (-not $toolchain -or -not $runtime) {
    Write-Host "✗ Swift 工具链目录不完整" -ForegroundColor Red
    exit 2
}

$swiftBin = Join-Path $toolchain.FullName "usr\bin"
$runtimeBin = Join-Path $runtime.FullName "usr\bin"
$sdk = Get-ChildItem (Join-Path $swiftRoot "Platforms") -Recurse -Directory -Filter "Windows.sdk" |
    Select-Object -First 1
if (-not $sdk) {
    Write-Host "✗ 未找到 Windows.sdk" -ForegroundColor Red
    exit 2
}

$env:Path = "$swiftBin;$runtimeBin;$env:Path"
$env:SDKROOT = $sdk.FullName

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$project = Resolve-Path (Join-Path $here "..\..")
$model = Join-Path $project "ios\DSHRemote\Sources\Core\MarkdownModel.swift"
$media = Join-Path $project "ios\DSHRemote\Sources\Core\MediaRefScan.swift"
$cache = Join-Path $project "ios\DSHRemote\Sources\Core\MarkdownCache.swift"
if (-not (Test-Path $media)) {
    Write-Host "✗ 找不到 $media" -ForegroundColor Red
    exit 2
}
if (-not (Test-Path $model)) {
    Write-Host "✗ 找不到 $model" -ForegroundColor Red
    exit 2
}

Push-Location $here
try {
    $exe = Join-Path $here "selftest.exe"
    if (Test-Path $exe) { Remove-Item $exe -Force }

    Write-Host "编译中（main.swift + Core/*.swift）…" -ForegroundColor DarkGray
    # 两个文件一起编译：测的就是项目里的真实代码
    # swiftc 把普通信息也写到 stderr，这里临时放开 ErrorActionPreference
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & (Join-Path $swiftBin "swiftc.exe") main.swift $model $media $cache -o $exe 2>&1 |
        Where-Object { $_ -notmatch "正在创建库|creating library|never used|#NoUsage" } |
        ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = $prev

    if (-not (Test-Path $exe)) {
        Write-Host "✗ 编译失败" -ForegroundColor Red
        exit 1
    }

    & $exe
    $code = $LASTEXITCODE
    Write-Host ""
    if ($code -eq 0) {
        Write-Host "selftest 通过" -ForegroundColor Green
    } else {
        Write-Host "selftest 失败（退出码 $code）" -ForegroundColor Red
    }
    exit $code
}
finally {
    Pop-Location
}
