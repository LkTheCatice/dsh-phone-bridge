# 从 Codemagic 下载最新构建的 IPA，核对版本后放进 dist/
#
# 用法：
#   1) 生成 token：Codemagic → Settings → Integrations → Codemagic API → Show token
#   2) 二选一存放：
#        - 环境变量 CODEMAGIC_TOKEN
#        - 文件 %USERPROFILE%\.codemagic-token（纯文本一行，别提交到 git）
#   3) 跑：.\tools\fetch-ipa.ps1
#
# 为什么需要它：Codemagic 的产物在它自己的 Artifacts 里，
# gh 管不到；GitHub Actions 的免费 macOS 额度已用尽（2026-11-12），
# 所以构建和取包都改走这条链路。

param(
    [string]$Repo = "",
    [switch]$Latest   # 取最近一次构建（不论成功失败）；默认只取成功的
)

$ErrorActionPreference = "Stop"

# 仓库名：没显式传就用当前 git remote（换 fork / 换账号都不用改脚本）
if (-not $Repo) {
  try {
    $url = (& git remote get-url origin) 2>$null
    if ($url -match 'github\.com[:/](.+?)(\.git)?$') { $Repo = $Matches[1] }
  } catch { }
}
if (-not $Repo) {
  Write-Host "✗ 拿不到仓库名（不是 git 仓库？）请显式传 -Repo owner/name" -ForegroundColor Red
  exit 1
}
$base = "https://api.codemagic.io"

# ---- token ----
$token = $env:CODEMAGIC_TOKEN
if (-not $token) {
    $f = Join-Path $env:USERPROFILE ".codemagic-token"
    if (Test-Path $f) { $token = (Get-Content $f -Raw).Trim() }
}
if (-not $token) {
    Write-Host "✗ 没有找到 token。生成方式：Codemagic → Settings → Integrations → Codemagic API → Show token" -ForegroundColor Red
    Write-Host "  存到环境变量 CODEMAGIC_TOKEN，或写进 $env:USERPROFILE\.codemagic-token"
    exit 2
}
$headers = @{ "x-auth-token" = $token }

function Get-Json($path) {
    $uri = if ($path.StartsWith("http")) { $path } else { "$base$path" }
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Get
}

# ---- 找 app ----
Write-Host "查应用列表…" -ForegroundColor DarkGray
$apps = Get-Json "/apps"
$appList = if ($apps.applications) { $apps.applications } else { $apps }
$app = $appList | Where-Object { $_.repository.htmlUrl -like "*$Repo*" -or $_.appName -like "*dsh*" } | Select-Object -First 1
if (-not $app) {
    Write-Host "✗ 在 Codemagic 里找不到 $Repo 对应的应用。先在 codemagic.io 添加这个仓库。" -ForegroundColor Red
    exit 3
}
Write-Host ("  应用: {0}  (id={1})" -f $app.appName, $app._id) -ForegroundColor DarkGray

# ---- 找最新构建 ----
Write-Host "查构建记录…" -ForegroundColor DarkGray
$builds = Get-Json "/builds?appId=$($app._id)&limit=10"
$list = if ($builds.builds) { $builds.builds } else { $builds }
if (-not $Latest) {
    $list = $list | Where-Object { $_.status -eq "finished" -and $_.buildStatus -ne "failed" }
}
$build = $list | Select-Object -First 1
if (-not $build) {
    Write-Host "✗ 没有可用的构建（可能还在跑，或者都失败了）。加 -Latest 可看最近一次。" -ForegroundColor Red
    exit 4
}
Write-Host ("  构建: {0}  {1}  {2}" -f $build._id, $build.status, $build.buildStatus) -ForegroundColor DarkGray

# ---- 找 artifact ----
$artifacts = $build.artifacts
if (-not $artifacts) {
    Write-Host "✗ 这次构建没有 artifact（构建可能失败）。" -ForegroundColor Red
    Write-Host "  失败时先看日志：$base/builds/$($build._id)"
    exit 5
}
$ipa = $artifacts | Where-Object { $_.name -like "*.ipa" } | Select-Object -First 1
if (-not $ipa) {
    Write-Host "✗ artifact 里没有 .ipa：" -ForegroundColor Red
    $artifacts | ForEach-Object { Write-Host "    $($_.name)" }
    exit 6
}

# ---- 下载 ----
$dist = Join-Path (Split-Path -Parent $PSScriptRoot) "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null
$tmp = Join-Path $dist "_cm.ipa"
Write-Host ("下载 {0} …" -f $ipa.name) -ForegroundColor DarkGray
Invoke-WebRequest -Uri "$base/artifacts/$($ipa._id)" -Headers $headers -OutFile $tmp

# ---- 核对版本 ----
$py = "C:\Users\acer\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe"
$env:PYTHONIOENCODING = "utf-8"
$code = @"
import zipfile, plistlib, sys
p = r'''$tmp'''
z = zipfile.ZipFile(p)
pl = plistlib.loads(z.read([x for x in z.namelist() if x.endswith('Info.plist')][0]))
print(pl.get('CFBundleShortVersionString'), pl.get('CFBundleVersion'))
"@
$info = & $py -c $code
$ver, $build_no = ($info -split " ")

$archived = Join-Path $dist "archive"
New-Item -ItemType Directory -Force -Path $archived | Out-Null
$old = Join-Path $dist "DSHRemote-unsigned.ipa"
if (Test-Path $old) {
    Move-Item $old (Join-Path $archived ("DSHRemote-{0}.{1}.ipa" -f $ver, $build_no)) -Force -ErrorAction SilentlyContinue
}
Move-Item $tmp $old -Force

Write-Host ("✓ 已就位: {0}.{1}  →  {2}" -f $ver, $build_no, $old) -ForegroundColor Green
