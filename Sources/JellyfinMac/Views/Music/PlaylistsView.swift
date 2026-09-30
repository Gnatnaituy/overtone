import SwiftUI

/// 播放列表页：网格展示本地/智能播放列表，点击进入详情
struct PlaylistsView: View {
    let onOpenPlaylist: (Playlist) -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var store = MusicDataStore.shared
    @State private var showCreatePlaylist = false
    @State private var showCreateSmart = false
    @State private var newPlaylistName = ""
    @State private var newSmartName = ""
    @State private var newSmartKeyword = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                PlaylistGrid(onOpenPlaylist: onOpenPlaylist)
                    .padding(.horizontal, 32)
                    .padding(.top, 24)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await store.loadIfNeeded() }
        .alert("新建播放列表", isPresented: $showCreatePlaylist) {
            TextField("播放列表名称", text: $newPlaylistName)
            Button("创建") {
                playlistStore.create(name: newPlaylistName)
                newPlaylistName = ""
            }
            Button("取消", role: .cancel) {}
        }
        .alert("新建智能播放列表", isPresented: $showCreateSmart) {
            TextField("播放列表名称", text: $newSmartName)
            TextField("艺术家关键字（如：初音ミク）", text: $newSmartKeyword)
            Button("创建") {
                playlistStore.createSmart(name: newSmartName, artistKeyword: newSmartKeyword)
                newSmartName = ""
                newSmartKeyword = ""
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("播放列表")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.primaryText)
            if !playlistStore.allPlaylists.isEmpty {
                Text("\(playlistStore.allPlaylists.count) 个")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }
            Spacer()
            Button {
                newPlaylistName = ""
                showCreatePlaylist = true
            } label: {
                Label("新建", systemImage: "plus")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                newSmartName = ""
                newSmartKeyword = ""
                showCreateSmart = true
            } label: {
                Label("智能", systemImage: "sparkles")
            }
            .buttonStyle(SecondaryButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(WindowDragArea().background(Theme.background))
    }
}

/// 播放列表网格（资料库「播放列表」分段与播放列表页共用）
struct PlaylistGrid: View {
    let onOpenPlaylist: (Playlist) -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared

    var body: some View {
        Group {
            if playlistStore.allPlaylists.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 36))
                        .foregroundStyle(Theme.tertiaryText)
                    Text("还没有播放列表，点击右上角「新建」创建")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 60)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)],
                    alignment: .leading,
                    spacing: 28
                ) {
                    ForEach(playlistStore.allPlaylists) { playlist in
                        PlaylistCard(playlist: playlist, onTap: { onOpenPlaylist(playlist) })
                    }
                }
            }
        }
    }
}

/// 播放列表卡片：前 4 首封面拼图（不足回退渐变图标）+ 名称 + 曲目数
struct PlaylistCard: View {
    let playlist: Playlist
    let onTap: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @State private var hovered = false

    /// 取前 4 首有封面的曲目做 2x2 拼图
    private var coverTracks: [BaseItemDto] {
        let ids = playlist.isSmart ? [] : playlist.trackIds
        let tracks = ids.compactMap { store.track(id: $0) }
        if tracks.isEmpty { return [] }
        return Array(tracks.prefix(4))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                    .overlay {
                        if hovered {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.radiusMd)
                                    .fill(Color.black.opacity(0.32))
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }

                Text(playlist.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: hovered ? -2 : 0)
        .shadow(color: Theme.hoverShadow, radius: hovered ? 10 : 0, y: hovered ? 6 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
    }

    private var subtitle: String {
        if playlist.isSmart {
            return "智能播放列表"
        }
        let count = playlist.trackIds.count
        return count > 0 ? "\(count) 首曲目" : "空播放列表"
    }

    @ViewBuilder
    private var cover: some View {
        if coverTracks.count >= 2 {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let size = (geo.size.width - gap) / 2
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        coverThumb(coverTracks[safe: 0], size: size)
                        coverThumb(coverTracks[safe: 1], size: size)
                    }
                    HStack(spacing: gap) {
                        coverThumb(coverTracks[safe: 2], size: size)
                        coverThumb(coverTracks[safe: 3], size: size)
                    }
                }
            }
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: playlist.isSmart ? "sparkles" : "music.note.list")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.accentText.opacity(0.5))
            }
        }
    }

    private func coverThumb(_ track: BaseItemDto?, size: CGFloat) -> some View {
        Group {
            if let track {
                RemoteImage(url: track.artworkURL(width: 200), contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Theme.surface2)
                    .frame(width: size, height: size)
            }
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
