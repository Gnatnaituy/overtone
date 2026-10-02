import SwiftUI

/// 正在播放页（v3 §4.1 氛围色 / §4.5 组件，预览 `.np`）：
/// - 宽窗口（W3+）：主区实体卡（封面 + 曲名 + 进度 + 5 键控制）+ 右栏 320 待播清单；
/// - 窄窗口：单列主区 + 底部玻璃待播抽屉（遮罩 + 位移淡入，Reduce Motion 只留透明度）。
struct NowPlayingView: View {
    let sizeClass: LayoutSizeClass

    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    @ObservedObject private var settings = AppSettings.shared

    @Environment(\.appReduceMotion) private var reduceMotion

    @State private var appeared = false
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine]?
    @State private var lyricsFailed = false
    /// 窄窗待播抽屉
    @State private var queueDrawerOpen = false
    /// 待播清单显隐（宽窗）
    @State private var showQueueColumn = true
    /// 封面取色（氛围层 §4.1）；nil → 回落品牌色系
    @State private var palette: Palette?
    /// 进度条 hover（把手显隐）
    @State private var progressHovered = false
    /// 主播放键 hover（放大反馈）
    @State private var playHovered = false

    /// Reduce Motion 下位移动画归零，只保留 120ms 透明度过渡
    private var toggleAnimation: Animation {
        reduceMotion ? Theme.Motion.reduced : Theme.Motion.base
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    topBar

                    if sizeClass.nowPlayingUsesSideQueue {
                        wideLayout(height: geo.size.height)
                    } else {
                        narrowLayout(height: geo.size.height)
                    }
                }

                // 窄窗：待播抽屉 + 遮罩（宽窗走右栏，不叠层）
                if !sizeClass.nowPlayingUsesSideQueue {
                    narrowQueueLayer(height: geo.size.height)
                }
            }
        }
        .task(id: music.currentTrack?.id) { await loadPalette() }
        .onAppear {
            showLyrics = settings.showLyrics
            appeared = true
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        }
        .onChange(of: music.currentTrack?.id) { _ in
            lyrics = nil
            lyricsFailed = false
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        }
        .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.spring, value: showLyrics)
        .animation(toggleAnimation, value: queueDrawerOpen)
        .animation(Theme.Motion.spring, value: showQueueColumn)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("正在播放")
                .textStyle(.title4, color: Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            sleepTimerMenu

            if sizeClass.nowPlayingUsesSideQueue {
                IconButton(
                    systemName: "list.bullet",
                    label: showQueueColumn ? "隐藏待播清单" : "显示待播清单",
                    size: Theme.Size.iconButtonSm,
                    isOn: showQueueColumn
                ) {
                    showQueueColumn.toggle()
                }
            }
        }
        .padding(.horizontal, sizeClass.isNarrow ? Theme.Spacing.xl : Theme.Spacing.xxl)
        .frame(height: Theme.Size.topBarHeight)
        // 顶栏属于 chrome 层：悬浮玻璃面板（§7.2 规则 2），与其余页面同构
        .background(WindowDragArea())
        .glassPanel(.regular, cornerRadius: Theme.Size.panelRadius, elevation: .e2)
        .padding(.top, Theme.Size.panelMargin)
        .padding(.horizontal, Theme.Size.panelGap)
    }

    // MARK: - 宽窗口布局（主区 + 右栏 320）

    private func wideLayout(height: CGFloat) -> some View {
        HStack(spacing: Theme.Spacing.xxxl) {
            mainCard(maxCover: min(sizeClass.nowPlayingCoverMax, max(height - 300, 200)))

            if showQueueColumn {
                queueColumn
                    .frame(width: Theme.Size.queuePanelWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .padding(.vertical, Theme.Spacing.xxl)
        .frame(maxWidth: sizeClass.contentMaxWidth ?? .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 窄窗口布局（单列 + 底部待播抽屉）

    private func narrowLayout(height: CGFloat) -> some View {
        ScrollView {
            mainCard(maxCover: min(sizeClass.nowPlayingCoverMax, max(height * 0.34, 140)))
                .padding(.horizontal, sizeClass.pageMargin)
                .padding(.top, Theme.Spacing.xxl)
                // 给底部「待播 N 首」入口留位，避免盖住控制行
                .padding(.bottom, 76)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主区（实体卡 + 氛围层）

    private func mainCard(maxCover: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)

        return VStack(spacing: Theme.Spacing.xxl) {
            coverLyricsSwitch

            if showLyrics {
                lyricsPane
            } else {
                coverPane(maxCover: maxCover)
            }

            progressSection
                .frame(maxWidth: 480)

            controls

            if let error = music.errorMessage {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .textStyle(.footnote)
                }
                .foregroundStyle(Theme.danger)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(Theme.Spacing.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 内容层：不透明 surface 卡（§7.2 规则 1「玻璃只给框」）
        .background(shape.fill(Theme.surface))
        // 氛围层：封面取色的两枚低饱和色斑，透明度 ≤20%，纯装饰
        .background(
            AmbientLayer(palette: palette ?? .fallback, reduceMotion: reduceMotion)
                .clipShape(shape)
        )
        .clipShape(shape)
        .overlay(shape.strokeBorder(Theme.borderSubtle))
    }

    /// 封面 / 歌词切换（§4.5 分段控件，选中态 = brandGradient 白字）
    private var coverLyricsSwitch: some View {
        SegmentedControl(
            segments: [
                .init("cover", "封面"),
                .init("lyrics", "歌词")
            ],
            selection: Binding(
                get: { showLyrics ? "lyrics" : "cover" },
                set: { newValue in
                    let wantsLyrics = newValue == "lyrics"
                    guard wantsLyrics != showLyrics else { return }
                    showLyrics = wantsLyrics
                    settings.showLyrics = wantsLyrics
                    if wantsLyrics { Task { await loadLyricsIfNeeded() } }
                }
            )
        )
    }

    /// 封面 + 曲名行（频谱 + 22/700）+ 艺人 · 专辑（13 textSecondary）
    private func coverPane(maxCover: CGFloat) -> some View {
        VStack(spacing: 18) {
            RemoteImage(url: music.currentTrack?.artworkURL(width: 640), contentMode: .fill)
                .frame(width: maxCover, height: maxCover)
                // 全部封面统一圆角 md（§7.2 规则 2）
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .elevation(.e3, cornerRadius: Theme.Radius.md)
                .id(music.currentTrack?.id)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .scaleEffect(appeared || reduceMotion ? 1 : 0.96)
                .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.spring, value: appeared)

            VStack(spacing: 5) {
                HStack(spacing: 9) {
                    if music.currentTrack != nil {
                        EqualizerBars(
                            active: music.isPlaying,
                            color: Theme.overtoneTeal,
                            barWidth: 3,
                            height: 14
                        )
                    }
                    Text(music.currentTrack?.name ?? "未在播放")
                        .textStyle(.title2, color: Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text([music.currentTrack?.albumArtist, music.currentTrack?.album]
                    .compactMap { $0 }.joined(separator: " · "))
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: max(maxCover, 320))
        }
        .frame(maxWidth: .infinity)
        .transition(.opacity)
    }

    // MARK: - 进度条（左右时间码 40 + 可拖动 / 键盘 ±5s）

    private var progressSection: some View {
        HStack(spacing: 10) {
            Text(formatPlaybackTime(progress.position))
                .textStyle(.monoSM, color: Theme.textSecondary)
                .frame(width: 40, alignment: .leading)

            scrubBar

            Text(formatPlaybackTime(progress.duration))
                .textStyle(.monoSM, color: Theme.textSecondary)
                .frame(width: 40, alignment: .trailing)
        }
        .frame(maxWidth: 480)
    }

    private var scrubBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.borderDefault)

                Capsule()
                    .fill(Theme.brand500)
                    .frame(width: max(4, geo.size.width * progressRatio))
                    .animation(progressHovered || reduceMotion ? nil : .linear(duration: 0.5),
                               value: progressRatio)

                if progressHovered {
                    Circle()
                        .fill(Theme.brand500)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(0, geo.size.width * progressRatio - 5),
                                       max(geo.size.width - 10, 0)))
                }
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        music.scrub(ratio: value.location.x / max(geo.size.width, 1))
                    }
                    .onEnded { _ in
                        music.endScrub()
                    }
            )
        }
        .frame(height: 12)
        .onHover { progressHovered = $0 }
        .animation(Theme.Motion.micro, value: progressHovered)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatPlaybackTime(progress.position)) / \(formatPlaybackTime(progress.duration))")
        // 键盘 / VoiceOver 微调 ±5s
        .accessibilityAdjustableAction { direction in
            let step = 5.0
            switch direction {
            case .increment: music.seekTo(position: progress.position + step)
            case .decrement: music.seekTo(position: progress.position - step)
            @unknown default: break
            }
        }
    }

    private var progressRatio: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }

    // MARK: - 5 键控制（随机 40 / 上一曲 40 / 主播放 56 / 下一曲 40 / 循环 40，间距 22）

    private var controls: some View {
        HStack(spacing: 22) {
            PlainIconButton(
                systemName: "shuffle",
                label: "随机播放",
                size: 40,
                isOn: music.playMode == .shuffle,
                action: { music.toggleShuffle() }
            )

            PlainIconButton(
                systemName: "backward.fill",
                label: "上一曲",
                size: 40,
                tint: Theme.textPrimary,
                action: { music.previous() }
            )

            Button {
                music.togglePlay()
            } label: {
                ZStack {
                    Image(systemName: "pause.fill")
                        .opacity(music.isPlaying ? 1 : 0)
                        .scaleEffect(music.isPlaying ? 1 : 0.5)
                    Image(systemName: "play.fill")
                        .opacity(music.isPlaying ? 0 : 1)
                        .scaleEffect(music.isPlaying ? 0.5 : 1)
                }
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(Theme.brandGradient))
                .elevation(.e2)
                .scaleEffect(playHovered && !reduceMotion ? 1.04 : 1)
                .contentShape(Circle())
                .animation(Theme.Motion.spring, value: music.isPlaying)
                .animation(Theme.Motion.micro, value: playHovered)
            }
            .buttonStyle(.plain)
            .onHover { playHovered = $0 }
            .help(music.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(music.isPlaying ? "暂停" : "播放")
            .accessibilityValue(music.isPlaying ? "播放中" : "已暂停")

            PlainIconButton(
                systemName: "forward.fill",
                label: "下一曲",
                size: 40,
                tint: Theme.textPrimary,
                action: { music.next() }
            )

            PlainIconButton(
                systemName: music.playMode == .singleRepeat ? "repeat.1" : "repeat",
                label: repeatLabel,
                size: 40,
                isOn: music.playMode == .listRepeat || music.playMode == .singleRepeat,
                action: { music.cycleRepeat() }
            )
        }
    }

    private var repeatLabel: String {
        switch music.playMode {
        case .listRepeat: return "列表循环"
        case .singleRepeat: return "单曲循环"
        default: return "循环播放"
        }
    }

    // MARK: - 待播清单（宽窗右栏 / 窄窗抽屉共用数据）

    /// 列出的行：当前曲（高亮 + 频谱）在前，其后是最多 40 首待播。
    private var listedRows: [QueueEntry] {
        guard music.currentIndex >= 0, music.queue.indices.contains(music.currentIndex) else { return [] }
        let end = min(music.currentIndex + 41, music.queue.count)
        return (music.currentIndex..<end).map { QueueEntry(index: $0, track: music.queue[$0]) }
    }

    @ViewBuilder
    private var queueRowList: some View {
        ForEach(listedRows) { entry in
            QueueRow(
                track: entry.track,
                index: entry.index,
                isNext: entry.index == music.currentIndex + 1,
                isCurrent: entry.index == music.currentIndex,
                isPlaying: music.isPlaying && entry.index == music.currentIndex
            ) {
                music.jump(to: entry.index)
            }
            .padding(.horizontal, Theme.Spacing.xs)
        }
    }

    /// 标题「待播清单 · N 首」；有收起动作时右侧补一个图标按钮
    private func queueHeader(count: Int, collapse: (() -> Void)? = nil) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.xs) {
                Text("待播清单")
                    .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                Text("· \(count) 首")
                    .textStyle(.bodySM, color: Theme.textTertiary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 0)

            if let collapse {
                PlainIconButton(systemName: "chevron.down", label: "收起待播清单", action: collapse)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 36)
    }

    /// 宽窗右栏：surface 卡 + lg 圆角 + e1（深色自动换描边）
    private var queueColumn: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)

        return VStack(alignment: .leading, spacing: 0) {
            queueHeader(count: listedRows.count)
                .padding(.bottom, Theme.Spacing.sm)

            if listedRows.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "队列已播完",
                    message: "去资料库挑几首吧"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { queueRowList }
                }
                .scrollIndicators(.hidden)
                .background(ScrollBarHider())
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(shape.fill(Theme.surface))
        .clipShape(shape)
        .elevation(.e1, cornerRadius: Theme.Radius.lg)
    }

    // MARK: - 窄窗待播层（抽屉 + 遮罩）

    @ViewBuilder
    private func narrowQueueLayer(height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if queueDrawerOpen {
                Theme.scrim
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture { queueDrawerOpen = false }
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }

            if queueDrawerOpen {
                drawerPanel(height: height)
                    // 位移 + 透明度；Reduce Motion 只保留透明度
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            } else {
                drawerToggle
                    .padding(.bottom, Theme.Spacing.xl)
                    .transition(.opacity)
            }
        }
    }

    private var drawerToggle: some View {
        Button {
            queueDrawerOpen = true
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 12, weight: .medium))
                Text("待播 \(listedRows.count) 首")
                Image(systemName: "chevron.up")
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(SecondaryButtonStyle(compact: true))
        .help("展开待播清单")
        .accessibilityLabel("展开待播清单，共 \(listedRows.count) 首")
    }

    /// 玻璃厚材质抽屉（§7.2：抽屉属 chrome 层）
    private func drawerPanel(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            queueHeader(count: listedRows.count, collapse: { queueDrawerOpen = false })
                .padding(.bottom, Theme.Spacing.sm)

            if listedRows.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "队列已播完",
                    message: "去资料库挑几首吧"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) { queueRowList }
                }
                .scrollIndicators(.hidden)
                .background(ScrollBarHider())
                .frame(height: min(max(height * 0.42, 140), 300))
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.md)
        .padding(.bottom, Theme.Spacing.lg)
        .frame(maxWidth: .infinity)
        .glassPanel(.thick, cornerRadius: Theme.Radius.md, elevation: .e3)
        .padding(.horizontal, Theme.Size.panelMargin)
        .padding(.bottom, Theme.Size.panelMargin)
    }

    // MARK: - 睡眠定时器

    private var sleepTimerMenu: some View {
        ZStack {
            Circle()
                .fill(music.sleepTimerEnd == nil
                      ? AnyShapeStyle(Theme.surface)
                      : AnyShapeStyle(Theme.brandGradient))
            Image(systemName: music.sleepTimerEnd == nil ? "moon.zzz" : "moon.zzz.fill")
                .font(.system(size: 13))
                .foregroundStyle(music.sleepTimerEnd == nil ? Theme.textSecondary : .white)
                // 光学补偿：moon.zzz 的月亮主体位于画布左下，按字形 bbox 居中会沉在圆心左下
                .offset(x: 0.7, y: -1.9)
        }
        .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
        .overlay(Circle().strokeBorder(music.sleepTimerEnd == nil ? Theme.borderDefault : .clear))
        .overlay {
            Menu {
                ForEach([15.0, 30.0, 45.0, 60.0], id: \.self) { minutes in
                    Button("\(Int(minutes)) 分钟后停止") {
                        music.setSleepTimer(minutes: minutes)
                    }
                }
                if music.sleepTimerEnd != nil {
                    Divider()
                    Button("关闭睡眠定时", role: .destructive) {
                        music.setSleepTimer(minutes: nil)
                    }
                }
            } label: {
                Color.clear
                    .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("睡眠定时器")
        }
        .help(sleepTimerHelp)
    }

    private var sleepTimerHelp: String {
        guard let end = music.sleepTimerEnd else { return "睡眠定时器" }
        let remain = max(Int(end.timeIntervalSinceNow / 60) + 1, 1)
        return "将在约 \(remain) 分钟后停止播放"
    }

    // MARK: - 歌词

    private func loadLyricsIfNeeded() async {
        guard lyrics == nil, !lyricsFailed else { return }
        guard let itemId = music.currentTrack?.id else { return }
        do {
            let fetched = try await APIClient.shared.fetchLyrics(itemId: itemId)
            lyrics = fetched
            lyricsFailed = fetched.isEmpty
        } catch {
            lyrics = []
            lyricsFailed = true
        }
    }

    /// 当前应高亮的歌词行（时间戳 ≤ 播放进度的最后一行）
    private var activeLyricIndex: Int? {
        guard let lyrics else { return nil }
        var index: Int?
        for (i, line) in lyrics.enumerated() {
            if let start = line.startSeconds, start <= progress.position + 0.2 {
                index = i
            } else if line.startSeconds != nil {
                break
            }
        }
        return index
    }

    /// 歌词行：当前行 16/600 `brandText`，其余 14 `textTertiary`（§4.1 第二谐波语义）
    private var lyricsPane: some View {
        Group {
            if let lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                                let isActive = index == activeLyricIndex
                                Text(line.text ?? "")
                                    .textStyle(
                                        isActive ? .title4 : .body,
                                        weight: isActive ? .semibold : nil,
                                        color: isActive ? Theme.brandText : Theme.textTertiary
                                    )
                                    .frame(maxWidth: .infinity)
                                    .multilineTextAlignment(.center)
                                    .id(index)
                                    .animation(Theme.Motion.base, value: isActive)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.lg)
                    }
                    .onChange(of: activeLyricIndex) { index in
                        guard let index else { return }
                        withAnimation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.base) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: 420)
                .frame(height: 260)
            } else if lyricsFailed {
                EmptyState(systemImage: "text.alignleft", title: "没有找到歌词")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 180)
            }
        }
        .transition(.opacity)
    }

    // MARK: - 封面取色（氛围层数据源）

    /// 用与封面同一个 URL 取图（命中同一份缓存），取色失败回落品牌色系。
    @MainActor
    private func loadPalette() async {
        guard let track = music.currentTrack, let url = track.artworkURL(width: 640) else {
            palette = nil
            return
        }
        let image = await ImageCache.shared.image(for: url)
        palette = Palette(image: image)
    }
}

// MARK: - 队列行（待播清单 / 窄窗抽屉 / 播放队列面板共用）

/// 列表行（§4.5）：高 52、圆角 6、hover `surfaceHover`、
/// 当前行 `surfaceSelected` + 3pt 指示条 + 频谱，封面 36 圆角 10。
struct QueueRow: View {
    let track: BaseItemDto
    let index: Int
    var isNext = false
    var isCurrent = false
    var isPlaying = false
    var showsIndex = false
    /// 拖拽把手（仅播放队列面板：List `.onMove` 的可见入口）
    var showsHandle = false
    var onRemove: (() -> Void)?
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.lg) {
                    if showsIndex || isCurrent {
                        ZStack {
                            if isCurrent {
                                EqualizerBars(
                                    active: isPlaying,
                                    color: Theme.overtoneTeal,
                                    barWidth: 2.5,
                                    height: 12
                                )
                            } else {
                                Text("\(index + 1)")
                                    .textStyle(.monoSM, color: Theme.textTertiary)
                            }
                        }
                        .frame(width: 22, alignment: .leading)
                    }

                    RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name ?? "")
                            .textStyle(.bodySM,
                                       weight: isNext || isCurrent ? .semibold : .medium,
                                       color: isCurrent ? Theme.brandText : Theme.textPrimary)
                            .lineLimit(1)
                        Text(track.albumArtist ?? track.album ?? "")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatPlaybackTime(track.runtimeSeconds))
                        .textStyle(.monoSM, color: Theme.textTertiary)
                        .frame(width: 40, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .focused($focused)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(rowLabel)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                        .contentShape(Rectangle())
                        .hitExpand(from: Theme.Size.iconButtonSm)
                }
                .buttonStyle(.plain)
                .opacity(hovered || focused ? 1 : 0)
                .allowsHitTesting(hovered || focused)
                .help(isCurrent ? "正在播放，不可移除" : "从队列移除")
                .accessibilityLabel(isCurrent ? "正在播放，不可移除" : "从队列移除")
            }

            if showsHandle {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(width: 16, height: 16)
                    .hitExpand(from: 16)
                    .help("拖动排序")
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 52)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Theme.brand500).frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
            .fill(backgroundFill)
    }

    private var backgroundFill: Color {
        if isCurrent { return Theme.surfaceSelected }
        if hovered { return Theme.surfaceHover }
        return .clear
    }

    /// 读屏合并朗读：第 N 首 / 曲名 / 艺人 / 时长，当前曲追加播放状态（§5.6）
    private var rowLabel: String {
        var parts: [String] = []
        if showsIndex { parts.append("第 \(index + 1) 首") }
        parts.append(track.name ?? "")
        if let artist = track.albumArtist, !artist.isEmpty { parts.append(artist) }
        parts.append(formatPlaybackTime(track.runtimeSeconds))
        if isCurrent { parts.append(isPlaying ? "播放中" : "已暂停") }
        return parts.joined(separator: "，")
    }
}

// MARK: - 本页私有：氛围层 / 封面取色 / 待播行数据
//
// 全部嵌进 `NowPlayingView`：共享层由其他文件负责，这里不新增模块级类型名，
// 避免与 Theme.swift / Components.swift 的既有或新增类型撞名。

extension NowPlayingView {
    /// 主区卡内的氛围层：**两枚**克制色斑（封面主色的低饱和渐变，α ≤ 20%）。
    ///
    /// 与窗口底的 `AmbientWash` 同源不同量：那里是四组大 wash，这里是两枚小色斑，
    /// 避免内容卡内部过艳；「降低透明度」开启时压暗到 60% 并降饱和（§7.3）。
    fileprivate struct AmbientLayer: View {
        let palette: Palette
        var reduceMotion = false

        @Environment(\.appReduceTransparency) private var reduceTransparency

        var body: some View {
            GeometryReader { geo in
                ZStack {
                    blob(
                        palette.primary,
                        rx: 0.90, ry: 0.90,
                        at: UnitPoint(x: 0.20, y: 0.10),
                        opacity: 0.18,
                        in: geo.size
                    )
                    blob(
                        palette.secondary,
                        rx: 0.80, ry: 0.80,
                        at: UnitPoint(x: 0.85, y: 0.90),
                        opacity: 0.13,
                        in: geo.size
                    )
                }
            }
            .opacity(reduceTransparency ? 0.6 : 1)
            .saturation(reduceTransparency ? 0.35 : 1)
            .animation(reduceMotion ? nil : Theme.Motion.base, value: palette)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }

        /// 一枚椭圆色斑：CSS `radial-gradient(<rx> <ry> at <x> <y>, …)` 的等价物
        private func blob(
            _ color: Color,
            rx: CGFloat,
            ry: CGFloat,
            at unit: UnitPoint,
            opacity: Double,
            in size: CGSize
        ) -> some View {
            let radius = max(size.height * ry, 1)
            let aspect = (size.width * rx) / radius
            return Circle()
                .fill(
                    RadialGradient(
                        colors: [color.opacity(opacity), color.opacity(0)],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    )
                )
                .frame(width: radius * 2, height: radius * 2)
                .scaleEffect(x: aspect, y: 1)
                .position(x: size.width * unit.x, y: size.height * unit.y)
        }
    }

    /// 封面主色 → 氛围层用的低饱和主色 + 邻近色。
    ///
    /// 本地降采样到 8×8 求平均（不新增共享 API）：平均色转 HSB 后压饱和度、收亮度，
    /// 灰度封面（饱和度过低）或取色失败返回 nil，由调用方回落品牌色系。
    fileprivate struct Palette: Equatable {
        let primary: Color
        let secondary: Color

        /// 回落：品牌主色 + 第二谐波青（§4.1 L3 泛音律动）
        static let fallback = Palette(primary: Theme.brand400, secondary: Theme.overtoneTeal)

        init(primary: Color, secondary: Color) {
            self.primary = primary
            self.secondary = secondary
        }

        init?(image: NSImage?) {
            guard let image, let hsb = Palette.averageHSB(of: image) else { return nil }
            // 低饱和：饱和度压到 ≤0.55，亮度收在中间带 —— 氛围层不能抢内容
            let saturation = min(hsb.saturation * 0.7, 0.55)
            guard saturation > 0.08 else { return nil }
            let brightness = min(max(hsb.brightness, 0.45), 0.90)

            self.primary = Color(hue: hsb.hue, saturation: saturation, brightness: brightness)
            let nearby = (hsb.hue + 0.08).truncatingRemainder(dividingBy: 1)
            self.secondary = Color(
                hue: nearby,
                saturation: min(saturation * 0.85, 0.50),
                brightness: min(brightness * 1.05, 1)
            )
        }

        /// 8×8 降采样平均色的 HSB（sRGB）
        private static func averageHSB(
            of image: NSImage
        ) -> (hue: Double, saturation: Double, brightness: Double)? {
            let side = 8
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: side,
                pixelsHigh: side,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(
                in: NSRect(x: 0, y: 0, width: side, height: side),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            guard let data = rep.bitmapData else { return nil }
            let samples = rep.samplesPerPixel
            var r = 0.0, g = 0.0, b = 0.0, weight = 0.0
            for y in 0..<side {
                for x in 0..<side {
                    let pixel = data + y * rep.bytesPerRow + x * samples
                    let alpha = samples >= 4 ? Double(pixel[3]) / 255 : 1
                    guard alpha > 0.5 else { continue }
                    r += Double(pixel[0]) / 255
                    g += Double(pixel[1]) / 255
                    b += Double(pixel[2]) / 255
                    weight += 1
                }
            }
            guard weight > 0 else { return nil }

            let color = NSColor(srgbRed: r / weight, green: g / weight, blue: b / weight, alpha: 1)
            var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
            color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
            return (Double(hue), Double(saturation), Double(brightness))
        }
    }

    /// 待播清单 / 抽屉的一行：队列下标 + 曲目（下标即 id，队列内唯一）
    fileprivate struct QueueEntry: Identifiable {
        let index: Int
        let track: BaseItemDto

        var id: Int { index }
    }
}
