<#
  DSH Helm 环境预检（preflight）

  用途：在新机器上装之前先跑一遍，把"装到一半才发现缺东西"提前暴露。
  只读，不修改任何东西。

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\preflight.ps1
#>

$ErrorActionPreference = "Continue"
$ok = 0
$warn = 0
$fail = 0

function Line($status, $name, $detail) {
  $color = switch ($status) {
    "OK"   { "Green" }
    "WARN" { "Yellow" }
    "FAIL" { "Red" }
    default { "Gray" }
  }
  Write-Host ("{0,-5} {1,-28} {2}" -f $status, $name, $detail) -ForegroundColor $color
  switch ($status) {
    "OK"   { $script:ok++ }
    "WARN" { $script:warn++ }
    "FAIL" { $script:fail++ }
  }
}

Write-Host ""
Write-Host "DSH Helm · 环境预检" -ForegroundColor Cyan
Write-Host ("=" * 60)

# ── 1. 系统 ─────────────────────────────────────────────
$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
if ($os) {
  Line "OK" "Windows" "$($os.Caption) build $($os.BuildNumber)"
} else {
  Line "FAIL" "Windows" "无法读取系统信息（是否在非 Windows 上运行？）"
}

$psv = $PSVersionTable.PSVersion
if ($psv.Major -ge 5) { Line "OK" "PowerShell" $psv.ToString() } else { Line "WARN" "PowerShell" "$psv（建议 5.1+）" }

# ── 2. Node ────────────────────────────────────────────
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) {
  Line "FAIL" "Node.js" "未安装。装 Node 24+：winget install OpenJS.NodeJS"
} else {
  $nodeVer = (& node -v) 2>$null
  $major = 0
  if ($nodeVer -match 'v(\d+)') { $major = [int]$Matches[1] }
  if ($major -ge 24) {
    Line "OK" "Node.js" "$nodeVer"
  } elseif ($major -ge 20) {
    Line "WARN" "Node.js" "$nodeVer（桥用到 node:zlib 的 zstd，需要 24+；旧版读不了会话日志）"
  } else {
    Line "FAIL" "Node.js" "$nodeVer（需要 24+）"
  }
}

# ── 3. DeepSeek Harness ────────────────────────────────
$dshHome = Join-Path $env:USERPROFILE ".dsh"
if (Test-Path $dshHome) {
  Line "OK" "DSH 家目录" $dshHome
} else {
  Line "FAIL" "DSH 家目录" "没找到 $dshHome —— 先启动一次 DeepSeek Harness"
}

$profiles = @()
if (Test-Path (Join-Path $dshHome "profiles")) {
  $profiles = Get-ChildItem (Join-Path $dshHome "profiles") -Directory | Select-Object -ExpandProperty Name
}
if ($profiles.Count -gt 0) {
  Line "OK" "DSH profile" ($profiles -join ", ")
} else {
  Line "FAIL" "DSH profile" "没有 profile 目录，插件无处可装"
}

$nm = Join-Path $dshHome "profiles\desktop\node_modules"
if (Test-Path $nm) {
  Line "OK" "DSH 插件目录" $nm
} else {
  Line "WARN" "DSH 插件目录" "不存在（首次安装时会自动创建）"
}

# ── 4. 端口 ────────────────────────────────────────────
$port = 8765
$inUse = $false
try {
  $conn = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
  if ($conn) { $inUse = $true }
} catch { }
if ($inUse) {
  Line "WARN" "端口 $port" "已被占用 —— 若是上次的桥在跑，属于正常；否则改 config.port"
} else {
  Line "OK" "端口 $port" "空闲"
}

# ── 5. 网络 ────────────────────────────────────────────
$ips = @()
try {
  $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
    Select-Object -ExpandProperty IPAddress
} catch { }
if ($ips.Count -gt 0) {
  Line "OK" "局域网 IPv4" ($ips -join ", ")
} else {
  Line "WARN" "局域网 IPv4" "没探测到（只有本机可用，手机连不上）"
}

# ── 6. 可选：Swift（跑本地自测用） ─────────────────────
$swift = Get-Command swiftc -ErrorAction SilentlyContinue
$swiftLocal = Join-Path $env:LOCALAPPDATA "Programs\Swift"
if ($swift) {
  Line "OK" "Swift 工具链" "PATH 里可用"
} elseif (Test-Path $swiftLocal) {
  Line "OK" "Swift 工具链" $swiftLocal
} else {
  Line "WARN" "Swift 工具链" "未安装（可选；只影响 tools\selftest，不影响桥和 App）"
}

# ── 7. 可选：构建工具 ──────────────────────────────────
foreach ($tool in @(@("git", "git"), @("xcodegen", "xcodegen"), @("icacls", "icacls"))) {
  $cmd = Get-Command $tool[0] -ErrorAction SilentlyContinue
  if ($cmd) { Line "OK" $tool[1] "" } else { Line "WARN" $tool[1] "未找到（$($tool[0])）" }
}

# ── 8. 仓库状态 ────────────────────────────────────────
$repo = Split-Path -Parent $PSScriptRoot
if (Test-Path (Join-Path $repo ".git")) {
  Line "OK" "仓库" $repo
  $secret = Join-Path $repo "pair.json"
  if (Test-Path $secret) { Line "FAIL" "pair.json 在仓库里" "绝不能提交，删掉并检查 .gitignore" }
} else {
  Line "WARN" "仓库" "不在 git 仓库里（跳过检查）"
}

Write-Host ("=" * 60)
Write-Host ("通过 $ok · 提醒 $warn · 阻塞 $fail") -ForegroundColor Cyan
if ($fail -gt 0) {
  Write-Host "有阻塞项，先按上面提示修好再安装。" -ForegroundColor Red
  exit 1
}
Write-Host "可以安装了：powershell -ExecutionPolicy Bypass -File .\install.ps1" -ForegroundColor Green
exit 0
