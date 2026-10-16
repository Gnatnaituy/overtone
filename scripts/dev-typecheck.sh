#!/bin/bash
# 串行化类型检查（debug 编译，不打包 .app）。
#
# 为什么需要它：多人/多 agent 并行改代码时，两个 `swift build` 同时写同一个 .build 目录
# 会互相破坏增量状态（报出与实际代码无关的编译错误）。这里用目录锁把编译串行化，
# 后到者排队等待，等锁超时（默认 600s）则报错退出，不静默跳过检查。
#
# 用法：./scripts/dev-typecheck.sh            # 全量类型检查，只打印错误/警告尾部
#      ./scripts/dev-typecheck.sh 2>&1 | tee /tmp/x.log
set -uo pipefail
cd "$(dirname "$0")/.."

LOCK_DIR=".build/.typecheck.lock"
WAIT_SECONDS="${TYPECHECK_LOCK_WAIT:-900}"
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # 陈旧锁清理：持有者进程已消失（pid 文件里的进程不存在）时接管
    if [ -f "$LOCK_DIR/pid" ]; then
        holder="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -rf "$LOCK_DIR"
            continue
        fi
    fi
    if [ "$waited" -ge "$WAIT_SECONDS" ]; then
        echo "✗ 等待编译锁超时（${WAIT_SECONDS}s）：$LOCK_DIR" >&2
        exit 3
    fi
    sleep 5
    waited=$((waited + 5))
done
echo $$ > "$LOCK_DIR/pid"
trap 'rm -rf "$LOCK_DIR"' EXIT

# `@State` 等宏的实现随 Xcode 提供；只有 Command Line Tools 时用仓库内替身插件兜底
# （原理见 docs/build-notes.md 与 tools/SwiftUIMacrosShim/README.md）。
have_swiftui_macros() {
    local developer
    developer="$(xcode-select -p 2>/dev/null || true)"
    [ -n "$developer" ] || return 1
    [ -f "$developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] && return 0
    [ -f "$developer/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ] && return 0
    return 1
}

MACRO_FLAGS=()
if have_swiftui_macros; then
    :
else
    SHIM_BIN="$(swift build -c release --package-path tools/SwiftUIMacrosShim --disable-sandbox --show-bin-path 2>/dev/null || true)"
    if [ -z "$SHIM_BIN" ] || [ ! -f "${SHIM_BIN}/SwiftUIMacros" ]; then
        swift build -c release --package-path tools/SwiftUIMacrosShim --disable-sandbox >/tmp/shim-build.log 2>&1 || {
            echo "✗ 替身宏插件构建失败，见 /tmp/shim-build.log" >&2; exit 4; }
        SHIM_BIN="$(swift build -c release --package-path tools/SwiftUIMacrosShim --disable-sandbox --show-bin-path)"
    fi
    MACRO_FLAGS=(-Xswiftc -load-plugin-executable -Xswiftc "${SHIM_BIN}/SwiftUIMacros#SwiftUIMacros")
fi

swift build --disable-sandbox ${MACRO_FLAGS[@]+"${MACRO_FLAGS[@]}"}
