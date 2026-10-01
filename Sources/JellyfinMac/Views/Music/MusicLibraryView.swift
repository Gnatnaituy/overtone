import SwiftUI

/// 资料库页（重做，§4.3）：顶栏 + 分段行 + 网格/列表视图切换 + 骨架屏 + 空态。
struct MusicLibraryView: View {
    let sizeClass: LayoutSizeClass
    @Binding var segment: LibrarySegment
    @Binding var viewMode: LibraryViewMode
    let sortMode: TrackSortMode
    let onSortModeChange: (TrackSortMode) -> Void
    let onOpenArtist: (BaseItemDto) -> Void
    let onOpenAlbum: (BaseItemDto) -> Void
    let onOpenPlaylist: (Playlist) -> Void
    @Binding var searchQuery: String
    let searchFocusRequest: Int
    let onSearchSubmit: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var music = MusicPlayerModel.shared
    /// 排序结果缓存：滚动时不重复排序 1000+ 曲目
    @State private var displayedTracks: [BaseItemDto] = []
    @State private var appeared = false

    private var metrics: TrackRowMetrics { TrackRowMetrics(sizeClass: sizeClass) }

    private var segmentSelection: Binding<String> {
        Binding(
            get: { segment.rawValue },
            set: { segment = LibrarySegment(rawValue: $0) ?? .albums }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            segmentBar
            ScrollView {
                PageContent(sizeClass: sizeClass) {
                    content
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
        }
        .background(Theme.canvas.ignoresSafeArea())
        .onAppear { appeared = true }
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

    // MARK: - 顶栏（标题 + 视图切换 + 排序）

    private var topBar: some View {
        PageTopBar(
            sizeClass: sizeClass,
            title: "资料库",
            searchText: $searchQuery,
            searchFocusRequest: searchFocusRequest,
            onSearchSubmit: onSearchSubmit
        ) {
            HStack(spacing: Theme.Spacing.md) {
                if segment == .tracks {
                    SortMenu(
                        current: sortMode.rawValue,
                        options: TrackSortMode.allCases.map(\.rawValue),
                        onSelect: { onSortModeChange(TrackSortMode(rawValue: $0) ?? .name) }
                    )
                }
                if segment == .albums || segment == .artists || segment == .playlists {
                    ViewModeToggle(mode: $viewMode)
                }
            }
        }
    }

    // MARK: - 第二行 56：分段 + 随机 / 播放全部

    private var segmentBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            SegmentedControl(
                segments: LibrarySegment.allCases.map { .init($0.rawValue, $0.title) },
                selection: segmentSelection
            )

            Spacer(minLength: Theme.Spacing.md)

            if segment == .tracks && !displayedTracks.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    IconButton(
                        systemName: "shuffle",
                        label: "随机播放",
                        size: Theme.Size.iconButtonSm,
                        action: { MusicPlayerModel.shared.play(tracks: displayedTracks.shuffled(), startAt: 0) }
                    )
                    playAllButton
                }
            }
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: 56)
        .background(Theme.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
        }
    }

    private var playAllButton: some View {
        Button {
            MusicPlayerModel.shared.play(tracks: displayedTracks, startAt: 0)
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                .background(Circle().fill(Theme.brandGradient))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("播放全部")
        .accessibilityLabel("播放全部")
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch segment {
        case .albums: albumsSection
        case .artists: artistsSection
        case .tracks: tracksSection
        case .playlists: playlistsSection
        }
    }

    private var isLoading: Bool {
        store.isLoading && store.tracks.isEmpty && store.albums.isEmpty && store.artists.isEmpty
    }

    // MARK: 专辑

    @ViewBuilder
    private var albumsSection: some View {
        if isLoading {
            SkeletonGrid(count: 8, minWidth: sizeClass.gridMin, spacing: sizeClass.gridSpacing)
        } else if store.albums.isEmpty {
            refreshEmptyState(title: "该媒体库还没有专辑", message: "检查服务器上的音乐库配置")
        } else if viewMode == .grid {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(Array(store.albums.enumerated()), id: \.element.id) { index, album in
                    PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                        .staggerAppear(index: index, visible: appeared)
                }
            }
        } else {
            albumList
        }
    }

    private var albumList: some View {
        VStack(spacing: 0) {
            ForEach(Array(store.albums.enumerated()), id: \.element.id) { index, album in
                LibraryListRow(
                    title: album.name ?? "",
                    subtitle: [album.albumArtist, album.productionYear.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "),
                    artworkURL: album.artworkURL(width: 96),
                    isCurrent: false,
                    isPlaying: false,
                    metrics: metrics,
                    onTap: { onOpenAlbum(album) }
                )
                if index < store.albums.count - 1 {
                    RowDivider()
                }
            }
        }
        .libraryTableChrome()
    }

    // MARK: 艺人

    @ViewBuilder
    private var artistsSection: some View {
        if isLoading {
            SkeletonGrid(count: 8, minWidth: sizeClass.gridMin, spacing: sizeClass.gridSpacing)
        } else if store.artists.isEmpty {
            refreshEmptyState(title: "该媒体库没有艺术家数据", message: "曲目可能未带艺术家标签")
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(Array(store.artists.enumerated()), id: \.element.id) { index, artist in
                    ArtistCard(artist: artist, width: 300, onTap: { onOpenArtist(artist) })
                        .staggerAppear(index: index, visible: appeared)
                }
            }
        }
    }

    // MARK: 歌曲

    @ViewBuilder
    private var tracksSection: some View {
        if isLoading {
            SkeletonList(count: 12)
        } else if displayedTracks.isEmpty {
            refreshEmptyState(title: "该媒体库还没有曲目", message: "检查服务器上的音乐库配置")
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                    MusicRow(
                        track: track,
                        index: index,
                        metrics: metrics,
                        isCurrent: music.currentTrack?.id == track.id,
                        isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                        onTap: { MusicPlayerModel.shared.play(tracks: displayedTracks, startAt: index) }
                    )
                }
            }
        }
    }

    // MARK: 播放列表

    @ViewBuilder
    private var playlistsSection: some View {
        PlaylistGrid(sizeClass: sizeClass, onOpenPlaylist: onOpenPlaylist, viewMode: viewMode)
    }

    // MARK: - 空态

    private func refreshEmptyState(title: String, message: String) -> some View {
        EmptyState(systemImage: "music.note.list", title: title, message: message) {
            Button {
                Task { await store.reload() }
            } label: {
                Label("刷新媒体库", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
        }
    }
}

// MARK: - 列表模式行（专辑 / 播放列表等非曲目条目）

struct LibraryListRow: View {
    let title: String
    let subtitle: String
    let artworkURL: URL?
    var isCircular = false
    var isCurrent = false
    var isPlaying = false
    let metrics: TrackRowMetrics
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.lg) {
                if let artworkURL {
                    RemoteImage(url: artworkURL, contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(isCircular
                                   ? AnyShape(Circle())
                                   : AnyShape(RoundedRectangle(cornerRadius: Theme.Radius.sm)))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .textStyle(.bodySM, weight: isCurrent ? .semibold : .medium,
                                   color: isCurrent ? Theme.brand500 : Theme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(hovered ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityLabel("\(title)，\(subtitle)")
    }
}

/// 行间分隔线（左侧让出封面宽度）
struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.borderSubtle)
            .frame(height: 1)
            .padding(.leading, 60)
    }
}

extension View {
    /// 表格容器：白卡 + radius-lg + borderSubtle
    func libraryTableChrome() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.borderSubtle)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }
}
