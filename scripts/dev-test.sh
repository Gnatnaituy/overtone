#!/bin/bash
# 跑内置自检（纯函数断言：authx 签名 / 地址规范化 / 时长 / 歌词 / 合并规则），
# 与 dev-typecheck.sh 共用同一把目录锁。
#
# 为什么复用同一把锁：`swift test` 同样会写 .build/，与另一个 `swift build` 并发
# 会互相破坏增量状态（表现为与代码无关的编译错误）。所以这里等同一把锁，
# 只是拿到锁之后跑的命令不同。
#
# 用法：./scripts/dev-test.sh                       # 跑全部单测
#      ./scripts/dev-test.sh --filter Feiniu        # 只跑某个类
set -uo pipefail
cd "$(dirname "$0")/.."

LOCK_DIR=".build/.typecheck.lock"
WAIT_SECONDS="${TYPECHECK_LOCK_WAIT:-900}"
waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
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
# （与 dev-typecheck.sh 同一套逻辑，见 docs/build-notes.md）。
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

# CLT 没有 XCTest，所以断言内建在可执行文件里（Sources/JellyfinMac/Diagnostics/SelfTest.swift）：
# 构建并运行 `--selftest`，失败返回非 0。
swift build --disable-sandbox ${MACRO_FLAGS[@]+"${MACRO_FLAGS[@]}"} >/dev/null || {
    echo "✗ 构建失败，先修编译错误" >&2; exit 5; }
BIN="$(swift build --disable-sandbox ${MACRO_FLAGS[@]+"${MACRO_FLAGS[@]}"} --show-bin-path)"
"$BIN/JellyfinMac" --selftest "$@"
