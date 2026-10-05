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
            // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
            .pageBodyWidthClamp()
        }
        .onAppear { appeared = true }
        .task {
            // 启动页直接落在资料库时，等库 ID 解析完再拉取，避免页面空着
            await store.ensureLoaded()
            displayedTracks = store.sortedTracks(by: sortMode)
        }
        .task(id: sortMode) {
            displayedTracks = store.sortedTracks(by: sortMode)
        }
        .onChange(of: store.dataRevision) { _ in
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

    // MARK: - 第二行 56：分段 + 随机 / 播放全部（§2.2）

    private var segmentBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            SegmentedControl(
                segments: LibrarySegment.allCases.map { .init($0.rawValue, $0.title) },
                selection: segmentSelection
            )

            Spacer(minLength: Theme.Spacing.md)

            if !playAllSource.isEmpty {
                HStack(spacing: Theme.Spacing.md) {
                    IconButton(
                        systemName: "shuffle",
                        label: "随机播放",
                        size: Theme.Size.iconButtonMd,
                        action: { MusicPlayerModel.shared.play(tracks: playAllSource.shuffled(), startAt: 0) }
                    )
                    playAllButton
                }
            }
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: 56)
    }

    /// 「播放全部 / 随机」的作用范围：歌曲页用当前排序结果，其余分段用整库曲目
    private var playAllSource: [BaseItemDto] {
        switch segment {
        case .tracks: return displayedTracks
        case .playlists: return []
        default: return store.sortedTracks(by: sortMode)
        }
    }

    private var playAllButton: some View {
        Button {
            playAll()
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .semibold))
                Text("播放全部")
                    .textStyle(.bodySM, weight: .medium)
            }
        }
        .buttonStyle(PrimaryButtonStyle(compact: true))
        .hitExpand(from: Theme.Size.buttonHeightSm, to: 44)
        .help("播放全部")
        .accessibilityLabel("播放全部")
    }

    /// §2.2 超限：「播放全部」>1000 首截断为 1000 + Toast 说明
    private func playAll() {
        let all = playAllSource
        guard !all.isEmpty else { return }
        let limit = 1000
        let queue = all.count > limit ? Array(all.prefix(limit)) : all
        MusicPlayerModel.shared.play(tracks: queue, startAt: 0)
        if all.count > limit {
            ToastCenter.shared.show(
                "已播放前 \(limit) 首（共 \(all.count) 首）",
                systemImage: "exclamationmark.circle"
            )
        }
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
                ForEach(store.albums.indices, id: \.self) { index in
                    PosterCard(item: store.albums[index], width: 320, onTap: { onOpenAlbum(store.albums[index]) })
                        .staggerAppear(index: index, visible: appeared)
                }
            }
        } else {
            albumList
        }
    }

    private var albumList: some View {
        VStack(spacing: 0) {
            ForEach(store.albums.indices, id: \.self) { index in
                let album = store.albums[index]
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
                ForEach(store.artists.indices, id: \.self) { index in
                    ArtistCard(artist: store.artists[index], width: 300,
                               onTap: { onOpenArtist(store.artists[index]) })
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
                // indices + 下标：整库可能数千首，`Array(enumerated())` 每次渲染
                // 都要复制一份约 272 字节/条 的元组数组（实测 1 万条约 1ms），
                // 而本页会随搜索输入与播放状态反复重渲染
                ForEach(displayedTracks.indices, id: \.self) { index in
                    MusicRow(
                        track: displayedTracks[index],
                        index: index,
                        metrics: metrics,
                        isCurrent: music.currentTrack?.id == displayedTracks[index].id,
                        isPlaying: music.isPlaying && music.currentTrack?.id == displayedTracks[index].id,
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
                                   color: isCurrent ? Theme.brandText : Theme.textPrimary)
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
