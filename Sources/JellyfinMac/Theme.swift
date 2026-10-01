import SwiftUI

// MARK: - 十六进制颜色

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
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

    // MARK: 表面（Surfaces）

    /// 窗口内容区底色，让白色卡片浮起
    static let canvas = Color(hex: 0xF5F6F8)
    /// 卡片、面板、设置分组
    static let surface = Color.white
    /// 表头、次级控件底、分段控件容器
    static let surfaceSunken = Color(hex: 0xF2F3F6)
    /// 行悬停
    static let surfaceHover = Color(hex: 0xEEF0F4)
    /// 选中行底色（brandTint）
    static let surfaceSelected = Color(hex: 0xEEF0FF)

    // MARK: 描边（Borders）

    static let borderSubtle = Color(hex: 0xE9EBEF)
    static let borderDefault = Color(hex: 0xDDE0E6)
    static let borderStrong = Color(hex: 0xC6CBD4)

    // MARK: 文字（Text）

    static let textPrimary = Color(hex: 0x14171C)
    static let textSecondary = Color(hex: 0x5B6472)
    /// ⚠️ 3.67:1 —— 仅用于分组标题、占位符、图标，禁止用于正文
    static let textTertiary = Color(hex: 0x7C8698)
    static let textOnAccent = Color.white

    // MARK: 品牌（Brand）

    static let brand400 = Color(hex: 0x6B71E3)
    static let brand500 = Color(hex: 0x4C53D8)
    static let brand600 = Color(hex: 0x3E45C0)
    /// 可选强调色之一（设置页「外观 · 强调色」）
    static let brandPurple = Color(hex: 0x7C4DDB)
    /// 选中底、焦点光晕
    static let brandTint = Color(hex: 0x4C53D8).opacity(0.08)
    /// 第二谐波：频谱柱、正在播放律动（装饰用）
    static let overtoneTeal = Color(hex: 0x12B8A6)
    /// 青色文字态（白底 5.11:1 ✅ AA）
    static let tealText = Color(hex: 0x0B7C6A)

    static let brandGradient = LinearGradient(
        colors: [brand400, brand600],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: 语义（Semantic）

    static let success = Color(hex: 0x14855F)
    static let warning = Color(hex: 0xA75B09)
    static let danger = Color(hex: 0xC8372D)
    static let favorite = Color(hex: 0xE04B78)

    // MARK: 遮罩

    /// 抽屉展开时覆盖内容区的遮罩
    static let scrim = Color(hex: 0x14171C).opacity(0.22)
    /// 封面 hover 时的压暗层
    static let coverScrim = Color.black.opacity(0.32)

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
        /// 窗口左上角留给红黄绿三键的空白条高度（透明标题栏 + fullSizeContentView）
        static let windowChromeHeight: CGFloat = 28
        /// 详情页面包屑栏
        static let crumbBarHeight: CGFloat = 44
        /// 迷你播放条
        static let playerBarHeight: CGFloat = 68
        static let playerBarHeightCompact: CGFloat = 56
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

    func body(content: Content) -> some View {
        elevation.layers.reduce(AnyView(content)) { view, layer in
            AnyView(
                view.shadow(
                    color: elevation.color.opacity(layer.opacity),
                    radius: layer.radius,
                    y: layer.y
                )
            )
        }
    }
}

extension View {
    /// 应用 3 档阴影之一。
    func elevation(_ elevation: Theme.Elevation) -> some View {
        modifier(ElevationModifier(elevation: elevation))
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
                    .strokeBorder(Theme.brand500, lineWidth: 1)
                    .opacity(isFocused ? 1 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius + 3)
                    .strokeBorder(Theme.brand500.opacity(0.28), lineWidth: 3)
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

    var playerBarHeight: CGFloat {
        self == .w0 ? Theme.Size.playerBarHeightCompact : Theme.Size.playerBarHeight
    }

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
