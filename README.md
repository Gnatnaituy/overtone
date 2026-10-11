# Overtone（泛音）

原生 macOS Jellyfin 音乐客户端 · SwiftUI 编写 · Liquid Glass 玻璃材质 · 靛蓝主音 / 泛音青双色体系

> **关于名字**：Overtone 是「泛音」——基音之上叠加的谐波，中文名本身就是现成的音乐术语。本项目是**非官方**客户端，与 Jellyfin 项目无隶属关系。

![正在播放](docs/screenshots/05-now-playing.jpg)

| 首页 | 资料库 · 艺人 |
|---|---|
| ![首页](docs/screenshots/01-home.jpg) | ![资料库 · 艺人](docs/screenshots/02-library-artists.jpg) |

| 资料库 · 歌曲 | 播放列表 |
|---|---|
| ![资料库 · 歌曲](docs/screenshots/03-library-tracks.jpg) | ![播放列表](docs/screenshots/04-playlists.jpg) |

| 设置 · 外观 | 窄窗口图标栏 |
|---|---|
| ![设置 · 外观](docs/screenshots/06-settings.jpg) | ![窄窗口图标栏](docs/screenshots/07-narrow-rail.jpg) |

## 功能

- **登录**：左右分栏（品牌区 + 表单卡），高级选项可配协议 / 端口 / 客户端名；记住会话，重启免登录
- **首页**：继续播放 · 快速入口（收藏 / 最近播放 / 最常播放 / 随机播放全部）· 最近添加 · 最常播放 Top 10
- **资料库**：专辑 / 艺人 / 歌曲 / 播放列表四分段，网格与列表双视图，排序菜单，骨架屏加载
- **播放列表**：本地列表 + 按艺术家关键字自动收集的智能列表，可与服务器双向同步；曲目可上移 / 下移
- **详情页**：专辑 / 艺人 / 播放列表统一骨架 —— 面包屑返回栏 + 大封面头部 + 曲目表
- **搜索**：搜索框常驻内容区顶栏（⌘F 聚焦），结果按歌曲 / 专辑 / 艺人 / 播放列表分组
- **设置页**：通用 / 播放 / 外观 / 媒体库 / 服务器与账号 / 关于 六个分组（⌘, 打开）
- **播放器**：原生 AVPlayer，全局迷你播放条（三区布局，窄窗降级两区），正在播放页（大封面 + 5 键控制 + 待播清单 + 歌词 + 睡眠定时）
- **进度同步 / 直连优先**：播放进度按设置的间隔上报服务器；默认直接播放原始文件，关闭直连或选非原始音质时自动走服务器转码
- **窄窗口五档**：侧栏在窄窗口降级为 64pt 图标栏（W1 可展开 240pt 抽屉），不丢导航；完整侧栏也可用 logo 行的按钮手动收成图标栏

## 快速开始

需要 macOS 13+（推荐 14）与 Xcode 15+ 工具链；只装 Command Line Tools 也能构建，原因见[构建笔记](docs/build-notes.md)。

```bash
./scripts/generate-icon.sh   # 生成图标（首次或换图标时）
./scripts/build-app.sh       # 打包成 build/Overtone.app
open build/Overtone.app
```

开发调试可直接 `swift run`。

首次使用：填服务器地址（如 `http://192.168.1.10:8096`，可省略 `http://`）、用户名与密码，点「连接服务器」；
首页会自动加载继续播放、最近添加与最常播放，侧栏可切换资料库 / 播放列表 / 正在播放 / 搜索。

## 快捷键

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
[侧栏 240 / 图标栏 64] | [内容区顶栏 64] [滚动区] [迷你播放条 68]

Sources/JellyfinMac/
├── JellyfinApp.swift        # 入口、AppDelegate、RootView、设置窗口
├── Theme.swift              # 设计令牌（颜色/字体/间距/圆角/阴影/动效）+ 五档断点
├── Models/                  # Jellyfin API 数据模型
├── Networking/APIClient.swift
├── State/                   # 会话管理、设置、共享数据、本地 + 智能播放列表
├── Components/              # 按钮、分段、封面卡片、曲目表、迷你播放条……
├── ViewModels/              # 专辑 / 艺人 / 搜索
├── Views/                   # 登录、主框架、首页、设置、Music（资料库 / 详情 / 正在播放 / 队列）
└── Player/                  # 播放器模型、进度上报
```

设计令牌全部收敛在 `Sources/JellyfinMac/Theme.swift`，页面里不出现硬编码色值与圆角；字号统一走
`.textStyle(_:)`，随系统文本大小缩放。可访问性：图标按钮均有 `accessibilityLabel`，hover 控件在键盘
聚焦时同样出现，进度条可键盘 ±5s 微调，尊重系统「减少动态效果」。

## 已知限制

- 播放器暂不支持字幕 / 音轨切换（跟随服务器默认轨道）
- 仅支持单个服务器
- 深色主题尚未落地（令牌层已预留，视觉稿只交付浅色）
- 交叉淡入当前作用于换曲淡入 / 暂停淡出，不是双播放器真交叉淡化
- 播放列表曲目排序提供「上移 / 下移」（拖拽排序的键盘等价物），暂无拖拽把手

## 更多文档

- [界面设计规范 v3](docs/ui-design/UI-Redesign-v3.md) · [高保真预览](docs/ui-design/UI-Redesign-v3-preview.html)（双主题 + 材质开关）；早期 [v2 规范](docs/ui-design/UI-Design-Spec.md) · [v2 预览](docs/ui-design/preview.html)
- [构建笔记](docs/build-notes.md)：外观为什么取决于 SDK 版本、没有 Xcode 时的宏插件兜底、自动打包
- [应用图标](docs/app-icon.md)：主图规范与换图标流程
- [命名与内部标识](docs/naming.md)：产品名与 target / Bundle ID / 数据目录的解耦

## 许可

仅用于个人学习使用。Jellyfin 是 Jellyfin 团队的商标，本项目是**非官方**客户端，与其无隶属关系。
