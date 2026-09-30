#!/bin/bash
# 生成 App 图标：由 Resources/AppIcon-1024.png（1024x1024 主图）打包成 build/AppIcon.icns
#
# 主图规格：macOS 标准图标（824x824 圆角方块 + 四周 100px 透明边距）。
# 需要换图标时，把新的预览图放到 Resources/icon-mockup-source.jpg（或 png），
# 再执行 scripts/make-icon.py 重新生成主图，然后跑本脚本。
set -euo pipefail
cd "$(dirname "$0")/.."

MASTER="Resources/AppIcon-1024.png"
MOCKUP="Resources/icon-mockup-source.jpg"
mkdir -p build

# 预览图比主图新时自动重做主图（需要带 Pillow 的 python3，缺失则跳过）
if [ -f "$MOCKUP" ] && [ "$MOCKUP" -nt "$MASTER" ]; then
    if python3 -c "import PIL" 2>/dev/null; then
        echo "▶ 预览图有更新，重新生成 1024 主图..."
        python3 scripts/make-icon.py "$MOCKUP" "$MASTER"
    else
        echo "! 预览图比主图新，但 python3 缺少 Pillow，沿用现有主图"
    fi
fi

if [ -f "$MASTER" ]; then
    ICON_PNG="$MASTER"
else
    # 兜底：没有主图时用代码画一个（旧版紫色渐变 + 播放三角）
    echo "! 未找到 $MASTER，回退到代码绘制图标"
    ICON_PNG="build/icon_1024.png"
    swift scripts/generate-icon.swift "$ICON_PNG"
fi

echo "▶ 生成 App 图标..."
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$ICON_PNG" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$ICON_PNG" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$ICON_PNG" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$ICON_PNG" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$ICON_PNG" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$ICON_PNG" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$ICON_PNG" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o build/AppIcon.icns
rm -rf "$ICONSET"
echo "✓ 图标已生成: build/AppIcon.icns"
