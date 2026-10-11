# 命名与内部标识

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

## 彻底改名

要连 target 和目录一起改，必须在装有 Xcode 的机器上做，改完 `swift build` 验证：

1. `Package.swift` 的 `name` 与 `targets.path`
2. `mv Sources/JellyfinMac Sources/<新名>`
3. 同步 `scripts/build-app.sh`（`cp .build/release/<新名>`、`CFBundleExecutable`）与 `scripts/watch-build.sh`（`pgrep/pkill -x <新名>`）
