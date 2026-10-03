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

/// 强调色色阶：400 渐变起点 / 500 主色实底 / 600 按压激活 / 深色文字档。
///
/// 设计规范只给了靛蓝的 `#6B71E3 / #4C53D8 / #3E45C0` 与深色文字档 `#A5AAFF`；
/// 泛音青与紫规范未定义，按主色套用靛蓝的 HSB 偏移推导。
struct AccentRamp {
    let light: NSColor
    let base: NSColor
    let dark: NSColor
    /// 深色主题下的品牌色文字/图标档（深底上主色对比度不足）
    let text: NSColor

    static func fixed(base: UInt32, light: UInt32, dark: UInt32, text: UInt32) -> AccentRamp {
        AccentRamp(
            light: NSColor(srgbHex: light),
            base: NSColor(srgbHex: base),
            dark: NSColor(srgbHex: dark),
            text: NSColor(srgbHex: text)
        )
    }

    static func derived(from hex: UInt32) -> AccentRamp {
        let base = NSColor(srgbHex: hex)
        return AccentRamp(
            light: base.shifted(saturation: -0.12, brightness: 0.045),
            base: base,
            dark: base.shifted(saturation: 0.03, brightness: -0.095),
            text: base.shifted(saturation: -0.295, brightness: 0.153)
        )
    }

    static func forChoice(_ choice: AppSettings.AccentChoice) -> AccentRamp {
        switch choice {
        case .indigo: return .fixed(base: 0x4C53D8, light: 0x6B71E3, dark: 0x3E45C0, text: 0xA5AAFF)
        case .teal: return .derived(from: 0x12B8A6)
        case .purple: return .derived(from: 0x7C4DDB)
        }
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

    /// 窗口内容区底色，让卡片浮起
    static let canvas = Color(token: 0xF5F6F8, 0x0E1014)
    /// 卡片、面板、设置分组
    static let surface = Color(token: 0xFFFFFF, 0x16191F)
    /// 表头、次级控件底、分段控件容器
    static let surfaceSunken = Color(token: 0xF2F3F6, 0x1D212A)
    /// 行悬停
    static let surfaceHover = Color(token: 0xEEF0F4, 0x222732)
    /// 选中行底色（强调色染；深色底上需要更高浓度才看得出来）
    static var surfaceSelected: Color {
        Color(appearanceDynamic: { appearance in
            accentRamp.base.withAlphaComponent(appearance.isDark ? 0.18 : 0.08)
        })
    }

    // MARK: 描边（Borders）—— 深色下承担浅色主题里阴影的分层职责

    static let borderSubtle = Color(token: 0xE9EBEF, 0x262B36)
    static let borderDefault = Color(token: 0xDDE0E6, 0x343B49)
    static let borderStrong = Color(token: 0xC6CBD4, 0x4B5468)

    // MARK: 文字（Text）

    static let textPrimary = Color(token: 0x14171C, 0xF2F4F8)
    static let textSecondary = Color(token: 0x5B6472, 0xA9B1C0)
    /// 浅色 3.67:1 / 深色 4.63:1 —— 仅用于分组标题、占位符、图标，禁止用于正文
    static let textTertiary = Color(token: 0x7C8698, 0x79839A)
    static let textOnAccent = Color.white

    // MARK: 品牌（Brand）—— 跟随「外观 · 强调色」，切换即时全局生效

    /// 当前强调色色阶：由 `AppSettings` 在启动装载与切换时写入。
    ///
    /// Theme 令牌要能在任意上下文读取（视图、模型、默认参数值），不能直接依赖
    /// `@MainActor` 的 AppSettings，所以这里存一份非隔离的镜像。
    static var accentRamp: AccentRamp = .fixed(
        base: 0x4C53D8, light: 0x6B71E3, dark: 0x3E45C0, text: 0xA5AAFF
    )

    static var brand400: Color { Color(accentDynamic: { accentRamp.light }) }
    /// 主色**实底**：深浅主题一致（白字 5.94:1 ✅）
    static var brand500: Color { Color(accentDynamic: { accentRamp.base }) }
    static var brand600: Color { Color(accentDynamic: { accentRamp.dark }) }
    /// 品牌色**文字/图标**：浅色用主色，深色用提亮档（主色在深底上对比度不足）
    static var brandText: Color {
        Color(appearanceDynamic: { appearance in
            appearance.isDark ? accentRamp.text : accentRamp.base
        })
    }

    /// 设置页「强调色」三个色块：固定值，**不随当前强调色变化**
    static let accentIndigo = Color(hex: 0x4C53D8)
    static let accentTeal = Color(hex: 0x12B8A6)
    static let accentPurple = Color(hex: 0x7C4DDB)

    /// 选中底、焦点光晕
    static var brandTint: Color {
        Color(appearanceDynamic: { appearance in
            accentRamp.base.withAlphaComponent(appearance.isDark ? 0.16 : 0.08)
        })
    }
    /// 第二谐波：频谱柱、正在播放律动（装饰用，固定泛音青，深色提亮）
    static let overtoneTeal = Color(token: 0x12B8A6, 0x2AD3C0)
    /// 青色文字态（浅色 5.12:1 / 深色 9.77:1 ✅ AA）
    static let tealText = Color(token: 0x0B7C6A, 0x45D6C3)

    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [brand400, brand600],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: 语义（Semantic）

    static let success = Color(token: 0x14855F, 0x3DC98A)
    static let warning = Color(token: 0xA75B09, 0xF0B429)
    static let danger = Color(token: 0xC8372D, 0xF26557)
    static let favorite = Color(token: 0xE04B78, 0xF0679B)

    // MARK: 遮罩

    /// 抽屉展开时覆盖内容区的遮罩（深色底上需更强对比）
    static let scrim = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0x14171C).withAlphaComponent(appearance.isDark ? 0.32 : 0.22)
    })
    /// 封面 hover 时的压暗层（压在图片上，两主题一致）
    static let coverScrim = Color.black.opacity(0.32)
    /// 骨架屏微光扫动（深色下只轻微提亮）
    static let shimmer = Color(appearanceDynamic: { appearance in
        NSColor.white.withAlphaComponent(appearance.isDark ? 0.05 : 0.75)
    })

    // MARK: 玻璃材质（§7.1 Liquid Glass）

    /// 玻璃层 1px 描边（浅色下替代阴影分层，深色下是唯一的分层手段）
    static let glassBorder = Color(appearanceDynamic: { appearance in
        NSColor.white.withAlphaComponent(appearance.isDark ? 0.10 : 0.62)
    })

    /// 小控件的半透明玻璃底（`glass.regular`，不做 blur —— §7.2 规则 4 性能预算）
    static let glassFill = Color(appearanceDynamic: { appearance in
        appearance.isDark
            ? NSColor(srgbHex: 0x1A1D26).withAlphaComponent(0.52)
            : NSColor.white.withAlphaComponent(0.50)
    })
    /// 强一档的玻璃底（`glass.thick`：播放条、菜单、弹窗、Toast）
    static let glassFillStrong = Color(appearanceDynamic: { appearance in
        appearance.isDark
            ? NSColor(srgbHex: 0x1E222C).withAlphaComponent(0.72)
            : NSColor.white.withAlphaComponent(0.70)
    })
    /// 更薄一档（`glass.thin`：顶栏、分段容器、次级控件底）
    static let glassFillThin = Color(appearanceDynamic: { appearance in
        appearance.isDark
            ? NSColor(srgbHex: 0x1A1D26).withAlphaComponent(0.40)
            : NSColor.white.withAlphaComponent(0.42)
    })

    /// 顶部镜面高光（specular）：1px 内高光，玻璃面板与控件共用
    static let glassHighlight = Color(appearanceDynamic: { appearance in
        NSColor.white.withAlphaComponent(appearance.isDark ? 0.10 : 0.70)
    })

    /// 玻璃面板投影：浅色主题下玻璃浮起需要一点投影，深色下几乎不可见
    static let glassShadow = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0x10141C).withAlphaComponent(appearance.isDark ? 0.10 : 0.14)
    })

    // MARK: 氛围层（§7.1 ambient）—— 玻璃之下必须有可透的内容

    /// 氛围 wash 的四组取色（浅色 α .42–.55 / 深色 α .10–.30，与预览一致）
    static let ambientIndigo = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0x6B71E3).withAlphaComponent(appearance.isDark ? 0.30 : 0.55)
    })
    static let ambientTeal = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0x12B8A6).withAlphaComponent(appearance.isDark ? 0.22 : 0.46)
    })
    static let ambientRose = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0xE04B78).withAlphaComponent(appearance.isDark ? 0.16 : 0.42)
    })
    static let ambientAmber = Color(appearanceDynamic: { appearance in
        NSColor(srgbHex: 0xF6B45A).withAlphaComponent(appearance.isDark ? 0.10 : 0.44)
    })
    /// 氛围层底色（渐变两端）
    static let ambientBaseTop = Color(token: 0xE4E8F6, 0x12141C)
    static let ambientBaseBottom = Color(token: 0xF4EEE5, 0x0A0C11)

    // MARK: 反色层（Toast 等浮层）

    /// 反色底：浅色主题深底、深色主题浅底
    static let inverseSurface = Color(token: 0x14171C, 0xF2F4F8)
    /// 反色底上的文字
    static let textOnInverse = Color(token: 0xFFFFFF, 0x14171C)

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

    // MARK: - 圆角（收敛为 6 档）

    enum Radius {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        static let lg: CGFloat = 14
        static let xl: CGFloat = 20
        static let full: CGFloat = 999
    }

    // MARK: - 阴影（3 档 + 焦点环）

    enum Elevation {
        /// 卡片静态
        case e1
        /// hover / 下拉 / 面板
        case e2
        /// 正在播放大封面、设置窗口
        case e3

        var color: Color { Color(hex: 0x10141C) }

        /// (radius, y, opacity) 组合；CSS blur 半径约为 SwiftUI radius 的 2 倍
        var layers: [(radius: CGFloat, y: CGFloat, opacity: Double)] {
            switch self {
            case .e1: return [(1, 1, 0.06)]
            case .e2: return [(4, 2, 0.08), (1, 1, 0.06)]
            case .e3: return [(14, 12, 0.12), (3, 2, 0.06)]
            }
        }
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

    /// 卡片 hover 上浮距离（Reduce Motion 下为 0，§7）
    static func lift(_ hovered: Bool, reduceMotion: Bool) -> CGFloat {
        (hovered && !reduceMotion) ? -2 : 0
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
        static let panelRadius: CGFloat = Radius.md
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
        static let settingsFormWidth: CGFloat = 480
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
            case .mono, .monoSM: return .monospaced
            default: return .default
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
        content
            .font(.system(size: style.size * scale, weight: weight ?? style.weight, design: style.design))
            .lineSpacing(style.lineSpacing * scale)
            .foregroundStyle(color ?? Theme.textPrimary)
    }
}

extension View {
    /// 应用令牌字号（随系统文本大小缩放）+ 颜色。
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
        let shadowed = elevation.layers.reduce(AnyView(content)) { view, layer in
            AnyView(
                view.shadow(
                    // 深色下投影几乎不可见，按 §4.2 规则 1 降到 30% 强度
                    color: elevation.color.opacity(layer.opacity * (dark ? 0.3 : 1)),
                    radius: layer.radius,
                    y: layer.y
                )
            )
        }
        if dark, let cornerRadius {
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

/// 键盘可见的焦点环：1px brand500 + 3px 光晕。
/// 需要与 `@FocusState` / `focusable()` 配合使用。
struct FocusRing: ViewModifier {
    let isFocused: Bool
    var cornerRadius: CGFloat = Theme.Radius.md

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Theme.brandText, lineWidth: 1)
                    .opacity(isFocused ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3)
                    .strokeBorder(Theme.brandText.opacity(0.28), lineWidth: 3)
                    .padding(-3)
                    .opacity(isFocused ? 1 : 0)
            }
            .animation(Theme.Motion.micro, value: isFocused)
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
        content
            .background { backdrop(shape: shape) }
            .overlay {
                if let tint { shape.fill(tint) }
            }
            .overlay {
                shape.strokeBorder(reduceTransparency || !glassSurfaces ? Theme.borderSubtle : Theme.glassBorder)
            }
            .overlay(alignment: .top) {
                // 顶部镜面高光：1px 内高光，让玻璃「有厚度」
                if !reduceTransparency && glassSurfaces {
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
        if reduceTransparency || !glassSurfaces {
            // 回退：surface 实底（对比度复核过的组合）
            shape.fill(Theme.surface)
        } else if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(material.fallback)
        }
    }
}

/// 玻璃面板投影：深色下投影不可见，只保留极弱一层；实底回退态用标准 e1/e2
private struct GlassShadow: ViewModifier {
    let elevation: Theme.Elevation?
    let solid: Bool

    func body(content: Content) -> some View {
        guard let elevation else { return AnyView(content) }
        let opacity: Double
        switch elevation {
        case .e1: opacity = solid ? 0.06 : 0.10
        case .e2: opacity = solid ? 0.08 : 0.14
        case .e3: opacity = solid ? 0.12 : 0.18
        }
        let radius: CGFloat
        let y: CGFloat
        switch elevation {
        case .e1: radius = 4; y = 2
        case .e2: radius = 10; y = 6
        case .e3: radius = 20; y = 12
        }
        return AnyView(
            content.shadow(color: Theme.glassShadow.opacity(opacity / 0.14), radius: radius, y: y)
        )
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
        content
            .background { shape.fill(fill) }
            .overlay { shape.strokeBorder(solid ? Theme.borderDefault : Theme.glassBorder) }
            .overlay(alignment: .top) {
                if !solid {
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

    var body: some View {
        GeometryReader { geo in
            ZStack {
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
