#!/bin/bash
# 构建 Overtone.app（release 编译 + 图标 + Info.plist + 临时签名）
set -euo pipefail
cd "$(dirname "$0")/.."

# 产品名（.app 名字 + 访达/启动台显示名）。内部可执行文件名仍是 Swift target 名 JellyfinMac，
# 两者解耦 —— 改产品名不动 bundle ID，所以钥匙串登录态与本地播放列表都不受影响。
APP_NAME="Overtone"
APP_DIR="build/$APP_NAME.app"

# `@State` 的宏实现（libSwiftUIMacros.dylib）随 Xcode 提供。只装了 Command Line Tools 的机器上
# 没有它（swift build 会报 "external macro implementation type 'SwiftUIMacros.StateMacro' could
# not be found"），此时用仓库里的替身插件兜底，原理见 tools/SwiftUIMacrosShim/README.md。
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
    echo "▶ 使用工具链自带的 SwiftUI 宏插件"
else
    echo "▶ 工具链没有 SwiftUI 宏插件（未装 Xcode），构建替身插件…"
    swift build -c release --package-path tools/SwiftUIMacrosShim --disable-sandbox
    SHIM_BIN="$(swift build -c release --package-path tools/SwiftUIMacrosShim --show-bin-path)"
    MACRO_FLAGS=(-Xswiftc -load-plugin-executable -Xswiftc "${SHIM_BIN}/SwiftUIMacros#SwiftUIMacros")
fi

echo "▶ 编译 release..."
# --disable-sandbox：部分 macOS 环境下 SwiftPM 内部 sandbox-exec 会被系统拒绝
# ${MACRO_FLAGS[@]+…}：macOS 自带的 bash 3.2 在 set -u 下不接受空数组展开
swift build -c release --disable-sandbox ${MACRO_FLAGS[@]+"${MACRO_FLAGS[@]}"}

echo "▶ 组装 $APP_NAME.app..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
# 可执行文件名必须与 Swift target 名一致（见 Package.swift），与产品显示名无关
cp .build/release/JellyfinMac "$APP_DIR/Contents/MacOS/JellyfinMac"

# 图标（失败不阻塞）
if [ -f "build/AppIcon.icns" ]; then
    cp build/AppIcon.icns "$APP_DIR/Contents/Resources/"
fi

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Overtone</string>
    <key>CFBundleDisplayName</key><string>Overtone</string>
    <key>CFBundleIdentifier</key><string>com.jellyfin.mac-client</string>
    <key>CFBundleVersion</key><string>1.0.0</string>
    <key>CFBundleShortVersionString</key><string>1.0.0</string>
    <key>CFBundleExecutable</key><string>JellyfinMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.entertainment</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key><true/>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
</dict>
</plist>
PLIST

if [ -f "build/AppIcon.icns" ]; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP_DIR/Contents/Info.plist"
fi

# 临时签名（本机可运行）
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

echo "✅ 完成: $APP_DIR"
echo "   启动: open $APP_DIR"
