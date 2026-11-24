#!/bin/sh
# ALSA 和 event3 仍由菜单持有。
#
# 用法（在掌机上）: run-via-menu.sh [app 参数...]     例: run-via-menu.sh --selftest
# 从电脑:          ssh rgds /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh

APP_SH="$(cd "$(dirname "$0")/.." && pwd)/RGDS-Agents.sh"
LOVE_BIN="$(cd "$(dirname "$0")" && pwd)/bin/love"

[ -x "$APP_SH" ] || { echo "!! 找不到启动脚本 $APP_SH" >&2; exit 1; }

if [ -z "$(pidof muos2.bin)" ]; then
    echo "!! muos2.bin 没在运行（可能已有其他 app 在前台），请先退出当前 app 回到菜单" >&2
    exit 1
fi

trap '' HUP
"$APP_SH" "$@" >/dev/null 2>&1 &
trap - HUP

i=0
while [ $i -lt 20 ]; do
    PID="$(pgrep -f "^$LOVE_BIN" | head -n 1)"
    if [ -n "$PID" ]; then
        echo ">> 已启动: love PID $PID（日志 /tmp/RGDS-Agents.log）"
        exit 0
    fi
    sleep 0.5
    i=$((i + 1))
done
echo "!! 10 秒内没看到 love 进程；查看 /tmp/RGDS-Agents.log" >&2
exit 1
