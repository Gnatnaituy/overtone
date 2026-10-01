import SwiftUI

/// 正在播放页（重做，§4.6）：
/// - 宽窗口（W3+）：左主区（大封面 + 信息 + 进度 + 5 键控制）+ 右栏 320 待播清单；
/// - 窄窗口：单列，待播清单降级为底部可展开抽屉（不再压缩封面）。
struct NowPlayingView: View {
    let sizeClass: LayoutSizeClass

    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    @ObservedObject private var settings = AppSettings.shared

    @State private var appeared = false
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine]?
    @State private var lyricsFailed = false
    /// 窄窗待播抽屉
    @State private var queueDrawerOpen = false
    /// 待播清单显隐（宽窗）
    @State private var showQueueColumn = true

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                topBar

                if sizeClass.nowPlayingUsesSideQueue {
                    wideLayout(height: geo.size.height)
                } else {
                    narrowLayout(height: geo.size.height)
                }
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
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
        .animation(Theme.Motion.spring, value: showLyrics)
        .animation(Theme.Motion.spring, value: queueDrawerOpen)
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
            lyricsToggle

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
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: 58)
        .background(WindowDragArea().background(Theme.surface))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
        }
    }

    // MARK: - 宽窗口布局

    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.huge) {
            mainSection(maxCover: min(sizeClass.nowPlayingCoverMax, max(height - 300, 200)))
                .frame(maxWidth: .infinity)

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
        VStack(spacing: Theme.Spacing.xl) {
            ScrollView {
                mainSection(maxCover: min(sizeClass.nowPlayingCoverMax, max(height * 0.34, 140)))
                    .padding(.horizontal, sizeClass.pageMargin)
                    .padding(.vertical, Theme.Spacing.xxl)
            }
            .scrollIndicators(.hidden)

            queueDrawer(height: height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 主区

    private func mainSection(maxCover: CGFloat) -> some View {
        VStack(spacing: Theme.Spacing.xxl) {
            RemoteImage(url: music.currentTrack?.artworkURL(width: 640), contentMode: .fill)
                .frame(width: maxCover, height: maxCover)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl))
                .elevation(.e3)
                .id(music.currentTrack?.id)
                .transition(.scale(scale: 0.94).combined(with: .opacity))
                .scaleEffect(appeared ? 1 : 0.96)
                .animation(Theme.Motion.spring, value: appeared)

            VStack(spacing: Theme.Spacing.xs) {
                Text(music.currentTrack?.name ?? "未在播放")
                    .textStyle(.title2, color: Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text([music.currentTrack?.albumArtist, music.currentTrack?.album]
                    .compactMap { $0 }.joined(separator: " · "))
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: maxCover)

            progressSection
                .frame(maxWidth: 480)

            controls

            if showLyrics { lyricsPane }

            if let error = music.errorMessage {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                    Text(error)
                        .textStyle(.footnote)
                }
                .foregroundStyle(Theme.danger)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var progressSection: some View {
        VStack(spacing: Theme.Spacing.sm) {
            // 原生 Slider：可访问性可增量调节（§8 进度调节）
            Slider(
                value: $progress.position,
                in: 0...max(progress.duration, 1),
                onEditingChanged: { editing in music.sliderEditingChanged(editing) }
            )
            .tint(Theme.brand500)
            .accessibilityLabel("播放进度")
            .accessibilityValue("\(formatPlaybackTime(progress.position)) / \(formatPlaybackTime(progress.duration))")

            HStack {
                Text(formatPlaybackTime(progress.position))
                    .textStyle(.monoSM, color: Theme.textSecondary)
                    .frame(width: 44, alignment: .leading)
                Spacer()
                Text(formatPlaybackTime(progress.duration))
                    .textStyle(.monoSM, color: Theme.textSecondary)
                    .frame(width: 44, alignment: .trailing)
            }
        }
    }

    /// 5 键控制：随机 40 / 上一首 40 / 播放 56 主色圆 / 下一首 40 / 循环 40，间距 24
    private var controls: some View {
        HStack(spacing: Theme.Spacing.xxxl) {
            PlainIconButton(
                systemName: "shuffle",
                label: "随机播放",
                size: 40,
                isOn: music.playMode == .shuffle,
                action: { music.toggleShuffle() }
            )

            PlainIconButton(
                systemName: "backward.fill",
                label: "上一首",
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
                .contentShape(Circle())
                .animation(Theme.Motion.spring, value: music.isPlaying)
            }
            .buttonStyle(.plain)
            .help(music.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(music.isPlaying ? "暂停" : "播放")
            .accessibilityValue(music.isPlaying ? "播放中" : "已暂停")

            PlainIconButton(
                systemName: "forward.fill",
                label: "下一首",
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

    // MARK: - 待播清单（宽窗右栏 / 窄窗抽屉）

    private var upNextTracks: [BaseItemDto] {
        guard music.currentIndex >= 0, music.currentIndex + 1 < music.queue.count else { return [] }
        return Array(music.queue[(music.currentIndex + 1)...].prefix(40))
    }

    private var queueColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Text("待播清单")
                    .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(upNextTracks.count) 首")
                    .textStyle(.footnote, color: Theme.textSecondary)
                Spacer(minLength: 0)
            }

            if upNextTracks.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "队列已播完",
                    message: "去资料库挑几首吧"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(upNextTracks.enumerated()), id: \.element.id) { index, track in
                            QueueRow(
                                track: track,
                                index: index,
                                isNext: index == 0,
                                isCurrent: false,
                                isPlaying: false,
                                showsIndex: true
                            ) {
                                if let target = music.queue.firstIndex(where: { $0.id == track.id }) {
                                    music.jump(to: target)
                                }
                            }
                            if index < upNextTracks.count - 1 { RowDivider() }
                        }
                    }
                    .libraryTableChrome()
                }
                .scrollIndicators(.hidden)
                .background(ScrollBarHider())
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func queueDrawer(height: CGFloat) -> some View {
        VStack(spacing: 0) {
            Button {
                queueDrawerOpen.toggle()
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 12, weight: .medium))
                    Text("待播 \(upNextTracks.count) 首")
                        .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                    Spacer(minLength: 0)
                    Image(systemName: queueDrawerOpen ? "chevron.down" : "chevron.up")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.horizontal, sizeClass.pageMargin)
                .frame(height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(queueDrawerOpen ? "收起待播清单" : "展开待播清单")

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            if queueDrawerOpen {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(upNextTracks.enumerated()), id: \.element.id) { index, track in
                            QueueRow(
                                track: track,
                                index: index,
                                isNext: index == 0,
                                isCurrent: false,
                                isPlaying: false,
                                showsIndex: true
                            ) {
                                if let target = music.queue.firstIndex(where: { $0.id == track.id }) {
                                    music.jump(to: target)
                                }
                            }
                            if index < upNextTracks.count - 1 { RowDivider() }
                        }
                    }
                    .padding(.horizontal, sizeClass.pageMargin)
                    .padding(.vertical, Theme.Spacing.md)
                }
                .scrollIndicators(.hidden)
                .background(ScrollBarHider())
                .frame(height: min(height * 0.4, 320))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(Theme.surface)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
        }
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

    private var lyricsToggle: some View {
        IconButton(
            systemName: "text.alignleft",
            label: showLyrics ? "关闭歌词" : "歌词",
            size: Theme.Size.iconButtonSm,
            isOn: showLyrics
        ) {
            showLyrics.toggle()
            settings.showLyrics = showLyrics
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        }
    }

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

    private var lyricsPane: some View {
        Group {
            if let lyrics, !lyrics.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: Theme.Spacing.lg) {
                            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                                let isActive = index == activeLyricIndex
                                Text(line.text ?? "")
                                    .textStyle(isActive ? .title4 : .body, color: isActive ? Theme.brand500 : Theme.textTertiary)
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
                        withAnimation(Theme.Motion.base) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            } else if lyricsFailed {
                EmptyState(systemImage: "text.alignleft", title: "没有找到歌词")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: 180)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .strokeBorder(Theme.borderSubtle)
        )
        .transition(.offset(y: -8).combined(with: .opacity))
    }
}

// MARK: - 队列行（待播清单 / 队列抽屉共用）

struct QueueRow: View {
    let track: BaseItemDto
    let index: Int
    var isNext = false
    var isCurrent = false
    var isPlaying = false
    var showsIndex = false
    var onRemove: (() -> Void)?
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: Theme.Spacing.lg) {
                    if showsIndex {
                        ZStack {
                            if isCurrent {
                                EqualizerBars(active: isPlaying, color: Theme.brand500, barWidth: 2.5, height: 12)
                            } else {
                                Text("\(index + 1)")
                                    .textStyle(.mono, color: Theme.textTertiary)
                            }
                        }
                        .frame(width: 24, alignment: .leading)
                    }

                    RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name ?? "")
                            .textStyle(.bodySM, weight: isNext || isCurrent ? .semibold : .medium,
                                       color: isCurrent ? Theme.brand500 : Theme.textPrimary)
                            .lineLimit(1)
                        Text(track.albumArtist ?? track.album ?? "")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatPlaybackTime(track.runtimeSeconds))
                        .textStyle(.mono, color: Theme.textSecondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focused)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(track.name ?? "")，\(track.albumArtist ?? "")，\(formatPlaybackTime(track.runtimeSeconds))")

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(hovered || focused ? 1 : 0)
                .allowsHitTesting(hovered || focused)
                .help(isCurrent ? "正在播放，不可移除" : "从队列移除")
                .accessibilityLabel(isCurrent ? "正在播放，不可移除" : "从队列移除")
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 56)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Theme.brand500).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if isCurrent { return Theme.surfaceSelected }
        if hovered { return Theme.surfaceHover }
        return .clear
    }
}
