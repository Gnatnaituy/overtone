import SwiftUI

// MARK: - v4 纸墨组件库（契约 §2 冻结接口）
//
// 这里是「纸带与信号」四个母题的载体：点线引导 / VU 段条 / ON AIR 灯牌 / 谐波线，
// 外加印刷规则标签、套封封面框、方形开关。
//
// 为什么组件内部不判风格：契约 §1 保证 `Theme.Paper.*` 在玻璃模式下也返回可用取值
// （等价玻璃色），所以这些组件只读 `Theme.Paper.*` 就能两种风格都不炸；
// 风格分支留在调用方（`Theme.isPaper ? VUProgress(…) : 原玻璃进度条`），
// 免得一个组件里套三层条件分支。

// MARK: - 点线引导（Leader dots）

/// 点线引导（§4.4 母题）：1pt dotted 横线，吃掉行内剩余宽度，落在文字基线上方 3pt。
///
/// 为什么自带 `firstTextBaseline` 对齐指南：点线是「跟着基线走」的排版元素，
/// 调用方只要放进 `HStack(alignment: .firstTextBaseline)` 就自动贴住曲名/艺人名，
/// 不必在每个页面各写一遍偏移量（预览 `.ld{margin:0 2px 7px}` 折算下来正是基线上方 3pt）。
///
/// **当前没有任何调用点**：2026-10-14 用户裁决「横线太多了」，列表里的点线全部撤掉，
/// 那三处（`PaperTrackRow` / `HomeView` 的 Top 10 行 / `PlaylistsView` 的列表行）改成等宽的弹性空白。
/// 组件按契约 §2「组件接口冻结」保留 —— 它仍是 v4 的排版元素，留给将来真需要「引导」的场景
/// （目录页 / 点菜单），不是漏删的遗留物。
struct LeaderDots: View {
    var body: some View {
        LeaderDotsShape()
            .stroke(Theme.Paper.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
            .frame(height: 1)
            // minWidth 12：窄窗里标题再长也留得下一段点线（预览 `min-width:14px` 同理）
            .frame(minWidth: 12, maxWidth: .infinity)
            // 指南值 = 自身底边 + 3 → 细线整体落在基线上方 3pt（负值会让它压住字形）
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 3 }
            .accessibilityHidden(true)
    }
}

private struct LeaderDotsShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - ON AIR 灯牌

/// ON AIR 灯牌（§2.4）：3px 圆角信号红方块 + mono 小字，正在播放时呼吸。
///
/// 为什么是「实心块 + 白字」而不是「红点 + 红字」：灯牌是模拟台机上的物理指示，
/// 实心块在纸面上唯一能压住 ink 的彩色（§3 红只属于声音）；白字块本身也自带
/// 「颜色不单独承载信息」的冗余（块 = 形状，文字 = 语义）。
struct OnAirBadge: View {
    /// true = 方块呼吸；Reduce Motion 下静止（§2.5）
    var isPlaying: Bool = false
    /// true = 只有红方块（窄列 / 极窄窗，给不了「ON AIR」五个字符的宽度）
    var compact: Bool = false

    var body: some View {
        Group {
            if compact {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Theme.Paper.signal)
                    .frame(width: 8, height: 8)
            } else {
                Text("ON AIR")
                    // 9pt mono + .14em 字距：灯牌字是印刷体铭牌，不跟随正文字号阶梯
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(9 * 0.14)
                    .foregroundStyle(Theme.textOnAccent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.Paper.signal)
                    )
                    .fixedSize()
            }
        }
        // 呼吸底档 0.40：静止态（Reduce Motion / 暂停）就停在设计稿的 40% 上
        .modifier(PaperBreathing(active: isPlaying, minOpacity: 0.40))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("正在播放")
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - VU 段条（全局唯一的进度形态）

/// VU 段条（§4.5）：10 段方条，已播 = 信号红实心，当前段 = 信号红 40% + 900ms 呼吸，
/// 未播 = hairline。
///
/// 段宽走 `maxWidth: .infinity` 而非固定值：320pt 窄列下段宽 ≈30pt，窄到 140pt 仍有
/// 12pt 段宽（§10 验收线）；段与段之间恒为 2pt，靠的是 HStack 的 spacing 不参与压缩。
/// 缓冲条（`buffer != nil`）画在主条上方 2pt 处，用 ink3 更细一档 —— 缓冲是
/// 「还没轮到的信息」，不能和信号红抢注意力（§3 红只属于声音）。
struct VUProgress: View {
    /// 0…1（越界自动钳制）
    var value: Double
    var segments: Int = 10
    var height: CGFloat = 6
    /// true = 当前段呼吸；Reduce Motion 下静止
    var isPlaying: Bool = false
    /// 非 nil 时在主条上方画更细的缓冲段条
    var buffer: Double? = nil

    @Environment(\.appReduceMotion) private var reduceMotion

    private let gap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let buffer {
                bar(progress: buffer, height: bufferHeight, cornerRadius: bufferRadius, isBuffer: true)
            }
            bar(progress: clamped(value), height: height, cornerRadius: cornerRadius, isBuffer: false)
        }
        // Reduce Motion 下连填充过渡也去掉（§7「减少动态效果：全部过渡归零」）
        .animation(reduceMotion ? nil : Theme.Motion.micro, value: clamped(value))
        .animation(reduceMotion ? nil : Theme.Motion.micro, value: buffer)
        .accessibilityHidden(true)
    }

    /// 圆角 1；高 10 的「大段条」（正在播放页）按预览放宽到 2
    private var cornerRadius: CGFloat { height >= 10 ? 2 : 1 }

    private var bufferHeight: CGFloat { max(2, height * 0.4) }
    private var bufferRadius: CGFloat { bufferHeight >= 10 ? 2 : 1 }

    /// `Reduce Motion` 下动画由 modifier 内部静止，这里只负责填充档位
    private func bar(progress: Double, height: CGFloat, cornerRadius: CGFloat, isBuffer: Bool) -> some View {
        let filled = filledIndex(progress)
        return HStack(spacing: gap) {
            ForEach(0..<max(segments, 0), id: \.self) { index in
                segment(index: index, filled: filled, height: height, cornerRadius: cornerRadius, isBuffer: isBuffer)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func segment(index: Int, filled: Int, height: CGFloat, cornerRadius: CGFloat, isBuffer: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        if index < filled {
            shape.fill(isBuffer ? Theme.Paper.ink3.opacity(0.45) : Theme.Paper.signal)
        } else if index == filled {
            // 当前段：主条给 900ms 呼吸（0.40 ↔ 0.25 有效浓度）；缓冲条不呼吸
            if isBuffer {
                shape.fill(Theme.Paper.hairline)
            } else {
                shape
                    .fill(Theme.Paper.signal.opacity(0.40))
                    .modifier(PaperBreathing(active: isPlaying, minOpacity: 0.62))
            }
        } else {
            shape.fill(Theme.Paper.hairline)
        }
    }

    /// 与预览 `renderVU` 同一套规则：`floor(value × 段数)`；等于段数时全部点亮、没有当前段。
    private func filledIndex(_ progress: Double) -> Int {
        guard segments > 0 else { return 0 }
        return min(max(Int((progress * Double(segments)).rounded(.down)), 0), segments)
    }

    private func clamped(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, 0), 1)
    }
}

/// 迷你 VU（§4.5）：高 4、无缓冲，调用方自己包 Button 做跳转（键盘 ±5s 沿用 v3）。
struct VUMiniProgress: View {
    var value: Double
    var isPlaying: Bool = false

    var body: some View {
        VUProgress(value: value, segments: 10, height: 4, isPlaying: isPlaying, buffer: nil)
    }
}

// MARK: - 印刷规则标签

/// 印刷规则标签（§4.7）：`─── 标题 ─────  右侧操作`。
///
/// 两条细线都是弹性宽度、一直吃到容器缘：这是报纸版面的「分栏线」，
/// 标题因此居中，右侧操作（排序 / 查看全部）跟在细线之后。
/// 标题用小型大写 + .08em 字距（§2.2），中文不受 uppercase 影响、英文标题自动转大写。
struct RuleLabel<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            rule
            Text(title)
                .textStyle(.caption, weight: .semibold, color: Theme.Paper.ink2)
                .textCase(.uppercase)
                .tracking(0.88) // 11pt × .08em
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            rule
            trailing()
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(Theme.Paper.hairline)
            .frame(height: 1)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

extension RuleLabel where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}

// MARK: - 方形开关

/// 方形开关（§4.2）：32×18 轨道（圆角 3）+ 14pt 方钮，**不是胶囊** —— v4 的印刷感
/// 来自直角，胶囊只留给快速入口。
///
/// `label` 是**无障碍标签**而不是可见文字：设置页的行标签在行首（`.set-row .sl`），
/// 控件里再画一遍就重复了。命中区仍撑到 44×44（§8）。
struct PaperSwitch: View {
    @Binding var isOn: Bool
    var label: String

    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.appReduceMotion) private var reduceMotion

    private let trackWidth: CGFloat = 32
    private let trackHeight: CGFloat = 18
    private let knobSize: CGFloat = 14
    private let knobInset: CGFloat = 2

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(isOn ? Theme.Paper.ink : Theme.Paper.sunken)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(borderColor, lineWidth: 1)
                    )
                RoundedRectangle(cornerRadius: 1)
                    .fill(isOn ? Theme.Paper.sheet : Theme.Paper.ink3)
                    .frame(width: knobSize, height: knobSize)
                    .padding(.leading, knobInset)
                    .offset(x: isOn ? knobTravel : 0)
            }
            .frame(width: trackWidth, height: trackHeight)
            .contentShape(Rectangle())
            .hitExpand(from: trackHeight, to: 44)
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : Theme.Motion.micro, value: isOn)
        .animation(reduceMotion ? nil : Theme.Motion.micro, value: hovered)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "开" : "关")
        .accessibilityAddTraits(isOn ? [.isButton, .isSelected] : .isButton)
    }

    /// 钮的行程 = 轨道宽 − 两侧内缩 − 钮宽（32 − 4 − 14 = 14）
    private var knobTravel: CGFloat { trackWidth - knobInset * 2 - knobSize }

    private var borderColor: Color {
        if isOn { return Theme.Paper.ink }
        return hovered ? Theme.Paper.hairlineStrong : Theme.Paper.hairline
    }
}

// MARK: - 印刷套封封面框

extension View {
    /// 印刷套封（§4.6）：2px 圆角 + 1px 内描边（距边 3pt），模拟封套压框。
    ///
    /// - Parameter isPaper: 调用方传 `Theme.isPaper`；false 时**原样返回**（玻璃下封面
    ///   由面板圆角与投影表达，不加压框）。
    func paperCoverFrame(_ isPaper: Bool, cornerRadius: CGFloat = 2) -> some View {
        modifier(PaperCoverFrameModifier(enabled: isPaper, cornerRadius: cornerRadius))
    }
}

private struct PaperCoverFrameModifier: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: max(cornerRadius - 1, 0))
                        .strokeBorder(frameColor, lineWidth: 1)
                        .padding(3)
                }
        } else {
            content
        }
    }

    /// 压在图片上的描边不算主题色（封面是设计资产，契约 §0 铁律 2 的例外）：
    /// 浅色主题用白框（纸面上一圈压印的白边），深色主题用黑框（预览 `--cov-frame` 同法）。
    private var frameColor: Color {
        colorScheme == .dark ? Color.black.opacity(0.18) : Color.white.opacity(0.22)
    }
}

// MARK: - 共用私有件

/// 纸墨侧的交互过渡（hover / 选中态换底）。
///
/// 为什么不能直接写 `reduceMotion ? nil : Theme.Motion.micro`：那会把**玻璃侧**在
/// 「减少动态效果」下的行为也一起改掉（铁律 1：玻璃零回归）。这里只在纸墨分支归零 ——
/// §7「减少动态效果：全部过渡归零」，玻璃侧照旧。
enum PaperMotion {
    static func micro(reduceMotion: Bool) -> Animation? {
        (Theme.isPaper && reduceMotion) ? nil : Theme.Motion.micro
    }
}

/// 900ms 呼吸（§2.5）。只在「正在播放 + 未开启减少动态效果」时运行；
/// 其余情况恒停在 `maxOpacity`（静止档就是设计稿的基准浓度）。
///
/// 为什么用 `@State` + `repeatForever` 而不是 `TimelineView`：呼吸元素同屏通常只有
/// 一个（当前行 / ON AIR），不需要 display link 推帧；`TimelineView` 每个实例都挂一条
/// 刷新源，行数一多就是纯浪费（对比 `EqualizerBars` 那种需要连续波形的地方才用它）。
struct PaperBreathing: ViewModifier {
    let active: Bool
    var minOpacity: Double = 0.45
    var maxOpacity: Double = 1

    @Environment(\.appReduceMotion) private var reduceMotion
    @State private var dimmed = false

    func body(content: Content) -> some View {
        content
            .opacity(dimmed ? minOpacity : maxOpacity)
            .onAppear { sync() }
            .onChange(of: active) { _ in sync() }
            .onChange(of: reduceMotion) { _ in sync() }
    }

    private func sync() {
        guard active, !reduceMotion else {
            // 停：用一次性短过渡回到静止档，把 repeatForever 顶掉，避免残留动画继续跑
            withAnimation(.linear(duration: 0.12)) { dimmed = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { dimmed = true }
    }
}

/// paper 按钮样式的 hover 追踪壳。
///
/// `ButtonStyle` 是值类型、拿不到 `@State`，而 v4 的按钮 hover 要换底色 / 描边
/// （§4.1：主按钮 hover 加深 8%、次按钮描边转墨），所以把「有状态的外壳」单独做成 View，
/// 样式内部只消费 `hovered` 布尔值。
struct PaperHoverReader<Content: View>: View {
    @ViewBuilder var content: (Bool) -> Content

    @State private var hovered = false

    var body: some View {
        content(hovered)
            .onHover { hovered = $0 }
    }
}
