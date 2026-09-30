import SwiftUI

/// 资料库页（设计稿）：顶栏大标题 + 分段控件（专辑/艺人/歌曲/播放列表），内容随分段切换
struct MusicLibraryView: View {
    @Binding var segment: LibrarySegment
    let sortMode: TrackSortMode
    let onSortModeChange: (TrackSortMode) -> Void
    let onOpenArtist: (BaseItemDto) -> Void
    let onOpenAlbum: (BaseItemDto) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var music = MusicPlayerModel.shared
    /// 排序结果缓存：滚动时不重复排序 1000+ 曲目
    @State private var displayedTracks: [BaseItemDto] = []

    private var segmentSelection: Binding<String> {
        Binding(
            get: { segment.rawValue },
            set: { segment = LibrarySegment(rawValue: $0) ?? .albums }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                Group {
                    switch segment {
                    case .albums: albumsGrid
                    case .artists: artistsGrid
                    case .tracks: tracksList
                    case .playlists: playlistsGrid
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: segment)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay {
            if store.isLoading && store.tracks.isEmpty && store.albums.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
        .task {
            await store.loadIfNeeded()
            displayedTracks = store.sortedTracks(by: sortMode)
        }
        .task(id: sortMode) {
            displayedTracks = store.sortedTracks(by: sortMode)
        }
        .onChange(of: store.tracks) { _ in
            displayedTracks = store.sortedTracks(by: sortMode)
        }
    }

    // MARK: - 顶栏（标题 + 分段控件，兼作窗口拖拽区）

    private var header: some View {
        HStack(spacing: 16) {
            Text("资料库")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(Theme.primaryText)

            Spacer()

            if segment == .tracks {
                compactPlayControls
                sortMenu
            }

            SegmentedControl(
                segments: [
                    .init("albums", "专辑"),
                    .init("artists", "艺人"),
                    .init("tracks", "歌曲"),
                    .init("playlists", "播放列表")
                ],
                selection: segmentSelection
            )
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 16)
        .background(WindowDragArea().background(Theme.background))
    }

    /// 歌曲分段的紧凑操作：随机 / 播放全部
    private var compactPlayControls: some View {
        HStack(spacing: 6) {
            Button {
                MusicPlayerModel.shared.play(tracks: displayedTracks.shuffled(), startAt: 0)
            } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.primaryText)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.surface))
                    .overlay(Circle().strokeBorder(Theme.border))
            }
            .buttonStyle(.plain)
            .disabled(displayedTracks.isEmpty)
            .opacity(displayedTracks.isEmpty ? 0.4 : 1)
            .help("随机播放")
            .accessibilityLabel("随机播放")

            Button {
                MusicPlayerModel.shared.play(tracks: displayedTracks, startAt: 0)
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Theme.accentGradient))
            }
            .buttonStyle(.plain)
            .disabled(displayedTracks.isEmpty)
            .opacity(displayedTracks.isEmpty ? 0.4 : 1)
            .help("播放全部")
            .accessibilityLabel("播放全部")
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(TrackSortMode.allCases) { mode in
                Button {
                    onSortModeChange(mode)
                } label: {
                    HStack {
                        Text(mode.rawValue)
                        if sortMode == mode {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Theme.accentText)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(sortMode.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(height: 28)
    }

    // MARK: - 专辑网格（设计稿：方形封面 + 标题 + 艺人·年份，悬停上浮）

    private var albumsGrid: some View {
        Group {
            if store.albums.isEmpty && !store.isLoading {
                emptyHint(icon: "square.stack.3d.up.fill", text: "该媒体库没有专辑数据")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)],
                    alignment: .leading,
                    spacing: 28
                ) {
                    ForEach(store.albums) { album in
                        PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                    }
                }
            }
        }
    }

    // MARK: - 艺人网格

    private var artistsGrid: some View {
        Group {
            if store.artists.isEmpty && !store.isLoading {
                emptyHint(icon: "person.2.fill", text: "该媒体库没有艺术家数据（曲目可能未带艺术家标签）")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 24)],
                    alignment: .leading,
                    spacing: 28
                ) {
                    ForEach(store.artists) { artist in
                        ArtistCard(artist: artist, onTap: { onOpenArtist(artist) })
                    }
                }
            }
        }
    }

    // MARK: - 歌曲列表（与歌单页一致的 MusicRow 布局）

    private var tracksList: some View {
        Group {
            if displayedTracks.isEmpty && !store.isLoading {
                emptyHint(icon: "music.note.list", text: "该媒体库没有曲目数据")
            } else {
                LazyVStack(spacing: 4) {
                    ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                        MusicRow(
                            track: track,
                            isCurrent: music.currentTrack?.id == track.id,
                            isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                            onTap: {
                                MusicPlayerModel.shared.play(tracks: displayedTracks, startAt: index)
                            }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 播放列表网格

    private var playlistsGrid: some View {
        PlaylistGrid(onOpenPlaylist: onOpenPlaylist)
    }

    private func emptyHint(icon: String, text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiaryText)
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }
}

/// 艺人卡片：圆形头像 + 居中名称，悬停轻微上浮
struct ArtistCard: View {
    let artist: BaseItemDto
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                RemoteImage(url: APIClient.shared.primaryImageURL(for: artist, width: 300), contentMode: .fill)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.border))
                    .shadow(color: Theme.cardShadow, radius: hovered ? 8 : 0, y: hovered ? 4 : 0)
                Text(artist.name ?? "未知艺术家")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: hovered ? -2 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
    }
}
