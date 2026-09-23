<#
  build-exe.ps1 —— 用 Windows 自带的 csc.exe 把脚本打包成 dist\net-switch.exe

  不需要安装任何东西（不用 ps2exe、不联网）：
    · 编译器 = %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe（Windows 自带）
    · 两个 .ps1 作为内嵌资源打进 exe
    · 目标类型 exe（控制台子系统）：终端里运行会有输出/退出码/会等待；
  · 启动器自己检测"控制台是不是我创建的"，是（计划任务/双击）就立刻隐藏窗口
      在命令行/PowerShell 里运行时挂到父控制台，输出照常可见

  用法： powershell -ExecutionPolicy Bypass -File build\build-exe.ps1
  产物： dist\net-switch.exe（约 20 KB，依赖 Windows 自带的 PowerShell 5.1）
#>
[CmdletBinding()]
param(
  [string]$OutDir = '',
  [switch]$KeepBuildDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot          # 仓库根目录（脚本在 build\ 下）
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
  $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
  throw "找不到 csc.exe（需要 Windows 自带的 .NET Framework 4.x 编译器）"
}

$srcFiles = @()
foreach ($n in @('net-switch.ps1', 'campus-login.ps1')) {
  $p = Join-Path $root $n
  if (-not (Test-Path -LiteralPath $p)) { throw "缺少源文件: $p" }
  # 关键：内嵌的脚本必须保持 UTF-8 with BOM，否则 PowerShell 5.1 会按 ANSI 读成乱码
  $bytes = [IO.File]::ReadAllBytes($p)
  if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    throw "$n 不是 UTF-8 with BOM，先修正再打包（PowerShell 5.1 读中文必需）"
  }
  $srcFiles += $p
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$exe = Join-Path $OutDir 'net-switch.exe'

$cscArgs = @(
  '/nologo', '/target:exe', '/optimize+', '/platform:anycpu',
  "/out:$exe",
  "/resource:$($srcFiles[0]),net-switch.ps1",
  "/resource:$($srcFiles[1]),campus-login.ps1",
  (Join-Path $PSScriptRoot 'Launcher.cs')
)

Write-Host "编译器: $csc"
Write-Host "内嵌资源: $(($srcFiles | ForEach-Object { Split-Path -Leaf $_ }) -join ', ')"
Write-Host "输出: $exe"
$out = & $csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) { $out | ForEach-Object { Write-Host $_ }; throw "编译失败（退出码 $LASTEXITCODE）" }
$out | Where-Object { $_ -notmatch 'warning' } | ForEach-Object { Write-Host $_ }

# 再在仓库根目录放一份：计划任务指向它，日志/状态才会落在根目录（而不是 dist\ 下被拆开）
$rootExe = Join-Path (Split-Path -Parent $PSScriptRoot) 'net-switch.exe'
Copy-Item -LiteralPath $exe -Destination $rootExe -Force

$fi = Get-Item -LiteralPath $exe
$ri = Get-Item -LiteralPath $rootExe
Write-Host ("`n编译成功: {0}  ({1:N0} KB, {2})" -f $fi.Name, ($fi.Length / 1KB), $fi.LastWriteTime)
Write-Host ("本机运行副本: {0}  ({1:N0} KB)  ← 计划任务用这份，日志/状态与脚本版共用根目录" -f $ri.FullName, ($ri.Length / 1KB))
Write-Host "验证：`n  & '$exe' -Mode status`n  & '$exe'            # 打开设置界面"
