# 卸载 dsh-phone-bridge：删插件（链接或目录）+ 从 cordis.patch.yml 移除配置块

param(
  [string]$Profile = "desktop",
  [string]$DshHome = "$env:USERPROFILE\.dsh"
)

$ErrorActionPreference = "Stop"

$profileDir = Join-Path $DshHome "profiles\$Profile"
$target = Join-Path $profileDir "node_modules\dsh-phone-bridge"
$patch = Join-Path $profileDir "cordis.patch.yml"

if (Test-Path $target) {
  $item = Get-Item $target -Force
  if ($item.LinkType) {
    # junction / symlink：只删链接本身，源码目录必须原样保留
    [System.IO.Directory]::Delete($target, $false)
    Write-Host "已移除链接: $target（源码未动）"
  } else {
    Remove-Item -Recurse -Force $target
    Write-Host "已删除目录: $target"
  }
}

if (Test-Path $patch) {
  $stamp = Get-Date -Format "yyyyMMddHHmmss"
  Copy-Item $patch "$patch.before-phone-bridge-remove-$stamp"
  $lines = Get-Content $patch
  $out = New-Object System.Collections.Generic.List[string]
  $skipping = $false
  foreach ($line in $lines) {
    if ($line -match "^\s*#\s*手机遥控端") { $skipping = $true; continue }
    if ($skipping) {
      if ($line -match "^\s*- insert:") { continue }
      if ($line -match "^\s+- id: phone-bridge") { continue }
      if ($line -match "^\s+name: dsh-phone-bridge") { continue }
      if ($line -match "^\s+config:") { continue }
      if ($line -match "^\s{8,}") { continue }
      $skipping = $false
    }
    $out.Add($line)
  }
  Set-Content -Path $patch -Value $out -Encoding UTF8
  Write-Host "已从 cordis.patch.yml 移除配置（备份后缀 before-phone-bridge-remove-$stamp）"
}

Write-Host ""
Write-Host "配对凭据没有自动删除，位置看 cordis.patch.yml 里的 stateDir："
Write-Host "  默认: $DshHome\phone-bridge"
Write-Host "本机实际: D:\Documents\deepseek-harness\dsh-phone-bridge"
Write-Host "确认不需要后手动删该目录即可。"
Write-Host "别忘了重启 DeepSeek Harness。"
