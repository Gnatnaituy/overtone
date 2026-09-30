import SwiftUI

struct MusicRow: View {
    let track: BaseItemDto
    var isCurrent = false
    var isPlaying = false
    var onRemove: (() -> Void)?
    var onTap: () -> Void

    @ObservedObject private var playlists = PlaylistStore.shared
    @ObservedObject private var store = MusicDataStore.shared
    @State private var hovered = false
    @State private var showInfo = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    artwork

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name ?? "")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isCurrent ? Theme.accentText : Theme.primaryText)
                            .lineLimit(1)
                        if !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .acceptClickThrough()

            Spacer()

            // 收藏状态常显（心形），其余操作悬停浮现
            favoriteButton

            if hovered {
                infoButton
                    .transition(.opacity)
                overflowMenu
                    .transition(.opacity)
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)
                    .help("从播放列表移除")
                    .accessibilityLabel("从播放列表移除")
                    .transition(.opacity)
                }
            }

            Text(formatPlaybackTime(track.runtimeSeconds))
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(hovered ? Theme.hoverFill : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        .animation(.easeOut(duration: 0.15), value: hovered)
        .onHover { hovered = $0 }
        .popover(isPresented: $showInfo, arrowEdge: .bottom) {
            TrackInfoView(track: track)
        }
    }

    // MARK: - 封面

    private var artwork: some View {
        RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border))
            .overlay {
                // 悬停：封面变暗 + 播放图标
                if hovered {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .fill(Color.black.opacity(0.32))
                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isCurrent {
                    // 正在播放：主色小圆徽章内嵌跳动的频谱柱
                    Circle()
                        .fill(Theme.accentGradient)
                        .frame(width: 18, height: 18)
                        .overlay(
                            EqualizerBars(active: isPlaying, color: .white, barWidth: 1.2, height: 7)
                        )
                        .offset(x: 5, y: -5)
                        .shadow(color: Theme.cardShadow, radius: 3, y: 1)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isCurrent)
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sub = track.album ?? track.albumArtist {
            parts.append(sub)
        }
        if let count = track.userData?.playCount, count > 0 {
            parts.append("播放 \(count) 次")
        }
        return parts.joined(separator: " · ")
    }

    private var infoButton: some View {
        Button {
            showInfo = true
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.hoverFill))
        }
        .buttonStyle(.plain)
        .help("曲目信息")
        .accessibilityLabel("曲目信息")
    }

    // MARK: - 收藏

    private var favoriteButton: some View {
        let isFavorite = track.userData?.isFavorite == true
        return Button {
            Task { await MusicDataStore.shared.toggleFavorite(track) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 13))
                .foregroundStyle(isFavorite ? Color(hex: 0xFF5C8A) : Theme.tertiaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(hovered || isFavorite ? Theme.hoverFill : Color.clear))
                .scaleEffect(isFavorite ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消收藏" : "收藏")
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isFavorite)
    }

    // MARK: - 更多操作（插播/入队/播放列表）

    private var overflowMenu: some View {
        Menu {
            Button {
                MusicPlayerModel.shared.playNext(track)
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            Button {
                MusicPlayerModel.shared.enqueue([track])
            } label: {
                Label("添加到队列", systemImage: "text.badge.plus")
            }
            Divider()
            if playlists.playlists.isEmpty {
                Text("暂无播放列表，请先在左侧创建")
            } else {
                ForEach(playlists.playlists) { playlist in
                    Button(playlist.name) {
                        playlists.add(track: track, to: playlist)
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Theme.hoverFill))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }
}
