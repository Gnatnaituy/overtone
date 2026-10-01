// swift-tools-version:5.9
import PackageDescription
import Foundation

/// 真实 SDK 版本。
///
/// SwiftPM 会把可执行文件 `LC_BUILD_VERSION` 的 **sdk 字段**写成这里声明的部署目标（13.0），
/// 而不是实际链接所用的 SDK 版本。macOS 依据该字段判断「App 是否按当前设计语言绘制」：
/// sdk 过旧时，红黄绿窗口按钮、开关等控件会回落到旧版外观（扁平、无玻璃质感），
/// 也就是拿不到 macOS 26 起的 Liquid Glass 外观。
///
/// 对比：Chrome 的二进制是 `minos 13.0 / sdk 26.5` —— 最低版本很低但外观是新的。
/// 因此这里显式传入 `-platform_version`：minos 保持部署目标，sdk 用真实 SDK 版本。
let sdkVersion: String = {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-version"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    do { try process.run() } catch { return "" }
    process.waitUntilExit()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}()

let deploymentTarget = "13.0"

let platformVersionFlags: [String] = sdkVersion.isEmpty ? [] : [
    "-Xlinker", "-platform_version",
    "-Xlinker", "macos",
    "-Xlinker", deploymentTarget,
    "-Xlinker", sdkVersion,
]

let package = Package(
    name: "JellyfinMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "JellyfinMac",
            path: "Sources/JellyfinMac",
            linkerSettings: platformVersionFlags.isEmpty
                ? []
                : [.unsafeFlags(platformVersionFlags)]
        )
    ]
)
