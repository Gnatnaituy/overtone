# 构建笔记

README 放不下的构建细节：外观与 SDK 版本的关系、没有 Xcode 时的宏插件兜底、自动打包。

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
[../tools/SwiftUIMacrosShim/README.md](../tools/SwiftUIMacrosShim/README.md)。

注意：手工 `swift run` / `swift build` 不会带上插件参数，没装 Xcode 时请用 `./scripts/build-app.sh`。

## 打包与自动覆盖

修改代码后会自动重新打包并覆盖 `build/Overtone.app`（应用在运行时会被重启以加载新版）。

```bash
./scripts/build-app.sh          # 手动打包一次，覆盖旧版本
./scripts/watch-build.sh --once # 同上（监听脚本的"打包一次"入口）
```

`scripts/watch-build.sh` 也可以作为可选工具常驻监听源码变化自动打包（`pkill -f watch-build.sh` 停止），按需使用。

## 协作时的类型检查锁

多人（或多 agent）并行改代码时，两个 `swift build` 同时写同一个 `.build` 会互相破坏增量状态，
报出与代码无关的编译错误。`scripts/dev-typecheck.sh` 用目录锁把编译串行化（后到者排队，
默认最长等 15 分钟），并自动带上宏插件参数：

```bash
./scripts/dev-typecheck.sh      # debug 类型检查，不打包
```

## 视觉回归截图（UI 改动验收用）

`scripts/dev-shot.sh` 启动指定 `.app`、等窗口出现后按 **窗口 id** 截图（`screencapture -l`），
适合改 UI 后做「同尺寸 A/B 对比」：

```bash
./scripts/dev-shot.sh --out /tmp/paper.png --style 纸墨 --theme 深色
./scripts/dev-shot.sh --app /tmp/overtone-before.app --out /tmp/before.png
```

- 风格 / 主题走**启动参数域**（`-settings.visualStyle paper`、`-settings.theme 深色`），只在本次进程内生效。
  ⚠️ **不要**用 `defaults write` + `CFFIXED_USER_HOME` 去"隔离"偏好：cfprefsd 是按用户共享的守护进程，
  它不认 `CFFIXED_USER_HOME`，`defaults write com.jellyfin.mac-client` 会**直接改到使用者的真实偏好**。
- `--style` 收界面词（玻璃/纸墨），内部映射成 `VisualStyle.rawValue`（`glass`/`paper`）——传中文原始值会解析失败并静默回落玻璃。
- `--size 1109x802` 想用辅助功能 API 钉窗口尺寸，但 SwiftUI 会按自己保存的 `NSWindow Frame …` 回弹，
  实测不可靠；要两边同尺寸，最稳的办法是让两次运行都没有保存过的窗口尺寸（两边都落到默认尺寸）。
- 窗口枚举小工具在 `/tmp/ot-winlist`（首次运行时自动编译）。

## 一个容易踩的坑：窗口恢复标识会随视图结构变化

SwiftUI 的窗口恢复标识由**场景内容的泛型类型签名**派生
（`defaults read com.jellyfin.mac-client` 里能看到 `NSWindow Frame SwiftUI.WindowGroup<…RootView…>`）。
只要视图结构改一次（例如给场景加 `.environment(...)`），签名就变，而 macOS 仍拿旧标识去恢复：
SwiftUI 认不出 → 恢复出的窗口是 `nil` → **启动后一个窗口都没有**。日志特征：

```
_restoreWindowWithRestoration: … window=0x0
orderRestoredWindows … has no restoredWindow, skipping ordering
```

因此 `JellyfinApp.init()` 会写 `ApplePersistenceIgnoreState = true` 关掉这套恢复
（`AppDelegate.disableWindowStateRestoration()`）。窗口位置/尺寸仍由 SwiftUI 的
`NSWindow Frame …` 偏好保持，不受影响。
