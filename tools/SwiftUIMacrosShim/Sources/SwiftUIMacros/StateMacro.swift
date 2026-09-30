import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@State` 的替身实现（SwiftUICore 里声明为 `#externalMacro(module: "SwiftUIMacros", type: "StateMacro")`）。
///
/// 展开规则（与 SwiftUI 属性包装器的语义一致）：
/// ```swift
/// @State private var count = 0
/// // →
/// private var _count = State(initialValue: 0)
/// @_StateProjectedValue private var $count = _count.projectedValue
/// // 以及 count 的 get/set 访问器
/// ```
/// 两个要点：
/// 1. `$count` 必须是**按需求值**的（每次访问都取 `_count.projectedValue`）。
///    实测 `State.projectedValue` 在没有安装 location 时返回的是快照 Binding，
///    在 init 阶段就把 Binding 存下来会导致 $x 失效，所以这里用访问器宏提供 get。
/// 2. 声明里带 `= _count.projectedValue` 只是为了给编译器一个可推断的类型
///    （Swift 要求计算属性必须有显式类型，而宏拿不到推断出的类型），
///    真正的取值由 `@_StateProjectedValue` 生成的 get 完成。
public struct StateMacro: AccessorMacro, PeerMacro {

    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        let info = try StatePropertyInfo(declaration)
        guard info.canProvideAccessors else { return [] }
        return [
            "get { \(raw: info.storageName).wrappedValue }",
            "nonmutating set { \(raw: info.storageName).wrappedValue = newValue }",
        ]
    }

    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        let info = try StatePropertyInfo(declaration)
        return [
            DeclSyntax(info.storageDeclaration),
            DeclSyntax(info.projectedValueDeclaration),
        ]
    }
}

/// `@_StateProjectedValue`：给 `$x` 生成 `get { _x.projectedValue }`
/// （SwiftUICore 里同名宏由 `StateProjectedValueMacro` 实现）
public struct StateProjectedValueMacro: AccessorMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingAccessorsOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [AccessorDeclSyntax] {
        guard let varDecl = declaration.as(VariableDeclSyntax.self),
              let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw StateMacroError.unsupportedPattern
        }
        let projected = identifier.identifier.text          // "$count"
        guard projected.hasPrefix("$") else {
            throw StateMacroError.unsupportedPattern
        }
        let storage = "_" + projected.dropFirst()           // "_count"
        return ["get { \(raw: storage).projectedValue }"]
    }
}

/// 从 `@State` 修饰的属性声明里抽出生成代码需要的信息
private struct StatePropertyInfo {
    let name: String
    /// 下划线存储属性名，如 `_showRename`
    let storageName: String
    /// 原属性的访问级别（`private ` / `public ` / …），存储与投影值保持一致
    let accessPrefix: String
    /// 原类型标注（可能没有，如 `@State private var hovered = false`）
    let type: TypeSyntax?
    let initialValue: ExprSyntax?
    /// 类型是可选的（`NSImage?`）→ 无初值时按 nil 初始化
    let isOptional: Bool

    var hasInitialValue: Bool { initialValue != nil }

    /// 无初值且非可选时必须由手写 init 给 `_x` 赋值，此时不生成读写器
    var canProvideAccessors: Bool { hasInitialValue || isOptional }

    init(_ declaration: some DeclSyntaxProtocol) throws {
        guard let varDecl = declaration.as(VariableDeclSyntax.self) else {
            throw StateMacroError.notAVariable
        }
        guard let binding = varDecl.bindings.first,
              let identifier = binding.pattern.as(IdentifierPatternSyntax.self) else {
            throw StateMacroError.unsupportedPattern
        }

        name = identifier.identifier.text
        storageName = "_" + name

        let accessLevels = ["private", "fileprivate", "internal", "package", "public", "open"]
        let access = varDecl.modifiers
            .map { $0.name.text }
            .first { accessLevels.contains($0) }
        accessPrefix = access.map { $0 + " " } ?? ""

        type = binding.typeAnnotation?.type
        initialValue = binding.initializer?.value
        isOptional = type?.is(OptionalTypeSyntax.self) == true
            || type?.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) == true
    }

    var storageDeclaration: DeclSyntax {
        if let type {
            if let initialValue {
                return "\(raw: accessPrefix)var \(raw: storageName): State<\(type)> = State(initialValue: \(initialValue))"
            }
            if isOptional {
                return "\(raw: accessPrefix)var \(raw: storageName): State<\(type)> = State(initialValue: nil)"
            }
            // 由手写 init 赋值（`_x = State(initialValue: …)`）
            return "\(raw: accessPrefix)var \(raw: storageName): State<\(type)>"
        }
        guard let initialValue else {
            return "\(raw: accessPrefix)var \(raw: storageName): State<Any>"
        }
        return "\(raw: accessPrefix)var \(raw: storageName) = State(initialValue: \(initialValue))"
    }

    var projectedValueDeclaration: DeclSyntax {
        // 有类型标注时直接写 `Binding<T>`，由 @_StateProjectedValue 提供 get。
        if let type {
            return "@_StateProjectedValue \(raw: accessPrefix)var $\(raw: name): Binding<\(type)>"
        }
        // 没有类型标注（`@State private var hovered = false`）时宏拿不到推断出的类型，
        // 用一个永不求值的哑初值把类型喂给编译器；真正的取值仍由访问器宏完成。
        guard let initialValue else {
            return "@_StateProjectedValue \(raw: accessPrefix)var $\(raw: name): Binding<Any>"
        }
        return "@_StateProjectedValue \(raw: accessPrefix)var $\(raw: name) = Binding(get: { \(initialValue) }, set: { _ in })"
    }
}

private enum StateMacroError: Error, CustomStringConvertible {
    case notAVariable
    case unsupportedPattern

    var description: String {
        switch self {
        case .notAVariable:
            return "@State 只能用在变量声明上"
        case .unsupportedPattern:
            return "@State 不支持这种变量声明形式"
        }
    }
}
