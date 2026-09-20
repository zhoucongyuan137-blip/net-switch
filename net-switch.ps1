<#
  net-switch.ps1  ——  校园有线网 / 手机热点 共存时自动选路

  背景：有线网卡自动跃点(25)低于无线(50)，宿舍断网(周日至周四 23:30 停止认证)后
        有线链路仍在、网关仍 ARP 应答，Windows 不会改判，默认路由与 DNS 被钉死在
        没有出口的有线上 —— 于是"插着网线时连手机热点也上不了网"。
  做法：把探测包用 socket 绑定到各网卡的本机地址，逐条线路测真实出口；
        谁通就优先谁（热点优先时：热点跃点 10 / 有线跃点 90），校园网恢复后自动还原。

  用法（一般直接双击同目录下的 .bat）：
    -Mode settle    定点任务：等到条件出现就跑几分钟收工退出，**不用整夜常驻**
                      -Until wireddown  晚上断网：等到"有线真的断掉"，把热点设为优先，然后退出
                      -Until wiredup    早上恢复：等到"有线真的恢复"，切回有线优先，然后退出
    -Mode auto      只探测切换一次就退出（登录时兜底调用）
    -Mode watch     （备选）整夜常驻守护；本机不用它，见 -Mode install 装的定点任务
    -Mode status    只读探测并显示状态（不需要管理员）
    -Mode hotspot   强制优先手机热点（需要管理员，会弹 UAC）
    -Mode campus    恢复有线优先（需要管理员，会弹 UAC）
    -Mode install   安装三个计划任务：断网时刻 / 恢复时刻 / 网络状态变化+登录兜底（需要管理员）
    -Mode uninstall 删除计划任务并恢复自动跃点（需要管理员）
    可加 -DryRun 只看判定结果、不改任何设置。
#>
[CmdletBinding()]
param(
  [ValidateSet('settle','watch','auto','hotspot','campus','status','install','uninstall')]
  [string]$Mode = 'status',
  [string]$WiredAlias = '',                 # 留空 = 自动识别有线网卡
  [string[]]$AltAlias  = @(),               # 留空 = 自动识别无线/手机USB共享
  [int]$AltMetric   = 10,                   # 热点优先时，热点接口跃点
  [int]$WiredMetric = 90,                   # 热点优先时，有线接口跃点
  [int]$Interval    = 60,                   # 探测间隔（秒）
  [ValidateSet('wireddown','wiredup')]
  [string]$Until    = 'wireddown',          # settle 模式等待的条件
  [int]$MaxMinutes  = 20,                   # settle 模式最长等待分钟数
  [string]$StopTime = '07:45',              # watch 模式：早于该时刻不退出
  [int]$MaxHours    = 10,                   # watch 模式最长运行小时数（保险）
  [string]$NightTime   = '23:30',           # install：断网时刻任务启动时间
  [string]$MorningTime = '07:00',           # install：恢复时刻任务启动时间
  [int]$NightMinutes   = 20,                # install：断网任务最长等待分钟
  [int]$MorningMinutes = 45,                # install：恢复任务最长等待分钟
  [string]$NightTask = 'NetSwitch-Night',
  [string]$MorningTask = 'NetSwitch-Morning',
  [string]$LogonTask = 'NetSwitch-Logon',
  [string]$CampusTask = 'NetSwitch-Campus',   # 登录后立刻认证（不等选路那 30 秒）
  [string]$WatchTask = 'NetSwitch-Watch',   # 旧版整夜常驻任务，安装时清掉
  [string]$LegacyTask = 'NetSwitch-Auto',   # 更旧版"每分钟起进程"任务，安装时清掉
  [switch]$DryRun,
  [switch]$NoCampusLogin                   # 关闭"有线没认证时自动调 campus-login.ps1"
)

$ErrorActionPreference = 'Continue'
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
# exe 形态下由启动器（build\Launcher.cs）注入这三个环境变量：
#   NETSWITCH_HOME       = exe 所在目录（日志/状态写这里）
#   NETSWITCH_SCRIPT_DIR = 脚本释放目录（找兄弟脚本 campus-login.ps1 用这个）
#   NETSWITCH_EXE        = exe 完整路径（自提权、注册计划任务用）
$BaseDir       = if ($env:NETSWITCH_HOME)       { $env:NETSWITCH_HOME }       else { $ScriptDir }
$PeerScriptDir = if ($env:NETSWITCH_SCRIPT_DIR) { $env:NETSWITCH_SCRIPT_DIR } else { $ScriptDir }
$LogPath    = Join-Path $BaseDir 'net-switch.log'
$StatePath  = Join-Path $BaseDir 'state.txt'

# 这些虚拟网卡不参与选路（VMware / Tailscale / VPN / 蓝牙 / Wi-Fi Direct 等）
$ExcludePattern = 'VMware|VirtualBox|Hyper-V|Tailscale|TAP-|VPN|Sangfor|ZeroTier|WireGuard|Npcap|Loopback|Bluetooth|蓝牙|Wi-Fi Direct|Meta|WAN Miniport|Kernel Debug'

$ProbeTcp  = @(@('223.5.5.5',443), @('119.29.29.29',443))
$ProbeIcmp = @('223.5.5.5','119.29.29.29')

function Write-Log([string]$msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { [Console]::Out.WriteLine($line) } catch {}
  try {
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 -ErrorAction Stop
    $c = @(Get-Content -LiteralPath $LogPath -ErrorAction SilentlyContinue)
    if ($c.Count -gt 800) { $c[-400..-1] | Set-Content -LiteralPath $LogPath -Encoding UTF8 }
  } catch {}
}

function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-WiredAliases {
  if ($WiredAlias) { return @($WiredAlias) }
  @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.MediaType -eq '802.3' -and $_.InterfaceDescription -notmatch $ExcludePattern } |
    Select-Object -ExpandProperty Name)
}

function Get-AltAliases {
  if ($AltAlias.Count -gt 0) { return @($AltAlias) }
  @(Get-NetAdapter -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceDescription -notmatch $ExcludePattern } |
    Where-Object { $_.MediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match 'RNDIS|Remote NDIS|USB.*Ethernet|iPhone|iOS|Android' } |
    Select-Object -ExpandProperty Name -Unique)
}

function Get-AdapterUp([string]$alias) {
  $a = Get-NetAdapter -InterfaceAlias $alias -ErrorAction SilentlyContinue
  if (-not $a) { return $false }
  ($a.Status -eq 'Up')
}

function Get-AdapterIPv4([string]$alias) {
  Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254.*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object -First 1 -ExpandProperty IPAddress
}

# 把 socket 绑定到本机某网卡的地址 -> 强制只用这条线路出去（实测：绑定源按网卡选路，
# 其它网卡不通时会直接报"向一个无法连接的网络尝试了套接字操作"）
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

function Test-IcmpBound([string]$srcIP, [string]$dst, [int]$timeoutMs = 1200) {
  if (-not $srcIP) { return $false }
  ping.exe -n 1 -w $timeoutMs -S $srcIP $dst | Out-Null
  ($LASTEXITCODE -eq 0)
}

function Test-Online([string]$srcIP) {
  if (-not $srcIP) { return $false }
  foreach ($p in $ProbeTcp)  { if (Test-TcpBound $srcIP $p[0] $p[1] 1500) { return $true } }
  foreach ($d in $ProbeIcmp) { if (Test-IcmpBound $srcIP $d 1200)       { return $true } }
  return $false
}

function Get-IfMetricText([string]$alias) {
  $i = Get-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue
  if (-not $i) { return '-' }
  if ($i.AutomaticMetric -eq 'Enabled') { return "自动($($i.InterfaceMetric))" }
  "$($i.InterfaceMetric)(手动)"
}

function Set-IfAutoMetric([string]$alias) {
  if ($DryRun) { Write-Log "  [DryRun] $alias 跃点 -> automatic"; return $true }
  try { Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction Stop; return $true }
  catch { Write-Log "  ! 恢复 $alias 自动跃点失败: $($_.Exception.Message)"; return $false }
}

function Set-IfMetric([string]$alias, [int]$m) {
  if ($DryRun) { Write-Log "  [DryRun] $alias 跃点 -> $m"; return $true }
  try { Set-NetIPInterface -InterfaceAlias $alias -AddressFamily IPv4 -InterfaceMetric $m -ErrorAction Stop; return $true }
  catch { Write-Log "  ! 设置 $alias 跃点=$m 失败: $($_.Exception.Message)"; return $false }
}

function Show-Status {
  $all = @()
  $all += @(Get-WiredAliases)
  $all += @(Get-AltAliases)
  $all += @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } | Select-Object -ExpandProperty Name)
  $all = $all | Where-Object { $_ } | Select-Object -Unique

  $rows = @()
  foreach ($a in $all) {
    $up = Get-AdapterUp $a
    $ip = if ($up) { Get-AdapterIPv4 $a } else { $null }
    $online = if ($up -and $ip) { Test-Online $ip } else { $false }
    $rows += [pscustomobject]@{
      接口   = $a
      链路   = if ($up) { 'Up' } else { 'Down' }
      IP     = if ($ip) { $ip } else { '-' }
      能出网 = if ($up) { if ($online) { '是' } else { '否' } } else { '-' }
      跃点   = Get-IfMetricText $a
    }
  }
  Write-Output ($rows | Format-Table -AutoSize | Out-String -Width 200)

  $idx = (Find-NetRoute -RemoteIPAddress 223.5.5.5 -ErrorAction SilentlyContinue |
          Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } | Select-Object -First 1).InterfaceIndex
  if ($idx) {
    $ad = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
    Write-Output ("系统当前会把公网流量交给: {1} (接口索引 {0})" -f $idx, $ad.Name)
    if ($ad -and ($ad.Name -match $ExcludePattern -or $ad.InterfaceDescription -match $ExcludePattern -or $ad.InterfaceDescription -match 'Tunnel')) {
      Write-Output ('  ↑ {0} 是虚拟网卡/隧道（{1}），不是真实出口：它只做中间人，' -f $ad.Name, $ad.InterfaceDescription)
      Write-Output '    真正的出口由它按"物理默认路由"选，看上面 以太网 / WLAN 两行的【能出网】才准。'
    }
    Write-Output ''
  }
}

function Apply-AltPreference {
  foreach ($a in Get-WiredAliases) { Set-IfMetric $a $WiredMetric | Out-Null }
  foreach ($a in Get-AltAliases)   { Set-IfMetric $a $AltMetric   | Out-Null }
}

function Apply-CampusPreference {
  foreach ($a in (@(Get-WiredAliases) + @(Get-AltAliases))) { Set-IfAutoMetric $a | Out-Null }
}

function Save-State([string]$s) { if (-not $DryRun) { try { Set-Content -LiteralPath $StatePath -Value $s -Encoding UTF8 } catch {} } }
function Read-State { try { Get-Content -LiteralPath $StatePath -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null } }

# 有线在线但出不了网时，调 campus-login.ps1 做校园网认证（带频率限制，认证脚本内部自带）
function Invoke-CampusLogin {
  $cl = Join-Path $PeerScriptDir 'campus-login.ps1'
  if (-not (Test-Path -LiteralPath $cl)) { return $false }
  Write-Log '  有线在线但出不了网 -> 尝试校园网认证'
  try {
    $out = & powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File $cl -Mode login -Quiet 2>&1
    foreach ($l in $out) { Write-Log ('  校园网: ' + ("$l").Trim()) }
    return ($LASTEXITCODE -eq 0)
  } catch {
    Write-Log ('  校园网认证调用失败: ' + $_.Exception.Message)
    return $false
  }
}

# 探测一轮并按需切换；返回本轮结论
function Invoke-Round {
  $wiredUp = @(); $wiredOn = @()
  foreach ($a in Get-WiredAliases) {
    if (Get-AdapterUp $a) { $wiredUp += $a; if (Test-Online (Get-AdapterIPv4 $a)) { $wiredOn += $a } }
  }

  # 有线插着却没网：多半是校园网需要认证 —— 先试一次自助登录，再重新判定出口
  if ($wiredUp.Count -gt 0 -and $wiredOn.Count -eq 0 -and -not $NoCampusLogin) {
    if (Invoke-CampusLogin) {
      Start-Sleep -Seconds 1
      $wiredOn = @()
      foreach ($a in $wiredUp) { if (Test-Online (Get-AdapterIPv4 $a)) { $wiredOn += $a } }
    }
  }

  $altUp = @(); $altOn = @()
  foreach ($a in Get-AltAliases) {
    if (Get-AdapterUp $a) { $altUp += $a; if (Test-Online (Get-AdapterIPv4 $a)) { $altOn += $a } }
  }

  $want = if ($altOn.Count -gt 0 -and $wiredOn.Count -eq 0) { 'alt' } else { 'campus' }
  $now  = Read-State
  $desc = '有线Up=[{0}] 有线通=[{1}] 无线Up=[{2}] 无线通=[{3}] => 选择 {4} (上次 {5})' -f `
          ($wiredUp -join '|'), ($wiredOn -join '|'), ($altUp -join '|'), ($altOn -join '|'), $want, $now

  if ($want -eq $now) {
    Write-Log "无变化 | $desc"
  } elseif ($want -eq 'alt') {
    Write-Log "切到热点优先 | $desc"; Apply-AltPreference; Save-State 'alt'
  } else {
    Write-Log "恢复有线优先 | $desc"; Apply-CampusPreference; Save-State 'campus'
  }

  [pscustomobject]@{ Want = $want; WiredOnline = ($wiredOn.Count -gt 0); AltOnline = ($altOn.Count -gt 0) }
}

function Test-TimeInWindow {
  $sp = $StopTime.Split(':')
  $now = Get-Date
  $stop = $now.Date.AddHours([int]$sp[0]).AddMinutes([int]$sp[1])
  $sp2 = $NightTime.Split(':')
  $start = $now.Date.AddHours([int]$sp2[0]).AddMinutes([int]$sp2[1])
  ($now -ge $start -or $now -le $stop)
}

# ---------------- 计划任务 ----------------
function New-TaskXml {
  param([string]$Name, [string]$Desc, [string]$TriggerXml, [string]$Arguments)
  $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
  $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>$Desc</Description>
    <URI>\$Name</URI>
  </RegistrationInfo>
  <Triggers>
$TriggerXml
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <WakeToRun>false</WakeToRun>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT2H</ExecutionTimeLimit>
    <Priority>7</Priority>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>$Arguments</Arguments>
    </Exec>
  </Actions>
</Task>
"@
  $f = Join-Path $env:TEMP "$Name.xml"
  Set-Content -LiteralPath $f -Value $xml -Encoding Unicode
  return $f
}

function New-DailyTrigger([string]$hhmm) {
  $today = (Get-Date).ToString('yyyy-MM-dd')
@"
    <CalendarTrigger>
      <StartBoundary>$today`T$hhmm`:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByDay>
        <DaysInterval>1</DaysInterval>
      </ScheduleByDay>
    </CalendarTrigger>
"@
}

function Install-Task {
  # 结束旧版常驻守护 / 清掉旧任务
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'net-switch\.ps1' -and $_.CommandLine -match '-Mode (watch|settle|auto)' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force; Write-Log "已结束旧进程 PID $($_.ProcessId)" } catch {} }
  foreach ($t in @($LegacyTask, $WatchTask)) { & schtasks.exe /Delete /TN $t /F 2>&1 | Out-Null }
  Remove-Item -LiteralPath $StatePath -ErrorAction SilentlyContinue

  # exe 形态：计划任务直接调 exe（启动器是 winexe，天然无窗口，不用 -WindowStyle）
  # 脚本形态：用 powershell -File -WindowStyle Hidden
  if ($env:NETSWITCH_EXE) {
    $common       = '"{0}"' -f $env:NETSWITCH_EXE
    $commonCampus = '"{0}"' -f $env:NETSWITCH_EXE
  } else {
    $common       = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $ScriptPath
    $commonCampus = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $PeerScriptDir 'campus-login.ps1')
  }

  # 网络状态一变（插拔网线 / NCSI 由"有网"变"无网"或反之）就自动判断一次；
  # 不轮询、不常驻，只在事件真的发生时才起一个几秒的进程
  $eventTrig = @'
    <EventTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5S</Delay>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"&gt;&lt;Select Path="Microsoft-Windows-NetworkProfile/Operational"&gt;*[System[(EventID=4004 or EventID=10000 or EventID=10001)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
'@
  $plan = @(
    @{ Name = $NightTask;   Time = $NightTime;   Desc = '校园网断网时把公网切到手机热点（定点运行几分钟即退出）'
       Trig = (New-DailyTrigger $NightTime);   Args = "$common -Mode settle -Until wireddown -MaxMinutes $NightMinutes" }
    @{ Name = $MorningTask; Time = $MorningTime; Desc = '校园网恢复时切回有线优先（定点运行几分钟即退出）'
       Trig = (New-DailyTrigger $MorningTime); Args = "$common -Mode settle -Until wiredup -MaxMinutes $MorningMinutes" }
    @{ Name = $CampusTask;  Time = '';           Desc = '登录后立刻做校园网认证（不等选路的 30 秒判定）'
       Trig = "    <LogonTrigger>`r`n      <Enabled>true</Enabled>`r`n    </LogonTrigger>`r`n"
       Args = "$commonCampus -Mode login -WaitForIpSec 40" }
    @{ Name = $LogonTask;   Time = '';           Desc = '网络状态变化或登录时自动判断一次（兜底，非常驻）'
       Trig = "    <LogonTrigger>`r`n      <Enabled>true</Enabled>`r`n      <Delay>PT30S</Delay>`r`n    </LogonTrigger>`r`n" + $eventTrig
       Args = "$common -Mode auto" }
  )

  $ok = $true
  foreach ($j in $plan) {
    $f = New-TaskXml -Name $j.Name -Desc $j.Desc -TriggerXml $j.Trig -Arguments $j.Args
    $out = & schtasks.exe /Create /TN $j.Name /XML $f /F 2>&1
    $when = if ($j.Time) { "（每天 $($j.Time)）" } else { '（登录时）' }
    Write-Log ("创建任务 {0}{1} -> {2}" -f $j.Name, $when, ($out -join ' '))
    & schtasks.exe /Query /TN $j.Name > $null 2>&1
    if ($LASTEXITCODE -ne 0) { $ok = $false; Write-Log "  ! 任务 $($j.Name) 注册失败" }
    Remove-Item -LiteralPath $f -ErrorAction SilentlyContinue
  }

  if ($ok) {
    Write-Log '三个计划任务都已注册（隐藏窗口 / 允许电池运行 / 错过时间点会尽快补跑）。'
    if (Test-TimeInWindow) {
      Write-Log '当前正处于夜间时段，按"断网"条件立刻跑一次定点任务...'
      & schtasks.exe /Run /TN $NightTask 2>&1 | Write-Host
      Start-Sleep -Seconds 8
    } else {
      Write-Log "现在不在夜间时段；今晚 $NightTime 自动切热点，明早 $MorningTime 自动切回。"
    }
    Write-Log '安装完成。日志见 net-switch.log'
  } else {
    Write-Log '安装失败：有任务没建全（可能不是管理员）。'
  }
}

function Uninstall-Task {
  foreach ($t in @($NightTask, $MorningTask, $CampusTask, $LogonTask, $WatchTask, $LegacyTask)) {
    $q = & schtasks.exe /Delete /TN $t /F 2>&1
    if ("$q" -notmatch '找不到|ERROR') { Write-Log "已删除计划任务 $t" }
  }
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match 'net-switch\.ps1' -and $_.CommandLine -match '-Mode (watch|settle|auto)' } |
    ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force; Write-Log "已结束进程 PID $($_.ProcessId)" } catch {} }
  Apply-CampusPreference
  Remove-Item -LiteralPath $StatePath -ErrorAction SilentlyContinue
  Write-Log '已删除全部计划任务，并让有线/无线恢复自动跃点。'
}

if ($Mode -in @('install','hotspot','campus','uninstall') -and -not (Test-Admin) -and -not $DryRun) {
  Write-Host '需要管理员权限，正在请求提权（会弹 UAC 窗口）...'
  if ($env:NETSWITCH_EXE) {
    # exe 形态：直接用 exe 重新拉起自己（脚本已内嵌，不需要 -File）
    Start-Process -FilePath $env:NETSWITCH_EXE -Verb RunAs -ArgumentList @('-Mode', $Mode)
  } else {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -Mode {1}' -f $ScriptPath, $Mode)
  }
  exit
}

switch ($Mode) {
  'install'   { Write-Log '== 安装定点任务（断网 / 恢复 / 登录兜底）=='; Install-Task }
  'uninstall' { Write-Log '== 卸载计划任务 =='; Uninstall-Task }
  'status'    { Write-Log '== 当前状态（只读探测）=='; Show-Status; Write-Log ('上次切换记录: ' + (Read-State)) }
  'hotspot'   { Write-Log '== 手动切换到手机热点优先 =='; Show-Status; Apply-AltPreference; Save-State 'alt'; Write-Log '已把热点设为最高优先（热点跃点 10 / 有线跃点 90）：公网走热点，有线同网段内网仍可访问。' }
  'campus'    { Write-Log '== 恢复有线优先 =='; Apply-CampusPreference; Save-State 'campus'; Write-Log '已恢复有线/无线自动跃点（有线 25 优先于无线 50）。' }
  'auto'      {
    $mutex = $null
    try { $mutex = New-Object System.Threading.Mutex($false, 'Local\NetSwitch-Auto'); if (-not $mutex.WaitOne(0)) { exit 0 } } catch { $mutex = $null }
    try {
      if (-not (Test-Admin) -and -not $DryRun) { Write-Log '需要管理员权限，跳过。'; exit 1 }
      Invoke-Round | Out-Null
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
  }
  'settle'    {
    if (-not (Test-Admin) -and -not $DryRun) { Write-Log '需要管理员权限，本次跳过。'; exit 1 }
    $mutex = $null
    try { $mutex = New-Object System.Threading.Mutex($false, 'Local\NetSwitch-Settle'); if (-not $mutex.WaitOne(0)) { Write-Log '已有一个定点任务在跑，退出。'; exit 0 } } catch { $mutex = $null }
    try {
      $deadline = (Get-Date).AddMinutes($MaxMinutes)
      Write-Log ('== 定点任务启动 == 等待条件 [{0}]，最长 {1} 分钟，每 {2} 秒探测一次' -f $Until, $MaxMinutes, $Interval)
      while ($true) {
        $r = Invoke-Round
        $t = Get-Date
        if ($Until -eq 'wiredup' -and $r.WiredOnline) {
          Write-Log '有线已恢复上网，定点任务退出。'; break
        }
        if ($Until -eq 'wireddown' -and -not $r.WiredOnline) {
          # 有线真的断了：无论热点此刻连没连，先把优先级摆好，之后插上热点即可用
          Apply-AltPreference; Save-State 'alt'
          Write-Log '有线已断（校园网停认证），已把热点设为优先，定点任务退出。'; break
        }
        if ($t -ge $deadline) {
          Write-Log ('等待 {0} 分钟内条件未出现，定点任务退出（保持当前设置）。' -f $MaxMinutes); break
        }
        Start-Sleep -Seconds $Interval
      }
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
  }
  'watch'     {
    if (-not (Test-Admin) -and -not $DryRun) { Write-Log '需要管理员权限，守护退出。'; exit 1 }
    $mutex = $null
    try { $mutex = New-Object System.Threading.Mutex($false, 'Local\NetSwitch-Watch'); if (-not $mutex.WaitOne(0)) { Write-Log '已有一个守护进程在跑，本次退出。'; exit 0 } } catch { $mutex = $null }
    try {
      $t0 = Get-Date
      $sp = $StopTime.Split(':')
      $stopAt = $t0.Date.AddHours([int]$sp[0]).AddMinutes([int]$sp[1])
      if ($stopAt -le $t0) { $stopAt = $stopAt.AddDays(1) }
      $hardStop = $t0.AddHours($MaxHours)
      Write-Log ('== 守护启动 == 每 {0} 秒探测一次；{1:MM-dd HH:mm} 之后且有线已恢复即退出，最晚 {2:MM-dd HH:mm}' -f $Interval, $stopAt, $hardStop)
      while ($true) {
        $r = Invoke-Round
        $t = Get-Date
        if ($t -ge $hardStop) { Write-Log ('到达最长运行时间 {0} 小时，守护退出。' -f $MaxHours); break }
        if ($t -ge $stopAt -and $r.WiredOnline) { Write-Log ('已过 {0:HH:mm} 且有线已恢复上网，守护退出。' -f $stopAt); break }
        Start-Sleep -Seconds $Interval
      }
    } finally { if ($mutex) { try { $mutex.ReleaseMutex() } catch {} } }
  }
}
