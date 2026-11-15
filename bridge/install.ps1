<#
  dsh-phone-bridge 安装器

  做的事：
    1. 检查 Node 24+、DSH profile 是否存在
    2. 把插件放进 %USERPROFILE%\.dsh\profiles\<Profile>\node_modules\dsh-phone-bridge
       —— 默认建 junction 链接指向本目录：源码留在原盘，C 盘占用 0 字节
    3. 备份 cordis.patch.yml，追加一条 phone-bridge 配置（幂等）
    4. 打印配对串

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\bridge\install.ps1
    ... -Roots "D:\work\output"                    # 手机允许读写的目录（可多个，逗号分隔）
    ... -LanHost 192.168.1.23                      # 固定局域网 IP（留空=自动探测）
    ... -Port 8899 -Profile web
    ... -StateDir 'D:\dsh-phone-bridge'            # token/密钥放到别的盘
    ... -Link:$false                               # 不建链接，直接复制（跨盘/无权限时用）
#>

param(
  [string]$Profile = "desktop",
  [string]$DshHome = "$env:USERPROFILE\.dsh",
  [string]$LanHost = "",
  [int]$Port = 8765,
  [string]$StateDir = "",
  [string[]]$Roots = @(),
  [bool]$Link = $true
)

$ErrorActionPreference = "Stop"

function Fail($msg) {
  Write-Host ""
  Write-Host "✗ $msg" -ForegroundColor Red
  Write-Host ""
  exit 1
}

$src = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── 0. 前置检查（新机器最常缺的两样） ──────────────────────
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { Fail "没找到 node。先装 Node 24+：winget install OpenJS.NodeJS" }
$nodeVer = (& node -v) 2>$null
if ($nodeVer -notmatch 'v(\d+)' -or [int]$Matches[1] -lt 24) {
  Write-Host "⚠ Node $nodeVer 版本偏低。桥用到 node:zlib 的 zstd（24+），"
  Write-Host "  低版本读不了会话历史，但不影响启动。建议升级：winget upgrade OpenJS.NodeJS"
}

$profileDir = Join-Path $DshHome "profiles\$Profile"
if (-not (Test-Path $profileDir)) {
  $available = @()
  $profilesRoot = Join-Path $DshHome "profiles"
  if (Test-Path $profilesRoot) {
    $available = Get-ChildItem $profilesRoot -Directory | Select-Object -ExpandProperty Name
  }
  $hint = if ($available.Count -gt 0) { "现有 profile：$($available -join ', ')" } else { "没有任何 profile —— 先启动一次 DeepSeek Harness 桌面版" }
  Fail "找不到 profile 目录：$profileDir`n  $hint`n  也可以显式指定：-Profile <名字>"
}

$target = Join-Path $profileDir "node_modules\dsh-phone-bridge"
$stamp = Get-Date -Format "yyyyMMddHHmmss"

# 旧装法（复制目录或链接）先清掉；junction 只删链接本身，不动源码
if (Test-Path $target) {
  $existing = Get-Item $target -Force
  if ($existing.LinkType) {
    [System.IO.Directory]::Delete($target, $false)
    Write-Host "[1/6] 移除旧链接（源码未受影响）"
  } else {
    Remove-Item -Recurse -Force $target
    Write-Host "[1/6] 移除旧的复制目录"
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null

if ($Link) {
  try {
    New-Item -ItemType Junction -Path $target -Target $src -ErrorAction Stop | Out-Null
    Write-Host "[2/6] 建立 junction -> $src（C 盘占用 0 字节）"
  } catch {
    Write-Host "[2/6] 建立链接失败（$($_.Exception.Message)），改为复制" -ForegroundColor Yellow
    $Link = $false
  }
}
if (-not $Link) {
  Copy-Item -Recurse -Force $src $target
  foreach ($skip in @("test", "install.ps1", "uninstall.ps1", "bin", "lib", "node_modules", ".git")) {
    if ($skip -in @("bin", "lib")) { continue }   # bin/lib 是运行时必需的
    $p = Join-Path $target $skip
    if (Test-Path $p) { Remove-Item -Recurse -Force $p -ErrorAction SilentlyContinue }
  }
  Write-Host "[2/6] 已复制插件 -> $target"
}

Write-Host "[3/6] 备份 cordis.patch.yml"
$patch = Join-Path $profileDir "cordis.patch.yml"
if (-not (Test-Path $patch)) { New-Item -ItemType File -Path $patch | Out-Null }
Copy-Item $patch "$patch.before-phone-bridge-$stamp"
Write-Host "       备份：$patch.before-phone-bridge-$stamp"

$text = Get-Content $patch -Raw
if ($text -match "dsh-phone-bridge") {
  Write-Host "[4/6] 配置已存在，跳过写入"
  Write-Host "       （要改 lanHost / roots 请手改 cordis.patch.yml，然后重启 DSH）"
} else {
  Write-Host "[4/6] 追加插件配置"
  $lan = if ($LanHost) { "`"$LanHost`"" } else { '""' }
  $rootLines = ""
  if ($Roots.Count -gt 0) {
    $rootLines = ($Roots | ForEach-Object { "          - '$($_.Trim())'" }) -join "`r`n"
  }
  $stateLine = if ($StateDir) { "        stateDir: '$StateDir'`r`n" } else { "" }
  $block = @"

# 手机遥控端（可运行 bridge\uninstall.ps1 移除）
- insert:
    - id: phone-bridge
      name: dsh-phone-bridge
      config:
        port: $Port
        lanHost: $lan
        askPhone: true
        approvalTimeoutMs: 90000
        requireE2ee: true
$stateLine        roots:
$rootLines
        notify:
          kind: ""
          server: ""
          key: ""
"@
  Add-Content -Path $patch -Value $block -Encoding UTF8
  if ($Roots.Count -eq 0) {
    Write-Host "       ⚠ roots 为空：手机暂时读不到任何文件，改 cordis.patch.yml 里的 roots 后重启" -ForegroundColor Yellow
  }
}

# 配置文件里已经有 stateDir 时沿用它（否则配对串会去 ~/.dsh/phone-bridge 找，永远找不到）
if (-not $StateDir) {
  try {
    $cfg = Get-Content $patch -Raw
    if ($cfg -match "(?m)^\s*stateDir:\s*'([^']+)'") { $StateDir = $Matches[1] }
    elseif ($cfg -match '(?m)^\s*stateDir:\s*"([^"]+)"') { $StateDir = $Matches[1] }
  } catch { }
}
if (-not $StateDir -and (Test-Path (Join-Path $env:USERPROFILE ".dsh\phone-bridge\pair.json"))) {
  $StateDir = Join-Path $env:USERPROFILE ".dsh\phone-bridge"
}
if ($StateDir) { Write-Host "       状态目录：$StateDir" }

# ── 给 DSH 打「提问远程提交」补丁 ────────────────────────────────
# 没有它：手机选的答案没法交给桌面端提交，手机卡片只能看不能答。
# 幂等；DSH 升级后重跑本脚本或 bin\patch-dsh.mjs 即可。
Write-Host "[5/6] 给 DSH 打提问补丁"
$prevEap2 = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$patchOut = (& node (Join-Path $src "bin\patch-dsh.mjs") 2>&1) -join "`n"
$ErrorActionPreference = $prevEap2
if ($patchOut -match "已打过|已打") {
  Write-Host "       ✓ $($patchOut -replace "`n", " / ")" -ForegroundColor Green
} else {
  Write-Host "       ⚠ $patchOut" -ForegroundColor Yellow
  Write-Host "         （DSH 版本可能变了；不影响桥本身，只是手机不能代答提问）" -ForegroundColor Yellow
}

Write-Host "[6/6] 生成配对串"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
if ($StateDir) { $env:DSH_PHONE_BRIDGE_DIR = $StateDir }
$pairing = (& node (Join-Path $src "bin\pairing.mjs") 2>&1 | Select-Object -First 3) -join "`n"
$ErrorActionPreference = $prevEap

Write-Host ""
Write-Host "================ 下一步 ================" -ForegroundColor Cyan
Write-Host "1. 完全退出 DeepSeek Harness（含托盘），重新打开"
Write-Host "2. 首次启动后，日志里应出现："
Write-Host "     [phone-bridge] 监听 127.0.0.1:$Port"
Write-Host "     [phone-bridge] 局域网监听 <你的内网IP>:$Port（自动探测）"
Write-Host "3. 再跑一次本命令（或 node bridge\bin\pairing.mjs）拿配对串："
Write-Host ""
if ($pairing -match 'dshnb://') {
  Write-Host $pairing -ForegroundColor Green
} else {
  Write-Host "  （现在还没有凭据 —— 桥只在 DSH 里运行时生成 pair.json，先完成第 1 步）" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "手机端：先装 IPA（见 README「手机侧」），再粘贴上面的 dshnb:// 串"
Write-Host "========================================="
Write-Host ""
exit 0
