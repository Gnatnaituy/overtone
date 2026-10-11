# 应用图标

图标主图是 `Resources/AppIcon-1024.png`：1024x1024、**满出血不透明**。macOS 会自己把
App 图标裁成系统标准形状（824x824 连续曲率圆角方块 + 系统投影），所以主图不需要自己做圆角。

## 换图标

把新的预览图（浅色背景上的圆角方块图标，右下角有文字水印也没关系）覆盖到
`Resources/icon-mockup-source.jpg`，然后：

```bash
python3 scripts/make-icon.py Resources/icon-mockup-source.jpg Resources/AppIcon-1024.png
./scripts/generate-icon.sh   # 打包成 build/AppIcon.icns
./scripts/build-app.sh       # 重新组装 build/Overtone.app
```

`make-icon.py` 需要 Pillow（`pip3 install pillow`）；`generate-icon.sh` 检测到预览图比主图新时
会自动调用它，机器上没有 Pillow 就跳过（沿用现有主图）。

## 坑：主图不能留透明区域

**主图不能留透明区域**（整张 1024x1024 都要有颜色）。带透明像素的 icns 在当前 macOS 上
会被系统额外套一层浅灰底板并把图标缩小（本项目旧图标也有这个问题），满出血不透明图才是正确的输入。
