#!/bin/bash
# 视觉验证助手（开发/验收用，不参与打包）：
# 启动指定的 Overtone.app，等窗口出现后按窗口 id 截图。
#
# 风格 / 深浅色用**启动参数域**传入（`-settings.visualStyle 纸墨`），不写用户偏好：
# UserDefaults 的 argument domain 优先级最高、只在本次进程内生效，进程退出即消失。
#
# ⚠️ 不要用 `defaults write` / `CFFIXED_USER_HOME` 来"隔离"偏好：cfprefsd 是按用户
# 共享的守护进程，它并不认 CFFIXED_USER_HOME，`defaults write com.jellyfin.mac-client`
# 会**直接改到使用者的真实偏好**（本项目 2026-10-13 踩过一次）。启动参数是唯一干净的开关。
#
# 用法：
#   ./scripts/dev-shot.sh --out /tmp/ot-shots/paper-home.png --style 纸墨 --theme 深色
#   ./scripts/dev-shot.sh --app /tmp/overtone-before.app --out /tmp/ot-shots/before.png
#   --style/--theme 省略即沿用当前偏好；--keep 保留进程（默认截完就退出）
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Overtone.app"
OUT="/tmp/ot-shots/shot-$(date +%H%M%S).png"
WAIT=10
KEEP=0
STYLE=""
THEME=""
SIZE=""

while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP="$2"; shift 2 ;;
        --out) OUT="$2"; shift 2 ;;
        --style) STYLE="$2"; shift 2 ;;
        --theme) THEME="$2"; shift 2 ;;
        --size) SIZE="$2"; shift 2 ;;
        --wait) WAIT="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        *) echo "用法: $0 [--app X.app] [--out x.png] [--style 玻璃|纸墨] [--theme 浅色|深色|跟随系统] [--size 1109x802] [--wait 秒] [--keep]" >&2; exit 2 ;;
    esac
done

[ -x "$APP/Contents/MacOS/JellyfinMac" ] || { echo "✗ 找不到可执行文件：$APP" >&2; exit 3; }

# 启动参数域覆盖（不落盘）。
# ⚠️ `settings.visualStyle` 存的是 `VisualStyle.rawValue`（`glass` / `paper`），
# 不是界面上的「玻璃 / 纸墨」——传中文会解析失败并静默回落 glass（踩过）。
case "$STYLE" in
    玻璃) STYLE=glass ;;
    纸墨) STYLE=paper ;;
esac
ARGV=()
[ -n "$STYLE" ] && ARGV+=(-settings.visualStyle "$STYLE")
[ -n "$THEME" ] && ARGV+=(-settings.theme "$THEME")
ARGV+=(-ApplePersistenceIgnoreState YES)

# 窗口枚举小工具（按 pid 过滤，编译一次缓存在 /tmp）
if [ ! -x /tmp/ot-winlist ]; then
    cat > /tmp/ot-winlist.swift <<'SWIFT'
import CoreGraphics
import Foundation
let pid = Int(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "") ?? -1
let opts = CGWindowListOption(arrayLiteral: .optionOnScreenOnly, .excludeDesktopElements)
if let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] {
    for w in list {
        guard let wpid = w[kCGWindowOwnerPID as String] as? Int, wpid == pid else { continue }
        let layer = w[kCGWindowLayer as String] as? Int ?? 0
        guard layer == 0 else { continue }
        let num = w[kCGWindowNumber as String] as? Int ?? -1
        let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        let width = bounds["Width"] as? Double ?? 0
        guard width > 200 else { continue }
        print(num)
    }
}
SWIFT
    swiftc -O /tmp/ot-winlist.swift -o /tmp/ot-winlist 2>/dev/null || { echo "✗ 窗口枚举工具编译失败" >&2; exit 4; }
fi

BIN="$APP/Contents/MacOS/JellyfinMac"
# 起新实例前，先收掉上一轮由本脚本启动的同路径实例（不动 /Applications 里的那个）
pkill -f "^$BIN" 2>/dev/null || true
sleep 1

"$BIN" ${ARGV[@]+"${ARGV[@]}"} >/tmp/ot-app.log 2>&1 &
APP_PID=$!
echo "▶ 启动 $APP (pid $APP_PID ${ARGV[*]:-})"

WID=""
for _ in $(seq 1 "$WAIT"); do
    sleep 1
    WID="$(/tmp/ot-winlist "$APP_PID" | head -1 || true)"
    [ -n "$WID" ] && break
done
if [ -z "$WID" ]; then
    echo "✗ 未找到窗口（$WAIT 秒）。日志尾部：" >&2
    tail -20 /tmp/ot-app.log >&2 || true
    kill "$APP_PID" 2>/dev/null || true
    exit 5
fi

# 可选：把窗口钉成固定尺寸/位置 —— 视觉回归对比要求两张图尺寸一致
# （尺寸不同像素 diff 直接不可比）。走 System Events 设 AX 属性。
if [ -n "$SIZE" ]; then
    SW="${SIZE%x*}"
    SH="${SIZE#*x}"
    osascript >/dev/null 2>&1 <<OSA || echo "⚠ 窗口尺寸设置失败，沿用当前尺寸" >&2
tell application "System Events"
    set frontmost of (first process whose unix id is $APP_PID) to true
    delay 0.4
    set win to first window of (first process whose unix id is $APP_PID)
    set position of win to {60, 60}
    set size of win to {$SW, $SH}
end tell
OSA
    sleep 1
    WID="$(/tmp/ot-winlist "$APP_PID" | head -1 || true)"
fi

sleep 3   # 等首屏数据（网络取图/列表）稳定
mkdir -p "$(dirname "$OUT")"
screencapture -x -o -l "$WID" "$OUT"
echo "✅ 截图: $OUT (window $WID)"

if [ "$KEEP" -eq 0 ]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
fi
