// swift-tools-version:5.9
import PackageDescription

// SwiftUIMacros 替身插件：本机只装了 Command Line Tools（没有 Xcode），
// SwiftUICore 里 `@State` 等宏的实现（libSwiftUIMacros.dylib）随 Xcode 提供，
// 缺了它 swift build 必然报 “external macro implementation type 'SwiftUIMacros.StateMacro' could not be found”。
// 这里用 swift-syntax 自己实现同名插件补上。
//
// 注意：本机 CLT 的 PackageDescription 没有 `.macro` 目标 API（`Target.Kind.macro` 存在但无构造函数），
// 所以这里用普通动态库产物 + `@main` 插件入口，编译时用 -load-plugin-library 挂上去。
let package = Package(
    name: "SwiftUIMacrosShim",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "SwiftUIMacros", targets: ["SwiftUIMacros"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", exact: "604.0.0")
    ],
    targets: [
        .executableTarget(
            name: "SwiftUIMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/SwiftUIMacros"
        )
    ]
)
