import SwiftUI

/// 底部迷你播放条（重做，§4.6）：三区布局（左信息 ≤220 / 中控制+进度 / 右音量+队列）。
/// 窄了降级为两区（信息 + 控制 + 队列），更窄再隐藏时间码与音量区。
///
/// **降级按播放条自身实测宽度判断，不能用窗口档位**：侧栏宽度可拖拽 180–320，
/// 同一档位下播放条可用宽度能差 250pt 以上。按档位判断时，三区布局的最小宽度
/// （左 220 + 控制 ≈330 + 右 220 + 间距内边距 ≈100 ≈ 870）会超过内容列宽度，
/// 整列（顶栏、页面一起）被顶出窗口右边缘 —— 顶栏搜索框、播放条右侧全被裁掉。
struct MiniPlayerBar: View {
    let onOpen: () -> Void
    let onToggleQueue: () -> Void
    var isQueueVisible = false

    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress

    @State private var progressHovered = false

    var body: some View {
        if let track = music.currentTrack {
            GeometryReader { geo in
                let layout = BarLayout(width: geo.size.width)
                // 单行三区（§2 骨架）：[封面 曲名 ≤220] [控制 + 进度] [音量 队列]
                HStack(spacing: layout.zoneSpacing) {
                    trackInfo(track)

                    Spacer(minLength: 0)

                    controlCluster(layout: layout)

                    Spacer(minLength: 0)

                    if layout.showsVolume {
                        volumeCluster
                    } else {
                        queueButton
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(height: Theme.Size.playerBarHeightGlass)
            // 播放条属于 chrome 层：悬浮玻璃面板（§7.2 规则 2），高度宽窄一致（§6 W0）
            .glassPanel(.thick, cornerRadius: Theme.Size.panelRadius, elevation: .e2)
            .padding(.horizontal, Theme.Size.panelGap)
            .padding(.bottom, Theme.Size.panelGap)
            .animation(Theme.Motion.spring, value: music.currentTrack?.id)
        }
    }

    // MARK: - 左区：封面 + 曲目信息

    private func trackInfo(_ track: BaseItemDto) -> some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                    .frame(width: Theme.Size.playerCover, height: Theme.Size.playerCover)
                    // 全部封面统一圆角 R=10（§7.2 规则 2）
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .id(track.id)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name ?? "未知曲目")
                        .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.sm) {
                        // 播放状态不只靠颜色：频谱柱 / 暂停图标双通道
                        if music.isPlaying {
                            EqualizerBars(active: true, color: Theme.overtoneTeal, barWidth: 2, height: 10)
                        }
                        Text([track.album, track.albumArtist].compactMap { $0 }.joined(separator: " · "))
                            .textStyle(.caption, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            // 左区上限 220（设计稿），窄窗可一路压缩到「封面 + 少量标题」，
            // 绝不反过来把控制区挤出播放条
            .frame(maxWidth: 220, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .help("打开正在播放")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在播放 \(track.name ?? "")，\(track.albumArtist ?? "")")
        .accessibilityHint("打开正在播放页")
    }

    // MARK: - 中区：控制 5 键 + 进度条（单行）

    private func controlCluster(layout: BarLayout) -> some View {
        HStack(spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.xs) {
                PlainIconButton(
                    systemName: "shuffle",
                    label: "随机播放",
                    size: Theme.Size.iconButtonSm,
                    isOn: music.playMode == .shuffle,
                    action: { music.toggleShuffle() }
                )

                PlainIconButton(
                    systemName: "backward.fill",
                    label: "上一首",
                    size: Theme.Size.iconButtonSm,
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
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.brandGradient))
                    .contentShape(Circle())
                    .animation(Theme.Motion.spring, value: music.isPlaying)
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
                .hitExpand(from: 36)
                .help(music.isPlaying ? "暂停" : "播放")
                .accessibilityLabel(music.isPlaying ? "暂停" : "播放")
                .accessibilityValue(music.isPlaying ? "播放中" : "已暂停")

                PlainIconButton(
                    systemName: "forward.fill",
                    label: "下一首",
                    size: Theme.Size.iconButtonSm,
                    tint: Theme.textPrimary,
                    action: { music.next() }
                )

                PlainIconButton(
                    systemName: music.playMode == .singleRepeat ? "repeat.1" : "repeat",
                    label: repeatLabel,
                    size: Theme.Size.iconButtonSm,
                    isOn: music.playMode == .listRepeat || music.playMode == .singleRepeat,
                    action: { music.cycleRepeat() }
                )
            }

            HStack(spacing: Theme.Spacing.md) {
                if layout.showsTime {
                    Text(formatPlaybackTime(progress.position))
                        .textStyle(.monoSM, color: Theme.textSecondary)
                        .frame(width: 36, alignment: .trailing)
                }
                progressBar
                    .frame(maxWidth: 560)
                if layout.showsTime {
                    Text(formatPlaybackTime(progress.duration))
                        .textStyle(.monoSM, color: Theme.textSecondary)
                        .frame(width: 36, alignment: .leading)
                }
            }
            .frame(minWidth: layout.progressMin)
        }
    }

    private var repeatLabel: String {
        switch music.playMode {
        case .listRepeat: return "列表循环"
        case .singleRepeat: return "单曲循环"
        default: return "循环播放"
        }
    }

    // MARK: - 右区：静音 + 音量 + 队列

    private var volumeCluster: some View {
        HStack(spacing: Theme.Spacing.lg) {
            PlainIconButton(
                systemName: volumeIcon,
                label: music.volume > 0 ? "静音" : "恢复音量",
                size: Theme.Size.iconButtonSm,
                action: { music.volume = music.volume > 0 ? 0 : 0.7 }
            )

            VolumeSlider(volume: $music.volume)
                .frame(minWidth: 60, maxWidth: 96)

            queueButton
        }
        .frame(maxWidth: 220, alignment: .trailing)
    }

    private var queueButton: some View {
        PlainIconButton(
            systemName: "list.bullet",
            label: "播放队列",
            size: Theme.Size.iconButtonSm,
            isOn: isQueueVisible,
            action: onToggleQueue
        )
    }

    private var volumeIcon: String {
        if music.volume <= 0 { return "speaker.slash.fill" }
        if music.volume < 0.4 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - 进度条（4pt 轨道，hover 6pt + 把手 10；可键盘 ±5s 微调）

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.borderDefault)
                Capsule()
                    .fill(Theme.brand500)
                    .frame(width: max(4, geo.size.width * progressRatio))
                    .animation(progressHovered ? .none : .linear(duration: 0.5), value: progressRatio)
                if progressHovered {
                    Circle()
                        .fill(Theme.brand500)
                        .frame(width: 10, height: 10)
                        .offset(x: min(max(0, geo.size.width * progressRatio - 5), max(geo.size.width - 10, 0)))
                }
            }
            .frame(height: progressHovered ? 6 : 4)
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
        .frame(height: 10)
        .onHover { progressHovered = $0 }
        .animation(Theme.Motion.micro, value: progressHovered)
        .accessibilityElement()
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(formatPlaybackTime(progress.position)) / \(formatPlaybackTime(progress.duration))")
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
}

// MARK: - 播放条分档（按自身实测宽度）

/// 播放条的宽度分档。
///
/// 判据是**播放条自己的宽度**而不是窗口档位：侧栏宽度可拖拽（180–320）或降级成
/// 64pt 图标栏，同一窗口档位下播放条可用宽度能差 250pt 以上。只有按实测宽度降级，
/// 才能保证「播放条最小宽度 ≤ 内容列宽度」，内容列不会被顶出窗口右边缘。
private struct BarLayout {
    /// 显示右侧音量区（三区布局需要 ≥820pt 才不挤）
    let showsVolume: Bool
    /// 显示进度条两侧时间码
    let showsTime: Bool
    /// 三区之间的间距
    let zoneSpacing: CGFloat
    /// 播放条左右内边距
    let horizontalPadding: CGFloat
    /// 进度条最小宽度
    let progressMin: CGFloat

    init(width: CGFloat) {
        // 三区实测：左信息 ≤220 + 控制区（图标 156 + 进度）+ 右音量 176 + 间距内边距 ≈100
        showsVolume = width >= 820
        showsTime = width >= 940
        let compact = width < 620
        zoneSpacing = compact ? Theme.Spacing.md : Theme.Spacing.xl
        horizontalPadding = compact ? Theme.Spacing.lg : Theme.Spacing.xxl
        progressMin = compact ? 56 : 96
    }
}

/// 细音量滑杆：胶囊轨道 + 主色填充，点击/拖动调节；键盘 ←/→ 微调 ±2%
struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.borderDefault)
                Capsule()
                    .fill(Theme.textSecondary)
                    .frame(width: max(3, geo.size.width * volume))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        volume = min(max(value.location.x / max(geo.size.width, 1), 0), 1)
                    }
            )
        }
        .frame(height: 10)
        .accessibilityElement()
        .accessibilityLabel("音量")
        .accessibilityValue("\(Int(volume * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: volume = min(volume + 0.02, 1)
            case .decrement: volume = max(volume - 0.02, 0)
            @unknown default: break
            }
        }
    }
}
