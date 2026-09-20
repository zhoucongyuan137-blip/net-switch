<#
  campus-login.ps1 —— 校园网自助认证（Dr.COM ePortal），配合 net-switch 后台自动登录

  协议参考 snowsong42/CUMT_SchoolNet_tk_GUI（GET /eportal/?c=Portal&a=login&...）：
    账号 = 学号 + 运营商后缀（@cmcc 移动 / @unicom 联通 / @telecom 电信 / 校园网无后缀）
    参数 = c=Portal, a=login, login_method=1, user_account, user_password, wlan_user_ip
    响应 = dr1003({...})，用 result / msg 判断真正的成败（HTTP 200 不代表登录成功）

  用法（一般用同目录的「校园网登录设置.bat」）：
    -Mode gui      打开设置界面：账号 / 密码 / 运营商 / 服务器；保存即用 DPAPI 加密存储
    -Mode login    后台登录一次（已在线会自动跳过；带频率限制与失败退避）
    -Mode status   只读：显示配置、是否存了密码、最近一次尝试结果
    -Mode forget   删除已保存的配置（含密码）
  密码用 Windows DPAPI（当前用户范围）加密后写入 %APPDATA%\net-switch\campus.json，不落明文。
#>
[CmdletBinding()]
param(
  [ValidateSet('gui','login','status','forget','selftest')]
  [string]$Mode = 'status',
  [string]$Account,
  [ValidateSet('','cmcc','unicom','telecom','campus')]
  [string]$Operator,
  [string]$Password,                                   # 仅命令行调试用；正常走配置
  [string]$PortalUrl = 'http://10.2.5.251:801/eportal/',
  [int]$TimeoutSec   = 6,
  [int]$MinIntervalSec = 180,                          # 两次尝试最短间隔
  [int]$WaitForIpSec   = 0,                            # 网卡还没 IP 时最多等多少秒（登录后立刻认证用）
  [int]$FailBackoffMin = 30,                           # 失败后的退避时间（分钟）
  [string]$ConfigPath = "$env:APPDATA\net-switch\campus.json",
  [switch]$Force,                                      # 忽略"已在线"，强制登录一次
  [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $MyInvocation.MyCommand.Path
$BaseDir    = if ($env:NETSWITCH_HOME) { $env:NETSWITCH_HOME } else { Split-Path -Parent $ScriptPath }
$LogPath    = Join-Path $BaseDir 'net-switch.log'
$StatePath  = Join-Path (Split-Path -Parent $ConfigPath) 'campus-state.json'
$Entropy    = [Text.Encoding]::UTF8.GetBytes('net-switch-campus')

$ExcludePattern = 'VMware|VirtualBox|Hyper-V|Tailscale|TAP-|VPN|Sangfor|ZeroTier|WireGuard|Npcap|Loopback|Bluetooth|蓝牙|Wi-Fi Direct|Meta|WAN Miniport|Kernel Debug'
$OpSuffix = @{ 'cmcc' = '@cmcc'; 'unicom' = '@unicom'; 'telecom' = '@telecom'; 'campus' = '' }
$OpName   = @{ 'cmcc' = '中国移动'; 'unicom' = '中国联通'; 'telecom' = '中国电信'; 'campus' = '校园网（无后缀）' }

function Write-Log([string]$msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  # stdout 用 [Console]::Out 而不是 Write-Host：PS 5.1 的 Write-Host 不经过标准输出，
  # 在"无控制台/被重定向"时会丢（exe 形态、计划任务、管道）；这样写既不丢也不污染返回值
  try { if (-not $Quiet) { [Console]::Out.WriteLine($line) } } catch {}
  try {
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    $c = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    if ($c.Count -gt 800) { $c[-400..-1] | Set-Content -LiteralPath $LogPath -Encoding UTF8 }
  } catch {}
}

# ---------- 密码加密（DPAPI，当前用户范围）----------
function Protect-Text([string]$plain) {
  Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
  $b = [Text.Encoding]::UTF8.GetBytes($plain)
  [Convert]::ToBase64String([Security.Cryptography.ProtectedData]::Protect($b, $Entropy, 'CurrentUser'))
}
function Unprotect-Text([string]$b64) {
  if (-not $b64) { return '' }
  try {
    Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
    $b = [Convert]::FromBase64String($b64)
    [Text.Encoding]::UTF8.GetString([Security.Cryptography.ProtectedData]::Unprotect($b, $Entropy, 'CurrentUser'))
  } catch { '' }
}

# ---------- 配置 ----------
function Read-Config {
  if (-not (Test-Path -LiteralPath $ConfigPath)) { return $null }
  try {
    $o = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    [pscustomobject]@{
      Account   = $o.account
      Operator  = if ($o.operator) { $o.operator } else { 'campus' }
      PortalUrl = if ($o.portalUrl) { $o.portalUrl } else { $PortalUrl }
      Password  = Unprotect-Text $o.password
      PasswordSaved = [bool]$o.password
      AutoLogin = if ($null -ne $o.autoLogin) { [bool]$o.autoLogin } else { $true }
    }
  } catch { Write-Log "读取配置失败: $($_.Exception.Message)"; $null }
}

function Save-Config([string]$acct, [string]$op, [string]$plainPwd, [string]$portal, [bool]$auto = $true) {
  $dir = Split-Path -Parent $ConfigPath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $obj = [ordered]@{
    account   = $acct
    operator  = $op
    portalUrl = $portal
    autoLogin = $auto
    updatedAt = (Get-Date).ToString('s')
  }
  if ($plainPwd) { $obj.password = Protect-Text $plainPwd }
  elseif (Test-Path -LiteralPath $ConfigPath) {
    $old = (Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    if ($old.password) { $obj.password = $old.password }     # 没改密码就沿用旧的密文
  }
  ($obj | ConvertTo-Json) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ---------- 尝试频率限制 ----------
function Read-State {
  if (-not (Test-Path -LiteralPath $StatePath)) { return [pscustomobject]@{ lastAttempt = $null; backoffUntil = $null; lastResult = ''; lastMsg = '' } }
  try { Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { [pscustomobject]@{ lastAttempt = $null; backoffUntil = $null; lastResult = ''; lastMsg = '' } }
}
function Save-State([string]$result, [string]$msg, [string]$backoffUntil) {
  $dir = Split-Path -Parent $StatePath
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [ordered]@{
    lastAttempt  = (Get-Date).ToString('s')
    lastResult   = $result
    lastMsg      = $msg
    backoffUntil = $backoffUntil
  } | ConvertTo-Json | Set-Content -LiteralPath $StatePath -Encoding UTF8
}

# ---------- 网卡 / 连通性 ----------
function Get-WiredIPv4 {
  Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.MediaType -eq '802.3' -and $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch $ExcludePattern } |
    ForEach-Object {
      Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1 -ExpandProperty IPAddress
    } | Select-Object -First 1
}

function Test-TcpBound([string]$srcIP, [string]$dst, [int]$port, [int]$timeoutMs = 1500) {
  if (-not $srcIP) { return $false }
  $sock = $null
  try {
    $sock = New-Object System.Net.Sockets.Socket(
      [System.Net.Sockets.AddressFamily]::InterNetwork,
      [System.Net.Sockets.SocketType]::Stream,
      [System.Net.Sockets.ProtocolType]::Tcp)
    $sock.Bind((New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($srcIP), 0)))
    $iar = $sock.BeginConnect($dst, $port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { $sock.EndConnect($iar); return $true }
    return $false
  } catch { return $false } finally { if ($sock) { try { $sock.Close() } catch {} } }
}

function Test-CampusOnline {
  param([string]$ip)
  if (-not $ip) { $ip = Get-WiredIPv4 }
  if (-not $ip) { return $false }
  foreach ($d in @('223.5.5.5','119.29.29.29')) { if (Test-TcpBound $ip $d 443 1500) { return $true } }
  return $false
}

# ---------- 登录 ----------
function Parse-PortalResponse([string]$text) {
  # 形如 dr1003({"result":1,"msg":"..."})，也兼容纯 JSON
  $json = $text
  $m = [regex]::Match($text, '\(\s*(\{.*\})\s*\)')
  if ($m.Success) { $json = $m.Groups[1].Value }
  $obj = $null
  try { $obj = $json | ConvertFrom-Json } catch {}
  if (-not $obj) {
    return [pscustomobject]@{ Ok = $false; Kind = 'unparsed'; Msg = ('响应无法解析: ' + $text.Substring(0, [Math]::Min(160, $text.Length))) }
  }
  $res = "$($obj.result)"; $msg = "$($obj.msg)"; $code = "$($obj.ret_code)"
  if ($msg -match '已在线|已经在线|重复认证') {
    return [pscustomobject]@{ Ok = $true; Kind = 'already'; Msg = ('该 IP 已在线：' + $msg) }
  }
  if ($res -eq '1' -or $code -eq '2' -or $msg -match '成功') {
    return [pscustomobject]@{ Ok = $true; Kind = 'ok'; Msg = if ($msg) { $msg } else { '认证成功' } }
  }
  $kind = 'failed'
  if ($msg -match '密码|账号|用户名') { $kind = 'bad-credential' }
  elseif ($msg -match '关闭|维护|不可用|未开放') { $kind = 'unavailable' }
  [pscustomobject]@{ Ok = $false; Kind = $kind; Msg = ('登录未成功: ' + $msg) }
}

function Invoke-PortalLogin {
  param($cfg, [string]$pwdOverride)
  $ip = Get-WiredIPv4
  if (-not $ip) { return [pscustomobject]@{ Ok = $false; Kind = 'no-wired-ip'; Msg = '有线网卡没有拿到 IPv4 地址（网线没插好？）' } }

  $pwd = if ($pwdOverride) { $pwdOverride } else { $cfg.Password }
  if (-not $pwd) { return [pscustomobject]@{ Ok = $false; Kind = 'no-password'; Msg = '还没有保存密码' } }

  $op   = if ($cfg.Operator) { $cfg.Operator } else { 'campus' }
  $user = $cfg.Account + $OpSuffix[$op]
  $base = ($cfg.PortalUrl).TrimEnd('/')
  # 注意：必须给每个 "键=值" 加括号。PowerShell 在数组字面量里会把
  # 'k=' + [Uri]::EscapeDataString($v) 解析成两个元素，拼出来的是 "user_account=&账号" 这种畸形串。
  $qs = @(
    'c=Portal'
    'a=login'
    'login_method=1'
    ('user_account='  + [Uri]::EscapeDataString($user))
    ('user_password=' + [Uri]::EscapeDataString($pwd))
    ('wlan_user_ip='  + [Uri]::EscapeDataString($ip))
  ) -join '&'
  $url = "$base/?$qs"

  # 日志里给密码打码
  Write-Log ("发起认证: 账号={0} 本机IP={1} 服务器={2}" -f $user, $ip, $base)
  try {
    $resp = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSec -UseBasicParsing `
             -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) net-switch' }
    $body = [string]$resp.Content
    Write-Log ('认证响应(HTTP {0}): {1}' -f $resp.StatusCode, $body.Substring(0, [Math]::Min(200, $body.Length)))
    $r = Parse-PortalResponse $body
    if ($r.Kind -eq 'unparsed') {
      # 有的部署返回 GBK 编码，按 GB18030 重新解一次再试
      try {
        $alt = [Text.Encoding]::GetEncoding('GB18030').GetString($resp.RawContentStream.ToArray())
        if ($alt -ne $body) {
          $r2 = Parse-PortalResponse $alt
          if ($r2.Kind -ne 'unparsed') { $r = $r2 }
        }
      } catch {}
    }
    # 再实测一下是否真的通了（响应说成功也以真连通为准）
    if ($r.Ok) {
      Start-Sleep -Milliseconds 800
      if (Test-CampusOnline $ip) { return [pscustomobject]@{ Ok = $true; Kind = 'ok'; Msg = '认证成功，外网已通' } }
      return [pscustomobject]@{ Ok = $true; Kind = 'ok-unconfirmed'; Msg = ('认证接口返回成功，但外网暂时还不通：' + $r.Msg) }
    }
    return $r
  } catch {
    return [pscustomobject]@{ Ok = $false; Kind = 'unreachable'; Msg = ('连不上认证服务器 ' + $base + '：' + $_.Exception.Message) }
  }
}

# ---------- GUI ----------
function Show-Gui {
  # ---- 高 DPI 适配：先声明 DPI 感知，再按屏幕缩放比例放大布局（否则 125%/150% 缩放下整窗口被拉伸发虚）----
  $scale = 1.0
  try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiHelper {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
}
'@ -ErrorAction SilentlyContinue
    $logical = [DpiHelper]::GetSystemMetrics(0)
    [void][DpiHelper]::SetProcessDPIAware()
    $physical = [DpiHelper]::GetSystemMetrics(0)
    if ($logical -gt 0 -and $physical -gt $logical) { $scale = [Math]::Round($physical / $logical, 3) }
  } catch { $scale = 1.0 }
  function Sx([double]$v) { [int][Math]::Round($v * $scale) }

  Add-Type -AssemblyName System.Windows.Forms
  Add-Type -AssemblyName System.Drawing
  [System.Windows.Forms.Application]::EnableVisualStyles()

  $cfg = Read-Config
  $form = New-Object System.Windows.Forms.Form
  $form.Text = '校园网自动登录'
  $form.AutoScaleMode = 'None'
  $form.ClientSize = New-Object System.Drawing.Size((Sx 404), (Sx 262))
  $form.StartPosition = 'CenterScreen'
  $form.FormBorderStyle = 'FixedDialog'
  $form.MaximizeBox = $false
  $form.MinimizeBox = $false
  $form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

  function New-Label($text, $x, $y, $w = 84) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point((Sx $x), (Sx $y))
    $l.Size = New-Object System.Drawing.Size((Sx $w), (Sx 22))
    $l.TextAlign = 'MiddleLeft'
    $l
  }
  function New-Box($x, $y, $w, $h = 24) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point((Sx $x), (Sx $y))
    $t.Size = New-Object System.Drawing.Size((Sx $w), (Sx $h))
    $t
  }

  $form.Controls.Add((New-Label '账号（学号）' 18 20))
  $tbAccount = New-Box 105 20 180
  if ($cfg) { $tbAccount.Text = $cfg.Account }
  $form.Controls.Add($tbAccount)

  $lblSuffix = New-Label '@cmcc' 290 20 110
  $form.Controls.Add($lblSuffix)

  $form.Controls.Add((New-Label '运营商' 18 55))
  $cbOp = New-Object System.Windows.Forms.ComboBox
  $cbOp.Location = New-Object System.Drawing.Point((Sx 105), (Sx 55))
  $cbOp.Size = New-Object System.Drawing.Size((Sx 180), (Sx 24))
  $cbOp.DropDownStyle = 'DropDownList'
  [void]$cbOp.Items.Add('中国移动')
  [void]$cbOp.Items.Add('中国联通')
  [void]$cbOp.Items.Add('中国电信')
  [void]$cbOp.Items.Add('校园网（无后缀）')
  $opIndex = @{ 'cmcc' = 0; 'unicom' = 1; 'telecom' = 2; 'campus' = 3 }
  $opFrom  = @('cmcc', 'unicom', 'telecom', 'campus')
  $cbOp.SelectedIndex = if ($cfg -and $opIndex.ContainsKey($cfg.Operator)) { $opIndex[$cfg.Operator] } else { 0 }
  $form.Controls.Add($cbOp)
  $cbOp.Add_SelectedIndexChanged({ $lblSuffix.Text = $OpSuffix[$opFrom[$cbOp.SelectedIndex]] })
  $lblSuffix.Text = $OpSuffix[$opFrom[$cbOp.SelectedIndex]]

  $form.Controls.Add((New-Label '密码' 18 90))
  $tbPwd = New-Box 105 90 180
  $tbPwd.UseSystemPasswordChar = $true
  $form.Controls.Add($tbPwd)

  $chkShow = New-Object System.Windows.Forms.CheckBox
  $chkShow.Text = '显示'
  $chkShow.Location = New-Object System.Drawing.Point((Sx 292), (Sx 91))
  $chkShow.Size = New-Object System.Drawing.Size((Sx 60), (Sx 22))
  $chkShow.Add_CheckedChanged({ $tbPwd.UseSystemPasswordChar = -not $chkShow.Checked })
  $form.Controls.Add($chkShow)

  $form.Controls.Add((New-Label '认证服务器' 18 125))
  $tbUrl = New-Box 105 125 280
  $tbUrl.Text = if ($cfg) { $cfg.PortalUrl } else { $PortalUrl }
  $form.Controls.Add($tbUrl)

  $chkAuto = New-Object System.Windows.Forms.CheckBox
  $chkAuto.Text = '保存后自动在后台登录（开机 / 插网线 / 网络变化 / 07:00）'
  $chkAuto.Location = New-Object System.Drawing.Point((Sx 18), (Sx 158))
  $chkAuto.Size = New-Object System.Drawing.Size((Sx 378), (Sx 22))
  $chkAuto.Checked = if ($cfg) { $cfg.AutoLogin } else { $true }
  $form.Controls.Add($chkAuto)

  $lblState = New-Object System.Windows.Forms.Label
  $lblState.Location = New-Object System.Drawing.Point((Sx 18), (Sx 186))
  $lblState.Size = New-Object System.Drawing.Size((Sx 372), (Sx 20))
  if ($cfg -and $cfg.PasswordSaved) {
    $lblState.Text = '已保存配置（密码用 DPAPI 加密）；密码留空 = 不修改'
    $lblState.ForeColor = [System.Drawing.Color]::DimGray
  } else {
    $lblState.Text = '还没有保存配置'
    $lblState.ForeColor = [System.Drawing.Color]::DarkOrange
  }
  $form.Controls.Add($lblState)

  $lblMsg = New-Object System.Windows.Forms.Label
  $lblMsg.Location = New-Object System.Drawing.Point((Sx 18), (Sx 208))
  $lblMsg.Size = New-Object System.Drawing.Size((Sx 372), (Sx 20))
  $form.Controls.Add($lblMsg)

  $btnSave = New-Object System.Windows.Forms.Button
  $btnSave.Text = '保存并测试登录'
  $btnSave.Location = New-Object System.Drawing.Point((Sx 105), (Sx 228))
  $btnSave.Size = New-Object System.Drawing.Size((Sx 130), (Sx 28))
  $form.Controls.Add($btnSave)

  $btnSaveOnly = New-Object System.Windows.Forms.Button
  $btnSaveOnly.Text = '仅保存'
  $btnSaveOnly.Location = New-Object System.Drawing.Point((Sx 245), (Sx 228))
  $btnSaveOnly.Size = New-Object System.Drawing.Size((Sx 70), (Sx 28))
  $form.Controls.Add($btnSaveOnly)

  $btnClose = New-Object System.Windows.Forms.Button
  $btnClose.Text = '关闭'
  $btnClose.Location = New-Object System.Drawing.Point((Sx 325), (Sx 228))
  $btnClose.Size = New-Object System.Drawing.Size((Sx 60), (Sx 28))
  $form.Controls.Add($btnClose)

  $doSave = {
    $acct = $tbAccount.Text.Trim()
    if (-not $acct) { $lblMsg.Text = '账号不能为空'; $lblMsg.ForeColor = [System.Drawing.Color]::Firebrick; return $false }
    $op = $opFrom[$cbOp.SelectedIndex]
    Save-Config $acct $op $tbPwd.Text.Trim() $tbUrl.Text.Trim() $chkAuto.Checked
    $tbPwd.Text = ''
    $lblState.Text = '已保存（密码用 DPAPI 加密，仅本机当前用户可解）'
    $lblState.ForeColor = [System.Drawing.Color]::DimGray
    return $true
  }

  $btnSaveOnly.Add_Click({
    if (& $doSave) { $lblMsg.Text = '已保存，之后会自动在后台登录'; $lblMsg.ForeColor = [System.Drawing.Color]::DarkGreen }
  })

  $btnSave.Add_Click({
    if (-not (& $doSave)) { return }
    $lblMsg.Text = '正在测试登录...'
    $lblMsg.ForeColor = [System.Drawing.Color]::DimGray
    $form.Refresh()
    $r = Invoke-PortalLogin (Read-Config) ''
    $lblMsg.Text = $r.Msg
    $lblMsg.ForeColor = if ($r.Ok) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::Firebrick }
  })

  $btnClose.Add_Click({ $form.Close() })

  # 不能用 ShowDialog()：用「powershell -WindowStyle Hidden」启动时，隐藏标志会作用到进程的
  # 第一个顶层窗口（就是本窗体），ShowDialog 不会再显示它 —— 表现就是双击 bat "没反应"。
  # 显式 Show() 会走 SetVisibleCore(true) → ShowWindow(SW_SHOW)，再用消息泵维持交互。
  $form.Show()
  [void]$form.Activate()
  $form.BringToFront()
  while ($form.Visible) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 100
  }
  $form.Dispose()
}

# ---------- 主流程 ----------
switch ($Mode) {
  'selftest' {
    # 不弹窗，只构建一次窗体，验证 GUI 代码可用
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'selftest'
    $tb = New-Object System.Windows.Forms.TextBox; $f.Controls.Add($tb)
    $cb = New-Object System.Windows.Forms.ComboBox; [void]$cb.Items.Add('中国移动'); $f.Controls.Add($cb)
    Write-Log ('GUI 自检通过：控件数 ' + $f.Controls.Count + '，WinForms 可用')
    $f.Dispose()
  }
  'gui' { Show-Gui }
  'forget' {
    Remove-Item -LiteralPath $ConfigPath -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $StatePath  -ErrorAction SilentlyContinue
    Write-Log '已删除保存的校园网配置与状态。'
  }
  'status' {
    $cfg = Read-Config
    $ip  = Get-WiredIPv4
    Write-Output ''
    Write-Output '===== 校园网自动登录 状态 ====='
    if (-not $cfg) {
      Write-Output '配置:      未配置（运行「校园网登录设置.bat」填账号密码）'
    } else {
      Write-Output ("配置:      账号 {0}{1}（{2}）" -f $cfg.Account, $OpSuffix[$cfg.Operator], $OpName[$cfg.Operator])
      Write-Output ("           服务器 {0}" -f $cfg.PortalUrl)
      Write-Output ("           密码   {0}" -f $(if ($cfg.PasswordSaved) { '已保存（DPAPI 加密）' } else { '未保存' }))
      Write-Output ("           自动登录 {0}" -f $(if ($cfg.AutoLogin) { '开' } else { '关' }))
    }
    Write-Output ("有线网卡:  {0}" -f $(if ($ip) { $ip } else { '没有 IPv4（网线未插/未拿到地址）' }))
    if ($ip) { Write-Output ("能否出网:  {0}" -f $(if (Test-CampusOnline $ip) { '能（无需登录）' } else { '不能（需要认证）' })) }
    $st = Read-State
    if ($st.lastAttempt) {
      Write-Output ("上次尝试:  {0}  {1}  {2}" -f $st.lastAttempt, $st.lastResult, $st.lastMsg)
      Write-Output ("退避到:    {0}" -f $(if ($st.backoffUntil) { $st.backoffUntil } else { '（无）' }))
    } else { Write-Output '上次尝试:  无记录' }
    Write-Output ("配置文件:  {0}" -f $ConfigPath)
    Write-Output ''
  }
  'login' {
    $cfg = Read-Config
    if (-not $cfg -or -not $cfg.Account) { if (-not $Password) { Write-Log '未配置校园网账号，跳过自动登录。'; exit 3 } }
    if ($Password -and $Account) {
      $cfg = [pscustomobject]@{ Account = $Account; Operator = $(if ($Operator) { $Operator } else { 'campus' })
                                PortalUrl = $PortalUrl; Password = $Password; PasswordSaved = $true; AutoLogin = $true }
    }
    if ($cfg -and -not $cfg.AutoLogin -and -not $Force -and -not $Password) { Write-Log '自动登录已在设置里关闭，跳过。'; exit 0 }

    $ip = Get-WiredIPv4
    if (-not $ip -and $WaitForIpSec -gt 0) {
      # 开机/登录瞬间网卡往往还没 DHCP 完，就地等一会儿（比固定延迟更早、比直接放弃更可靠）
      $sw = [Diagnostics.Stopwatch]::StartNew()
      Write-Log ('有线网卡还没拿到 IPv4，最多等 {0} 秒…' -f $WaitForIpSec)
      while (-not $ip -and $sw.Elapsed.TotalSeconds -lt $WaitForIpSec) {
        Start-Sleep -Seconds 2
        $ip = Get-WiredIPv4
      }
      if ($ip) { Write-Log ('有线网卡就绪（等了 {0:N0} 秒，IP {1}）' -f $sw.Elapsed.TotalSeconds, $ip) }
    }
    if (-not $ip) { Write-Log '有线网卡没有 IPv4，跳过校园网认证。'; exit 4 }
    if (-not $Force -and (Test-CampusOnline $ip)) { Write-Log '校园网已在线，无需认证。'; exit 0 }

    $st = Read-State
    $now = Get-Date
    if (-not $Force) {
      if ($st.backoffUntil) {
        $bu = $null; try { $bu = [datetime]::Parse($st.backoffUntil) } catch {}
        if ($bu -and $now -lt $bu) { Write-Log ("上次失败（{0}），退避到 {1:HH:mm}，本次跳过。" -f $st.lastMsg, $bu); exit 0 }
      }
      if ($st.lastAttempt) {
        $la = $null; try { $la = [datetime]::Parse($st.lastAttempt) } catch {}
        if ($la -and ($now - $la).TotalSeconds -lt $MinIntervalSec) { Write-Log '距上次尝试太近，跳过。'; exit 0 }
      }
    }

    $r = Invoke-PortalLogin $cfg ''
    if ($r.Ok) {
      Save-State 'ok' $r.Msg ''
      Write-Log ('校园网认证结果: 成功 — ' + $r.Msg)
      exit 0
    }
    $backoff = $now.AddMinutes($FailBackoffMin).ToString('s')
    Save-State $r.Kind $r.Msg $backoff
    Write-Log ('校园网认证结果: 失败[' + $r.Kind + '] ' + $r.Msg + ('（{0} 分钟内不再重试）' -f $FailBackoffMin))
    exit 1
  }
}
