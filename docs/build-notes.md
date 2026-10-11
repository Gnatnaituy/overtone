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
