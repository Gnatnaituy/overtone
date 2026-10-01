import SwiftUI

/// 底部迷你播放条（重做，§4.6）：三区布局（左信息 220 / 中控制+进度 / 右音量+队列）。
/// W0 降级为两区（信息 + 控制），W1 隐藏音量区与时间标签。
struct MiniPlayerBar: View {
    let sizeClass: LayoutSizeClass
    let onOpen: () -> Void
    let onToggleQueue: () -> Void
    var isQueueVisible = false

    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress

    @State private var progressHovered = false

    private var showsVolume: Bool { sizeClass.playerBarShowsVolume }
    private var showsTime: Bool { sizeClass.playerBarShowsTime }

    var body: some View {
        if let track = music.currentTrack {
            HStack(spacing: Theme.Spacing.xl) {
                trackInfo(track)

                Spacer(minLength: 0)

                controlCluster

                Spacer(minLength: 0)

                if showsVolume {
                    volumeCluster
                } else {
                    queueButton
                }
            }
            .padding(.horizontal, sizeClass.isNarrow ? Theme.Spacing.lg : Theme.Spacing.xxl)
            .frame(height: sizeClass.playerBarHeight)
            .frame(maxWidth: .infinity)
            .background(Theme.surface)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.borderSubtle).frame(height: 1)
            }
            .animation(Theme.Motion.spring, value: music.currentTrack?.id)
        }
    }

    // MARK: - 左区：封面 + 曲目信息

    private func trackInfo(_ track: BaseItemDto) -> some View {
        Button(action: onOpen) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                    .frame(width: Theme.Size.playerCover, height: Theme.Size.playerCover)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
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
            .frame(width: showsVolume ? 220 : nil, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .help("打开正在播放")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("正在播放 \(track.name ?? "")，\(track.albumArtist ?? "")")
        .accessibilityHint("打开正在播放页")
    }

    // MARK: - 中区：控制 5 键 + 进度条

    private var controlCluster: some View {
        VStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xxl) {
                PlainIconButton(
                    systemName: "shuffle",
                    label: "随机播放",
                    size: Theme.Size.iconButtonMd,
                    isOn: music.playMode == .shuffle,
                    action: { music.toggleShuffle() }
                )

                PlainIconButton(
                    systemName: "backward.fill",
                    label: "上一首",
                    size: Theme.Size.iconButtonMd,
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
                .help(music.isPlaying ? "暂停" : "播放")
                .accessibilityLabel(music.isPlaying ? "暂停" : "播放")
                .accessibilityValue(music.isPlaying ? "播放中" : "已暂停")

                PlainIconButton(
                    systemName: "forward.fill",
                    label: "下一首",
                    size: Theme.Size.iconButtonMd,
                    tint: Theme.textPrimary,
                    action: { music.next() }
                )

                PlainIconButton(
                    systemName: music.playMode == .singleRepeat ? "repeat.1" : "repeat",
                    label: repeatLabel,
                    size: Theme.Size.iconButtonMd,
                    isOn: music.playMode == .listRepeat || music.playMode == .singleRepeat,
                    action: { music.cycleRepeat() }
                )
            }

            HStack(spacing: Theme.Spacing.md) {
                if showsTime {
                    Text(formatPlaybackTime(progress.position))
                        .textStyle(.monoSM, color: Theme.textSecondary)
                        .frame(width: 40, alignment: .trailing)
                }
                progressBar
                if showsTime {
                    Text(formatPlaybackTime(progress.duration))
                        .textStyle(.monoSM, color: Theme.textSecondary)
                        .frame(width: 40, alignment: .leading)
                }
            }
            .frame(maxWidth: 560)
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
                .frame(width: 96)

            queueButton
        }
        .frame(width: 220, alignment: .trailing)
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
