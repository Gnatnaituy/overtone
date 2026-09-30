import SwiftUI

/// 播放队列抽屉：显示当前队列、点击跳播、拖动排序、移除
struct QueuePanelView: View {
    @ObservedObject private var music = MusicPlayerModel.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(Theme.divider).frame(height: 1)

            if music.queue.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("队列为空，去点一首歌吧")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                queueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            // 与内容区之间的细分隔线 + 轻投影
            Rectangle()
                .fill(Theme.divider)
                .frame(width: 1)
                .shadow(color: Theme.cardShadow, radius: 6, x: -3)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("播放队列")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            Text("\(music.queue.count) 首")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.hoverFill))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.hoverFill))
            }
            .buttonStyle(.plain)
            .help("关闭队列")
            .accessibilityLabel("关闭队列")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var queueList: some View {
        List {
            ForEach(Array(music.queue.enumerated()), id: \.element.id) { index, track in
                QueueRowView(
                    track: track,
                    index: index,
                    isCurrent: index == music.currentIndex,
                    isPlaying: music.isPlaying && index == music.currentIndex,
                    onTap: { music.jump(to: index) },
                    onRemove: { music.removeQueueItem(at: index) }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            }
            .onMove { source, destination in
                music.moveQueueItems(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .padding(.vertical, 6)
    }
}

private struct QueueRowView: View {
    let track: BaseItemDto
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // 主区（序号/封面/标题/时长）：点击跳播；Button 保证键盘与 VoiceOver 可激活
            Button(action: onTap) {
                HStack(spacing: 10) {
                    ZStack {
                        if isCurrent {
                            EqualizerBars(active: isPlaying, color: Theme.accentStart, barWidth: 2, height: 12)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Theme.secondaryText)
                        }
                    }
                    .frame(width: 24)

                    RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name ?? "")
                            .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Theme.accentText : Theme.primaryText)
                            .lineLimit(1)
                        Text(track.albumArtist ?? track.album ?? "")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer()

                    if !hovered {
                        Text(formatPlaybackTime(track.runtimeSeconds))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hovered {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.hoverFill))
                }
                .buttonStyle(.plain)
                .help(isCurrent ? "正在播放，不可移除" : "从队列移除")
                .accessibilityLabel(isCurrent ? "正在播放，不可移除" : "从队列移除")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Theme.selectedFill : (hovered ? Theme.hoverFill : Color.clear))
        )
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
    }
}
