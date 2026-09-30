import SwiftUI

/// 底部播放条（设计稿三区布局）：左侧封面/信息 · 中部控制+进度 · 右侧音量/队列
struct MiniPlayerBar: View {
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var progress = MusicPlayerModel.shared.progress
    let onOpen: () -> Void
    let onToggleQueue: () -> Void
    var isQueueVisible = false
    /// 窄窗口：收起右侧音量区、隐藏时间标签
    var isCompact = false

    @State private var progressHovered = false

    var body: some View {
        if let track = music.currentTrack {
            HStack(spacing: 16) {
                // 左区：封面 + 曲目信息（点击展开正在播放页）
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm))
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm).strokeBorder(Theme.border))
                            .id(track.id)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))

                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.name ?? "未知曲目")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.primaryText)
                                .lineLimit(1)
                            Text([track.album, track.albumArtist].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: isCompact ? nil : 220, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
                .help("打开正在播放")

                Spacer(minLength: 0)

                // 中区：控制按钮 + 进度条
                VStack(spacing: 6) {
                    HStack(spacing: 18) {
                        Button {
                            music.toggleShuffle()
                        } label: {
                            Image(systemName: "shuffle")
                                .font(.system(size: 13))
                                .foregroundStyle(music.playMode == .shuffle ? Theme.accentText : Theme.secondaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help("随机播放")
                        .accessibilityLabel("随机播放")

                        Button {
                            music.previous()
                        } label: {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.primaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
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
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Theme.primaryText))
                            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: music.isPlaying)
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help(music.isPlaying ? "暂停" : "播放")
                        .accessibilityLabel(music.isPlaying ? "暂停" : "播放")

                        Button {
                            music.next()
                        } label: {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.primaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help("下一首")
                        .accessibilityLabel("下一首")

                        Button {
                            music.cycleRepeat()
                        } label: {
                            Image(systemName: music.playMode == .singleRepeat ? "repeat.1" : "repeat")
                                .font(.system(size: 13))
                                .foregroundStyle(music.playMode == .listRepeat || music.playMode == .singleRepeat ? Theme.accentText : Theme.secondaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help(music.playMode == .listRepeat ? "列表循环" : music.playMode == .singleRepeat ? "单曲循环" : "循环播放")
                        .accessibilityLabel(music.playMode == .listRepeat ? "列表循环" : music.playMode == .singleRepeat ? "单曲循环" : "循环播放")
                    }

                    // 进度条：时间 + 细滑杆（点击/拖动跳转）
                    HStack(spacing: 10) {
                        if !isCompact {
                            Text(formatPlaybackTime(progress.position))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 40, alignment: .trailing)
                        }
                        progressBar
                        if !isCompact {
                            Text(formatPlaybackTime(progress.duration))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 40, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 560)
                }

                Spacer(minLength: 0)

                // 右区：音量 + 队列
                if !isCompact {
                    HStack(spacing: 10) {
                        Button {
                            music.volume = music.volume > 0 ? 0 : 0.7
                        } label: {
                            Image(systemName: volumeIcon)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help(music.volume > 0 ? "静音" : "恢复音量")
                        .accessibilityLabel(music.volume > 0 ? "静音" : "恢复音量")

                        VolumeSlider(volume: $music.volume)
                            .frame(width: 96)

                        Button {
                            onToggleQueue()
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 13))
                                .foregroundStyle(isQueueVisible ? Theme.accentText : Theme.secondaryText)
                                .frame(width: 26, height: 26)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .acceptClickThrough()
                        .help("播放队列")
                        .accessibilityLabel("播放队列")
                    }
                    .frame(width: 220, alignment: .trailing)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 68)
            .frame(maxWidth: .infinity)
            .background(Theme.background)
            .overlay(alignment: .top) {
                Rectangle().fill(Theme.divider).frame(height: 1)
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: music.currentTrack?.id)
        }
    }

    private var volumeIcon: String {
        if music.volume <= 0 { return "speaker.slash.fill" }
        if music.volume < 0.4 { return "speaker.wave.1.fill" }
        return "speaker.wave.3.fill"
    }

    // MARK: - 进度滑杆

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.border)
                Capsule()
                    .fill(Theme.primaryText)
                    .frame(width: max(4, geo.size.width * progressRatio))
                    .animation(progressHovered ? .none : .linear(duration: 0.5), value: progressRatio)
                if progressHovered {
                    Circle()
                        .fill(Theme.primaryText)
                        .frame(width: 10, height: 10)
                        .shadow(color: Theme.cardShadow, radius: 2, y: 1)
                        .offset(x: min(max(0, geo.size.width * progressRatio - 5), geo.size.width - 10))
                }
            }
            .frame(height: progressHovered ? 6 : 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        music.scrub(ratio: value.location.x / geo.size.width)
                    }
                    .onEnded { _ in
                        music.endScrub()
                    }
            )
        }
        .frame(height: 8)
        .onHover { progressHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: progressHovered)
    }

    private var progressRatio: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }
}

/// 细音量滑杆：胶囊轨道 + 主色填充，点击/拖动调节
struct VolumeSlider: View {
    @Binding var volume: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.border)
                Capsule()
                    .fill(Theme.secondaryText)
                    .frame(width: max(3, geo.size.width * volume))
            }
            .frame(height: 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        volume = min(max(value.location.x / geo.size.width, 0), 1)
                    }
            )
        }
        .frame(height: 8)
        .accessibilityLabel("音量")
    }
}
