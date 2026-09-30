import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

/// 白色扁平主题（设计稿令牌：白底 + 灰阶层次 + 蓝色主色）
enum Theme {
    // MARK: - 表面与线条

    static let background = Color.white                        // 主内容区（#ffffff）
    static let sidebarBackground = Color.white                 // 侧栏（白底 + 右侧分隔线）
    static let surface = Color(hex: 0xF9FAFB)                  // 卡片/面板（gray-50）
    static let surface2 = Color(hex: 0xF3F4F6)                 // 次级表面（gray-100）
    static let fieldFill = Color(hex: 0xF3F4F6)                // 输入框/次级控件底色（gray-100）
    static let border = Color(hex: 0xE5E7EB)                   // 细边框（gray-200）
    static let borderStrong = Color(hex: 0xD1D5DB)
    static let divider = Color(hex: 0xE5E7EB)
    static let hoverFill = Color(hex: 0xF3F4F6)                // 悬停底色（gray-100）
    static let selectedFill = Color(hex: 0x2563EB).opacity(0.08)  // 选中高亮（主色浅底）

    // MARK: - 文字

    static let primaryText = Color(hex: 0x111827)              // gray-900
    static let secondaryText = Color(hex: 0x6B7280)            // gray-500
    static let tertiaryText = Color(hex: 0x9CA3AF)             // gray-400

    // MARK: - 品牌色

    static let primaryBlue = Color(hex: 0x2563EB)              // blue-600
    static let primaryBlueLight = Color(hex: 0x3B82F6)         // blue-500

    static let accentStart = Color(hex: 0x3B82F6)
    static let accentEnd = Color(hex: 0x2563EB)
    static let accentText = Color(hex: 0x2563EB)
    static let accentGradient = LinearGradient(
        colors: [accentStart, accentEnd],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: - 阴影（扁平化：极轻、只在需要层次处出现）

    static let cardShadow = Color.black.opacity(0.06)
    static let hoverShadow = Color.black.opacity(0.10)
    static let glow = Color(hex: 0x2563EB).opacity(0.10)

    // MARK: - 圆角（设计稿令牌）

    static let radiusSm: CGFloat = 4
    static let radiusMd: CGFloat = 8
    static let radiusLg: CGFloat = 12
    static let radiusXl: CGFloat = 16

    // MARK: - 标准动画曲线（全局统一节奏）

    /// 快速微交互：按钮按压、悬停高亮
    static let micro = Animation.spring(response: 0.25, dampingFraction: 0.8)
    /// 常规过渡：面板出现/收起、迷你播放条
    static let smooth = Animation.spring(response: 0.35, dampingFraction: 0.85)
    /// 大区块过渡：页面切换、正在播放页
    static let spacious = Animation.spring(response: 0.45, dampingFraction: 0.88)
    /// 弹性出场：Logo、封面入场
    static let bouncy = Animation.spring(response: 0.55, dampingFraction: 0.7)
}

// MARK: - 响应式断点（多端适配）

/// 依据内容区宽度划分布局档位（对齐设计稿 768 / 1024 断点）
enum LayoutSizeClass {
    /// 窄窗口：侧栏自动收起、网格 3 列、播放条收纳右侧区域
    case compact
    /// 常规窗口：默认布局
    case regular

    static func from(width: CGFloat) -> LayoutSizeClass {
        width < 860 ? .compact : .regular
    }
}
