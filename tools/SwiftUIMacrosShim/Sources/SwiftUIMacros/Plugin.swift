import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// 插件入口：把替身宏注册给编译器
@main
struct SwiftUIMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [
        StateMacro.self,
        StateProjectedValueMacro.self
    ]
}
