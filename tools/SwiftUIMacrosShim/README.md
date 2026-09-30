# SwiftUIMacros 替身插件（无 Xcode 时的编译兜底）

## 为什么需要它

`@State` 在 macOS 15+ SDK 里不是普通的属性包装器，而是声明在 **SwiftUICore** 里的宏：

```swift
@attached(accessor, names: named(init), named(get), named(set))
@attached(peer, names: prefixed(`_`), prefixed(__), prefixed(`$`))
public macro State() = #externalMacro(module: "SwiftUIMacros", type: "StateMacro")
```

宏的**实现**（`libSwiftUIMacros.dylib`）随 Xcode 一起提供。只装了 Command Line Tools 的机器上
这个插件不存在，于是任何 `@State` 都会让 `swift build` 直接失败：

```
error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found
```

## 它是怎么补上的

用开源的 [swift-syntax](https://github.com/swiftlang/swift-syntax) 实现一个同名插件
（模块名 `SwiftUIMacros`、类型名 `StateMacro`），把 `@State` 展开成等价的属性包装器代码：

```swift
@State private var count = 0
// ↓ 展开
private var _count = State(initialValue: 0)
@_StateProjectedValue private var $count = Binding(get: { 0 }, set: { _ in })
private var count: Int {
    get { _count.wrappedValue }
    nonmutating set { _count.wrappedValue = newValue }
}
```

运行时状态管理仍然由 SwiftUI 的 `State` / `Binding` 完成，插件只负责把样板代码写出来。

两个关键细节（都踩过坑）：

1. **`$x` 必须按需求值**：实测 `State.projectedValue` 在 location 还没安装时返回的是**快照** Binding，
   所以 `$x` 的取值由访问器宏 `@_StateProjectedValue` 生成 `get { _x.projectedValue }`，
   声明里的 `= Binding(get:set:)` 只是喂给编译器一个可推断的类型（Swift 要求计算属性必须有显式类型，
   而宏拿不到推断结果）。哑初值里的表达式写在闭包里，不会被求值。
2. **只能走"进程外插件"**：工具链自带的插件是 `CompilerSwiftSyntax*` 模块编译的，而本机没有这些模块的
   接口文件；用开源 `SwiftSyntax` 静态链接出来的 dylib 会因为协议标识不一致被判定为
   “not a valid macro implementation type”。改用可执行插件 + `-load-plugin-executable` 后，
   宏解析和展开都在插件进程内完成，绕开了这个问题。

仓库里实际用到的宏只有 `@State`（`@Binding`/`@ObservedObject`/`@StateObject`/`@EnvironmentObject`/
`@Environment`/`@FocusState`/`@Published` 在这个 SDK 里仍是普通属性包装器，不需要插件）。
如果以后用到 `@Entry`、`@Animatable`、`@Preview` 等，需要在这里补上对应的宏实现。

## 怎么用

`scripts/build-app.sh` 会自动判断：找不到 Xcode 的 `libSwiftUIMacros.dylib` 时，先构建本插件，
再给 `swift build` 加上

```
-Xswiftc -load-plugin-executable -Xswiftc "<bin>/SwiftUIMacros#SwiftUIMacros"
```

手动构建：

```bash
swift build -c release --package-path tools/SwiftUIMacrosShim --disable-sandbox
swift build -c release --disable-sandbox \
  -Xswiftc -load-plugin-executable \
  -Xswiftc "$(swift build -c release --package-path tools/SwiftUIMacrosShim --show-bin-path)/SwiftUIMacros#SwiftUIMacros"
```

依赖的 swift-syntax 版本与本机工具链对齐（Swift 6.4 → `604.0.0`）；工具链升级后如果报插件不兼容，
把 `Package.swift` 里的 `exact:` 换成对应版本即可。首次构建需要联网拉取 swift-syntax。
