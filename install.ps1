<#
  DSH Helm 一键安装（仓库根目录入口）

  给从 GitHub 拿到项目的人用：
    git clone https://github.com/<you>/dsh-phone-bridge
    cd dsh-phone-bridge
    powershell -ExecutionPolicy Bypass -File .\install.ps1

  可以先跑预检看环境缺什么：
    powershell -ExecutionPolicy Bypass -File .\tools\preflight.ps1

  参数会原样透传给 bridge\install.ps1（-Roots / -LanHost / -Port / -Profile ...）
#>

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$inner = Join-Path $here "bridge\install.ps1"

if (-not (Test-Path $inner)) {
  Write-Host "✗ 找不到 bridge\install.ps1 —— 请在仓库根目录执行本脚本" -ForegroundColor Red
  exit 1
}

Write-Host ""
Write-Host "DSH Helm 安装器" -ForegroundColor Cyan
Write-Host "仓库：$here"
Write-Host ""

# 环境预检（不阻塞，只提示）
$preflight = Join-Path $here "tools\preflight.ps1"
if (Test-Path $preflight) {
  & powershell -NoProfile -ExecutionPolicy Bypass -File $preflight
  if ($LASTEXITCODE -ne 0) {
    Write-Host "预检有阻塞项，先修好再装。" -ForegroundColor Red
    exit $LASTEXITCODE
  }
  Write-Host ""
}

& powershell -NoProfile -ExecutionPolicy Bypass -File $inner @args
