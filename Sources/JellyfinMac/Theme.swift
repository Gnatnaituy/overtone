import AppKit
import SwiftUI

// MARK: - 十六进制颜色

extension NSAppearance {
    /// 当前外观是否深色 —— 双主题令牌按这个分支解析
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }

    /// 双主题令牌：浅色 / 深色成对定义，由 AppKit 在**绘制时**按当前外观解析。
    ///
    /// 因此「浅色 / 深色 / 跟随系统」切换不需要重建视图树 —— 换 `NSApp.appearance`
    /// 后 AppKit 会重新解析所有动态色并重绘，导航栈与滚动位置都不丢。
    init(token light: UInt32, _ dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            NSColor(srgbHex: appearance.isDark ? dark : light)
        })
    }

    /// 需要「外观 + 强调色」共同决定的令牌（选中底、品牌色文字）
    init(appearanceDynamic provider: @escaping (NSAppearance) -> NSColor) {
        self.init(nsColor: NSColor(name: nil, dynamicProvider: provider))
    }

    /// 只跟强调色走的令牌（品牌色阶）
    init(accentDynamic provider: @escaping () -> NSColor) {
        self.init(nsColor: NSColor(name: nil) { _ in provider() })
    }
}

extension NSColor {
    convenience init(srgbHex hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }

    /// 按 HSB 偏移派生同色系深浅（规范只为靛蓝定义了 400/600 与深色文字档）
    func shifted(saturation ds: CGFloat, brightness db: CGFloat) -> NSColor {
        guard let srgb = usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let shifted = NSColor(
            hue: h,
            saturation: min(max(s + ds, 0), 1),
            brightness: min(max(b + db, 0), 1),
            alpha: a
        )
        return shifted.usingColorSpace(.sRGB) ?? self
    }
}

/// 视觉风格：v3「Liquid Glass」、v4「纸带与信号」、v6「棱镜 Prism」并存，设置里即时切换。
///
/// 顶格声明（不嵌套在 `Theme` 里、不做隔离）：设置项、环境值、视图分支都要能直接引用它，
/// 嵌进 `Theme` 会逼着每个消费方写 `Theme.VisualStyle` 这种长名字，也让 `Env` 键默认值的
/// 声明绕远路。
enum VisualStyle: String, CaseIterable, Identifiable, Sendable {
    /// v3 Liquid Glass（默认）—— 玻璃材质 + 圆角 + 投影
    case glass
    /// v4 纸带与信号 —— 纸墨 + 细线 + 零投影
    case paper
    /// v6 棱镜 Prism —— 白卡 + 大圆角 + 紫调强调 + 封面取色（Apple Music / Primuse 式轻盈感）
    case prism

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass: return "玻璃"
        case .paper: return "纸墨"
        case .prism: return "棱镜"
        }
    }

    /// 设置页副说明：一句话讲清「选它意味着什么」
    var detail: String {
        switch self {
        case .glass: return "玻璃材质、圆角与投影，层次靠材质与光"
        case .paper: return "纸墨质感、1px 细线与零投影，层次靠纸墨反差"
        case .prism: return "白卡、大圆角与紫调强调，轻盈通透的 Apple Music 风"
        }
    }

    /// 是否「棱镜」—— 复用玻璃的视图结构，只换令牌与材质（页面分支统一写 `Theme.isPrism`）。
    var isPrism: Bool { self == .prism }

    /// 无障碍标签（分段控件读屏用）
    var accessibilityName: String { "视觉风格：\(title)" }
}

/// 强调色色阶：400 渐变起点 / 500 主色实底 / 600 按压激活 / 文字档。
///
/// 设计规范只给了靛蓝的 `#6B71E3 / #4C53D8 / #3E45C0` 与深色文字档 `#A5AAFF`；
/// 泛音青与紫规范未定义，按主色套用靛蓝的 HSB 偏移推导。
///
/// v4 的强调色**深浅分档**（预览 `data-theme` + `data-accent` 两组变量）：浅色 `#C2402A` /
/// 深色 `#E85E3C`，所以色阶同时带浅、深两个基准色 —— 玻璃模式下两者相同，
/// 取色与改动前逐字节一致。
struct AccentRamp {
    /// 浅色外观的 400 档（渐变起点）
    let light: NSColor
    /// 浅色外观的 500 档（主色实底）
    let base: NSColor
    /// 浅色外观的 600 档（按压激活）—— 名字保持原样，既有调用点语义不变
    let dark: NSColor
    /// 深色外观的 400 档
    let lightDark: NSColor
    /// 深色外观的 500 档（主色实底）
    let baseDark: NSColor
    /// 深色外观的 600 档（按压激活）
    let darkDark: NSColor
    /// 文字/图标档：浅色用主色，深色用提亮档（深底上主色对比度不足）
    let text: NSColor

    static func fixed(
        base: UInt32,
        light: UInt32,
        dark: UInt32,
        text: UInt32,
        darkBase: UInt32? = nil,
        darkLight: UInt32? = nil,
        darkDark: UInt32? = nil
    ) -> AccentRamp {
        AccentRamp(
            light: NSColor(srgbHex: light),
            base: NSColor(srgbHex: base),
            dark: NSColor(srgbHex: dark),
            lightDark: NSColor(srgbHex: darkLight ?? light),
            baseDark: NSColor(srgbHex: darkBase ?? base),
            darkDark: NSColor(srgbHex: darkDark ?? dark),
            text: NSColor(srgbHex: text)
        )
    }

    /// 只有主色时按 HSB 偏移推导整套（靛蓝的偏移量）。
    ///
    /// `darkHex` 给了就按它单独推导深色外观三档 —— v4 的强调色深浅差异是设计给的
    /// 固定值（如信号红 `#C2402A` / `#E85E3C`），不能靠偏移猜。
    static func derived(from hex: UInt32, darkHex: UInt32? = nil) -> AccentRamp {
        let base = NSColor(srgbHex: hex)
        let darkBase = NSColor(srgbHex: darkHex ?? hex)
        // 深色基准与浅色相同（玻璃模式）时，深色三档保持原有的「按主色偏移」结果，
        // 这样玻璃模式的取色与改动前完全一致
        let sameAcrossAppearances = darkHex == nil
        return AccentRamp(
            light: base.shifted(saturation: -0.12, brightness: 0.045),
            base: base,
            dark: base.shifted(saturation: 0.03, brightness: -0.095),
            lightDark: sameAcrossAppearances
                ? base.shifted(saturation: -0.12, brightness: 0.045)
                : darkBase.shifted(saturation: -0.12, brightness: 0.045),
            baseDark: darkBase,
            darkDark: sameAcrossAppearances
                ? base.shifted(saturation: 0.03, brightness: -0.095)
                : darkBase.shifted(saturation: 0.03, brightness: -0.095),
            text: base.shifted(saturation: -0.295, brightness: 0.153)
        )
    }

    /// 当前风格下的色阶。
    ///
    /// 纸墨（v4）用预览文件头 `data-accent` 的成对色值：浅色是「墨色」版本，
    /// 深色是提亮版本（深底上原色对比度不足）。玻璃（v3）沿用原色，取色不变。
    static func forChoice(_ choice: AppSettings.AccentChoice, style: VisualStyle) -> AccentRamp {
        // 棱镜（v6）：比玻璃更饱和、更「屏幕发光」的一组色阶 ——
        // 白卡/浅灰底上需要更高色度才压得住，深色下则提亮到接近霓虹。
        if style == .prism {
            switch choice {
            case .indigo:
                return .fixed(
                    base: 0x5B5BF0, light: 0x7C7BFF, dark: 0x4A48D8, text: 0xB3B2FF,
                    darkBase: 0x8A88FF, darkLight: 0xA8A6FF, darkDark: 0x6E6CF0
                )
            case .teal:
                return .fixed(
                    base: 0x06B6D4, light: 0x22D3EE, dark: 0x0891B2, text: 0x67E8F9,
                    darkBase: 0x22D3EE, darkLight: 0x67E8F9, darkDark: 0x0891B2
                )
            case .purple:
                return .fixed(
                    base: 0x8B5CF6, light: 0xA78BFA, dark: 0x7C3AED, text: 0xC4B5FD,
                    darkBase: 0xA78BFA, darkLight: 0xC4B5FD, darkDark: 0x8B5CF6
                )
            case .signal:
                return .fixed(
                    base: 0xF43F5E, light: 0xFB7185, dark: 0xE11D48, text: 0xFDA4AF,
                    darkBase: 0xFB7185, darkLight: 0xFDA4AF, darkDark: 0xF43F5E
                )
            }
        }
        guard style == .paper else {
            switch choice {
            case .indigo: return .fixed(base: 0x4C53D8, light: 0x6B71E3, dark: 0x3E45C0, text: 0xA5AAFF)
            case .teal: return .derived(from: 0x12B8A6)
            case .purple: return .derived(from: 0x7C4DDB)
            case .signal: return .derived(from: 0xC2402A)
            }
        }
        switch choice {
        case .signal:
            return .fixed(
                base: 0xC2402A, light: 0xE85E3C, dark: 0xA83420, text: 0xF07A58,
                darkBase: 0xE85E3C, darkLight: 0xF07A58, darkDark: 0xC2402A
            )
        case .indigo:
            return .fixed(
                base: 0x4C53D8, light: 0x6B71E3, dark: 0x3E45C0, text: 0xA5AAFF,
                darkBase: 0x8A8DF0, darkLight: 0xA5AAFF, darkDark: 0x6B71E3
            )
        case .teal:
            return .fixed(
                base: 0x2E6E66, light: 0x2E6E66, dark: 0x245A54, text: 0x7CC4BC,
                darkBase: 0x57ADA4, darkLight: 0x57ADA4, darkDark: 0x3E857C
            )
        case .purple:
            return .fixed(
                base: 0x7C4DDB, light: 0x7C4DDB, dark: 0x6635B8, text: 0xC7B0FF,
                darkBase: 0xB694FF, darkLight: 0xB694FF, darkDark: 0x8A5FE0
            )
        }
    }
}

/// 由强调色色阶派生的一整套品牌令牌，**构造一次后缓存**。
///
/// 为什么必须缓存（实测数据）：`Color(nsColor:)` 包出来的动态色按**实例标识**比较 ——
/// 同一段配方构造的两个动态色 `isEqual` 为 `false`，包成 `Color` 后 `==` 也是 `false`；
/// 而纯色 `NSColor` 的 `Color` 相等性正常（`true`）。构造一个动态色约 **633ns**，
/// 纯色只要 **22ns**（28 倍）。
///
/// 后果：`Theme.brand500` 这类令牌若每次访问都新建，SwiftUI 拿到的永远是「变了的」值 ——
/// 它靠视图值的 `Equatable` 跳过未变化的子树，令牌不稳定就等于**放弃了这层跳过**，
/// 卡片网格里每个选中态 / 品牌色元素每次渲染都被判定为需要重绘。
struct AccentTokens {
    let brand400: Color
    let brand500: Color
    let brand600: Color
    let brandText: Color
    let brandTint: Color
    let surfaceSelected: Color
    let gradient: LinearGradient

    /// - Parameter style: 当前视觉风格。v4 纸墨的染色浓度更高（预览 `--signal-tint`：
    ///   浅 9–10% / 深 14–16%）；v6 棱镜再提一档（浅 12% / 深 22–24%，白卡上需要更明显的
    ///   选中底）；玻璃沿用原浓度（浅 8% / 深 16%·18%），取色逐字节不变。
    ///   风格切换会整体重建本结构，所以这里的分支不会「换了风格不生效」。
    init(_ ramp: AccentRamp, style: VisualStyle = .glass) {
        // 色阶由闭包捕获（不是在绘制时读全局）：`accentRamp` 的 didSet 会整体重建本结构，
        // 所以缓存里的色阶始终是当前那一套
        let paper = style == .paper
        let prism = style == .prism
        let tintAlphaLight: Double = prism ? 0.12 : (paper ? 0.10 : 0.08)
        let tintAlphaDark: Double = prism ? 0.22 : (paper ? 0.16 : 0.16)
        let selectedAlphaLight: Double = prism ? 0.14 : (paper ? 0.10 : 0.08)
        let selectedAlphaDark: Double = prism ? 0.24 : (paper ? 0.18 : 0.18)
        brand400 = Color(appearanceDynamic: { $0.isDark ? ramp.lightDark : ramp.light })
        brand500 = Color(appearanceDynamic: { $0.isDark ? ramp.baseDark : ramp.base })
        brand600 = Color(appearanceDynamic: { $0.isDark ? ramp.darkDark : ramp.dark })
        // 需要「外观 + 强调色」共同决定：深色主题下品牌文字用提亮档
        // —— v4 的 `signal-ink`（`#A83420` / `#F07A58`）就是这样成对定义的
        brandText = Color(appearanceDynamic: { appearance in
            appearance.isDark ? ramp.text : ramp.base
        })
        // 染色底同理走深浅两档（v4 的深色档是提亮版，用浅色档铺深底会糊成一片）
        brandTint = Color(appearanceDynamic: { appearance in
            let base = appearance.isDark ? ramp.baseDark : ramp.base
            return base.withAlphaComponent(appearance.isDark ? tintAlphaDark : tintAlphaLight)
        })
        surfaceSelected = Color(appearanceDynamic: { appearance in
            let base = appearance.isDark ? ramp.baseDark : ramp.base
            return base.withAlphaComponent(appearance.isDark ? selectedAlphaDark : selectedAlphaLight)
        })
        gradient = LinearGradient(
            colors: [brand400, brand600],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 设计令牌（v2）

/// Overtone 设计令牌：浅色主题 + 靛蓝主音 / 泛音青双色体系。
///
/// 规则（对应 UI-Design-Spec §3）：
/// - 页面里**不允许**再出现硬编码色值 / 圆角 / 阴影 / 字号，一律走本枚举；
/// - 圆角收敛为 6 档（xs/sm/md/lg/xl/full），阴影 3 档（e1/e2/e3）；
/// - `textTertiary` 对比度 3.67:1，**禁止用于正文**（仅分组标题、占位符、图标）。
enum Theme {

    // MARK: 表面（Surfaces）—— 深色下靠明度阶梯表达层级：canvas < surface < hover

    /// 窗口内容区底色，让卡片浮起。
    ///
    /// v4 起是**风格化令牌**：读数来自 `state` 缓存（玻璃 / 纸墨两套），实例稳定 ——
    /// 原因见 `AccentTokens`。glass 下取值与 v3 完全一致。
    static var canvas: Color { state.active.canvas }
    /// 卡片、面板、设置分组
    static var surface: Color { state.active.surface }
    /// 表头、次级控件底、分段控件容器
    static var surfaceSunken: Color { state.active.surfaceSunken }
    /// 行悬停
    static var surfaceHover: Color { state.active.surfaceHover }

    // MARK: 描边（Borders）—— 深色下承担浅色主题里阴影的分层职责

    static var borderSubtle: Color { state.active.borderSubtle }
    static var borderDefault: Color { state.active.borderDefault }
    static var borderStrong: Color { state.active.borderStrong }

    // MARK: 文字（Text）

    static var textPrimary: Color { state.active.textPrimary }
    static var textSecondary: Color { state.active.textSecondary }
    /// 浅色 3.67:1 / 深色 4.63:1 —— 仅用于分组标题、占位符、图标，禁止用于正文
    static var textTertiary: Color { state.active.textTertiary }
    static let textOnAccent = Color.white

    // MARK: 品牌（Brand）—— 跟随「外观 · 强调色」，切换即时全局生效

    /// 当前强调色色阶：由 `AppSettings` 在启动装载与切换时写入。
    ///
    /// Theme 令牌要能在任意上下文读取（视图、模型、默认参数值），不能直接依赖
    /// `@MainActor` 的 AppSettings，所以这里存一份非隔离的镜像。
    ///
    /// 写入时**整体重建**派生令牌缓存（`accentTokens`）：品牌色令牌必须保持实例稳定，
    /// 否则每次访问都返回不相等的 `Color`，SwiftUI 的相等性跳过机制全部失效
    /// （原因与实测数据见 `AccentTokens`）。
    static var accentRamp: AccentRamp = .forChoice(.indigo, style: .glass) {
        didSet { accentTokens = AccentTokens(accentRamp, style: visualStyle) }
    }

    /// 品牌令牌缓存（首次访问时按当前 `accentRamp` 构造）
    private static var accentTokens = AccentTokens(accentRamp, style: .glass)

    static var brand400: Color { accentTokens.brand400 }
    /// 主色**实底**：浅色主题用 500 档、深色主题用提亮档（v4 深浅分档；玻璃下两者同值）
    static var brand500: Color { accentTokens.brand500 }
    static var brand600: Color { accentTokens.brand600 }
    /// 品牌色**文字/图标**：浅色用主色，深色用提亮档（主色在深底上对比度不足）
    static var brandText: Color { accentTokens.brandText }

    /// 设置页「强调色」四个色块的固定值，**不随当前强调色变化**
    /// （放在 `Paper` 里是因为这四组色值同时就是 v4 的纸墨强调色色阶；玻璃模式取同值）
    static var accentIndigo: Color { Paper.accentIndigo }
    static var accentTeal: Color { Paper.accentTeal }
    static var accentPurple: Color { Paper.accentPurple }
    static var accentSignal: Color { Paper.accentSignal }

    /// 选中底、焦点光晕
    static var brandTint: Color { accentTokens.brandTint }
    /// 选中行底色（强调色染；深色底上需要更高浓度才看得出来）
    static var surfaceSelected: Color { accentTokens.surfaceSelected }
    /// 第二谐波：频谱柱、正在播放律动（装饰用，固定泛音青，深色提亮）；
    /// 纸墨下解析为 v4 的 `#2E6E66 / #57ADA4`（墨绿，比玻璃的青更沉）
    static var overtoneTeal: Color { state.active.overtoneTeal }
    /// 青色文字态（浅色 5.12:1 / 深色 9.77:1 ✅ AA）
    static var tealText: Color { state.active.tealText }

    static var brandGradient: LinearGradient { accentTokens.gradient }

    // MARK: 视觉风格（v3 玻璃 / v4 纸墨 / v6 棱镜）

    /// 当前风格镜像（非隔离静态量，任意上下文可读；取值只从 `state` 缓存来）
    static var visualStyle: VisualStyle = .glass {
        didSet { state = StyleState(style: visualStyle, accent: accentRamp) }
    }

    /// 是否纸墨模式 —— 页面里所有风格分支都写成 `Theme.isPaper ? 纸墨 : 原玻璃代码`
    static var isPaper: Bool { visualStyle == .paper }

    /// 是否棱镜模式 —— 复用玻璃的视图结构，只换令牌 / 材质 / 圆角；
    /// 页面里需要为「白卡 + 大圆角 + 紫调」单独处理时读它。
    static var isPrism: Bool { visualStyle == .prism }

    /// 风格化令牌缓存：玻璃 / 纸墨 / 棱镜三套**同时构造一次**，切换只是换引用。
    ///
    /// 为什么三套都留着：`active` 每次访问都要返回同一个 `Color` 实例（原因见 `AccentTokens`），
    /// 所以不能在 `active` 里按风格现算 —— 来回切换风格必须命中同一批实例。
    private struct StyleState {
        let glass = GlassTokens()
        let ink = InkTokens()
        let prism = PrismTokens()
        let active: Palette
        /// 形状族（圆角）随风格走，缓存成值类型供 `Theme.Radius` 直接读
        let radius: Radii

        init(style: VisualStyle, accent: AccentRamp) {
            switch style {
            case .glass:
                active = glass.palette
                radius = Radii(xs: 4, sm: 6, md: 10, lg: 14, xl: 20, cover: 10)
            case .paper:
                active = ink.palette
                radius = Radii(xs: 2, sm: 3, md: 3, lg: 4, xl: 6, cover: 2)
            case .prism:
                active = prism.palette
                // 棱镜：Apple Music 式大圆角（卡片 12 / 面板 12 / 大卡 22，封面 10）
                radius = Radii(xs: 6, sm: 8, md: 12, lg: 16, xl: 22, cover: 10)
            }
            // 风格参与强调色令牌的构造（v4 / v6 染色浓度不同），换风格必须一起重建
            accentTokens = AccentTokens(accent, style: style)
        }
    }

    /// 圆角六档 + 封面档（值类型，`Radii.glass` / `Radii.paper` 各构造一次）
    private struct Radii {
        let xs: CGFloat
        let sm: CGFloat
        let md: CGFloat
        let lg: CGFloat
        let xl: CGFloat
        let cover: CGFloat
    }

    private static var state = StyleState(style: .glass, accent: accentRamp)

    /// 写入视觉风格：重建风格化令牌缓存 + 触发全局重绘（`AppSettings` 与 `AppDelegate` 调用）。
    ///
    /// 与强调色同理：动态色是绘制时解析的，改动全局变量不会让 SwiftUI 重算 body，
    /// 所以这里借一次「高对比同色系外观」的往返让 AppKit 重新解析全部动态色
    /// （实测手法与原因见 `refreshAccent`）。
    @MainActor
    static func applyVisualStyle(_ style: VisualStyle) {
        guard style != visualStyle else { return }
        visualStyle = style
        refreshAccent()
    }

    /// 启动时按持久化的风格应用。
    ///
    /// `AppDelegate` 是**非隔离**上下文（与 `applyStoredTheme` 并列），所以这里直接读
    /// UserDefaults 并写缓存；由 AppKit 在主线程启动流程里调用，构造完视图树之前就已生效，
    /// 不需要那一次「重解析往返」。
    static func applyStoredStyle() {
        let stored = UserDefaults.standard.string(forKey: "settings.visualStyle") ?? ""
        visualStyle = VisualStyle(rawValue: stored) ?? .glass
    }

    // MARK: 风格化令牌数据（两套同时构造，切换只换 `state.active` 的引用）

    /// 玻璃（v3）令牌面：取值与 v3 逐字节一致。
    ///
    /// 各 `static let` 只构造一次 —— 令牌实例稳定是硬约束（原因见 `AccentTokens`），
    /// `Palette` 每个字段都指向其中之一，所以 `Theme.canvas` 每次访问都是同一个实例。
    private struct GlassTokens {
        let canvas = Color(token: 0xF5F6F8, 0x0E1014)
        let surface = Color(token: 0xFFFFFF, 0x16191F)
        let surfaceSunken = Color(token: 0xF2F3F6, 0x1D212A)
        let surfaceHover = Color(token: 0xEEF0F4, 0x222732)

        let borderSubtle = Color(token: 0xE9EBEF, 0x262B36)
        let borderDefault = Color(token: 0xDDE0E6, 0x343B49)
        let borderStrong = Color(token: 0xC6CBD4, 0x4B5468)

        let textPrimary = Color(token: 0x14171C, 0xF2F4F8)
        let textSecondary = Color(token: 0x5B6472, 0xA9B1C0)
        let textTertiary = Color(token: 0x7C8698, 0x79839A)

        let overtoneTeal = Color(token: 0x12B8A6, 0x2AD3C0)
        let tealText = Color(token: 0x0B7C6A, 0x45D6C3)
        /// 玻璃模式下「纸墨泛音青底色」的等价物（纸墨才真正用得上）
        let tealTint = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x12B8A6).withAlphaComponent(appearance.isDark ? 0.16 : 0.08)
        })

        let success = Color(token: 0x14855F, 0x3DC98A)
        let warning = Color(token: 0xA75B09, 0xF0B429)
        let danger = Color(token: 0xC8372D, 0xF26557)
        let favorite = Color(token: 0xE04B78, 0xF0679B)

        let scrim = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x14171C).withAlphaComponent(appearance.isDark ? 0.32 : 0.22)
        })
        let shimmer = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.05 : 0.75)
        })

        let glassBorder = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.10 : 0.62)
        })
        let glassFill = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x1A1D26).withAlphaComponent(0.52)
                : NSColor.white.withAlphaComponent(0.50)
        })
        let glassFillStrong = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x1E222C).withAlphaComponent(0.72)
                : NSColor.white.withAlphaComponent(0.70)
        })
        let glassFillThin = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x1A1D26).withAlphaComponent(0.40)
                : NSColor.white.withAlphaComponent(0.42)
        })
        let glassHighlight = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.10 : 0.70)
        })
        let glassShadow = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x10141C).withAlphaComponent(appearance.isDark ? 0.10 : 0.14)
        })

        let ambientIndigo = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x6B71E3).withAlphaComponent(appearance.isDark ? 0.30 : 0.55)
        })
        let ambientTeal = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x12B8A6).withAlphaComponent(appearance.isDark ? 0.22 : 0.46)
        })
        let ambientRose = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0xE04B78).withAlphaComponent(appearance.isDark ? 0.16 : 0.42)
        })
        let ambientAmber = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0xF6B45A).withAlphaComponent(appearance.isDark ? 0.10 : 0.44)
        })
        let ambientBaseTop = Color(token: 0xE4E8F6, 0x12141C)
        let ambientBaseBottom = Color(token: 0xF4EEE5, 0x0A0C11)

        let inverseSurface = Color(token: 0x14171C, 0xF2F4F8)
        let textOnInverse = Color(token: 0xFFFFFF, 0x14171C)

        var palette: Palette { Palette(self) }
    }

    /// 棱镜（v6）令牌面：Apple Music / Primuse 式的「白卡 + 浅灰画布 + 紫调强调」。
    ///
    /// 与玻璃的差别不在结构（视图仍走玻璃分支），而在：
    /// - 表面更实、更亮（白卡而非磨砂玻璃），层级靠柔和投影与 1px 冷灰细线；
    /// - 圆角更大（面板 12 / 大卡 22），更接近 Apple Music 的圆润感；
    /// - 氛围层是紫罗兰 / 青 / 粉的低饱和 wash，配合封面取色；
    /// - 强调色色阶更饱和（`AccentRamp.forChoice(_:style: .prism)`）。
    ///
    /// 深色主题下就是 Primuse 沉浸播放页的底：近黑底 + 更亮的表面 + 霓虹紫。
    private struct PrismTokens {
        let canvas = Color(token: 0xF3F4FA, 0x0B0C12)
        let surface = Color(token: 0xFFFFFF, 0x151822)
        let surfaceSunken = Color(token: 0xECEEF6, 0x1C202C)
        let surfaceHover = Color(token: 0xE7E9F4, 0x242936)

        let borderSubtle = Color(token: 0xE6E8F1, 0x262C3A)
        let borderDefault = Color(token: 0xD9DCE9, 0x343B4D)
        let borderStrong = Color(token: 0xC3C7D8, 0x4A536A)

        let textPrimary = Color(token: 0x11131B, 0xF4F6FB)
        let textSecondary = Color(token: 0x5A6072, 0xAAB2C4)
        let textTertiary = Color(token: 0x8A90A2, 0x7C859A)

        let overtoneTeal = Color(token: 0x0EA5A0, 0x2DD4BF)
        let tealText = Color(token: 0x0B7C74, 0x5EEAD4)
        let tealTint = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x0EA5A0).withAlphaComponent(appearance.isDark ? 0.20 : 0.10)
        })

        let success = Color(token: 0x12855F, 0x3DDC97)
        let warning = Color(token: 0xB45309, 0xFBBF24)
        let danger = Color(token: 0xDC2626, 0xF87171)
        let favorite = Color(token: 0xEC4899, 0xF472B6)

        let scrim = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x0B1020).withAlphaComponent(appearance.isDark ? 0.36 : 0.24)
        })
        let shimmer = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.07 : 0.80)
        })

        let glassBorder = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.12 : 0.90)
        })
        let glassFill = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x161A24).withAlphaComponent(0.78)
                : NSColor.white.withAlphaComponent(0.82)
        })
        let glassFillStrong = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x1B202C).withAlphaComponent(0.88)
                : NSColor.white.withAlphaComponent(0.94)
        })
        let glassFillThin = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x14171F).withAlphaComponent(0.72)
                : NSColor.white.withAlphaComponent(0.72)
        })
        let glassHighlight = Color(appearanceDynamic: { appearance in
            NSColor.white.withAlphaComponent(appearance.isDark ? 0.12 : 0.85)
        })
        let glassShadow = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x0B1020).withAlphaComponent(appearance.isDark ? 0.16 : 0.10)
        })

        let ambientIndigo = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x7C6CFF).withAlphaComponent(appearance.isDark ? 0.32 : 0.24)
        })
        let ambientTeal = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0x22D3EE).withAlphaComponent(appearance.isDark ? 0.20 : 0.16)
        })
        let ambientRose = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0xF472B6).withAlphaComponent(appearance.isDark ? 0.20 : 0.18)
        })
        let ambientAmber = Color(appearanceDynamic: { appearance in
            NSColor(srgbHex: 0xFDBA74).withAlphaComponent(appearance.isDark ? 0.14 : 0.14)
        })
        let ambientBaseTop = Color(token: 0xF2F3FA, 0x0E1020)
        let ambientBaseBottom = Color(token: 0xF8F5FA, 0x090A10)

        let inverseSurface = Color(token: 0x10131A, 0xF4F6FB)
        let textOnInverse = Color(token: 0xFFFFFF, 0x10131A)

        var palette: Palette { Palette(self) }
    }

    /// 纸墨（v4）令牌面：`docs/ui-design/UI-Redesign-v4.md` §2.1。
    ///
    /// 与 v3 不同，v4 的纸色只有一套、深浅由**双主题成对定义**满足（`Color(token:_:)`
    /// 在绘制时解析外观），所以这里全都是 `static let` 纯值，构造一次即稳定。
    private struct InkTokens {
        /// 纸 · 画布
        let paperCanvas = Color(token: 0xF4EEE1, 0x17130E)
        /// 纸 · 页面（卡片 / 白纸）
        let paperSheet = Color(token: 0xFBF7EC, 0x201A13)
        /// 纸 · 凹陷
        let paperSunken = Color(token: 0xEDE5D2, 0x17120C)
        /// 纸 · 悬停
        let paperHover = Color(token: 0xEFE7D4, 0x272017)

        /// 墨 · 主文字
        let ink = Color(token: 0x221D16, 0xEFE6D3)
        /// 墨 · 次级
        let ink2 = Color(token: 0x5F5749, 0xA99C86)
        /// 墨 · 三级
        let ink3 = Color(token: 0x8B8170, 0x7C7260)

        /// 细线 `rgba(34,29,22,.16)` / `rgba(239,230,211,.16)`
        let hairline = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0xEFE6D3).withAlphaComponent(0.16)
                : NSColor(srgbHex: 0x221D16).withAlphaComponent(0.16)
        })
        /// 强线 `.32` / `.30`
        let hairlineStrong = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0xEFE6D3).withAlphaComponent(0.30)
                : NSColor(srgbHex: 0x221D16).withAlphaComponent(0.32)
        })

        /// 泛音青（纸墨下是墨绿）：`#2E6E66` / `#57ADA4`
        let teal = Color(token: 0x2E6E66, 0x57ADA4)
        /// 青色文字态：浅色压深到 4.5:1 以上，深色用预览的提亮档
        let tealText = Color(token: 0x245A54, 0x7CC4BC)
        /// 泛音青底色（预览 `--teal-tint`：浅 10% / 深 14%）
        let tealTint = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0x57ADA4).withAlphaComponent(0.14)
                : NSColor(srgbHex: 0x2E6E66).withAlphaComponent(0.10)
        })

        /// 遮罩：墨色 22% / 32%
        let scrim = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0xEFE6D3).withAlphaComponent(0.32)
                : NSColor(srgbHex: 0x221D16).withAlphaComponent(0.22)
        })
        /// 骨架扫光：纸面下就是细线（谐波线扫过）
        let shimmer = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0xEFE6D3).withAlphaComponent(0.16)
                : NSColor(srgbHex: 0x221D16).withAlphaComponent(0.16)
        })

        /// 玻璃三件套在纸墨下退化：1px 细线 + 无高光 + 无投影
        let glassBorder = Color(appearanceDynamic: { appearance in
            appearance.isDark
                ? NSColor(srgbHex: 0xEFE6D3).withAlphaComponent(0.16)
                : NSColor(srgbHex: 0x221D16).withAlphaComponent(0.16)
        })
        let clear = Color.clear

        /// 说明：纸墨的「信号」不在这里 —— 它跟随用户选的强调色阶
        /// （`AccentRamp.forChoice(_:style: .paper)`），由 `accentTokens` 提供。

        var palette: Palette {
            Palette(
                canvas: paperCanvas,
                surface: paperSheet,
                surfaceSunken: paperSunken,
                surfaceHover: paperHover,
                borderSubtle: hairline,
                borderDefault: hairline,
                borderStrong: hairlineStrong,
                textPrimary: ink,
                textSecondary: ink2,
                textTertiary: ink3,
                overtoneTeal: teal,
                tealText: tealText,
                tealTint: tealTint,
                success: teal,
                warning: Color(token: 0xA83420, 0xF07A58),
                danger: Color(token: 0xC2402A, 0xE85E3C),
                favorite: Color(token: 0xC2402A, 0xE85E3C),
                scrim: scrim,
                shimmer: shimmer,
                glassBorder: glassBorder,
                glassFill: paperSheet,
                glassFillStrong: paperSheet,
                glassFillThin: paperSheet,
                glassHighlight: clear,
                glassShadow: clear,
                // 纸墨下氛围层整体不渲染（`AmbientWash` 退化成 `Paper.canvas` 纯色），
                // 令牌仍指向纸面，免得别处直接取用拿到冲突色
                ambientIndigo: paperCanvas,
                ambientTeal: paperCanvas,
                ambientRose: paperCanvas,
                ambientAmber: paperCanvas,
                ambientBaseTop: paperCanvas,
                ambientBaseBottom: paperCanvas,
                inverseSurface: ink,
                textOnInverse: paperSheet,
                // 品牌面板**双主题固定反色**（v4 §2.1「像报纸的固定版头」）：
                // 深色主题下是更深的墨 `#100D09`，不是翻成浅底深字
                panelFill: Color(token: 0x221D16, 0x100D09),
                panelInk: Color(token: 0xF4EEE1, 0xEFE6D3)
            )
        }
    }

    /// 一套「当前风格」的语义令牌面。
    ///
    /// 字段全是 `Color` 引用（不是配方）：`Theme.canvas` 之类的 `static var` 直接读缓存字段，
    /// 每次访问返回同一个实例 —— 动态色按实例比较，现算会让 SwiftUI 的相等性跳过全部失效。
    private struct Palette {
        let canvas: Color
        let surface: Color
        let surfaceSunken: Color
        let surfaceHover: Color

        let borderSubtle: Color
        let borderDefault: Color
        let borderStrong: Color

        let textPrimary: Color
        let textSecondary: Color
        let textTertiary: Color

        let overtoneTeal: Color
        let tealText: Color
        let tealTint: Color

        let success: Color
        let warning: Color
        let danger: Color
        let favorite: Color

        let scrim: Color
        let shimmer: Color

        let glassBorder: Color
        let glassFill: Color
        let glassFillStrong: Color
        let glassFillThin: Color
        let glassHighlight: Color
        let glassShadow: Color

        let ambientIndigo: Color
        let ambientTeal: Color
        let ambientRose: Color
        let ambientAmber: Color
        let ambientBaseTop: Color
        let ambientBaseBottom: Color

        let inverseSurface: Color
        let textOnInverse: Color
        /// 反色版头（登录左栏 / 播放中大字）：纸墨下是**双主题固定**的墨底纸字
        let panelFill: Color
        let panelInk: Color

        /// 玻璃风格：字段直接指向 `GlassTokens` 的 `static let`（构造一次，永远同一实例）
        init(_ t: GlassTokens) {
            canvas = t.canvas
            surface = t.surface
            surfaceSunken = t.surfaceSunken
            surfaceHover = t.surfaceHover
            borderSubtle = t.borderSubtle
            borderDefault = t.borderDefault
            borderStrong = t.borderStrong
            textPrimary = t.textPrimary
            textSecondary = t.textSecondary
            textTertiary = t.textTertiary
            overtoneTeal = t.overtoneTeal
            tealText = t.tealText
            tealTint = t.tealTint
            success = t.success
            warning = t.warning
            danger = t.danger
            favorite = t.favorite
            scrim = t.scrim
            shimmer = t.shimmer
            glassBorder = t.glassBorder
            glassFill = t.glassFill
            glassFillStrong = t.glassFillStrong
            glassFillThin = t.glassFillThin
            glassHighlight = t.glassHighlight
            glassShadow = t.glassShadow
            ambientIndigo = t.ambientIndigo
            ambientTeal = t.ambientTeal
            ambientRose = t.ambientRose
            ambientAmber = t.ambientAmber
            ambientBaseTop = t.ambientBaseTop
            ambientBaseBottom = t.ambientBaseBottom
            inverseSurface = t.inverseSurface
            textOnInverse = t.textOnInverse
            // 玻璃下没有「固定版头」概念，等价物就是反色层（浅色深底 / 深色浅底）
            panelFill = t.inverseSurface
            panelInk = t.textOnInverse
        }

        /// 棱镜风格：字段与玻璃一一对应，只是取值换成白卡 / 紫调那一套。
        init(_ t: PrismTokens) {
            canvas = t.canvas
            surface = t.surface
            surfaceSunken = t.surfaceSunken
            surfaceHover = t.surfaceHover
            borderSubtle = t.borderSubtle
            borderDefault = t.borderDefault
            borderStrong = t.borderStrong
            textPrimary = t.textPrimary
            textSecondary = t.textSecondary
            textTertiary = t.textTertiary
            overtoneTeal = t.overtoneTeal
            tealText = t.tealText
            tealTint = t.tealTint
            success = t.success
            warning = t.warning
            danger = t.danger
            favorite = t.favorite
            scrim = t.scrim
            shimmer = t.shimmer
            glassBorder = t.glassBorder
            glassFill = t.glassFill
            glassFillStrong = t.glassFillStrong
            glassFillThin = t.glassFillThin
            glassHighlight = t.glassHighlight
            glassShadow = t.glassShadow
            ambientIndigo = t.ambientIndigo
            ambientTeal = t.ambientTeal
            ambientRose = t.ambientRose
            ambientAmber = t.ambientAmber
            ambientBaseTop = t.ambientBaseTop
            ambientBaseBottom = t.ambientBaseBottom
            inverseSurface = t.inverseSurface
            textOnInverse = t.textOnInverse
            // 棱镜的登录左栏 / 播放页大字同样走反色层（白底深字 / 深底浅字）
            panelFill = t.inverseSurface
            panelInk = t.textOnInverse
        }

        /// 纸墨风格：显式传入（`InkTokens` 里有几处是同一份纸色复用）
        init(
            canvas: Color,
            surface: Color,
            surfaceSunken: Color,
            surfaceHover: Color,
            borderSubtle: Color,
            borderDefault: Color,
            borderStrong: Color,
            textPrimary: Color,
            textSecondary: Color,
            textTertiary: Color,
            overtoneTeal: Color,
            tealText: Color,
            tealTint: Color,
            success: Color,
            warning: Color,
            danger: Color,
            favorite: Color,
            scrim: Color,
            shimmer: Color,
            glassBorder: Color,
            glassFill: Color,
            glassFillStrong: Color,
            glassFillThin: Color,
            glassHighlight: Color,
            glassShadow: Color,
            ambientIndigo: Color,
            ambientTeal: Color,
            ambientRose: Color,
            ambientAmber: Color,
            ambientBaseTop: Color,
            ambientBaseBottom: Color,
            inverseSurface: Color,
            textOnInverse: Color,
            panelFill: Color,
            panelInk: Color
        ) {
            self.canvas = canvas
            self.surface = surface
            self.surfaceSunken = surfaceSunken
            self.surfaceHover = surfaceHover
            self.borderSubtle = borderSubtle
            self.borderDefault = borderDefault
            self.borderStrong = borderStrong
            self.textPrimary = textPrimary
            self.textSecondary = textSecondary
            self.textTertiary = textTertiary
            self.overtoneTeal = overtoneTeal
            self.tealText = tealText
            self.tealTint = tealTint
            self.success = success
            self.warning = warning
            self.danger = danger
            self.favorite = favorite
            self.scrim = scrim
            self.shimmer = shimmer
            self.glassBorder = glassBorder
            self.glassFill = glassFill
            self.glassFillStrong = glassFillStrong
            self.glassFillThin = glassFillThin
            self.glassHighlight = glassHighlight
            self.glassShadow = glassShadow
            self.ambientIndigo = ambientIndigo
            self.ambientTeal = ambientTeal
            self.ambientRose = ambientRose
            self.ambientAmber = ambientAmber
            self.ambientBaseTop = ambientBaseTop
            self.ambientBaseBottom = ambientBaseBottom
            self.inverseSurface = inverseSurface
            self.textOnInverse = textOnInverse
            self.panelFill = panelFill
            self.panelInk = panelInk
        }
    }

    // MARK: v4 纸墨令牌（§2.1）—— glass 下同样可用（返回等价玻璃色）
    /// 纸 / 墨 / 信号原始令牌。
    ///
    /// 两种模式下**都可无条件访问**：玻璃模式返回与语义令牌等价的玻璃色，
    /// 这样组件写 `Theme.Paper.hairline` 时不必到处判风格，也不会在切换瞬间拿到 nil。
    enum Paper {
        /// 纸 · 画布 `#F4EEE1` / `#17130E`
        static var canvas: Color { Theme.state.active.canvas }
        /// 纸 · 页面（卡片 / 白纸）`#FBF7EC` / `#201A13`
        static var sheet: Color { Theme.state.active.surface }
        /// 纸 · 凹陷 `#EDE5D2` / `#17120C`
        static var sunken: Color { Theme.state.active.surfaceSunken }
        /// 纸 · 悬停 `#EFE7D4` / `#272017`
        static var hover: Color { Theme.state.active.surfaceHover }
        /// 墨 · 主文字 `#221D16` / `#EFE6D3`
        static var ink: Color { Theme.state.active.textPrimary }
        /// 墨 · 次级 `#5F5749` / `#A99C86`
        static var ink2: Color { Theme.state.active.textSecondary }
        /// 墨 · 三级 `#8B8170` / `#7C7260`
        static var ink3: Color { Theme.state.active.textTertiary }
        /// 信号红 `#C2402A` / `#E85E3C`（纸墨下也跟随用户选的强调色）
        static var signal: Color { Theme.brand500 }
        /// 信号红 · 文字用 `#A83420` / `#F07A58`（小字 / 链接）
        static var signalInk: Color { Theme.brandText }
        /// 信号红底色（浅 9% / 深 14%）
        static var signalTint: Color { Theme.brandTint }
        /// 泛音青 `#2E6E66` / `#57ADA4`
        static var teal: Color { Theme.state.active.overtoneTeal }
        /// 泛音青底色
        static var tealTint: Color { Theme.state.active.tealTint }
        /// 细线 `rgba(34,29,22,.16)` / `rgba(239,230,211,.16)`
        static var hairline: Color { Theme.state.active.borderSubtle }
        /// 强线 `.32` / `.30`
        static var hairlineStrong: Color { Theme.state.active.borderStrong }
        /// 实心墨块（选中态）= **当前主题的墨**，深色主题下就是浅墨
        static var inkFill: Color { Theme.state.active.textPrimary }
        /// 反色版头（登录左栏 / 播放中大字）底：预览 `--pane-bg`。
        ///
        /// **双主题固定反色**（v4 §2.1：「像报纸的固定版头」）—— 深色主题下不是翻成浅底，
        /// 而是更深的墨 `#100D09`；所以取值来自缓存里那对固定色，不走 `state.active`
        /// 的语义映射（那套映射在深色下会把「墨」解析成浅色文字档）。
        static var panelFill: Color { Theme.state.active.panelFill }
        /// 反色版头上的字：预览 `--pane-fg`，同样双主题固定（浅色纸 / 深色米墨）
        static var panelInk: Color { Theme.state.active.panelInk }

        /// 设置页强调色色块固定值（也是纸墨模式的成对色阶）
        static let accentSignal = Color(hex: 0xC2402A)
        static let accentIndigo = Color(hex: 0x4C53D8)
        static let accentTeal = Color(hex: 0x12B8A6)
        static let accentPurple = Color(hex: 0x7C4DDB)
    }

    // MARK: 语义（Semantic）

    static var success: Color { state.active.success }
    static var warning: Color { state.active.warning }
    static var danger: Color { state.active.danger }
    static var favorite: Color { state.active.favorite }

    // MARK: 遮罩

    /// 抽屉展开时覆盖内容区的遮罩（深色底上需更强对比）
    static var scrim: Color { state.active.scrim }
    /// 封面 hover 时的压暗层（压在图片上，两主题 / 两风格一致）
    static let coverScrim = Color.black.opacity(0.32)
    /// 骨架屏微光扫动（深色下只轻微提亮）；纸墨下换成谐波线扫过（`Paper.hairline`）
    static var shimmer: Color { state.active.shimmer }

    // MARK: 玻璃材质（§7.1 Liquid Glass）—— 纸墨下这些令牌解析成纸面（无玻璃）

    /// 玻璃层 1px 描边（浅色下替代阴影分层，深色下是唯一的分层手段）
    static var glassBorder: Color { state.active.glassBorder }

    /// 小控件的半透明玻璃底（`glass.regular`，不做 blur —— §7.2 规则 4 性能预算）
    static var glassFill: Color { state.active.glassFill }
    /// 强一档的玻璃底（`glass.thick`：播放条、菜单、弹窗、Toast）
    static var glassFillStrong: Color { state.active.glassFillStrong }
    /// 更薄一档（`glass.thin`：顶栏、分段容器、次级控件底）
    static var glassFillThin: Color { state.active.glassFillThin }

    /// 顶部镜面高光（specular）：1px 内高光，玻璃面板与控件共用；纸墨下退化为透明
    static var glassHighlight: Color { state.active.glassHighlight }

    /// 玻璃面板投影：浅色主题下玻璃浮起需要一点投影，深色下几乎不可见；纸墨下退化为透明
    static var glassShadow: Color { state.active.glassShadow }

    // MARK: 氛围层（§7.1 ambient）—— 玻璃之下必须有可透的内容
    //
    // 纸墨下 `AmbientWash` 整体不渲染（返回 `Paper.canvas` 纯色），这些令牌仍按纸面解析，
    // 免得别处直接取用时拿到与纸面冲突的颜色。

    /// 氛围 wash 的四组取色（浅色 α .42–.55 / 深色 α .10–.30，与预览一致）
    static var ambientIndigo: Color { state.active.ambientIndigo }
    static var ambientTeal: Color { state.active.ambientTeal }
    static var ambientRose: Color { state.active.ambientRose }
    static var ambientAmber: Color { state.active.ambientAmber }
    /// 氛围层底色（渐变两端）
    static var ambientBaseTop: Color { state.active.ambientBaseTop }
    static var ambientBaseBottom: Color { state.active.ambientBaseBottom }

    // MARK: 反色层（Toast 等浮层）

    /// 反色底：浅色主题深底、深色主题浅底；纸墨下 = 墨 / 纸（固定版头同款）
    static var inverseSurface: Color { state.active.inverseSurface }
    /// 反色底上的文字
    static var textOnInverse: Color { state.active.textOnInverse }

    // MARK: 主题应用

    /// 应用主题（浅色 / 深色 / 跟随系统）。
    ///
    /// 令牌是**绘制时**按外观解析的动态色，所以只换 `NSApp.appearance` 即可全局生效，
    /// AppKit 会重新解析并重绘；不需要重建视图树，也不丢导航与滚动状态。
    @MainActor
    static func applyTheme(_ choice: AppSettings.ThemeChoice) {
        NSApp.appearance = choice.appearance
    }

    /// 启动时按持久化的设置应用外观（`AppDelegate` 是非隔离上下文，直接读 UserDefaults）
    static func applyStoredTheme() {
        let stored = UserDefaults.standard.string(forKey: "settings.theme") ?? ""
        NSApp.appearance = AppSettings.ThemeChoice(storedRawValue: stored).appearance
    }

    /// 强调色变更后让全应用按新色阶重绘。
    ///
    /// SwiftUI 不会因为全局变量变化就重算所有 body，但动态 NSColor 是**绘制时**解析的：
    /// 切一次外观再切回来会让 AppKit 重新解析所有动态色并重绘。
    /// 实测（同机四组对照）：
    /// - 同一轮 runloop 内切回 → **无效**（两次赋值被合并，等于没变）
    /// - 下一轮 runloop 切回 → 有效 ✅
    /// - 同名新实例 / 仅 needsDisplay → 无效
    ///
    /// 中间那一帧用的是**高对比同色系**外观（深色下切高对比深色），本应用令牌解析出的
    /// 明暗不变，因此不会闪；只有系统控件会短暂换成高对比绘制。
    @MainActor
    static func refreshAccent() {
        let appearance = NSApp.appearance
        let dark = (appearance ?? NSApp.effectiveAppearance).isDark
        NSApp.appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
        DispatchQueue.main.async { NSApp.appearance = appearance }
    }

    // MARK: - 间距（4pt 基线）

    enum Spacing {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 8
        static let lg: CGFloat = 12
        static let xl: CGFloat = 16
        static let xxl: CGFloat = 20
        static let xxxl: CGFloat = 24
        /// 区块间距
        static let section: CGFloat = 32
        static let page: CGFloat = 40
        static let huge: CGFloat = 48
    }

    // MARK: - 圆角（收敛为 6 档；纸墨下一律收紧到印刷品的直角感）

    /// 形状族：玻璃 4/6/10/14/20；纸墨 2/3/3/4/6（v4 §2.3「统一 3px」，封面 2）。
    ///
    /// 与颜色令牌同样**只从缓存读**（`Radius` 是热路径：每张卡片、每个按钮都取），
    /// 所以不是每次访问现算 if，而是读 `state.style` 里的一个 `CGFloat`。
    enum Radius {
        static var xs: CGFloat { Theme.state.radius.xs }
        static var sm: CGFloat { Theme.state.radius.sm }
        static var md: CGFloat { Theme.state.radius.md }
        static var lg: CGFloat { Theme.state.radius.lg }
        static var xl: CGFloat { Theme.state.radius.xl }
        /// 胶囊：两风格一致
        static var full: CGFloat { 999 }
        /// 封面（v4 §2.3：纸墨封面 2px；玻璃沿用面板圆角档）
        static var cover: CGFloat { Theme.state.radius.cover }
    }

    // MARK: - 阴影（3 档 + 焦点环）

    enum Elevation {
        /// 卡片静态
        case e1
        /// hover / 下拉 / 面板
        case e2
        /// 正在播放大封面、设置窗口
        case e3

        /// 阴影色（缓存实例：每次访问都新建的 `Color` 不相等，会破坏 SwiftUI 的跳过机制）
        static let color = Color(hex: 0x10141C)
    }

    // MARK: - 动效

    enum Motion {
        /// 120ms —— 按压、hover 换底
        static let micro = Animation.timingCurve(0.2, 0, 0.2, 1, duration: 0.12)
        /// 200ms —— 下拉、面板、Toast、侧栏宽度
        static let base = Animation.timingCurve(0.2, 0, 0.2, 1, duration: 0.2)
        /// 260ms —— 页面切换（位移 8pt + 淡入）
        static let page = Animation.timingCurve(0.2, 0, 0.2, 1, duration: 0.26)
        /// spring(0.35 / 0.85) —— 迷你播放条、卡片入场
        static let spring = Animation.spring(response: 0.35, dampingFraction: 0.85)
        /// 列表错落入场：30ms × index，最多 10 项
        static func stagger(index: Int) -> Animation {
            .timingCurve(0.2, 0, 0.2, 1, duration: 0.26)
                .delay(Double(min(index, 10)) * 0.03)
        }
        /// Reduce Motion 下仅保留 120ms 透明度过渡
        static let reduced = Animation.linear(duration: 0.12)
    }

    /// 卡片 hover 上浮距离：玻璃 −2pt；纸墨 0（v4 不用上浮，改用封面按压）。
    /// Reduce Motion 下恒为 0（§7）。
    static func lift(_ hovered: Bool, reduceMotion: Bool) -> CGFloat {
        guard hovered, !reduceMotion, !isPaper else { return 0 }
        return -2
    }

    // MARK: - 尺寸常量（组件规格，对应 §5）

    enum Size {
        /// 一级导航图标栏宽度（W0/W1）
        static let railWidth: CGFloat = 64
        /// 完整侧栏默认宽度（W3/W4）
        static let sidebarWidth: CGFloat = 240
        /// 完整侧栏最小/最大宽度（可拖拽）
        static let sidebarMin: CGFloat = 180
        static let sidebarMax: CGFloat = 320
        /// 内容区顶栏
        static let topBarHeight: CGFloat = 64
        /// 窗口左上角留给红黄绿三键的空白条高度（透明标题栏 + fullSizeContentView）。
        ///
        /// 三键被移进悬浮侧栏面板内（首键左上角 (20,20)，16pt 高 → 到 36pt），
        /// 面板内边距 10 起算，所以内容顶部要留 10 + 34 = 44pt 才不压到三键。
        static let windowChromeHeight: CGFloat = 34
        /// 详情页面包屑栏
        static let crumbBarHeight: CGFloat = 44
        /// 迷你播放条（实体 68 / 玻璃 60，宽窄一致）
        static let playerBarHeight: CGFloat = 68
        static let playerBarHeightGlass: CGFloat = 60
        /// 悬浮面板外边距与面板间距（§7.2 规则 2）
        static let panelMargin: CGFloat = 10
        static let panelGap: CGFloat = 12
        /// 悬浮面板统一圆角（窗口 / 顶栏 / 侧栏 / 播放条 / 抽屉 / 全部封面）
        /// —— 跟随 `Radius.md`：玻璃 10 / 纸墨 3（`Theme.Size.panelRadius` 是 `static var`，
        /// 但只在布局路径读取，没有实例稳定性要求）
        static var panelRadius: CGFloat { Radius.md }
        /// 列表行 / 曲目行
        static let listRowHeight: CGFloat = 48
        static let trackRowHeight: CGFloat = 44
        /// 图标按钮三档
        static let iconButtonSm: CGFloat = 28
        static let iconButtonMd: CGFloat = 32
        static let iconButtonLg: CGFloat = 44
        /// 分段控件：容器 36 / 段 28
        static let segmentedHeight: CGFloat = 36
        static let segmentHeight: CGFloat = 28
        /// 输入框
        static let fieldHeight: CGFloat = 32
        static let formFieldHeight: CGFloat = 44
        /// 按钮
        static let buttonHeight: CGFloat = 44
        static let buttonHeightSm: CGFloat = 32
        /// 详情页封面
        static let detailCover: CGFloat = 220
        /// 迷你播放条封面
        static let playerCover: CGFloat = 48
        /// 正在播放右栏（待播清单）
        static let queuePanelWidth: CGFloat = 320
        /// 设置窗口
        static let settingsNavWidth: CGFloat = 180
        /// 设置内容列的最大宽度：720 窗口时代是 480，内容列被两侧留白挤得很窄
        /// （表单卡只有 480）；加宽到 640 后，带说明文字 + 右侧控件的行不再互相挤。
        static let settingsFormWidth: CGFloat = 640
        /// 设置窗口尺寸：导航 180 + 分隔线 + 内容列（640 + 两边 20 留白）
        static let settingsWindowWidth: CGFloat = 880
        static let settingsWindowHeight: CGFloat = 560
    }

    // MARK: - 字体层级（相对动态字号，最小 11pt）

    /// 字号令牌。配合 `.textStyle(_:)` 使用，随系统文本大小缩放。
    enum TextStyle: CaseIterable {
        case display
        case title1
        case title2
        case title3
        case title4
        case bodyLG
        case body
        case bodySM
        case footnote
        case caption
        /// 时间码 / 数值（SF Mono，避免跳动）
        case mono
        case monoSM

        var size: CGFloat {
            switch self {
            case .display: return 34
            case .title1: return 28
            case .title2: return 22
            case .title3: return 18
            case .title4: return 16
            case .bodyLG: return 15
            case .body: return 14
            case .bodySM: return 13
            case .footnote: return 12
            case .caption: return 11
            case .mono: return 12
            case .monoSM: return 11
            }
        }

        var weight: Font.Weight {
            switch self {
            case .display, .title1, .title2: return .bold
            case .title3, .title4: return .semibold
            case .caption: return .semibold
            case .body, .bodyLG, .bodySM, .footnote: return .regular
            case .mono, .monoSM: return .regular
            }
        }

        var design: Font.Design {
            switch self {
            case .mono, .monoSM:
                return .monospaced
            case .display, .title1, .title2, .title3:
                // v4 §2.2：页面大标题 / 专辑名 / 艺人名走衬线（印刷感）；正文与导航保持无衬线。
                // 玻璃模式恒为 .default，渲染与 v3 一致。纸墨下 SwiftUI 会按系统衬线族
                // （macOS 上即 New York / 宋体系）解析，中文回落到系统衬线映射。
                return Theme.isPaper ? .serif : .default
            default:
                return .default
            }
        }

        /// 动态字号缩放基准
        var relativeTo: Font.TextStyle {
            switch self {
            case .display, .title1: return .largeTitle
            case .title2, .title3: return .title2
            case .title4: return .title3
            case .bodyLG, .body: return .body
            case .bodySM: return .callout
            case .footnote, .mono: return .footnote
            case .caption, .monoSM: return .caption
            }
        }

        /// 额外行距（目标行高 − 字号 × 1.2，下限 0）
        var lineSpacing: CGFloat {
            let target: CGFloat
            switch self {
            case .display: target = 40
            case .title1: target = 34
            case .title2: target = 28
            case .title3: target = 26
            case .title4: target = 24
            case .bodyLG: target = 22
            case .body: target = 20
            case .bodySM: target = 18
            case .footnote: target = 16
            case .caption: target = 16
            case .mono: target = 16
            case .monoSM: target = 16
            }
            return max(0, target - size * 1.2)
        }
    }
}

// MARK: - 字号修饰符（相对动态字号）

private struct ScaledTextStyleModifier: ViewModifier {
    let style: Theme.TextStyle
    var weight: Font.Weight?
    var color: Color?

    @ScaledMetric private var scale: CGFloat

    init(style: Theme.TextStyle, weight: Font.Weight?, color: Color?) {
        self.style = style
        self.weight = weight
        self.color = color
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        let styled = content
            .font(.system(size: style.size * scale, weight: weight ?? style.weight, design: style.design))
            .lineSpacing(style.lineSpacing * scale)
        // 只有**显式给了颜色**时才写 `foregroundStyle`；省略 `color` 一律继承外层。
        //
        // 为什么不能有「隐式默认 = textPrimary」：这个修饰符直接作用在 Text 上，它写下的
        // 那层 `foregroundStyle` 会盖掉祖先容器的颜色 —— 按钮样式（`PrimaryButtonStyle`
        // 的纸底字）、选中行（侧栏 `foreground`）、语义色容器（`.foregroundStyle(Theme.danger)`
        // 的错误文案）全部被压成 textPrimary。纸墨模式下就表现为墨块上的墨字：
        // 侧栏选中行的文字整个消失（2026-10-14 截图复现）。
        // 需要 textPrimary 的调用点显式传 `color:` —— 全仓 185 处里 180 处本来就显式传。
        if let color = color {
            styled.foregroundStyle(color)
        } else {
            styled
        }
    }
}

extension View {
    /// 应用令牌字号（随系统文本大小缩放）+ 颜色。
    ///
    /// `color` 省略时**不写颜色**：文字颜色由环境 / 外层 `.foregroundStyle` 决定
    /// （见 `ScaledTextStyleModifier.body` 的注释）。要 `textPrimary` 就显式传。
    func textStyle(_ style: Theme.TextStyle, weight: Font.Weight? = nil, color: Color? = nil) -> some View {
        modifier(ScaledTextStyleModifier(style: style, weight: weight, color: color))
    }

    /// 分组标题：11pt 大写 + tracking 0.06em（仅用于非正文）
    func sectionCaption() -> some View {
        self
            .textStyle(.caption, color: Theme.textTertiary)
            .textCase(.uppercase)
            .tracking(0.66)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - 阴影

private struct ElevationModifier: ViewModifier {
    let elevation: Theme.Elevation
    var cornerRadius: CGFloat?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let dark = colorScheme == .dark
        // 深色下投影几乎不可见，按 §4.2 规则 1 降到 30% 强度
        let scale = dark ? 0.3 : 1.0
        // 按档位展开成固定层数：不再用 AnyView 逐层包裹。
        // AnyView 会抹掉静态类型、让 SwiftUI 无法按结构比较视图，
        // 而这段修饰符挂在每一张卡片 / 每一行上，代价被行数放大。
        let shadowed = Group {
            if Theme.isPaper {
                // v4 §2.1：不用投影，层次靠纸墨反差与 1px 细线；
                // 唯一例外是 Toast 的「活版压印」硬阴影（§4.8，2px 偏移、零模糊）。
                // e1/e2 因此完全不挂 shadow —— 连离屏通道都不开。
                switch elevation {
                case .e1, .e2:
                    content
                case .e3:
                    content.shadow(color: Theme.Paper.ink.opacity(0.22), radius: 0, x: 0, y: 2)
                }
            } else {
                switch elevation {
                case .e1:
                    content.shadow(color: Theme.Elevation.color.opacity(0.06 * scale), radius: 1, y: 1)
                case .e2:
                    content
                        .shadow(color: Theme.Elevation.color.opacity(0.08 * scale), radius: 4, y: 2)
                        .shadow(color: Theme.Elevation.color.opacity(0.06 * scale), radius: 1, y: 1)
                case .e3:
                    content
                        .shadow(color: Theme.Elevation.color.opacity(0.12 * scale), radius: 14, y: 12)
                        .shadow(color: Theme.Elevation.color.opacity(0.06 * scale), radius: 3, y: 2)
                }
            }
        }
        if Theme.isPaper {
            // 纸墨下深色主题也靠细线分层，索性两套主题都画：纸面无描边会「糊」在画布上
            if let cornerRadius {
                shadowed.overlay {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(Theme.Paper.hairline)
                }
            } else {
                shadowed
            }
        } else if dark, let cornerRadius {
            // 深色层级主要由描边承担（表面明度阶梯 + borderSubtle 描边）
            shadowed.overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.borderSubtle)
            }
        } else {
            shadowed
        }
    }
}

extension View {
    /// 应用 3 档阴影之一。
    ///
    /// 深色主题下投影不可见，改为「弱投影 + 描边」表达层级 —— 传入圆角即会画描边。
    func elevation(_ elevation: Theme.Elevation, cornerRadius: CGFloat? = nil) -> some View {
        modifier(ElevationModifier(elevation: elevation, cornerRadius: cornerRadius))
    }
}

// MARK: - 焦点环（替代系统蓝框）

/// 键盘可见的焦点环：1px 强调色 + 3px 光晕；纸墨下改 1px 墨线（v4 的选中/焦点是墨，不是红）。
/// 需要与 `@FocusState` / `focusable()` 配合使用。
struct FocusRing: ViewModifier {
    let isFocused: Bool
    var cornerRadius: CGFloat = Theme.Radius.md

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(ringColor, lineWidth: 1)
                    .opacity(isFocused ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3)
                    .strokeBorder(ringColor.opacity(0.28), lineWidth: 3)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            }
            .animation(Theme.Motion.micro, value: isFocused)
    }

    /// 玻璃 = 品牌色（跟随强调色的焦点语义）；纸墨 = 墨色（信号红只属于声音）
    private var ringColor: Color {
        Theme.isPaper ? Theme.Paper.ink : Theme.brandText
    }
}

extension View {
    func focusRing(_ isFocused: Bool, cornerRadius: CGFloat = Theme.Radius.md) -> some View {
        modifier(FocusRing(isFocused: isFocused, cornerRadius: cornerRadius))
    }
}

// MARK: - Liquid Glass 材质（§7）

/// 玻璃材质三档（§7.1）。
///
/// 双层结构（§7.2 规则 1）：**chrome 层**（侧栏 / 顶栏 / 播放条 / 抽屉 / 菜单 / 弹窗 /
/// Toast / 次级控件）走玻璃，**内容层**（卡片、表格、设置卡、曲目行）保持不透明 `surface`。
/// 玻璃只给「框」，不给「内容」。
enum GlassMaterial {
    /// 顶栏、分段容器、次级控件底
    case thin
    /// 侧栏、抽屉、搜索框、胶囊按钮
    case regular
    /// 播放条、菜单、弹窗、Toast
    case thick

    /// macOS 13–25 的回退材质（§7.4）
    var fallback: Material {
        switch self {
        case .thin: return .ultraThinMaterial
        case .regular: return .regularMaterial
        case .thick: return .thickMaterial
        }
    }
}

/// 「降低透明度」环境值（§7.3 可访问性回退）。
private struct ReduceTransparencyKey: EnvironmentKey {
    static let defaultValue = false
}

/// 「玻璃表面」环境值：玻璃之下必须有可透的内容（§7.2 规则 3）。
///
/// 独立设置窗口没有氛围层，玻璃在那里只会得到「白底上的半透明白」——
/// 观感与对比度双输，所以设置场景把它关掉，控件回落 `surfaceSunken` 实底。
private struct GlassSurfacesKey: EnvironmentKey {
    static let defaultValue = true
}

/// 视觉风格环境值：给「必须按风格改结构」（而不只是改色）的视图用。
///
/// 为什么要有它：`Theme.isPaper` 是全局镜像，读它**不会**让视图订阅变化 ——
/// 视图得靠 `.id(settings.visualStyle)` 重建，或者靠注入的环境值参与相等性比较。
/// 默认 `.glass`，所以没注入的场景（预览、单元测试）行为与 v3 一致。
private struct VisualStyleKey: EnvironmentKey {
    static let defaultValue = VisualStyle.glass
}

extension EnvironmentValues {
    /// 系统「辅助功能 → 显示 → 降低透明度」；开启后全部玻璃换回实底材质。
    var appReduceTransparency: Bool {
        get { self[ReduceTransparencyKey.self] }
        set { self[ReduceTransparencyKey.self] = newValue }
    }

    /// 当前场景是否使用玻璃表面（主窗口 true / 独立设置窗口 false）
    var appGlassSurfaces: Bool {
        get { self[GlassSurfacesKey.self] }
        set { self[GlassSurfacesKey.self] = newValue }
    }

    /// 当前视觉风格（玻璃 / 纸墨）；由 scene 层注入 `AppSettings.visualStyle`
    var appVisualStyle: VisualStyle {
        get { self[VisualStyleKey.self] }
        set { self[VisualStyleKey.self] = newValue }
    }
}

/// 监听系统「降低透明度」变化（切换后立即重绘，不需要重启）。
@MainActor
final class AccessibilityDisplayObserver: ObservableObject {
    static let shared = AccessibilityDisplayObserver()

    @Published private(set) var reduceTransparency =
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let value = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
            if self.reduceTransparency != value { self.reduceTransparency = value }
        }
    }
}

/// 玻璃面板：chrome 层的统一材质。
///
/// - macOS 26+ 走 `glassEffect`（配合系统 Liquid Glass）；
/// - macOS 13–25 回退 `.ultraThinMaterial / .regularMaterial / .thickMaterial`；
/// - 「降低透明度」开启时回落 `surface` 实底 + `borderSubtle` 描边 + `e1`（§7.3）。
///
/// 浅色玻璃单靠投影浮不起来，所以玻璃态额外叠一层 `glassBorder` 描边与顶部镜面高光。
private struct GlassPanelModifier: ViewModifier {
    var material: GlassMaterial = .regular
    var cornerRadius: CGFloat = Theme.Radius.md
    /// 面板投影档位；传 nil 表示不要投影（内嵌控件用）
    var elevation: Theme.Elevation? = .e2
    /// 叠在材质之上的染色层（Toast 的反色面等）；实底回退态同样叠加，保证对比度
    var tint: Color?

    @Environment(\.appReduceTransparency) private var reduceTransparency
    @Environment(\.appGlassSurfaces) private var glassSurfaces
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let paper = Theme.isPaper
        // 棱镜：不调用 Material / glassEffect —— 白卡 + 柔和投影就是这套风格的全部材质。
        // 与纸墨的区别是「有投影、圆角更大、表面是纯白而不是纸色」。
        let prism = Theme.isPrism
        content
            .background { backdrop(shape: shape) }
            .overlay {
                if let tint { shape.fill(tint) }
            }
            .overlay {
                shape.strokeBorder(
                    paper || prism || reduceTransparency || !glassSurfaces
                        ? (paper ? Theme.Paper.hairline : Theme.borderSubtle)
                        : Theme.glassBorder
                )
            }
            .overlay(alignment: .top) {
                // 顶部镜面高光：1px 内高光，让玻璃「有厚度」（纸墨 / 棱镜无高光）
                if !paper && !prism && !reduceTransparency && glassSurfaces {
                    Rectangle()
                        .fill(Theme.glassHighlight)
                        .frame(height: 1)
                        .padding(.horizontal, cornerRadius)
                }
            }
            .clipShape(shape)
            .modifier(GlassShadow(elevation: elevation, solid: reduceTransparency || !glassSurfaces))
    }

    @ViewBuilder
    private func backdrop(shape: RoundedRectangle) -> some View {
        if Theme.isPaper {
            // 纸墨：不透明纸面，**不调用任何 Material / glassEffect** ——
            // v4 的 chrome 直接落在纸面上（`Paper.sheet`），透出下层氛围反而会脏
            shape.fill(Theme.Paper.sheet)
        } else if Theme.isPrism {
            // 棱镜：纯白 / 深灰实底卡，投影与细线做层级（Apple Music 式）
            shape.fill(Theme.surface)
        } else if reduceTransparency || !glassSurfaces {
            // 回退：surface 实底（对比度复核过的组合）
            shape.fill(Theme.surface)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(material.fallback)
        }
    }
}

/// 玻璃面板投影：深色下投影不可见，只保留极弱一层；实底回退态用标准 e1/e2。
/// 纸墨下**一律不出投影**（v4 §2.1 零投影，层次靠细线 + 纸墨反差）。
private struct GlassShadow: ViewModifier {
    let elevation: Theme.Elevation?
    let solid: Bool

    /// 单层投影参数（nil 档位 / 纸墨 = 不投影）
    private var shadow: (opacity: Double, radius: CGFloat, y: CGFloat)? {
        if Theme.isPaper { return nil }
        // 棱镜：投影要比玻璃更「浮」一点（白卡需要阴影才能离开浅灰画布），
        // 半径更大、透明度略低，接近 Apple Music 的柔和悬浮。
        if Theme.isPrism {
            switch elevation {
            case .none: return nil
            case .e1: return (solid ? 0.05 : 0.08, 6, 3)
            case .e2: return (solid ? 0.07 : 0.12, 16, 8)
            case .e3: return (solid ? 0.10 : 0.16, 28, 16)
            }
        }
        switch elevation {
        case .none: return nil
        case .e1: return (solid ? 0.06 : 0.10, 4, 2)
        case .e2: return (solid ? 0.08 : 0.14, 10, 6)
        case .e3: return (solid ? 0.12 : 0.18, 20, 12)
        }
    }

    func body(content: Content) -> some View {
        // ViewBuilder 的 if/else 生成 _ConditionalContent（静态类型，SwiftUI 可结构比较），
        // 不像 AnyView 那样抹掉类型；nil 档位直接不挂 shadow，避免无谓的离屏通道
        if let spec = shadow {
            content.shadow(
                color: Theme.glassShadow.opacity(spec.opacity / 0.14),
                radius: spec.radius,
                y: spec.y
            )
        } else {
            content
        }
    }
}

extension View {
    /// 把视图包成玻璃面板（chrome 层专用，§7.2）。
    func glassPanel(
        _ material: GlassMaterial = .regular,
        cornerRadius: CGFloat = Theme.Radius.md,
        elevation: Theme.Elevation? = .e2,
        tint: Color? = nil
    ) -> some View {
        modifier(
            GlassPanelModifier(
                material: material,
                cornerRadius: cornerRadius,
                elevation: elevation,
                tint: tint
            )
        )
    }

    /// 小控件的「仿玻璃」外观：半透明底 + 玻璃描边 + 顶部高光，**不做 blur**。
    ///
    /// §7.2 规则 4 的性能预算：同屏可见 blur 层 ≤ 4，所以只有大面板走真材质，
    /// 按钮 / 输入框 / 分段容器 / 胶囊这类成排出现的小控件用半透明表面等价呈现 ——
    /// 底下就是氛围层，透出来的观感与磨砂玻璃一致，代价为零。
    func glassControl(
        cornerRadius: CGFloat = Theme.Radius.md,
        strength: GlassMaterial = .regular
    ) -> some View {
        modifier(GlassControlModifier(cornerRadius: cornerRadius, strength: strength))
    }
}

private struct GlassControlModifier: ViewModifier {
    let cornerRadius: CGFloat
    let strength: GlassMaterial

    @Environment(\.appReduceTransparency) private var reduceTransparency
    @Environment(\.appGlassSurfaces) private var glassSurfaces

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        let paper = Theme.isPaper
        let prism = Theme.isPrism
        content
            .background { shape.fill(fill) }
            .overlay {
                shape.strokeBorder(
                    paper ? Theme.Paper.hairline
                        : (prism ? Theme.borderSubtle : (solid ? Theme.borderDefault : Theme.glassBorder))
                )
            }
            .overlay(alignment: .top) {
                // 纸墨 / 棱镜：无高光，控件只是一个实底 + 1px 细线
                if !paper && !prism && !solid {
                    Rectangle()
                        .fill(Theme.glassHighlight)
                        .frame(height: 1)
                        .padding(.horizontal, cornerRadius)
                }
            }
            .clipShape(shape)
    }

    private var solid: Bool { reduceTransparency || !glassSurfaces }

    private var fill: Color {
        // 纸墨：无玻璃，控件底直接是纸（thin 档用凹陷纸，与分段容器/输入框的 v3 语义对齐）
        if Theme.isPaper {
            return strength == .thin ? Theme.Paper.sunken : Theme.Paper.sheet
        }
        // 棱镜：白卡风格 —— 分段容器 / 输入框用浅灰凹陷，按钮用白底
        if Theme.isPrism {
            return strength == .thin ? Theme.surfaceSunken : Theme.surface
        }
        guard !solid else {
            // 实底场景：分段容器/输入框回落 sunken，按钮回落 surface
            return strength == .thin ? Theme.surfaceSunken : Theme.surface
        }
        switch strength {
        case .thin: return Theme.glassFillThin
        case .regular: return Theme.glassFill
        case .thick: return Theme.glassFillStrong
        }
    }
}

// MARK: - 内容列宽度是硬约束（§7.2 规则 3）

extension View {
    /// 页面滚动体宽度钳制：把**上报宽度**钉在父级提议宽度上（内容照旧按自身最小宽度布局）。
    ///
    /// **为什么必须有这一层**：内容列宽度 = 窗口宽 − 侧栏块（§7.2 规则 3），而页面滚动体
    /// （`ScrollView`）会把内容的最小宽度上报给父级 —— 详情页头部操作行一行摆开最小 ≈412pt，
    /// 加上封面 220 + 间距 28 + 页面边距 48 ≈ 708pt。内容列只有 658pt 时（938pt 窗口 +
    /// 270pt 侧栏，2026-10-03 截图）页面 VStack 会按 708pt 铺开，**顶栏 / 面包屑作为页面
    /// 子视图被一起撑宽**：玻璃面板右缘连同 12pt 外边距与圆角被窗口右缘裁掉，头部操作行
    /// 的「删除」按钮也被裁一半。
    ///
    /// 钳制后：滚动体对外只报「父级给的宽度」，超宽内容只在滚动体内部溢出（被滚动体裁切），
    /// 页面宽度 = 内容列宽度，chrome 永远拿得到完整的面板宽度。宽度是硬约束，所以这里用
    /// `minWidth: 0` 而不是让它参与最小宽度协商。
    func pageBodyWidthClamp() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 氛围层（§7.2 规则 3）

/// 窗口底的封面取色 wash：四组 radial + 一条底色渐变。
///
/// 玻璃之下必须有可透的内容 —— 没有氛围层，透材质就是一片死灰。
/// 「降低透明度」开启时压暗到 30% 并降到 35% 饱和度（§7.3）。
struct AmbientWash: View {
    @Environment(\.appReduceTransparency) private var reduceTransparency
    /// 必须**读环境值**而不是 `Theme.isPaper`：全局镜像读了不订阅，
    /// 氛围层挂在 RootView 上（不在 MainView 那棵会重建的呈现子树里），
    /// 只读镜像会导致切到纸墨后这层渐变色斑赖着不走。
    @Environment(\.appVisualStyle) private var appStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // 纸墨：氛围层整体不渲染，窗口底就是纸面纯色（v4 §2.1「不用投影、靠纸墨反差」）。
                // 颜色仍走令牌（`Theme.Paper.canvas`），结构由订阅到的 `appStyle` 决定。
                Theme.Paper.canvas
                // 玻璃与棱镜都渲染氛围层（棱镜的白卡需要底下有淡彩才不呆板）；
                // 纸墨整体不渲染，窗口底就是纸面纯色（v4 §2.1「不用投影、靠纸墨反差」）。
                if appStyle == .glass || appStyle == .prism {
                    LinearGradient(
                        colors: [Theme.ambientBaseTop, Theme.ambientBaseBottom],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    blob(Theme.ambientIndigo, rx: 0.52, ry: 0.62, at: UnitPoint(x: 0.08, y: 0.04), in: geo.size)
                    blob(Theme.ambientTeal, rx: 0.46, ry: 0.58, at: UnitPoint(x: 0.92, y: 0.12), in: geo.size)
                    blob(Theme.ambientRose, rx: 0.55, ry: 0.50, at: UnitPoint(x: 0.82, y: 0.96), in: geo.size)
                    blob(Theme.ambientAmber, rx: 0.48, ry: 0.56, at: UnitPoint(x: 0.20, y: 0.90), in: geo.size)
                }
            }
        }
        .opacity(reduceTransparency ? 0.30 : 1)
        .saturation(reduceTransparency ? 0.35 : 1)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// 一枚椭圆色斑：CSS `radial-gradient(<rx> <ry> at <x> <y>, …)` 的等价物
    private func blob(
        _ color: Color,
        rx: CGFloat,
        ry: CGFloat,
        at unit: UnitPoint,
        in size: CGSize
    ) -> some View {
        let radius = max(size.height * ry, 1)
        let aspect = (size.width * rx) / radius
        return Circle()
            .fill(
                RadialGradient(
                    // 色停点落在 62% 处（与预览 CSS 的 `transparent 62%` 一致），
                    // 否则色斑会扩散得比设计稿更满、整页偏色
                    colors: [color, color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: radius * 0.62
                )
            )
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(x: aspect, y: 1)
            .position(x: size.width * unit.x, y: size.height * unit.y)
    }
}

// MARK: - 响应式断点（macOS 窄窗口五档，对应 §6）

/// 以**内容区宽度 W**（窗口宽 − 侧栏宽）划分的布局档位。
enum LayoutSizeClass: Int, Comparable, CaseIterable {
    /// W < 640：图标栏 64，页面边距 16，网格 min 140
    case w0
    /// W 640–819：图标栏 64（可抽屉），边距 20，网格 min 150
    case w1
    /// W 820–1023：完整侧栏 220（可拖拽），边距 24，网格 min 160
    case w2
    /// W 1024–1339：完整侧栏 240，边距 28，网格 min 180
    case w3
    /// W ≥ 1340：完整侧栏 240，边距 32（内容最大 1440 居中），网格 min 200
    case w4

    static func < (lhs: LayoutSizeClass, rhs: LayoutSizeClass) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 以内容区宽度划分（规范 §6 的原始定义）。
    static func from(contentWidth: CGFloat) -> LayoutSizeClass {
        switch contentWidth {
        case ..<640: return .w0
        case ..<820: return .w1
        case ..<1024: return .w2
        case ..<1340: return .w3
        default: return .w4
        }
    }

    /// 以**窗口宽度**划分。
    ///
    /// 侧栏宽度本身取决于档位（图标栏 64 / 完整 220–240），直接按"窗口宽 − 侧栏宽"
    /// 求解会震荡（900pt 窗口：减去 240 得 W1，减去 64 又得 W2，两者都不自洽）。
    /// 因此这里把规范 §6 的内容区阈值折算成窗口阈值，保证单调且与设计稿窗口一致：
    /// 520 → W0、760 → W1、1000 → W2、1180 → W3、1440+ → W4。
    static func from(windowWidth: CGFloat) -> LayoutSizeClass {
        switch windowWidth {
        case ..<640: return .w0
        case ..<860: return .w1
        case ..<1100: return .w2
        case ..<1420: return .w3
        default: return .w4
        }
    }

    /// 顶栏常驻搜索框宽度（窄窗降级）
    var topBarSearchWidth: CGFloat {
        switch self {
        case .w0: return 148
        case .w1: return 176
        case .w2: return 200
        default: return 240
        }
    }

    // MARK: 侧栏

    /// 侧栏是否降级为 64pt 图标栏
    var usesIconRail: Bool { self <= .w1 }

    /// 图标栏是否提供「展开抽屉」入口（W1；W0 空间过窄不提供）
    var railOffersDrawer: Bool { self == .w1 }

    /// 完整侧栏宽度
    var sidebarWidth: CGFloat {
        switch self {
        case .w2: return 220
        default: return Theme.Size.sidebarWidth
        }
    }

    // MARK: 页面

    /// 页面水平边距
    var pageMargin: CGFloat {
        switch self {
        case .w0: return 16
        case .w1: return 20
        case .w2: return 24
        case .w3: return 28
        case .w4: return 32
        }
    }

    /// 内容最大宽度（W4 居中，nil 表示不限制）
    var contentMaxWidth: CGFloat? { self == .w4 ? 1440 : nil }

    /// 网格最小列宽
    var gridMin: CGFloat {
        switch self {
        case .w0: return 140
        case .w1: return 150
        case .w2: return 160
        case .w3: return 180
        case .w4: return 200
        }
    }

    /// 网格最大列宽
    var gridMax: CGFloat { gridMin + 60 }

    /// 网格间距
    var gridSpacing: (h: CGFloat, v: CGFloat) {
        switch self {
        case .w0: return (12, 16)
        case .w1: return (16, 20)
        default: return (20, 24)
        }
    }

    /// 列表/详情页左右边距是否为紧凑形态
    var isNarrow: Bool { self <= .w1 }

    // MARK: 详情页

    /// 详情页封面尺寸（窄窗 140/160，常规 220）
    var detailCoverSize: CGFloat {
        switch self {
        case .w0: return 140
        case .w1: return 160
        default: return Theme.Size.detailCover
        }
    }

    /// 详情页封面与信息是否纵向堆叠
    var detailStacksVertically: Bool { self <= .w1 }

    // MARK: 迷你播放条

    /// 播放条高度：宽窄一致（§6 W0 行），玻璃态 60 / 实体态 68
    var playerBarHeight: CGFloat { Theme.Size.playerBarHeight }
    var playerBarHeightGlass: CGFloat { Theme.Size.playerBarHeightGlass }

    /// 是否显示右侧音量区
    var playerBarShowsVolume: Bool { self >= .w2 }

    /// 是否显示两侧时间码
    var playerBarShowsTime: Bool { self >= .w3 }

    // MARK: 正在播放页

    /// 待播清单作为右栏（否则降级为底部抽屉）
    var nowPlayingUsesSideQueue: Bool { self >= .w3 }

    /// 正在播放大封面尺寸上限
    var nowPlayingCoverMax: CGFloat {
        switch self {
        case .w0: return 260
        case .w1: return 300
        default: return 400
        }
    }

    // MARK: 顶栏

    /// 顶栏搜索框是否显示 ⌘F 提示
    var topBarShowsSearch: Bool { self >= .w2 }
}
