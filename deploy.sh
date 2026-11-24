#!/bin/sh
# 部署本仓库到 Anbernic RG DS（TF 卡 /mnt/mmc），与原版 rgds-lua-demo 并存互不覆盖
# 用法: ./deploy.sh [目标]        默认 rgds（mDNS: rgds.local）
#
# 目录布局（全部在 TF 卡上，自包含）：
#   /mnt/mmc/Roms/APPS/RGDS-Agents.sh               ← 前端菜单入口
#   /mnt/mmc/Roms/APPS/RGDS-Agents/main.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/conf.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/screens.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/screen-launch.sh
#   /mnt/mmc/Roms/APPS/RGDS-Agents/subscreen.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/evdev.lua         ← 下屏触摸（event1），Weston 不把点按派给 SDL
#   /mnt/mmc/Roms/APPS/RGDS-Agents/micwave.lua       ← 麦克风波形/电平/按键录音（主线程）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/micthread.lua     ← 录音线程（OpenAL → 共享环形缓冲）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/alsoft.conf       ← OpenAL 私有配置：录音走 dsnoop（只传给 love，不传给菜单）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/stt.lua          ← 常驻 SenseVoice 助手（游戏启动/退出时拉起和关掉）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/sttthread.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/aid.lua          ← MiniMax 对话（游戏启动/退出时拉起和关掉 rgds-aid）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/aidthread.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/rgds-aid.py      ← 本机 sidecar，密钥在设备 config 里，不进仓库
#   /mnt/mmc/Roms/APPS/RGDS-Agents/stt/             ← sv-helper、两个 sherpa .so、model.int8.onnx、tokens.txt
#   /mnt/mmc/Roms/APPS/RGDS-Agents/fonts/          ← 思源黑体，信息面板和主屏字幕用
#   /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh
#   /mnt/mmc/Roms/APPS/RGDS-Agents/bin/love         ← LÖVE 11.5 aarch64
#   /mnt/mmc/Roms/APPS/RGDS-Agents/lib/*.so         ← 系统缺失的 3 个 so
#   /mnt/mmc/Roms/APPS/Imgs/RGDS-Agents.png         ← 菜单图标
# 前端只把 APPS 根目录下的 *.sh 列为条目，子目录里的 run-via-menu.sh 不会出现在菜单里。

set -e

TARGET="${1:-rgds}"
NAME="RGDS-Agents"
APPS="/mnt/mmc/Roms/APPS"
GAME="$APPS/$NAME"
SCRIPT="$APPS/$NAME.sh"

echo ">> 目标: $TARGET"
echo ">> 复制应用代码"
ssh "$TARGET" "mkdir -p '$GAME/bin' '$GAME/lib' '$APPS/Imgs'"
scp -q main.lua conf.lua subscreen.lua screens.lua screen-launch.sh evdev.lua touchpoll.lua touchthread.lua micwave.lua micthread.lua stt.lua sttthread.lua aid.lua aidthread.lua rgds-aid.py alsoft.conf run-via-menu.sh "$TARGET:$GAME/"
ssh "$TARGET" "chmod +x '$GAME/run-via-menu.sh' '$GAME/screen-launch.sh'"

if [ -f fonts/SourceHanSansCN-Regular.otf ]; then
  echo ">> 复制中日文字体"
  ssh "$TARGET" "mkdir -p '$GAME/fonts'"
  scp -q fonts/SourceHanSansCN-Regular.otf "$TARGET:$GAME/fonts/"
fi

if [ -x stt/sv-helper ]; then
  echo ">> 复制语音识别助手和模型（模型约 229MB，大小相同则跳过）"
  ssh "$TARGET" "mkdir -p '$GAME/stt/lib'"
  scp -q stt/sv-helper stt/tokens.txt "$TARGET:$GAME/stt/"
  scp -q stt/lib/libonnxruntime.so stt/lib/libsherpa-onnx-c-api.so "$TARGET:$GAME/stt/lib/"
  ssh "$TARGET" "chmod +x '$GAME/stt/sv-helper'"
  local_size=$(wc -c < stt/model.int8.onnx)
  remote_size=$(ssh "$TARGET" "wc -c < '$GAME/stt/model.int8.onnx' 2>/dev/null" || echo 0)
  if [ "$local_size" != "$remote_size" ]; then
    scp -q stt/model.int8.onnx "$TARGET:$GAME/stt/model.int8.onnx"
  else
    echo ">> 模型已在掌机上，跳过"
  fi
fi

echo ">> 从掌机 /opt/love 复制运行时（若不存在则提示）"
ssh "$TARGET" "
set -e
if [ ! -x /opt/love/love-11.5 ]; then
  echo '!! /opt/love/love-11.5 不存在。先安装 LÖVE 11.5 aarch64：'
  echo '   curl -sLO https://deb.debian.org/debian/pool/main/l/love/love_11.5-4_arm64.deb'
  echo '   dpkg-deb -x love_11.5-4_arm64.deb /tmp/lv && cp /tmp/lv/usr/bin/love-11.5 /opt/love/'
  exit 1
fi
cp /opt/love/love-11.5 '$GAME/bin/love'
for so in libluajit-5.1.so.2 libmodplug.so.1 libtheoradec.so.2; do
  src=/opt/love/lib/\$so
  case \$so in
    libmodplug.so.1) [ -f \$src ] || src=/opt/love/lib/libmodplug.so.1.0.0 ;;
    libtheoradec.so.2) [ -f \$src ] || src=/opt/love/lib/libtheoradec.so.2.1.1 ;;
  esac
  [ -f \"\$src\" ] && cp \"\$src\" '$GAME/lib/'\$so
done
chmod +x '$GAME/bin/love'
"

echo ">> 安装菜单入口脚本"
LAUNCHER_TMP="$(mktemp)"
cat > "$LAUNCHER_TMP" <<'LAUNCHER'
#!/bin/sh
# RGDS-Agents 启动器（由前端菜单调用，stdout 被丢弃，故另存日志）
SHDIR="$(cd "$(dirname "$0")" && pwd)"
export HOME=/root
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
export RGDS_LOG=/tmp/RGDS-Agents.log
"$SHDIR/RGDS-Agents/screen-launch.sh" run -- \
    env \
    LD_LIBRARY_PATH="$SHDIR/RGDS-Agents/lib:$LD_LIBRARY_PATH" \
    ALSOFT_CONF="$SHDIR/RGDS-Agents/alsoft.conf" \
    SDL_VIDEO_DOUBLE_BUFFER=1 \
    "$SHDIR/RGDS-Agents/bin/love" "$SHDIR/RGDS-Agents" "$@" \
    > "$RGDS_LOG" 2>&1
LAUNCHER
scp -q "$LAUNCHER_TMP" "$TARGET:$SCRIPT"
rm -f "$LAUNCHER_TMP"
ssh "$TARGET" "chmod +x '$SCRIPT'"

if [ -f icon.png ]; then
  echo ">> 安装菜单图标"
  scp -q icon.png "$TARGET:$APPS/Imgs/$NAME.png"
fi

echo ">> 校验"
ssh "$TARGET" "ls -l '$SCRIPT'; echo; ls -lR '$GAME' | head -20; echo; df -h /mnt/mmc | tail -1"

echo ">> 完成。从掌机菜单 APPS 里运行 $NAME.sh"
echo "   SSH 在菜单保持运行时后台启动: ssh $TARGET '$GAME/run-via-menu.sh'"
echo "   要重新启动，先 SIGTERM 掉 love 进程，等 muos2.bin 在运行后再执行。日志 /tmp/RGDS-Agents.log"
echo "   ALSA 和 event3 仍由菜单持有。"
