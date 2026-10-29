import SwiftUI

/// 沉浸式（全屏）歌词：覆盖「正在播放」页的内容区 —— 大字号居中 + 当前行高亮 +
/// 点行跳转 + Esc 退出。
///
/// 交互刻意克制，只保留五项：滚动 / 高亮 / 点行 seek / 底部进度条 / 退出。
/// 偏移调节留在歌词面板里（这里只做只读展示），避免同一屏出现两套调参 UI。
///
/// 视觉：
/// - 玻璃：封面模糊 + `surface` 雾面罩 + 与主区同源的封面取色色斑（`NowPlayingView.AmbientLayer`）；
/// - 纸墨：纸面底色 + 上下细线，当前行 `Paper.signalInk`、其余 `Paper.ink2`（v4 §6.6 歌词）；
/// - 两套都只放大字号层级（`.display` / `.title1` / `.title2`），不引入新字体或外部依赖。
///
/// 为什么不拆成独立窗口：任务约束「不要拆成独立窗口」。这里用「正在播放页」内的全页覆盖层，
/// 侧栏与窗口 chrome 保持可见（`MainView` 不在本功能的写作用域内）。
///
/// 观察范围：本视图只观察播放器（歌名 / 封面），**不**观察 `PlaybackProgress`（2Hz）——
/// 依赖进度的歌词区与进度条各自封装成子视图（`ImmersiveLyricsPane` /
/// `ImmersiveProgressFooter`），与 `NowPlayingView` 的既有做法一致：全屏模糊背景不该被
/// 每 0.5s 的进度 tick 拖着重算。
struct ImmersiveLyricsView: View {
    /// 歌词；空表 = 正在加载（`failed` 为真时表示确实没有歌词）
    let lyrics: [LyricLine]
    /// 拉取失败（无歌词）—— 空表时用来区分「加载中」与「这首歌没有歌词」
    let failed: Bool
    let sizeClass: LayoutSizeClass
    /// 歌词偏移（秒，正值 = 歌词推迟）；只读展示
    let offset: Double
    /// 封面取色（与主区氛围层同源）；纸墨模式 / 取色失败为 nil
    let palette: NowPlayingView.Palette?
    let onClose: () -> Void

    @ObservedObject private var music = MusicPlayerModel.shared
    @Environment(\.appReduceMotion) private var reduceMotion
    @Environment(\.appReduceTransparency) private var reduceTransparency
    /// 必须读环境值而不是 `Theme.isPaper` 全局镜像：镜像读了不订阅。
    @Environment(\.appVisualStyle) private var appStyle

    var body: some View {
        GeometryReader { geo in
            ZStack {
                backdrop(in: geo.size)

                VStack(spacing: 0) {
                    header

                    rule
                        .padding(.bottom, Theme.Spacing.md)

                    ImmersiveLyricsPane(
                        lyrics: lyrics,
                        failed: failed,
                        offset: offset,
                        sizeClass: sizeClass
                    )

                    rule
                        .padding(.top, Theme.Spacing.md)

                    ImmersiveProgressFooter(offset: offset)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, Theme.Spacing.xxl)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 模糊封面会溢出自身 frame：裁在页面边界内，避免盖到侧栏上
            .clipped()
        }
        // Esc 双保险：`.keyboardShortcut(.cancelAction)` 不依赖焦点，`.onExitCommand` 兜底
        .background(escapeShortcut)
        .onExitCommand(perform: onClose)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("沉浸式歌词")
        .accessibilityAddTraits(.isModal)
    }

    // MARK: - 背景

    @ViewBuilder
    private func backdrop(in size: CGSize) -> some View {
        if ink.isPaper {
            paperBackdrop
        } else {
            glassBackdrop(in: size)
        }
    }

    /// 纸墨：纸面 + 自上而下的极浅纸色渐变（印刷品没有灯光母题，不做模糊 / 取色）
    private var paperBackdrop: some View {
        ZStack {
            Theme.Paper.canvas
            LinearGradient(
                colors: [Theme.Paper.sheet.opacity(0.55), Theme.Paper.canvas.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .accessibilityHidden(true)
    }

    /// 玻璃：封面模糊 + 雾面罩 + 封面取色色斑（与主区氛围层同一份数据，不重复取色）
    private func glassBackdrop(in size: CGSize) -> some View {
        ZStack {
            coverImage(in: size)
            // 雾面罩：歌词落在封面任何区域都要可读；「降低透明度」下几乎实底（§7.3）
            Theme.surface.opacity(reduceTransparency ? 0.97 : 0.82)
            NowPlayingView.AmbientLayer(palette: palette ?? .fallback, reduceMotion: reduceMotion)
        }
        .accessibilityHidden(true)
    }

    private func coverImage(in size: CGSize) -> some View {
        RemoteImage(ref: music.currentTrack?.artworkRef(width: 1280), contentMode: .fill)
            .frame(width: size.width, height: size.height)
            .clipped()
            .blur(radius: reduceTransparency ? 0 : 44, opaque: true)
            .saturation(reduceTransparency ? 0.4 : 1.2)
            .opacity(reduceTransparency ? 0.16 : 0.5)
    }

    // MARK: - 顶栏（歌名 / 艺人 + 退出）

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(music.currentTrack?.title ?? "未在播放")
                    .textStyle(.title4, weight: .semibold, color: ink.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .textStyle(.footnote, color: ink.tertiary)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            closeButton
        }
        .padding(.bottom, Theme.Spacing.lg)
    }

    private var subtitle: String {
        let parts = [music.currentTrack?.artistName, music.currentTrack?.albumTitle]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        // 空字符串也要占一行，避免顶栏高度在两首歌之间跳动
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            HStack(spacing: Theme.Spacing.xs) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                Text("退出")
                    .textStyle(.footnote, weight: .medium)
            }
            .foregroundStyle(ink.secondary)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 30)
            // paper = sunken 纸底 + hairline；glass = 薄玻璃（同一个修饰符两端都成立）
            .glassControl(cornerRadius: Theme.Radius.sm, strength: .thin)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .help("退出沉浸式歌词（Esc）")
        .accessibilityLabel("退出沉浸式歌词")
    }

    /// 0 尺寸的 Esc 快捷键载体：不占布局、不参与读屏，只负责接住取消动作
    private var escapeShortcut: some View {
        Button("退出沉浸式歌词", action: onClose)
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }

    /// 顶栏下 / 底部上各一条分栏细线（纸墨 hairline；玻璃 borderSubtle）
    private var rule: some View {
        Rectangle()
            .fill(ink.ruleColor)
            .frame(height: 1)
            .accessibilityHidden(true)
    }

    // MARK: - 令牌

    private var ink: ImmersiveInk { ImmersiveInk(isPaper: appStyle == .paper) }

    private var horizontalPadding: CGFloat {
        switch sizeClass {
        case .w0: return Theme.Spacing.xxl
        case .w1: return Theme.Spacing.xxxl
        default: return Theme.Spacing.page
        }
    }
}

// MARK: - 歌词区（单独观察播放进度）

/// 歌词滚动区：当前行放大 + 品牌色，非当前行降透明；点行 seek。
///
/// 单独成视图的原因同 `NowPlayingView.LyricsPane`：只有高亮与滚动依赖 2Hz 的
/// `PlaybackProgress`，把观察收在这里，全屏背景与顶栏不跟着重算。
private struct ImmersiveLyricsPane: View {
    let lyrics: [LyricLine]
    let failed: Bool
    /// 歌词偏移（秒，正值 = 歌词推迟）
    let offset: Double
    let sizeClass: LayoutSizeClass

    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    @ObservedObject private var music = MusicPlayerModel.shared
    @Environment(\.appReduceMotion) private var reduceMotion
    @Environment(\.appVisualStyle) private var appStyle

    var body: some View {
        Group {
            if !lyrics.isEmpty {
                lyricsScroll
            } else if failed {
                placeholder("这首歌没有歌词", systemImage: "text.alignleft")
            } else {
                placeholder("歌词加载中…", systemImage: "text.alignleft", loading: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 滚动

    private var lyricsScroll: some View {
        let active = activeIndex
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: lineGap) {
                    ForEach(lyrics.indices, id: \.self) { index in
                        lineView(index: index, isActive: index == active)
                    }
                }
                .padding(.vertical, Theme.Spacing.huge)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: lyricsMaxWidth)
            .frame(maxWidth: .infinity)
            .onAppear {
                // 先让首帧完成布局：ScrollViewReader 对 LazyVStack 的远端行要等布局后才拿得到 frame
                let target = active
                DispatchQueue.main.async {
                    scroll(to: target, proxy: proxy, animated: false)
                }
            }
            .onChange(of: active) { newValue in
                scroll(to: newValue, proxy: proxy, animated: !reduceMotion)
            }
            .onChange(of: music.currentTrack?.id) { _ in
                let target = activeIndex
                DispatchQueue.main.async {
                    scroll(to: target, proxy: proxy, animated: false)
                }
            }
        }
    }

    private func scroll(to index: Int?, proxy: ScrollViewProxy, animated: Bool) {
        guard let index else { return }
        if animated {
            withAnimation(Theme.Motion.base) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }

    // MARK: 行

    @ViewBuilder
    private func lineView(index: Int, isActive: Bool) -> some View {
        let line = lyrics[index]
        let text = Text(line.textOrPlaceholder)
            .textStyle(
                isActive ? activeStyle : idleStyle,
                weight: isActive ? nil : .regular,
                color: isActive ? ink.accent : ink.secondary
            )
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            // 纯文本歌词没有当前行：不做降透明，否则整页像被压暗
            .opacity(isActive || !hasSynced ? 1 : 0.68)
            // Reduce Motion 下不做缩放，只留字号 / 颜色差异
            .scaleEffect(reduceMotion || isActive ? 1 : 0.97)
            .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.base, value: isActive)
            .id(index)

        if let start = line.start {
            Button {
                seek(toLineStart: start)
            } label: {
                text
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lineAccessibilityLabel(line, isActive: isActive))
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .help("跳到 \(formatPlaybackTime(start + offset))")
        } else {
            text
        }
    }

    private func lineAccessibilityLabel(_ line: LyricLine, isActive: Bool) -> String {
        var parts: [String] = []
        if isActive { parts.append("当前行") }
        parts.append(line.text.isEmpty ? "间奏" : line.text)
        if let start = line.start { parts.append("跳到 \(formatPlaybackTime(start + offset))") }
        return parts.joined(separator: "，")
    }

    private func placeholder(_ title: String, systemImage: String, loading: Bool = false) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            if loading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(ink.tertiary)
            }
            Text(title)
                .textStyle(.bodySM, color: ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: 数据 / 样式

    private var activeIndex: Int? {
        LyricsTimeline.activeIndex(lyrics: lyrics, position: progress.position, offset: offset)
    }

    private var hasSynced: Bool {
        LyricsTimeline.hasSyncedLyrics(lyrics)
    }

    /// 点行：跳到「这一行开始唱」的播放位置。
    ///
    /// 偏移是「歌词推迟 +offset」，要让这行**现在**成为当前行，播放位置就得是 `start + offset`
    /// （查表时 `position − offset == start`）。
    private func seek(toLineStart start: Double) {
        MusicPlayerModel.shared.seekTo(position: max(start + offset, 0))
    }

    private var ink: ImmersiveInk { ImmersiveInk(isPaper: appStyle == .paper) }

    /// 当前行字号（比非当前行大两档，只做字号层级，不额外缩放字号）
    private var activeStyle: Theme.TextStyle {
        switch sizeClass {
        case .w0, .w1: return .title2
        case .w2: return .title1
        default: return .display
        }
    }

    /// 非当前行字号；纸墨下这三档都解析为衬线（`.title4` 会回落到无衬线，故不用）
    private var idleStyle: Theme.TextStyle {
        switch sizeClass {
        case .w0, .w1, .w2: return .title3
        default: return .title2
        }
    }

    private var lineGap: CGFloat {
        switch sizeClass {
        case .w0, .w1: return Theme.Spacing.md
        case .w2: return Theme.Spacing.lg
        case .w3: return Theme.Spacing.xl
        default: return Theme.Spacing.xxl
        }
    }

    private var lyricsMaxWidth: CGFloat {
        switch sizeClass {
        case .w0: return 480
        case .w1: return 560
        case .w2: return 640
        case .w3: return 760
        default: return 860
        }
    }
}

// MARK: - 底部进度条（单独观察播放进度）

/// 底部进度：时间码 + 可拖动进度条（纸墨 = VU 段条，玻璃 = 胶囊条）+ 只读偏移提示。
private struct ImmersiveProgressFooter: View {
    /// 歌词偏移（秒，正值 = 推迟）；非 0 时显示只读提示
    let offset: Double

    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    @Environment(\.appVisualStyle) private var appStyle

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.lg) {
                Text(formatPlaybackTime(progress.position))
                    .textStyle(.monoSM, color: ink.tertiary)
                    .frame(width: 44, alignment: .leading)

                scrubBar

                Text(formatPlaybackTime(progress.duration))
                    .textStyle(.monoSM, color: ink.tertiary)
                    .frame(width: 44, alignment: .trailing)
            }
            .frame(maxWidth: 720)

            if offset != 0 {
                Text("歌词偏移 \(LyricsTimeline.offsetText(offset))")
                    .textStyle(.caption, color: ink.tertiary)
                    .accessibilityLabel("当前歌词偏移 \(LyricsTimeline.offsetText(offset))")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Theme.Spacing.lg)
    }

    private var scrubBar: some View {
        GeometryReader { geo in
            scrubVisual
                .frame(height: 12)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            MusicPlayerModel.shared.scrub(ratio: value.location.x / max(geo.size.width, 1))
                        }
                        .onEnded { _ in
                            MusicPlayerModel.shared.endScrub()
                        }
                )
        }
        .frame(height: 14)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue(
            "\(formatPlaybackTime(progress.position)) / \(formatPlaybackTime(progress.duration))"
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: MusicPlayerModel.shared.seekTo(position: progress.position + 5)
            case .decrement: MusicPlayerModel.shared.seekTo(position: progress.position - 5)
            @unknown default: break
            }
        }
    }

    /// 纸墨 = VU 段条（全局唯一的进度形态）；玻璃 = 胶囊条
    @ViewBuilder
    private var scrubVisual: some View {
        if ink.isPaper {
            VUProgress(value: progressRatio, segments: 24, height: 8)
        } else {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.borderDefault)
                    Capsule()
                        .fill(Theme.brand500)
                        .frame(width: max(3, geo.size.width * progressRatio))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var progressRatio: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }

    private var ink: ImmersiveInk { ImmersiveInk(isPaper: appStyle == .paper) }
}

// MARK: - 沉浸式配色（三种子类型共用）

/// 纸墨 / 玻璃两套文字与细线令牌。沉浸式全屏没有卡片外框，所有颜色都从这里取，
/// 避免三个子视图各写一份 `isPaper ? … : …`。
private struct ImmersiveInk {
    let isPaper: Bool

    var primary: Color { isPaper ? Theme.Paper.ink : Theme.textPrimary }
    var secondary: Color { isPaper ? Theme.Paper.ink2 : Theme.textSecondary }
    var tertiary: Color { isPaper ? Theme.Paper.ink3 : Theme.textTertiary }
    /// 当前行：纸墨 = 信号红文字档（v4 预览 `.lyrics b`）；玻璃 = 品牌色文字档
    var accent: Color { isPaper ? Theme.Paper.signalInk : Theme.brandText }
    /// 分栏细线：纸墨 hairline / 玻璃 borderSubtle
    var ruleColor: Color { isPaper ? Theme.Paper.hairline : Theme.borderSubtle }
}
