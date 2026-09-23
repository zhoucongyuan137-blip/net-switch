# net-switch（Linux 版）

有线没出口时自动改走手机热点 + 校园网自助认证。**只用一个 Python 3 文件**（除 GUI 需 tkinter 外无第三方依赖）。

## 和 Windows 版的机制差异

| | Windows 版 | Linux 版 |
|---|---|---|
| 选路机制 | 接口**跃点数**（`Set-NetIPInterface -InterfaceMetric`） | 默认路由的 **metric**（`ip route replace default … metric 10`） |
| "钉住某张网卡"去探测 | socket `Bind` 到该卡本机 IP | `SO_BINDTODEVICE`（无权限时自动退化成绑定源 IP） |
| 凭据存储 | Windows DPAPI 加密 | `~/.config/net-switch/campus.json`，权限 **600**，密码 base64（可用 `NETSWITCH_PASSWORD` 环境变量覆盖） |
| 开机/定时 | 计划任务（登录触发 / 每日 23:30 / 07:00） | systemd：`net-switch-campus.service`（开机即认证）+ 两个 timer |
| GUI | WinForms | tkinter |

撤销更干净：Linux 版只是**加一条 metric 更小的 default 路由**，撤销就是精确删掉那一条，不动别人的路由。

## 用法

```bash
python3 net-switch-linux.py status          # 只读：接口 / 出口 / 默认路由 / 配置
python3 net-switch-linux.py gui             # 图形界面填账号密码（需要 python3-tk）
python3 net-switch-linux.py login --wait-for-ip 40   # 只认证（开机用，等网卡拿 IP）
python3 net-switch-linux.py auto            # 单次判断 + 切换 + 兜底认证
python3 net-switch-linux.py settle --until wireddown --max-minutes 20
python3 net-switch-linux.py install         # 装 systemd 单元与 timer（需要 sudo）
python3 net-switch-linux.py uninstall
python3 net-switch-linux.py forget          # 删除保存的凭据
```

任何命令都能加 `--dry-run`（放在子命令前后都行）：只打印将要执行的命令和判定结果，不动任何设置。

## systemd（install 会写这几个）

| 单元 | 作用 |
|---|---|
| `net-switch-campus.service` | 开机（multi-user.target）立刻认证；脚本自己会等网卡拿到 IP（最多 40 秒） |
| `net-switch-night.timer` → `net-switch-night.service` | 每天 23:30 起，等到**有线真的断了**就切热点，跑完即退 |
| `net-switch-morning.timer` → `net-switch-morning.service` | 每天 07:00 起，等到**有线恢复**就切回有线优先，跑完即退 |

`Persistent=true`：机器关机错过了时间点，开机后补跑一次。

## 依赖

- 改路由需要 root：`install` 和自动切换用 `sudo -n`（要求已配 NOPASSWD，或直接用 root 跑）。只读的 `status`/探测不需要 root。
- GUI 需要 `python3-tk`：`sudo apt install python3-tk`
- 探测/认证只用标准库；`ping` 仅作 ICMP 兜底（可选）

## 已知差异（相对 Windows 版 v1.1.3）

Windows 版已加入"从门户劫持页发现校园侧地址/MAC（wlanuserip/mac/nasip），并用它认证 + 认证后复查是否仍被拦截"。
**Linux 版尚未移植**：它仍用本机地址作为 `wlan_user_ip`。直接接校园网口时没问题；
若设备接在宿舍路由器后面（本机是 192.168.x.x），会出现"接口报成功但出口没放行"的假成功现象。
