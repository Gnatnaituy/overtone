#!/bin/bash
# 监听源码变化，自动重新打包并覆盖 build/Overtone.app
# 用法：
#   ./scripts/watch-build.sh            # 打包后若应用在运行则自动重启
#   ./scripts/watch-build.sh --no-restart  # 只打包不重启
#   ./scripts/watch-build.sh --once     # 立即打包一次后退出（等价于手动打包）
#
# 工作方式：每 2 秒对 Sources/ 与 Package.swift 的内容做一次 md5 快照，
# 有变化则执行 build-app.sh（覆盖旧版本 .app）。零外部依赖。
set -uo pipefail
cd "$(dirname "$0")/.."

RESTART=1
ONCE=0
for arg in "$@"; do
    case "$arg" in
        --no-restart) RESTART=0 ;;
        --once) ONCE=1 ;;
    esac
done

snapshot() {
    find Sources Package.swift -type f -exec md5 -q {} \; 2>/dev/null | md5 -q
}

build() {
    echo ""
    echo "▶ $(date '+%H:%M:%S') 检测到源码变更，开始打包..."
    if ./scripts/build-app.sh; then
        # 进程名取自可执行文件名（Swift target 仍叫 JellyfinMac），不是 App 显示名
        if [ "$RESTART" = "1" ] && pgrep -x JellyfinMac >/dev/null; then
            echo "▶ 应用正在运行，重启以加载新版本..."
            pkill -x JellyfinMac
            sleep 1
            open build/Overtone.app
            echo "✅ 已重启 build/Overtone.app"
        else
            echo "✅ 打包完成（未重启）: build/Overtone.app"
        fi
    else
        echo "❌ 打包失败，保持旧版本不变"
    fi
}

if [ "$ONCE" = "1" ]; then
    build
    exit 0
fi

echo "📡 监听中（每 2 秒）：Sources/ 和 Package.swift 有改动将自动打包覆盖 build/Overtone.app"
echo "   Ctrl+C 退出"
LAST=""
while true; do
    SIG=$(snapshot)
    if [ "$SIG" != "$LAST" ]; then
        if [ -n "$LAST" ]; then
            build
        fi
        LAST="$SIG"
    fi
    sleep 2
done
