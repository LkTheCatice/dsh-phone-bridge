<#
  dsh-phone-bridge 安装器

  做的事：
    1. 把插件放进 %DSH_HOME%\profiles\<Profile>\node_modules\dsh-phone-bridge
       —— 默认建 junction 链接指向本目录：源码留在原盘，C 盘占用 0 字节
    2. 备份 cordis.patch.yml，追加一条 phone-bridge 配置（幂等）
    3. 打印配对串，等你重启 DeepSeek Harness

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    ... -Link:$false                               # 不建链接，直接复制
    ... -StateDir 'D:\dsh-phone-bridge'            # token/密钥也放到别的盘
    ... -LanHost 192.168.1.23                      # 额外监听内网 IP
    ... -Profile web -Port 8899
#>

param(
  [string]$Profile = "desktop",
  [string]$DshHome = "$env:USERPROFILE\.dsh",
  [string]$LanHost = "",
  [int]$Port = 8765,
  [string]$StateDir = "",
  [bool]$Link = $true
)

$ErrorActionPreference = "Stop"

$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$profileDir = Join-Path $DshHome "profiles\$Profile"
if (-not (Test-Path $profileDir)) {
  throw "找不到 profile 目录：$profileDir（先用 dsh 启动一次这个 profile）"
}

$target = Join-Path $profileDir "node_modules\dsh-phone-bridge"
$stamp = Get-Date -Format "yyyyMMddHHmmss"

# 旧装法（复制目录或链接）先清掉；junction 只删链接本身，不动源码
if (Test-Path $target) {
  $existing = Get-Item $target -Force
  if ($existing.LinkType) {
    [System.IO.Directory]::Delete($target, $false)
    Write-Host "[0/4] 移除旧链接（源码未受影响）"
  } else {
    Remove-Item -Recurse -Force $target
    Write-Host "[0/4] 移除旧的复制目录"
  }
}

New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null

if ($Link) {
  Write-Host "[1/4] 建立 junction -> $src"
  New-Item -ItemType Junction -Path $target -Target $src | Out-Null
  Write-Host "       C 盘占用：0 字节（只是链接）"
} else {
  Write-Host "[1/4] 复制插件 -> $target"
  Copy-Item -Recurse -Force $src $target
  foreach ($skip in @("test", "install.ps1", "uninstall.ps1", ".git")) {
    $p = Join-Path $target $skip
    if (Test-Path $p) { Remove-Item -Recurse -Force $p }
  }
}

Write-Host "[2/4] 备份 cordis.patch.yml"
$patch = Join-Path $profileDir "cordis.patch.yml"
if (-not (Test-Path $patch)) { New-Item -ItemType File -Path $patch | Out-Null }
Copy-Item $patch "$patch.before-phone-bridge-$stamp"
Write-Host "       备份：$patch.before-phone-bridge-$stamp"

$text = Get-Content $patch -Raw
if ($text -match "dsh-phone-bridge") {
  Write-Host "[3/4] 配置已存在，跳过写入（改配置请手改 cordis.patch.yml）"
} else {
  Write-Host "[3/4] 追加插件配置"
  $lan = if ($LanHost) { "`"$LanHost`"" } else { '""' }
  $block = @"

# 手机遥控端（可运行 uninstall.ps1 移除）
- insert:
    - id: phone-bridge
      name: dsh-phone-bridge
      config:
        port: $Port
        lanHost: $lan
        askPhone: true
        approvalTimeoutMs: 90000
        requireE2ee: true
        roots: []
        notify:
          kind: ""
          server: ""
          key: ""
"@
  if ($StateDir) {
    $block = $block -replace "(?m)^        roots: \[\]", "        stateDir: '$StateDir'`r`n        roots: []"
  }
  Add-Content -Path $patch -Value $block -Encoding UTF8
}

Write-Host "[4/4] 生成配对凭据"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$env:DSH_PHONE_BRIDGE_DIR = if ($StateDir) { $StateDir } else { "" }
$pairing = (& node (Join-Path $src "bin\pairing.mjs") 2>$null | Select-Object -First 1)
$ErrorActionPreference = $prevEap

Write-Host ""
Write-Host "================ 下一步 ================"
Write-Host "1. 完全退出 DeepSeek Harness（托盘也退），重新打开"
Write-Host "2. 启动后在日志里看到 [phone-bridge] 监听 127.0.0.1:$Port 即成功"
Write-Host "3. 拿这条串去手机 App 里粘贴配对："
Write-Host ""
Write-Host $pairing
Write-Host ""
Write-Host "外网访问（推荐）：tailscale serve --bg --https=443 $Port"
Write-Host "  之后手机连 https://<机器名>.<tailnet>.ts.net"
Write-Host "========================================="
