#!/bin/sh
# 部署本仓库到 Anbernic RG DS（TF 卡 /mnt/mmc），与原版 rgds-lua-demo 并存互不覆盖
# 用法: ./deploy.sh [目标]        默认 rgds（mDNS: rgds.local）
#
# 目录布局（全部在 TF 卡上，自包含）：
#   /mnt/mmc/Roms/APPS/RGDS-Agents.sh               ← 前端菜单入口
#   /mnt/mmc/Roms/APPS/RGDS-Agents/main.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/conf.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/subscreen.lua     ← 第二块屏上的信息面板窗口
#   /mnt/mmc/Roms/APPS/RGDS-Agents/evdev.lua         ← 下屏触摸（event1），Weston 不把点按派给 SDL
#   /mnt/mmc/Roms/APPS/RGDS-Agents/micwave.lua       ← 麦克风波形/电平/按键录音（主线程）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/micthread.lua     ← 录音线程（OpenAL → 共享环形缓冲）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/alsoft.conf       ← OpenAL 私有配置：录音走 dsnoop（启动脚本 export ALSOFT_CONF）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/stt.lua          ← 常驻 SenseVoice 助手（游戏启动/退出时拉起和关掉）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/sttthread.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/aid.lua          ← MiniMax 对话（游戏启动/退出时拉起和关掉 rgds-aid）
#   /mnt/mmc/Roms/APPS/RGDS-Agents/aidthread.lua
#   /mnt/mmc/Roms/APPS/RGDS-Agents/rgds-aid.py      ← 本机 sidecar，密钥在设备 config 里，不进仓库
#   /mnt/mmc/Roms/APPS/RGDS-Agents/stt/             ← sv-helper、两个 sherpa .so、model.int8.onnx、tokens.txt
#   /mnt/mmc/Roms/APPS/RGDS-Agents/fonts/          ← 思源黑体，信息面板和主屏字幕用
#   /mnt/mmc/Roms/APPS/RGDS-Agents/run-via-menu.sh  ← SSH 按菜单流程启动
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
SSH_KEY="${RGDS_SSH_KEY:-$HOME/.ssh/id_ed25519}"

rssh() {
  if [ -f "$SSH_KEY" ]; then
    ssh -o IdentitiesOnly=yes -i "$SSH_KEY" "$@"
  else
    ssh "$@"
  fi
}

rscp() {
  if [ -f "$SSH_KEY" ]; then
    scp -q -o IdentitiesOnly=yes -i "$SSH_KEY" "$@"
  else
    scp -q "$@"
  fi
}

file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
    return 0
  fi
  return 1
}

remote_opencode_digest() {
  rssh "$1" "if [ ! -f '$2' ]; then echo MISSING; elif command -v sha256sum >/dev/null 2>&1; then sha256sum '$2' | awk '{print \$1}'; elif command -v shasum >/dev/null 2>&1; then shasum -a 256 '$2' | awk '{print \$1}'; else echo NOSHA; fi"
}

opencode_should_skip_upload() {
  remote_path="$1"
  if local_sha="$(file_sha256 opencode/bin/opencode)"; then
    remote_sha="$(remote_opencode_digest "$TARGET" "$remote_path")"
    remote_sha="$(printf '%s' "$remote_sha" | tr -d '[:space:]')"
    if [ "$remote_sha" = "$local_sha" ]; then
      return 0
    fi
    if [ "$remote_sha" != "NOSHA" ]; then
      return 1
    fi
  fi
  local_size=$(wc -c < opencode/bin/opencode | tr -d '[:space:]')
  remote_size=$(rssh "$TARGET" "[ -f '$remote_path' ] && wc -c < '$remote_path' | tr -d '[:space:]' || echo 0")
  remote_size=$(printf '%s' "$remote_size" | tr -d '[:space:]')
  [ "$local_size" = "$remote_size" ]
}

echo ">> 目标: $TARGET"
echo ">> 复制应用代码"
rssh "$TARGET" "mkdir -p '$GAME/bin' '$GAME/lib' '$APPS/Imgs'"
rscp main.lua conf.lua subscreen.lua evdev.lua touchpoll.lua touchthread.lua micwave.lua micthread.lua stt.lua sttthread.lua aid.lua aidthread.lua rgds-aid.py alsoft.conf run-via-menu.sh "$TARGET:$GAME/"
rssh "$TARGET" "chmod +x '$GAME/run-via-menu.sh'"

if [ -d opencode ]; then
  echo ">> 复制 OpenCode 服务与配置脚本"
  rssh "$TARGET" "mkdir -p '$GAME/opencode/bin'"
  rscp opencode/opencode-service.sh opencode/opencode-setup-web.py opencode/AGENTS.md "$TARGET:$GAME/opencode/"
  rssh "$TARGET" "chmod +x '$GAME/opencode/opencode-service.sh' '$GAME/opencode/opencode-setup-web.py'"
  if [ -f opencode/bin/opencode ]; then
    if opencode_should_skip_upload "$GAME/opencode/bin/opencode"; then
      echo ">> opencode 二进制已在掌机上，跳过"
    else
      echo ">> 复制 opencode 二进制"
      rscp opencode/bin/opencode "$TARGET:$GAME/opencode/bin/opencode.new"
      rssh "$TARGET" "chmod +x '$GAME/opencode/bin/opencode.new' && mv -f '$GAME/opencode/bin/opencode.new' '$GAME/opencode/bin/opencode'"
    fi
  elif rssh "$TARGET" "[ -f '$GAME/opencode/bin/opencode' ]"; then
    echo ">> 本地无 opencode 二进制，掌机上已有，跳过"
  else
    echo "!! 缺少 opencode/bin/opencode（本地和掌机都没有）。先运行 ./setup-opencode.sh，再重新部署。" >&2
    exit 1
  fi
  if rssh "$TARGET" "[ -d /etc/init.d ] && [ -w /etc/init.d ]"; then
    echo ">> 安装开机自启脚本 /etc/init.d/S55opencode"
    INIT_TMP="$(mktemp)"
    cat > "$INIT_TMP" <<INIT_EOF
#!/bin/sh
SERVICE="$GAME/opencode/opencode-service.sh"
[ -x "\$SERVICE" ] || exit 0
exec "\$SERVICE" "\$@"
INIT_EOF
    rscp "$INIT_TMP" "$TARGET:/etc/init.d/S55opencode"
    rm -f "$INIT_TMP"
    rssh "$TARGET" "chmod +x /etc/init.d/S55opencode"
  fi
fi

if [ -f fonts/SourceHanSansCN-Regular.otf ]; then
  echo ">> 复制中日文字体"
  rssh "$TARGET" "mkdir -p '$GAME/fonts'"
  rscp fonts/SourceHanSansCN-Regular.otf "$TARGET:$GAME/fonts/"
fi

if [ -x stt/sv-helper ]; then
  echo ">> 复制语音识别助手和模型（模型约 229MB，大小相同则跳过）"
  rssh "$TARGET" "mkdir -p '$GAME/stt/lib'"
  rscp stt/sv-helper stt/tokens.txt "$TARGET:$GAME/stt/"
  rscp stt/lib/libonnxruntime.so stt/lib/libsherpa-onnx-c-api.so "$TARGET:$GAME/stt/lib/"
  rssh "$TARGET" "chmod +x '$GAME/stt/sv-helper'"
  local_size=$(wc -c < stt/model.int8.onnx)
  remote_size=$(rssh "$TARGET" "wc -c < '$GAME/stt/model.int8.onnx' 2>/dev/null" || echo 0)
  if [ "$local_size" != "$remote_size" ]; then
    rscp stt/model.int8.onnx "$TARGET:$GAME/stt/model.int8.onnx"
  else
    echo ">> 模型已在掌机上，跳过"
  fi
fi

echo ">> 从掌机 /opt/love 复制运行时（若不存在则提示）"
rssh "$TARGET" "
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
export LD_LIBRARY_PATH="$SHDIR/RGDS-Agents/lib:$LD_LIBRARY_PATH"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/var/run}"
export SDL_VIDEO_DOUBLE_BUFFER=1
export RGDS_LOG=/tmp/RGDS-Agents.log
export ALSOFT_CONF="$SHDIR/RGDS-Agents/alsoft.conf"
cd "$SHDIR/RGDS-Agents" || exit 1
"$SHDIR/RGDS-Agents/bin/love" . "$@" > "$RGDS_LOG" 2>&1
LAUNCHER
rscp "$LAUNCHER_TMP" "$TARGET:$SCRIPT"
rm -f "$LAUNCHER_TMP"
rssh "$TARGET" "chmod +x '$SCRIPT'"

if [ -f icon.png ]; then
  echo ">> 安装菜单图标"
  rscp icon.png "$TARGET:$APPS/Imgs/$NAME.png"
fi

echo ">> 校验"
rssh "$TARGET" "ls -l '$SCRIPT'; echo; ls -lR '$GAME' | head -20; echo; df -h /mnt/mmc | tail -1"

echo ">> 完成。从掌机菜单 APPS 里运行 $NAME.sh"
echo "   SSH 按菜单流程启动（前端需在菜单界面）: ssh $TARGET '$GAME/run-via-menu.sh'"
echo "   不要直接 ssh 执行 $SCRIPT：菜单仍占着音频和手柄，app 会无声且按键被菜单同时响应"
