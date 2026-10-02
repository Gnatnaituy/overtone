# Overtone（泛音）

原生 macOS Jellyfin 音乐客户端，SwiftUI 编写，深浅双主题 + 靛蓝主音 / 泛音青双色体系，chrome 层走 Liquid Glass 玻璃材质。

> **关于名字**：Overtone 是「泛音」——基音之上叠加的谐波。官方客户端之外的另一层听感；中文名本身就是现成的音乐术语。本项目是**非官方**客户端，与 Jellyfin 项目无隶属关系。

界面遵循 [`docs/ui-design/UI-Redesign-v3.md`](docs/ui-design/UI-Redesign-v3.md)（v3 设计规范，「基音与泛音」）与
[`docs/ui-design/UI-Redesign-v3-preview.html`](docs/ui-design/UI-Redesign-v3-preview.html)（双主题高保真预览，含材质开关）。
早期版本：[`UI-Design-Spec.md`](docs/ui-design/UI-Design-Spec.md)（v2）· [`preview.html`](docs/ui-design/preview.html)（v2 预览）。

## 功能

- **登录**：左右分栏（品牌区 + 表单卡），高级选项可配协议 / 端口 / 客户端名；记住会话，重启免登录
- **首页**：继续播放（带进度的卡片组）· 快速入口（收藏 / 最近播放 / 最常播放 / 随机播放全部）· 最近添加 · 最常播放 Top 10
- **资料库**：专辑 / 艺人 / 歌曲 / 播放列表四分段，网格与列表双视图，排序菜单，骨架屏加载
- **播放列表**：本地列表 + 按艺术家关键字自动收集的智能列表，可与服务器双向同步；曲目可上移 / 下移
- **详情页**：专辑 / 艺人 / 播放列表统一骨架 —— 面包屑返回栏 + 大封面头部 + 曲目表
- **搜索**：搜索框常驻内容区顶栏（⌘F 聚焦），结果按歌曲 / 专辑 / 艺人 / 播放列表分组
- **设置页**：通用 / 播放 / 外观 / 媒体库 / 服务器与账号 / 关于 六个分组（⌘, 打开）
- **播放器**：原生 AVPlayer，全局迷你播放条（三区布局，窄窗降级两区），正在播放页（大封面 + 5 键控制 + 待播清单 + 歌词 + 睡眠定时）
- **进度同步**：播放进度按设置的间隔上报到服务器，多端进度一致
- **直连优先**：默认直接播放原始文件；关闭直连或选非原始音质时自动走服务器转码
- **窄窗口五档**：侧栏在窄窗口降级为 64pt 图标栏（W1 可展开 240pt 抽屉），不丢导航；完整侧栏也可用 logo 行的按钮手动收成图标栏

## 界面结构

```
[侧栏 240 / 图标栏 64] | [内容区顶栏 64] [滚动区] [迷你播放条 68]
```

- 设计令牌全部收敛在 `Sources/JellyfinMac/Theme.swift`（颜色 / 字体 / 间距 / 圆角 / 阴影 / 动效 / 断点）
- 页面里不出现硬编码色值与圆角；字号统一走 `.textStyle(_:)`，随系统文本大小缩放
- 可访问性：图标按钮均有 `accessibilityLabel`，hover 控件在键盘聚焦时同样出现，
  进度条可键盘 ±5s 微调，尊重系统「减少动态效果」

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

## 外观为什么取决于 SDK 版本

`Package.swift` 里有一段 `xcrun --show-sdk-version` + `-platform_version` 的 linkerSettings，
不是多余的：**macOS 用可执行文件 `LC_BUILD_VERSION` 的 `sdk` 字段决定 App 是否按当前设计语言绘制**。

SwiftPM 会把该字段写成 `platforms:` 里声明的部署目标（本项目是 13.0），于是系统认为这是一个
用旧 SDK 链接的 App，红黄绿窗口按钮、开关等控件全部回落到旧版扁平外观，拿不到 macOS 26 起的
Liquid Glass。对比 Chrome 的二进制是 `minos 13.0 / sdk 26.5` —— 最低版本很低但外观是新的。

所以这里显式传入 `-platform_version macos <部署目标> <真实 SDK 版本>`：**minos 仍是 13.0
（继续支持 macOS 13+），sdk 用真实 SDK 版本**。检查方式：

```bash
vtool -show-build build/Overtone.app/Contents/MacOS/JellyfinMac   # 应显示 sdk 27.0 之类
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
3. 首页会自动加载继续播放、最近添加与最常播放；侧栏可切换资料库 / 播放列表 / 正在播放 / 搜索

### 快捷键

| 快捷键 | 行为 |
|---|---|
| `⌘F` | 聚焦搜索框（任何场景） |
| `空格` | 播放 / 暂停（输入框聚焦时放行给输入框） |
| `⌘→ / ⌘←` | 下一曲 / 上一曲 |
| `⌘[` | 返回上一级 |
| `⌘1 … ⌘5` | 切换一级页（首页 / 资料库 / 播放列表 / 正在播放 / 搜索） |
| `⌘,` | 打开设置 |
| `Esc` | 收起图标栏展开的抽屉 |

## 项目结构

```
Sources/JellyfinMac/
├── JellyfinApp.swift        # 入口、AppDelegate、RootView、设置窗口
├── Theme.swift              # 设计令牌（颜色/字体/间距/圆角/阴影/动效）+ 五档断点
├── Models/                  # Jellyfin API 数据模型
├── Networking/APIClient.swift
├── State/
│   ├── AppState.swift       # 会话管理（登录/恢复/登出）
│   ├── AppSettings.swift    # 设置页数据源 + 应用级「减少动态效果」
│   ├── MusicDataStore.swift # 曲目/专辑/艺人共享数据
│   └── PlaylistStore.swift  # 本地 + 智能播放列表
├── Components/
│   ├── Components.swift     # 按钮/分段/输入框/骨架屏/Toast/空态/快捷键
│   ├── MediaComponents.swift# 封面卡片/曲目表/曲目行/顶栏/面包屑
│   └── MiniPlayerBar.swift  # 底部迷你播放条 + 音量滑杆
├── ViewModels/              # 专辑 / 艺人 / 搜索
├── Views/
│   ├── LoginView.swift      # 登录（左右分栏，窄窗单列）
│   ├── MainView.swift       # 侧栏 / 图标栏 / 抽屉 / 导航栈 / 快捷键
│   ├── HomeView.swift       # 首页
│   ├── SettingsView.swift   # 设置（6 分组）
│   └── Music/               # 资料库 / 播放列表 / 详情 / 搜索 / 正在播放 / 队列
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
- 深色主题尚未落地（令牌层已预留，视觉稿只交付浅色）
- 交叉淡入当前作用于换曲淡入 / 暂停淡出，不是双播放器真交叉淡化
- 播放列表曲目排序提供「上移 / 下移」（拖拽排序的键盘等价物），暂无拖拽把手

## 许可

仅用于个人学习使用。Jellyfin 是 Jellyfin 团队的商标，本项目是**非官方**客户端，与其无隶属关系。
