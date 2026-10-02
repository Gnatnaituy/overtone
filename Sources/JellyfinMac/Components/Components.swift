import SwiftUI

// MARK: - 窗口拖拽区（无边框窗口手动拖动）

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        /// 锚点式拖拽：记录按下瞬间的鼠标位置与窗口原点，
        /// 之后每次事件都按"相对按下点"的绝对量重算窗口位置。
        /// 不能改成增量式（window.frame.origin + delta）——顶栏区同时存在系统标题栏
        /// 拖拽路径，任何一帧被系统先移动后，增量式会基于被污染的基线继续累加/纠正，
        /// 表现为窗口来回抖动（2026-08-24 定位）。
        private var anchorMouse: NSPoint = .zero
        private var anchorOrigin: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            FileHandle.standardError.write("DRAGAREA down\n".data(using: .utf8)!)
            anchorMouse = NSEvent.mouseLocation
            anchorOrigin = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let current = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: anchorOrigin.x + (current.x - anchorMouse.x),
                y: anchorOrigin.y + (current.y - anchorMouse.y)
            )
            window.setFrameOrigin(newOrigin)
        }
    }
}

// MARK: - 首击穿透

/// 注意：本视图（作为按钮的 background）在当前 macOS 上并不会被命中——
/// SwiftUI 的 hosting view 拦截了按钮区域的 hit-test，acceptsFirstMouse
/// 永远不会被询问，因此"未激活窗口需点两次"的问题由 AppDelegate 的
/// 窗口级点击穿透 monitor（先激活窗口再直接投递命中视图）统一解决。
/// 这里保留 acceptClickThrough() 仅为历史兼容，实际不再生效。
private final class ClickThroughView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct AcceptClickThrough: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClickThroughView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// 让控件在窗口未激活时也能响应第一次点击（贴近按钮使用，勿加在滚动容器上）
    func acceptClickThrough() -> some View {
        background(AcceptClickThrough())
    }

    /// 把命中区扩到 ≥44×44pt，**视觉尺寸与布局占位都不变**（§5.3 规则 1）。
    ///
    /// 做法：向外 padding 撑到最小命中区 → 在该尺寸上定义 contentShape → 再负 padding
    /// 把布局占位收回来。渲染不受影响（padding 区不画背景），只有热区变大。
    /// 触屏 / Catalyst 移植时这条底线同样生效。
    func hitExpand(from visualSize: CGFloat, to minimum: CGFloat = 44) -> some View {
        let inset = max((minimum - visualSize) / 2, 0)
        guard inset > 0 else { return AnyView(self) }
        return AnyView(
            self
                .padding(inset)
                .contentShape(Rectangle())
                .padding(-inset)
        )
    }
}

// MARK: - 隐藏滚动条

/// 隐藏所在 ScrollView 的垂直滚动条（NSScrollView 层）：
/// SwiftUI 的 .scrollIndicators(.hidden) 在部分 macOS 版本上不生效，
/// 传统样式滚动条仍会渲染并叠加到相邻的拖拽分割条上
struct ScrollBarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollBarHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollBarHidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { self.hideScroller() }
        }

        private func hideScroller() {
            var candidate = superview
            while let view = candidate {
                if let scroll = view as? NSScrollView {
                    scroll.hasVerticalScroller = false
                    scroll.scrollerStyle = .overlay
                    return
                }
                candidate = view.superview
            }
        }
    }
}

// MARK: - 均衡器动效（正在播放指示）

/// 三根跳动的频谱柱，TimelineView 驱动（无 Timer 泄漏，暂停时静止）。
/// 不设 minimumInterval：跟随屏幕刷新率（ProMotion 120Hz / 普通屏 60Hz），
/// 动画交给系统 display link 节奏，不自行推帧。
/// 开启「减少动态效果」时静止为三根等高柱（§8 动效）。
struct EqualizerBars: View {
    var active: Bool = true
    var color: Color = Theme.overtoneTeal
    var barWidth: CGFloat = 2.5
    var height: CGFloat = 12

    @Environment(\.appReduceMotion) private var reduceMotion

    private let phases: [Double] = [0, 1.7, 3.1]

    var body: some View {
        Group {
            if reduceMotion {
                staticBars
            } else {
                TimelineView(.animation(paused: !active)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    HStack(spacing: barWidth * 0.8) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule()
                                .fill(color)
                                .frame(width: barWidth, height: barHeight(t: t, phase: phases[i]))
                        }
                    }
                }
            }
        }
        .frame(height: height)
        .opacity(active ? 1 : 0.35)
        .animation(Theme.Motion.base, value: active)
        .accessibilityHidden(true)
    }

    private var staticBars: some View {
        HStack(spacing: barWidth * 0.8) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule().fill(color).frame(width: barWidth, height: height * 0.62)
            }
        }
    }

    /// 双正弦叠加，模拟音乐律动（不规则但平滑）
    private func barHeight(t: Double, phase: Double) -> CGFloat {
        let wave = (sin(t * 6.0 + phase) + sin(t * 9.3 + phase * 1.6)) / 2.0
        let ratio = 0.5 + 0.38 * wave // 0.12 ~ 0.88
        return max(height * 0.18, height * ratio)
    }
}

// MARK: - 错落入场动画（30ms × index，最多 10 项）

private struct StaggerAppear: ViewModifier {
    let index: Int
    let visible: Bool
    @Environment(\.appReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: (visible || reduceMotion) ? 0 : 8)
            .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.stagger(index: index), value: visible)
    }
}

extension View {
    func staggerAppear(index: Int, visible: Bool = true) -> some View {
        modifier(StaggerAppear(index: index, visible: visible))
    }
}

// MARK: - 按钮样式（§5）

/// 主按钮：`brandGradient` 底白字，高 44（小 32），内边距 20，圆角 10
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appReduceMotion) private var reduceMotion
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.body, weight: .medium, color: Theme.textOnAccent)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? Theme.Size.buttonHeightSm : Theme.Size.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.brandGradient)
                    .brightness(configuration.isPressed ? -0.06 : 0)
            )
            .elevation(.e1)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Theme.Motion.micro, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// 次级按钮：玻璃材质（§7.4 `SecondaryButtonStyle` 接材质令牌），文字 `textPrimary`
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.appReduceMotion) private var reduceMotion
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.body, weight: .medium, color: Theme.textPrimary)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? Theme.Size.buttonHeightSm : Theme.Size.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(configuration.isPressed ? Theme.surfaceHover : Color.clear)
            )
            .glassControl(cornerRadius: Theme.Radius.md)
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(Theme.Motion.micro, value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// 幽灵按钮：透明底，文字 `textSecondary`，hover `surfaceHover`（用于「取消 / 显示全部」）
struct GhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.body, weight: .medium, color: Theme.textSecondary)
            .padding(.horizontal, compact ? 12 : 16)
            .frame(height: compact ? Theme.Size.buttonHeightSm : Theme.Size.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(configuration.isPressed ? Theme.surfaceHover : Color.clear)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

/// 危险按钮：`surface` 底 + `danger` 描边 + `danger` 文字（退出登录、删除）
struct DangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .textStyle(.body, weight: .medium, color: Theme.danger)
            .padding(.horizontal, compact ? 14 : 20)
            .frame(height: compact ? Theme.Size.buttonHeightSm : Theme.Size.buttonHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(configuration.isPressed ? Theme.danger.opacity(0.08) : Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.danger)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }
}

// MARK: - 图标按钮（28 / 32 / 44 三档，必须有 accessibilityLabel）

/// 圆形图标按钮：玻璃圆底（§7.4），hover 换 `surfaceHover`。
/// - 视觉 28/32/44 三档，**命中区一律 ≥44×44pt**（§5.3）；
/// - 选中态用 `brandTint` 底 + `brand500` 描边（不只靠颜色，配 `isOn` 图标差异）。
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = Theme.Size.iconButtonMd
    var isOn = false
    var tint: Color?
    var help: String?
    var action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(surface)
                .contentShape(Circle())
                .hitExpand(from: size)
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: size / 2)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .animation(Theme.Motion.micro, value: isOn)
        .help(help ?? label)
        .accessibilityLabel(label)
    }

    private var iconSize: CGFloat {
        switch size {
        case ..<30: return 12
        case ..<38: return 13
        default: return 16
        }
    }

    private var foreground: Color {
        if let tint { return tint }
        return isOn ? Theme.brandText : Theme.textSecondary
    }

    @ViewBuilder
    private var surface: some View {
        if isOn {
            // 选中态：实底 tint + 主色描边（玻璃下选中要压得住底下的氛围色）
            Circle()
                .fill(Theme.surfaceSelected)
                .overlay(Circle().strokeBorder(Theme.brand500))
        } else {
            Circle()
                .fill(hovered ? Theme.surfaceHover : Color.clear)
                .glassControl(cornerRadius: size / 2)
        }
    }
}

/// 无底框的纯图标按钮（工具栏 / 行内联用）：视觉 28pt，命中区 ≥44×44pt
struct PlainIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = Theme.Size.iconButtonSm
    var isOn = false
    var tint: Color?
    var action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size < 32 ? 13 : 15, weight: .medium))
                .foregroundStyle(tint ?? (isOn ? Theme.brandText : (hovered ? Theme.textPrimary : Theme.textSecondary)))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(hovered ? Theme.surfaceHover : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .hitExpand(from: size)
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - 自定义外观的菜单

/// 带自定义外观的菜单。
///
/// macOS 的 `.menuStyle(.borderlessButton)` 会**吞掉 label 内的背景与描边**，并附加系统内边距
/// （头像的渐变圆、排序控件的白底描边都会消失）。因此这里把外观层与交互层分离：
/// 正常绘制 label，再覆盖一个透明 `Menu` 只负责弹出与命中。
struct TokenMenu<Label: View, Content: View>: View {
    var accessibilityLabel: String?
    var help: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        label()
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    content()
                } label: {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel(accessibilityLabel ?? "")
            }
            .help(help ?? accessibilityLabel ?? "")
    }
}

// MARK: - 分段控件（容器高 36，段高 28 圆角 6，选中 = brandGradient + 白字）

struct SegmentedControl: View {
    struct Segment: Identifiable {
        let id: String
        let title: String
        var systemImage: String?

        init(_ id: String, _ title: String, systemImage: String? = nil) {
            self.id = id
            self.title = title
            self.systemImage = systemImage
        }
    }

    let segments: [Segment]
    @Binding var selection: String
    /// 仅图标（视图切换用）
    var iconOnly = false

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                segmentButton(segment)
            }
        }
        .padding(3)
        .frame(height: Theme.Size.segmentedHeight)
        // 分段容器属于 chrome 层（§7.2 规则 1）：玻璃薄材质
        .glassControl(cornerRadius: Theme.Radius.md, strength: .thin)
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ segment: Segment) -> some View {
        let isSelected = segment.id == selection
        return SegmentButton(
            title: segment.title,
            systemImage: segment.systemImage,
            isSelected: isSelected,
            iconOnly: iconOnly
        ) {
            selection = segment.id
        }
    }
}

private struct SegmentButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let iconOnly: Bool
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .medium))
                }
                if !iconOnly {
                    Text(title)
                        .textStyle(.bodySM, weight: .medium, color: isSelected ? Theme.textOnAccent : Theme.textSecondary)
                }
            }
            .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textSecondary)
            .padding(.horizontal, iconOnly ? 9 : 14)
            .frame(height: Theme.Size.segmentHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            .hitExpand(from: Theme.Size.segmentHeight, to: 44)
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: isSelected)
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.brandGradient) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - Chip（高 22，圆角 6，11/500）

struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.caption, weight: .medium, color: Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .strokeBorder(Theme.borderSubtle)
            )
    }
}

/// 流派 / 筛选 chips，超限折叠（§2.3 超限：chips ≤3 + 「+N」展开）。
///
/// 展开后仍可收起，键盘与读屏都能到达（「+N」是一个真按钮，不是装饰）。
struct ChipRow: View {
    let items: [String]
    /// 折叠时最多显示几枚
    var limit = 3

    @State private var expanded = false

    private var visible: [String] {
        expanded ? items : Array(items.prefix(limit))
    }

    private var overflow: Int { max(items.count - limit, 0) }

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(visible, id: \.self) { item in
                Chip(text: item)
            }
            if overflow > 0 {
                Button {
                    expanded.toggle()
                } label: {
                    Chip(text: expanded ? "收起" : "+\(overflow)")
                }
                .buttonStyle(.plain)
                .hitExpand(from: 22, to: 32)
                .help(expanded ? "收起流派标签" : "展开其余 \(overflow) 个流派标签")
                .accessibilityLabel(expanded ? "收起流派标签" : "展开其余 \(overflow) 个流派标签")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("流派")
    }
}

// MARK: - 内联横幅（§2.1 错误：服务器不可达等全局提示）

/// 顶栏下方的内联横幅：图标 + 文案 + 可选操作。
/// 颜色不是唯一载体 —— 永远带警示/对勾图标与文字说明（§5.5）。
struct InlineBanner: View {
    enum Kind {
        case error, warning, info

        var systemImage: String {
            switch self {
            case .error: return "exclamationmark.triangle.fill"
            case .warning: return "exclamationmark.circle.fill"
            case .info: return "info.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .error: return Theme.danger
            case .warning: return Theme.warning
            case .info: return Theme.brandText
            }
        }
    }

    let kind: Kind
    let message: String
    var actionTitle: String?
    var onAction: (() -> Void)?

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(kind.tint)
            Text(message)
                .textStyle(.bodySM, color: Theme.textPrimary)
                .lineLimit(2)
            Spacer(minLength: Theme.Spacing.md)
            if let actionTitle, let onAction {
                Button(actionTitle, action: onAction)
                    .buttonStyle(GhostButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(minHeight: 44)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(kind.tint.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .strokeBorder(kind.tint.opacity(0.35))
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - 确认弹窗（宽 420，圆角 14 + e3；破坏性操作主位为危险按钮）

/// 二次确认弹窗（§4.5）：退出登录 / 清除缓存 / 删除等破坏性操作必配。
struct ConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle = "确认"
    var isDestructive = true
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Theme.scrim
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Text(title)
                    .textStyle(.title4, color: Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(message)
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Theme.Spacing.lg) {
                    Spacer(minLength: 0)
                    Button("取消", action: onCancel)
                        .buttonStyle(GhostButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                    Button(confirmTitle, action: onConfirm)
                        .buttonStyle(isDestructive ? AnyButtonStyle(DangerButtonStyle(compact: true))
                                                   : AnyButtonStyle(PrimaryButtonStyle(compact: true)))
                }
                .padding(.top, Theme.Spacing.xs)
            }
            .padding(Theme.Spacing.xxxl)
            .frame(width: 420, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.surface)
            )
            .glassPanel(.thick, cornerRadius: Theme.Radius.lg, elevation: .e3)
            .accessibilityElement(children: .contain)
        }
        .transition(.opacity)
    }
}

/// 类型擦除的按钮样式（弹窗里主 / 危险按钮二选一）
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

/// 挂在根视图：`ConfirmDialog` 的呈现层（一次只允许一个弹窗）。
///
/// 主窗口与设置窗口各挂一份 host，请求记录**发起窗口**，只有那个窗口渲染弹窗 ——
/// 否则同一个请求会在两个窗口里各弹一次。
private struct DialogHost: ViewModifier {
    @ObservedObject private var center = DialogCenter.shared
    @State private var hostWindow: NSWindow?

    func body(content: Content) -> some View {
        content
            .background(WindowProbe { hostWindow = $0 })
            .overlay {
                if let request = center.request, isTarget(request) {
                    ConfirmDialog(
                        title: request.title,
                        message: request.message,
                        confirmTitle: request.confirmTitle,
                        isDestructive: request.isDestructive,
                        onConfirm: {
                            center.dismiss()
                            request.onConfirm()
                        },
                        onCancel: { center.dismiss() }
                    )
                }
            }
            .animation(Theme.Motion.base, value: center.request?.id)
    }

    private func isTarget(_ request: ConfirmRequest) -> Bool {
        guard let target = request.window else { return true }
        guard let hostWindow else { return false }
        return target === hostWindow
    }
}

/// 读取自身所在窗口（弹窗归属判定用）
private struct WindowProbe: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { ProbeView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ProbeView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = self.window
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}

extension View {
    func dialogHost() -> some View { modifier(DialogHost()) }
}

struct ConfirmRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    var confirmTitle: String = "确认"
    var isDestructive = true
    /// 发起请求的窗口：弹窗只在该窗口渲染
    var window: NSWindow?
    let onConfirm: () -> Void

    static func == (lhs: ConfirmRequest, rhs: ConfirmRequest) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class DialogCenter: ObservableObject {
    static let shared = DialogCenter()

    @Published private(set) var request: ConfirmRequest?

    private init() {}

    func confirm(
        title: String,
        message: String,
        confirmTitle: String = "确认",
        isDestructive: Bool = true,
        onConfirm: @escaping () -> Void
    ) {
        request = ConfirmRequest(
            title: title,
            message: message,
            confirmTitle: confirmTitle,
            isDestructive: isDestructive,
            window: NSApp.keyWindow ?? WindowManager.mainWindow,
            onConfirm: onConfirm
        )
    }

    func dismiss() { request = nil }
}

/// 快速入口胶囊（首页：收藏 / 最近播放 / 最常播放 / 随机播放全部）
///
/// 视觉高 32（§2.1），命中区 44 —— 行高 44 由外层保证。
struct QuickPill: View {
    let title: String
    let systemImage: String
    var iconColor: Color = Theme.textSecondary
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.appReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(iconColor)
                Text(title)
                    .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
            }
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(
                Capsule().fill(hovered ? Theme.surfaceHover : Color.clear)
            )
            .glassControl(cornerRadius: 16)
            .contentShape(Capsule())
            .hitExpand(from: 32, to: 44)
            .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion) / 2)
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: 22)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityLabel(title)
    }
}

// MARK: - 输入框（高 32，圆角 10，surfaceSunken + 描边；聚焦焦点环）

struct TokenField<Content: View>: View {
    var height: CGFloat = Theme.Size.fieldHeight
    var isFocused = false
    var isError = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 11)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isFocused ? Theme.surface : Color.clear)
            )
            // 输入框属于 chrome 层（§7.4）：玻璃材质 + 聚焦时主色描边 + 焦点环
            .glassControl(cornerRadius: Theme.Radius.md)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(borderColor, lineWidth: isFocused ? 1.5 : 1)
            )
            .focusRing(isFocused)
            .animation(Theme.Motion.micro, value: isFocused)
    }

    private var borderColor: Color {
        if isError { return Theme.danger }
        if isFocused { return Theme.brand500 }
        return Color.clear
    }
}

/// 常驻搜索框（240×32，含 ⌘F 提示）
struct SearchField: View {
    @Binding var text: String
    var placeholder = "搜索曲目、专辑、艺人"
    var width: CGFloat = 240
    /// 外部请求聚焦（⌘F）：值变化即聚焦，无需调用方持有 FocusState
    var focusRequest: Int = 0
    var showsShortcutBadge = true
    var onSubmit: (() -> Void)?
    @FocusState private var focused: Bool

    var body: some View {
        TokenField(isFocused: focused) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .focused($focused)
                    .onSubmit { onSubmit?() }
                if text.isEmpty {
                    if showsShortcutBadge {
                        Text("⌘F")
                            .textStyle(.caption, weight: .medium, color: Theme.textTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                                    .fill(Theme.surface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                                    .strokeBorder(Theme.borderDefault)
                            )
                    }
                } else {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索")
                }
            }
        }
        .frame(width: width)
        .onChange(of: focusRequest) { _ in
            focused = true
        }
    }
}

// MARK: - 骨架屏（surfaceSunken + 1.2s 微光扫动）

struct SkeletonBlock: View {
    var cornerRadius: CGFloat = Theme.Radius.md

    @Environment(\.appReduceMotion) private var reduceMotion
    @State private var sweeping = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Theme.surfaceSunken)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geo in
                        LinearGradient(
                            colors: [.clear, Theme.shimmer, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: max(geo.size.width * 0.55, 24))
                        .offset(x: sweeping ? geo.size.width * 1.6 : -geo.size.width * 0.6)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                }
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    sweeping = true
                }
            }
            .accessibilityHidden(true)
    }
}

/// 网格骨架屏（默认 8 个占位卡），替代整页 spinner
struct SkeletonGrid: View {
    var count = 8
    var minWidth: CGFloat = 170
    var spacing: (h: CGFloat, v: CGFloat) = (20, 24)

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing.h)],
            alignment: .leading,
            spacing: spacing.v
        ) {
            ForEach(0..<count, id: \.self) { index in
                VStack(alignment: .leading, spacing: 10) {
                    SkeletonBlock()
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                    SkeletonBlock(cornerRadius: Theme.Radius.xs)
                        .frame(height: 10)
                        .frame(maxWidth: index.isMultiple(of: 2) ? 120 : 90, alignment: .leading)
                    SkeletonBlock(cornerRadius: Theme.Radius.xs)
                        .frame(height: 10)
                        .frame(maxWidth: 70, alignment: .leading)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// 列表骨架屏（行高 48）
struct SkeletonList: View {
    var count = 10

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: 12) {
                    SkeletonBlock(cornerRadius: Theme.Radius.sm)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 6) {
                        SkeletonBlock(cornerRadius: Theme.Radius.xs).frame(height: 10).frame(maxWidth: 220)
                        SkeletonBlock(cornerRadius: Theme.Radius.xs).frame(height: 8).frame(maxWidth: 140)
                    }
                    Spacer()
                }
                .frame(height: Theme.Size.listRowHeight)
                .padding(.horizontal, 12)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 空态（插画 64 谐波线条 + 标题 16/600 + 说明 13 + 主操作）

/// 谐波线条：一条基音 + 若干振幅递减的泛音（§4.1「基音与泛音」母题）
struct HarmonicLines: Shape {
    var count = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 48
        for line in 0..<count {
            let frequency = Double(line + 1)
            let amplitude = rect.height / 2 / Double(line + 1)
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            for step in 0...steps {
                let t = Double(step) / Double(steps)
                let point = CGPoint(
                    x: rect.minX + rect.width * t,
                    y: rect.midY - amplitude * sin(2 * .pi * frequency * t)
                )
                path.addLine(to: point)
            }
        }
        return path
    }
}

/// 空态插画：品牌色圆底 + 谐波线条 + 语义图标（装饰元素，不参与朗读）
struct HarmonicMark: View {
    var systemImage: String?
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.brandTint)
            HarmonicLines()
                .stroke(Theme.brandText.opacity(0.32), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                .frame(width: size * 0.74, height: size * 0.42)
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.28, weight: .regular))
                    .foregroundStyle(Theme.brandText)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct EmptyState<Action: View>: View {
    let systemImage: String
    let title: String
    var message: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            HarmonicMark(systemImage: systemImage)
            Text(title)
                .textStyle(.title4, color: Theme.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            action()
                .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, Theme.Spacing.xxxl)
    }
}

extension EmptyState where Action == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

// MARK: - Toast（底部居中，高 44，圆角 10，#14171C 底白字，3s 自动消失）

struct ToastMessage: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var systemImage: String = "checkmark"

    static func == (lhs: ToastMessage, rhs: ToastMessage) -> Bool { lhs.id == rhs.id }
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()

    @Published private(set) var current: ToastMessage?
    private var dismissTask: Task<Void, Never>?

    private init() {}

    func show(_ text: String, systemImage: String = "checkmark") {
        current = ToastMessage(text: text, systemImage: systemImage)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

struct ToastView: View {
    let message: ToastMessage

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: message.systemImage)
                .font(.system(size: 13, weight: .semibold))
            Text(message.text)
                .textStyle(.bodySM, weight: .medium, color: Theme.textOnInverse)
        }
        .foregroundStyle(Theme.textOnInverse)
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: 44)
        // Toast 属于 chrome 层：玻璃厚材质 + 反色染层（§7.4）；实底回退时染层仍在，对比度不丢
        .glassPanel(
            .thick,
            cornerRadius: Theme.Radius.md,
            elevation: .e2,
            tint: Theme.inverseSurface.opacity(0.78)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}

/// 挂在根视图：Toast 底部居中，上移 88pt 不遮挡迷你播放条
private struct ToastHost: ViewModifier {
    @ObservedObject private var center = ToastCenter.shared

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message = center.current {
                ToastView(message: message)
                    .padding(.bottom, 88)
                    .transition(.offset(y: 12).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(Theme.Motion.base, value: center.current)
    }
}

extension View {
    func toastHost() -> some View { modifier(ToastHost()) }
}

// MARK: - 区块标题（18/600 + 右侧操作，§4.3 title3 = 区块标题）

struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            Text(title)
                .textStyle(.title3, color: Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// 分组标题（详情页眉标：11/600 大写 tracking）
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.caption, color: Theme.textTertiary)
            .textCase(.uppercase)
            .tracking(0.66)
    }
}

// MARK: - 全局键盘快捷键（§2.2）

/// 本地按键监听：
/// - `⌘F` 聚焦搜索（任何场景，输入框内也生效）
/// - `空格` 播放/暂停、`⌘→ / ⌘←` 下一曲/上一曲
/// - `⌘1…⌘5` 切换一级页、`⌘,` 打开设置、`⌘[` 返回上一级、`⌫` 删除选中项
/// - `⌘R` 刷新媒体库、`⌘↑ / ⌘↓` 播放列表详情内上移/下移选中曲目
/// 焦点在文本输入框时除 `⌘F` / `⌘,` 外全部放行给输入框
struct KeyboardShortcutHandler: NSViewRepresentable {
    struct Actions {
        var onSpace: () -> Void = {}
        var onNext: () -> Void = {}
        var onPrevious: () -> Void = {}
        var onFocusSearch: () -> Void = {}
        var onPrimaryPage: (Int) -> Void = { _ in }
        var onBack: () -> Void = {}
        var onDelete: () -> Void = {}
        var onEscape: () -> Void = {}
        /// ⌘R：刷新媒体库
        var onRefresh: () -> Void = {}
        /// ⌘↑ / ⌘↓：播放列表内上移 / 下移选中曲目
        var onMoveUp: () -> Void = {}
        var onMoveDown: () -> Void = {}
    }

    var actions: Actions

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.actions = actions
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.actions = actions
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var actions = Actions()

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isTyping = isTextInputFocused
            let key = event.charactersIgnoringModifiers?.lowercased()

            // ⌘F：任何场景都聚焦搜索
            if key == "f", flags == .command {
                actions.onFocusSearch()
                return nil
            }
            // Esc：收起抽屉 / 取消聚焦
            if event.keyCode == 53, flags.isEmpty {
                actions.onEscape()
                return event
            }

            guard !isTyping else { return event }

            // 空格：播放/暂停（无修饰键）
            if event.charactersIgnoringModifiers == " ", flags.isEmpty {
                actions.onSpace()
                return nil
            }

            guard flags == .command else { return event }

            // ⌘1…⌘5：一级页
            if let key, let number = Int(key), (1...5).contains(number) {
                actions.onPrimaryPage(number)
                return nil
            }
            // ⌘R：刷新媒体库
            if key == "r" { actions.onRefresh(); return nil }
            // ⌘↑ / ⌘↓：播放列表内上移 / 下移
            if event.keyCode == 126 { actions.onMoveUp(); return nil }
            if event.keyCode == 125 { actions.onMoveDown(); return nil }
            // ⌘→ / ⌘←：下一曲 / 上一曲
            if event.keyCode == 124 { actions.onNext(); return nil }
            if event.keyCode == 123 { actions.onPrevious(); return nil }
            // ⌘[：返回上一级
            if key == "[" { actions.onBack(); return nil }
            // ⌫：删除选中项
            if event.keyCode == 51 { actions.onDelete(); return nil }
            return event
        }

        /// 首响应者是 NSTextView（TextField/SecureField 的底层）时视为正在输入
        private var isTextInputFocused: Bool {
            NSApplication.shared.keyWindow?.firstResponder is NSTextView
        }
    }
}

// MARK: - 时间格式化

func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// 曲目集合总时长（页面头元信息用）：小时为单位紧凑显示
func formatTotalDuration(_ seconds: Double) -> String {
    let hours = seconds / 3600
    if hours >= 10 { return String(format: "%.0f 小时", hours) }
    if hours >= 1 { return String(format: "%.1f 小时", hours) }
    return "\(Int(seconds / 60)) 分钟"
}
