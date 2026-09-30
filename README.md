# Overtone（泛音）

原生 macOS Jellyfin 客户端，SwiftUI 编写，暗色主题设计。

> **关于名字**：Overtone 是「泛音」——基音之上叠加的谐波。官方客户端之外的另一层听感；中文名本身就是现成的音乐术语。本项目是**非官方**客户端，与 Jellyfin 项目无隶属关系。

## 功能

- **登录**：服务器地址 + 用户名/密码，记住会话（重启免登录），侧栏一键退出
- **首页**：继续观看（主视觉横幅 + 进度条卡片）、最新电影 / 剧集 / 单集
- **媒体库**：按库浏览（电影、剧集、音乐、混合、家庭视频…），支持分页加载
- **搜索**：工具栏搜索框，按类型分组展示结果
- **详情页**：背景图、海报、简介、评分、季选择器、单集列表
- **播放器**：原生 AVPlayer，±10 秒快进快退、进度条拖动、控制条自动隐藏、空格播放/暂停
- **进度同步**：播放进度每 10 秒上报到服务器，多端进度一致
- **直连优先**：容器/编码兼容时直接播放原始文件，否则自动走服务器转码（HLS）
- **独立音乐模块**：音乐库按艺术家/专辑浏览、专辑曲目列表顺序播放、全局迷你播放条（页面间不中断）、正在播放页（封面模糊背景、进度、音量控制）

## 环境要求

- macOS 13+（推荐 14）
- Xcode 15+（含 Swift 工具链）；只装 Command Line Tools 也能构建，见下方「没有 Xcode 时」

## 构建与运行

```bash
# 1. 生成图标并打包 .app（build/Overtone.app）
./scripts/generate-icon.sh
./scripts/build-app.sh

# 2. 启动
open build/Overtone.app
```

开发调试可直接：

```bash
swift run
```

## 没有 Xcode 时（SwiftUI 宏插件兜底）

`@State` 在这个 SDK 里是宏，宏的**实现** `libSwiftUIMacros.dylib` 随 Xcode 提供。只装了
Command Line Tools 的机器上它不存在，直接 `swift build` 会失败：

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

`scripts/build-app.sh` 会检测这种情况，自动构建并使用仓库内的替身插件
（`tools/SwiftUIMacrosShim`，基于 swift-syntax，把 `@State` 展开成等价的属性包装器代码），
因此**无需 Xcode 也能打包**。首次构建需要联网拉取 swift-syntax，细节与坑见
[tools/SwiftUIMacrosShim/README.md](tools/SwiftUIMacrosShim/README.md)。

注意：手工 `swift run` / `swift build` 不会带上插件参数，没装 Xcode 时请用 `./scripts/build-app.sh`。

## 打包与自动覆盖

修改代码后会自动重新打包并覆盖 `build/Overtone.app`（应用在运行时会被重启以加载新版）。

```bash
./scripts/build-app.sh          # 手动打包一次，覆盖旧版本
./scripts/watch-build.sh --once # 同上（监听脚本的"打包一次"入口）
```

`scripts/watch-build.sh` 也可以作为可选工具常驻监听源码变化自动打包（`pkill -f watch-build.sh` 停止），按需使用。

## 应用图标

图标主图是 `Resources/AppIcon-1024.png`：1024x1024、**满出血不透明**。macOS 会自己把
App 图标裁成系统标准形状（824x824 连续曲率圆角方块 + 系统投影），所以主图不需要自己做圆角。

换图标：把新的预览图（浅色背景上的圆角方块图标，右下角有文字水印也没关系）覆盖到
`Resources/icon-mockup-source.jpg`，然后：

```bash
python3 scripts/make-icon.py Resources/icon-mockup-source.jpg Resources/AppIcon-1024.png
./scripts/generate-icon.sh   # 打包成 build/AppIcon.icns
./scripts/build-app.sh       # 重新组装 build/Overtone.app
```

`make-icon.py` 需要 Pillow（`pip3 install pillow`）；`generate-icon.sh` 检测到预览图比主图新时
会自动调用它，机器上没有 Pillow 就跳过（沿用现有主图）。

注意：**主图不能留透明区域**（整张 1024x1024 都要有颜色）。带透明像素的 icns 在当前 macOS 上
会被系统额外套一层浅灰底板并把图标缩小（本项目旧图标也有这个问题），满出血不透明图才是正确的输入。

## 使用说明

1. 填写 Jellyfin 服务器地址（如 `http://192.168.1.10:8096`，可省略 `http://`）
2. 输入用户名和密码，点击「连接服务器」
3. 首页会自动加载继续观看和最新内容；左侧栏可切换媒体库

## 项目结构

```
Sources/JellyfinMac/
├── JellyfinApp.swift        # 入口、AppDelegate、RootView
├── Theme.swift              # 暗色主题、品牌渐变
├── Models/                  # Jellyfin API 数据模型
├── Networking/APIClient.swift
├── State/AppState.swift     # 会话管理（登录/恢复/登出）
├── Components/              # 图片缓存、海报卡片、按钮/输入框样式
├── ViewModels/              # 首页 / 媒体库 / 详情 / 搜索
├── Views/                   # 登录、主界面、首页、媒体库、详情、搜索、播放器
└── Player/                  # 播放器模型、进度上报
```

## 命名与内部标识

产品名 **Overtone** 与内部标识是**刻意解耦**的：改名只动「外表」，不动登录态和本地数据。

| 层面 | 值 | 说明 |
|---|---|---|
| 产品名 / `.app` 名 | `Overtone` / `Overtone.app` | 由 `scripts/build-app.sh` 的 `APP_NAME` 决定，访达和启动台显示的就是它 |
| 界面文案 | `Overtone` | 窗口标题、登录页、侧栏标题 |
| Swift target / 源码目录 | `JellyfinMac` / `Sources/JellyfinMac/` | **未改**：见下方「彻底改名」 |
| Bundle ID | `com.jellyfin.mac-client` | **未改**：钥匙串存密码用的 `service` 就是它，改了要重新登录一次 |
| 本地数据目录 | `~/Library/Application Support/JellyfinMac/` | **未改**：播放列表在这里，改了会"丢"列表（除非写迁移） |
| 可执行文件名 | `JellyfinMac` | **未改**：跟 target 名一致，用户看不到 |

> 注意：`scripts/watch-build.sh` 判断「应用是否在运行」用的是**可执行文件名**（`pgrep -x JellyfinMac`），不是产品名——所以只改产品名时这里无需改动。

**彻底改名**（要连 target 和目录一起改，必须在装有 Xcode 的机器上做，改完 `swift build` 验证）：

1. `Package.swift` 的 `name` 与 `targets.path`
2. `mv Sources/JellyfinMac Sources/<新名>`
3. 同步 `scripts/build-app.sh`（`cp .build/release/<新名>`、`CFBundleExecutable`）与 `scripts/watch-build.sh`（`pgrep/pkill -x <新名>`）

## 已知限制

- 播放器暂不支持字幕/音轨切换（跟随服务器默认轨道）
- 仅支持单个服务器

## 许可

仅用于个人学习使用。Jellyfin 是 Jellyfin 团队的商标，本项目是**非官方**客户端，与其无隶属关系。
