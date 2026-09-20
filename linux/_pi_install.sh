#!/bin/bash
set -u
SRC="$HOME/net-switch-linux.py"
DST="/opt/net-switch"
echo "########## 1) 安装到 $DST（root 所有，其余只读）##########"
sudo install -d -m 755 "$DST"
sudo install -m 755 -o root -g root "$SRC" "$DST/net-switch-linux.py"
ls -la "$DST"
echo "版本: $(sudo "$DST/net-switch-linux.py" --version 2>&1 || true)"
echo
echo "########## 2) 跑 install（写 systemd 单元 + enable --now）##########"
sudo python3 "$DST/net-switch-linux.py" install
echo "退出码: $?"
echo
echo "########## 3) 回读单元内容（ExecStart 路径 / Persistent）##########"
systemctl cat net-switch-campus.service net-switch-night.timer net-switch-night.service net-switch-morning.timer 2>&1 | sed 's/^/  /'
echo
echo "########## 4) 定时器清单 ##########"
systemctl list-timers 'net-switch*' --all --no-pager 2>&1 | sed 's/^/  /'
echo
echo "########## 5) 四个单元是否 enabled / active ##########"
for u in net-switch-campus.service net-switch-night.timer net-switch-morning.timer; do
  printf "  %-32s enabled=%s active=%s\n" "$u" "$(systemctl is-enabled $u 2>&1)" "$(systemctl is-active $u 2>&1)"
done
echo
echo "########## 6) 手动触发一次"开机认证"服务，看日志 ##########"
sudo systemctl start net-switch-campus.service
sleep 3
systemctl status net-switch-campus.service --no-pager -l 2>&1 | tail -12 | sed 's/^/  /'
echo "--- /opt/net-switch/net-switch.log ---"; sudo tail -6 "$DST/net-switch.log" | sed 's/^/  /'
echo
echo "########## 7) sudo 下的配置路径识别（SUDO_USER 生效）##########"
sudo python3 "$DST/net-switch-linux.py" status 2>&1 | grep -a "配置" | sed 's/^/  /'
echo
echo "########## 8) root 身份跑一次夜间判定（dry-run，不动路由）##########"
sudo python3 "$DST/net-switch-linux.py" settle --until wireddown --max-minutes 0 --interval 5 --dry-run
echo
echo "########## 9) 确认没有留下常驻进程 ##########"
ps -eo pid,etime,cmd | grep -a "net-switch" | grep -v grep || echo "  无常驻进程 ✓"
