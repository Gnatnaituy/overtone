import SwiftUI

/// 正在播放页（设计稿）：大封面 + 标题/进度/控制 + 右侧待播清单；保留歌词与睡眠定时
struct NowPlayingView: View {
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    @State private var appeared = false

    /// 歌词
    @State private var showLyrics = false
    @State private var lyrics: [LyricLine]?
    @State private var lyricsFailed = false

    /// 待播清单展示开关（右上角按钮切换）
    @State private var showQueueList = true

    /// 实测布局高度（替代硬编码常量）：顶栏、封面之外的信息区高度
    @State private var topBarHeight: CGFloat = 58
    @State private var infoHeight: CGFloat = 198

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 820
            let artwork = adaptiveArtworkSize(
                height: geo.size.height,
                compact: compact
            )
            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, compact ? 20 : 32)
                    .background(MeasureHeight<TopBarHeightKey>())

                if compact {
                    compactLayout(artworkSize: artwork)
                } else {
                    regularLayout(artworkSize: artwork)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .onPreferenceChange(TopBarHeightKey.self) { topBarHeight = $0 }
        .onPreferenceChange(InfoStackHeightKey.self) { infoHeight = $0 }
        .onAppear {
            appeared = false
            withAnimation(Theme.bouncy) { appeared = true }
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        }
        .onChange(of: music.currentTrack?.id) { _ in
            lyrics = nil
            lyricsFailed = false
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showLyrics)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: showQueueList)
    }

    // MARK: - 布局分支（拆分以避免 release 模式下类型推断失败）

    /// 窄窗口：主区在上自适应，待播清单占据剩余空间并内部滚动
    private func compactLayout(artworkSize: CGFloat) -> some View {
        VStack(spacing: 20) {
            mainSection(artworkSize: artworkSize)
            if showQueueList {
                upNext
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 宽窗口：整页不滚动，封面/控制随高度自适应，待播清单内部滚动
    private func regularLayout(artworkSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 48) {
            mainSection(artworkSize: artworkSize)
                .frame(maxWidth: .infinity)
            if showQueueList {
                upNext
                    .frame(width: 280)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
    }

    // MARK: - 顶栏（标题 + 歌词/睡眠定时，兼作拖拽区）

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("正在播放")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primaryText)
            Spacer()
            sleepTimerMenu
            lyricsToggle
            queueToggle
        }
        .padding(.vertical, 14)
        .background(WindowDragArea().background(Theme.background))
    }

    // MARK: - 主区（封面 + 信息 + 进度 + 控制）

    /// 封面尺寸随窗口高度自适应：依据实测的顶栏与信息区高度，
    /// 剩余高度分给封面（窄窗口额外预留待播清单空间）
    private func adaptiveArtworkSize(height: CGFloat, compact: Bool) -> CGFloat {
        let verticalPadding: CGFloat = compact ? 32 : 40
        let spacing: CGFloat = 20
        // 窄窗口下方待播清单至少保留的高度（隐藏时不再预留，封面可用更多空间）
        let queueReserve: CGFloat = (compact && showQueueList) ? 180 : 0
        let available = height - topBarHeight - verticalPadding - spacing - infoHeight - queueReserve
        let upperBound: CGFloat = compact ? 260 : 400
        return min(max(available, 140), upperBound)
    }

    private func mainSection(artworkSize: CGFloat) -> some View {
        VStack(spacing: 20) {
            RemoteImage(url: music.currentTrack?.artworkURL(width: 640), contentMode: .fill)
                .frame(width: artworkSize, height: artworkSize)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusXl))
                .shadow(color: Theme.hoverShadow, radius: 20, y: 10)
                .id(music.currentTrack?.id)
                .transition(.scale(scale: 0.92).combined(with: .opacity))
                .scaleEffect(appeared ? 1 : 0.95)
                .animation(Theme.bouncy, value: appeared)

            // 信息区（标题/进度/控制/歌词）：测量高度供封面自适应计算
            VStack(spacing: 20) {
                VStack(spacing: 4) {
                    Text(music.currentTrack?.name ?? "未在播放")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text([music.currentTrack?.albumArtist, music.currentTrack?.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
                .frame(maxWidth: artworkSize)

                progressSection
                    .frame(maxWidth: 480)

                controls

                if showLyrics {
                    lyricsPane
                }

                if let error = music.errorMessage {
                    Text(error)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }
            .background(MeasureHeight<InfoStackHeightKey>())
        }
        .frame(maxWidth: .infinity)
    }

    private var progressSection: some View {
        VStack(spacing: 6) {
            Slider(
                value: $progress.position,
                in: 0...max(progress.duration, 1),
                onEditingChanged: { editing in music.sliderEditingChanged(editing) }
            )
            .tint(Theme.primaryBlue)
            .accessibilityLabel("播放进度")
            HStack {
                Text(formatPlaybackTime(progress.position))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                Spacer()
                Text(formatPlaybackTime(progress.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 32) {
            Button {
                music.toggleShuffle()
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 15))
                    .foregroundStyle(music.playMode == .shuffle ? Theme.accentText : Theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("随机播放")
            .accessibilityLabel("随机播放")

            Button {
                music.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("上一首")
            .accessibilityLabel("上一首")

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
                .background(Circle().fill(Theme.accentGradient))
                .shadow(color: Theme.primaryBlue.opacity(0.3), radius: 10, y: 4)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: music.isPlaying)
            }
            .buttonStyle(.plain)
            .help(music.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(music.isPlaying ? "暂停" : "播放")

            Button {
                music.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("下一首")
            .accessibilityLabel("下一首")

            Button {
                music.cycleRepeat()
            } label: {
                Image(systemName: music.playMode == .singleRepeat ? "repeat.1" : "repeat")
                    .font(.system(size: 15))
                    .foregroundStyle(music.playMode == .listRepeat || music.playMode == .singleRepeat ? Theme.accentText : Theme.secondaryText)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(music.playMode == .listRepeat ? "列表循环" : music.playMode == .singleRepeat ? "单曲循环" : "循环播放")
            .accessibilityLabel(music.playMode == .listRepeat ? "列表循环" : music.playMode == .singleRepeat ? "单曲循环" : "循环播放")
        }
    }

    // MARK: - 待播清单（设计稿：右侧卡片列表，内部滚动不带动整页）

    private var upNext: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("待播清单")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Text("\(max(music.queue.count - music.currentIndex - 1, 0)) 首")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            if upNextTracks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("队列已播完")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(upNextTracks.enumerated()), id: \.element.id) { offset, track in
                            upNextRow(track: track, isNext: offset == 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border))
    }

    /// 当前曲目之后的队列（最多展示 30 首）
    private var upNextTracks: [BaseItemDto] {
        guard music.currentIndex >= 0, music.currentIndex + 1 < music.queue.count else { return [] }
        return Array(music.queue[(music.currentIndex + 1)...].prefix(30))
    }

    private func upNextRow(track: BaseItemDto, isNext: Bool) -> some View {
        Button {
            if let index = music.queue.firstIndex(where: { $0.id == track.id }) {
                music.jump(to: index)
            }
        } label: {
            HStack(spacing: 10) {
                RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "")
                        .font(.system(size: 13, weight: isNext ? .semibold : .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(track.albumArtist ?? track.album ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                Text(formatPlaybackTime(track.runtimeSeconds))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(isNext ? Color.white : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .strokeBorder(isNext ? Theme.border : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 睡眠定时器

    private var sleepTimerMenu: some View {
        // 视觉层：图标与圆形底在 ZStack 中严格同心
        //（borderlessButton 菜单样式会吞掉 label 内背景、附加系统内边距，导致图标在圆圈内偏移）
        ZStack {
            Circle()
                .fill(music.sleepTimerEnd == nil ? AnyShapeStyle(Theme.hoverFill) : AnyShapeStyle(Theme.accentGradient))
            Image(systemName: music.sleepTimerEnd == nil ? "moon.zzz" : "moon.zzz.fill")
                .font(.system(size: 13))
                .foregroundStyle(music.sleepTimerEnd == nil ? Theme.secondaryText : .white)
                // 光学补偿：moon.zzz 字形的月亮主体位于画布左下（zzz 悬于右上），
                // 按字形 bbox 居中时月亮会沉在圆心左下约 (0.7, 1.9)pt，视觉上不居中。
                // 实测偏移 (0.7, -1.9) 可让月亮主体对准圆心（两种变体所需偏移几乎一致）。
                .offset(x: 0.7, y: -1.9)
        }
        .frame(width: 30, height: 30)
        .overlay(Circle().strokeBorder(music.sleepTimerEnd == nil ? Theme.border : .clear))
        .scaleEffect(music.sleepTimerEnd == nil ? 1 : 1.05)
        .animation(Theme.micro, value: music.sleepTimerEnd == nil)
        // 交互层：透明 Menu 覆盖同一区域，仅负责弹出定时选项
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
                    .frame(width: 30, height: 30)
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
        Button {
            showLyrics.toggle()
            if showLyrics { Task { await loadLyricsIfNeeded() } }
        } label: {
            Image(systemName: "captions.bubble")
                .font(.system(size: 13))
                .foregroundStyle(showLyrics ? .white : Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(showLyrics ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hoverFill))
                )
                .overlay(Circle().strokeBorder(showLyrics ? .clear : Theme.border))
                .scaleEffect(showLyrics ? 1.05 : 1)
                .animation(Theme.micro, value: showLyrics)
        }
        .buttonStyle(.plain)
        .help("歌词")
        .accessibilityLabel(showLyrics ? "关闭歌词" : "歌词")
    }

    /// 待播清单显隐切换（歌词按钮右侧）
    private var queueToggle: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                showQueueList.toggle()
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13))
                .foregroundStyle(showQueueList ? .white : Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(showQueueList ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.hoverFill))
                )
                .overlay(Circle().strokeBorder(showQueueList ? .clear : Theme.border))
                .scaleEffect(showQueueList ? 1.05 : 1)
                .animation(Theme.micro, value: showQueueList)
        }
        .buttonStyle(.plain)
        .help(showQueueList ? "隐藏待播清单" : "显示待播清单")
        .accessibilityLabel(showQueueList ? "隐藏待播清单" : "显示待播清单")
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
                        LazyVStack(spacing: 10) {
                            ForEach(Array(lyrics.enumerated()), id: \.offset) { index, line in
                                let isActive = index == activeLyricIndex
                                Text(line.text ?? "")
                                    .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                                    .foregroundStyle(isActive ? Theme.accentText : Theme.secondaryText)
                                    .frame(maxWidth: .infinity)
                                    .multilineTextAlignment(.center)
                                    .id(index)
                                    .animation(.easeInOut(duration: 0.25), value: isActive)
                            }
                        }
                        .padding(.vertical, 12)
                    }
                    .onChange(of: activeLyricIndex) { index in
                        guard let index else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(index, anchor: .center)
                        }
                    }
                }
            } else if lyricsFailed {
                VStack(spacing: 8) {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("没有找到歌词")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 440, height: 170)
        .background(RoundedRectangle(cornerRadius: Theme.radiusLg).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - 布局高度测量

private struct TopBarHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct InfoStackHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 把所在区域的实际高度写入对应 preference，供自适应布局测量
private struct MeasureHeight<K: PreferenceKey>: View where K.Value == CGFloat {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(key: K.self, value: geo.size.height)
        }
    }
}
