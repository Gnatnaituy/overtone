import SwiftUI

/// 资料库页（重做，§4.3）：顶栏 + 分段行 + 网格/列表视图切换 + 骨架屏 + 空态。
struct MusicLibraryView: View {
    let sizeClass: LayoutSizeClass
    @Binding var segment: LibrarySegment
    @Binding var viewMode: LibraryViewMode
    let sortMode: MediaSort
    let onSortModeChange: (MediaSort) -> Void
    let onOpenArtist: (MediaItem) -> Void
    let onOpenAlbum: (MediaItem) -> Void
    let onOpenPlaylist: (Playlist) -> Void
    @Binding var searchQuery: String
    let searchFocusRequest: Int
    let onSearchSubmit: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var music = MusicPlayerModel.shared
    /// 排序结果缓存：滚动时不重复排序 1000+ 曲目
    @State private var displayedTracks: [MediaItem] = []
    /// 专辑 id → 曲目数（`MediaItem` 没有 ChildCount，用已加载曲库现算一次并缓存）
    @State private var albumTrackCounts: [String: Int] = [:]
    @State private var appeared = false
    /// 已挂载过的分段：切回不再重建。
    /// 曲库「歌曲」分段一次要把可见的十几行实装出来，实测 0.27s 主线程 CPU / 次。
    @State private var mountedSegments: Set<LibrarySegment> = []

    private var metrics: TrackRowMetrics { TrackRowMetrics(sizeClass: sizeClass) }

    private var segmentSelection: Binding<String> {
        Binding(
            get: { segment.rawValue },
            set: { segment = LibrarySegment(rawValue: $0) ?? .albums }
        )
    }

    /// 本次渲染要出现的分段：已挂载的 + 当前选中的（首次进入即挂载）
    private var renderedSegments: [LibrarySegment] {
        var segments = mountedSegments
        segments.insert(segment)
        return LibrarySegment.allCases.filter { segments.contains($0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            segmentBar
            loadStatusBanner
            // 每个分段一个常驻滚动体：切换只改可见性（已实现的行、滚动位置都保留）
            ZStack {
                ForEach(renderedSegments, id: \.self) { current in
                    let active = current == segment
                    segmentScroll(current)
                        .opacity(active ? 1 : 0)
                        // 同 MainView：只淡入进入的分段，离场瞬时切掉（交叉淡入两整段内容太贵）
                        .animation(active ? Theme.Motion.base : nil, value: active)
                        // 当前分段必须压在最上层，否则隐藏分段的滚动体会吃掉滚轮事件
                        .zIndex(active ? 1 : 0)
                        .disabled(!active)
                        .accessibilityHidden(!active)
                }
            }
            .animation(nil, value: segment)
        }
        .onAppear { appeared = true }
        .onChange(of: segment) { newValue in mountedSegments.insert(newValue) }
        .task {
            // 启动页直接落在资料库时，等库 ID 解析完再拉取，避免页面空着
            await store.ensureLoaded()
            refreshDerived()
        }
        .task(id: sortMode) {
            refreshDerived()
        }
        .onChange(of: store.dataRevision) { _ in
            refreshDerived()
        }
    }

    /// 重算两个派生缓存：排序结果（列表视图用）与专辑曲目数（列表模式右列用）
    private func refreshDerived() {
        displayedTracks = store.sortedTracks(by: sortMode)
        var counts: [String: Int] = [:]
        for track in store.tracks {
            guard let albumID = track.albumID else { continue }
            counts[albumID, default: 0] += 1
        }
        albumTrackCounts = counts
    }

    /// 单个分段的滚动体（原来只有一个滚动体，包着会随分段切换整体重建的内容）
    private func segmentScroll(_ current: LibrarySegment) -> some View {
        ScrollView {
            PageContent(sizeClass: sizeClass) {
                section(current)
            }
        }
        .scrollIndicators(.hidden)
        .background(ScrollBarHider())
        // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
        .pageBodyWidthClamp()
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
                        current: sortMode.displayName,
                        options: MediaSort.allCases.map(\.displayName),
                        onSelect: { picked in
                            // 菜单项按展示名匹配回枚举（`SortMenu` 只认字符串）
                            onSortModeChange(
                                MediaSort.allCases.first { $0.displayName == picked } ?? .name
                            )
                        }
                    )
                }
                if segment == .albums || segment == .artists || segment == .playlists {
                    ViewModeToggle(mode: $viewMode)
                }
            }
        }
    }

    // MARK: - 曲库加载状态（`MusicDataStore` 的两个只读状态）

    /// 拉取失败 / 被上限截断时的内联提示：
    /// - `loadError`：整库没取到（服务器未授权音乐目录、或网络错误）
    /// - `isTruncated`：曲库超出单次加载上限，只装了前 N 首
    @ViewBuilder
    private var loadStatusBanner: some View {
        if let error = store.loadError {
            InlineBanner(
                kind: .error,
                message: error,
                actionTitle: "重试",
                onAction: { Task { await store.reload() } }
            )
            .padding(.horizontal, sizeClass.pageMargin)
            .padding(.top, Theme.Spacing.lg)
        } else if store.isTruncated {
            InlineBanner(
                kind: .warning,
                message: "曲库超出单次加载上限，当前只加载了前 \(store.tracks.count) 首"
            )
            .padding(.horizontal, sizeClass.pageMargin)
            .padding(.top, Theme.Spacing.lg)
        } else if store.isPartialFailure {
            InlineBanner(
                kind: .warning,
                message: "部分内容加载失败，列表可能不完整",
                actionTitle: "重试",
                onAction: { Task { await store.reload() } }
            )
            .padding(.horizontal, sizeClass.pageMargin)
            .padding(.top, Theme.Spacing.lg)
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
    private var playAllSource: [MediaItem] {
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
    private func section(_ current: LibrarySegment) -> some View {
        switch current {
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
            if Theme.isPaper { albumTableHeader }
            ForEach(store.albums.indices, id: \.self) { index in
                let album = store.albums[index]
                LibraryListRow(
                    title: album.title,
                    subtitle: [album.artistName, album.year.map(String.init)]
                        .compactMap { $0 }.joined(separator: " · "),
                    artwork: album.artworkRef(width: 96),
                    isCurrent: false,
                    isPlaying: false,
                    metrics: metrics,
                    trailingText: albumTrackCounts[album.id].map { "\($0) 首" },
                    onTap: { onOpenAlbum(album) }
                )
                if index < store.albums.count - 1 {
                    RowDivider()
                }
            }
        }
        .libraryTableChrome()
    }

    /// 定宽表格表头（§6.3）：caption 级 + 强细线，列位与 `LibraryListRow` 对齐。
    /// 只在 paper 出现 —— glass 的列表行本来没有表头。
    private var albumTableHeader: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("标题")
                .padding(.leading, 40)
            Spacer(minLength: 0)
            Text("曲目")
                .frame(width: 64, alignment: .trailing)
        }
        .textStyle(.caption, color: Theme.Paper.ink2)
        .tracking(0.66)
        .padding(.horizontal, metrics.horizontalPadding)
        // 让开行尾的 chevron（约 21pt），表头才会压在数字列正上方
        .padding(.trailing, Theme.Spacing.xxl)
        .padding(.bottom, Theme.Spacing.sm)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Paper.hairlineStrong)
                .frame(height: 1)
        }
        .accessibilityHidden(true)
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
                        // §6.3 / §4.4：资料库列表是定宽对齐表格 —— 不用点线，
                        // 点线只给「可变长内容」的引导（曲目/队列/Top10）
                        rowStyle: .alignedTable,
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
    let artwork: ArtworkRef?
    var isCircular = false
    var isCurrent = false
    var isPlaying = false
    let metrics: TrackRowMetrics
    /// 定宽表格的右侧数值列（paper 的曲目数等）；nil = 不显示（glass 全部为 nil）
    var trailingText: String?
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.lg) {
                if let artwork {
                    RemoteImage(ref: artwork, contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .modifier(LibraryRowCover(isCircular: isCircular))
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .paperSerifTitle(.bodySM,
                                         weight: isCurrent ? .semibold : .medium,
                                         color: isCurrent ? currentColor : Theme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let trailingText {
                    Text(trailingText)
                        .textStyle(.mono, color: Theme.Paper.ink2)
                        .frame(width: 64, alignment: .trailing)
                        .fixedSize()
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .frame(height: metrics.rowHeight)
            .background(
                // paper 的表格行是「整行铺满的纸面高亮」——预览 `.ld-row:hover` 没有圆角，
                // 所以这里用 0 而不是发明一个新的圆角档；glass 仍是 Radius.sm 圆角条
                RoundedRectangle(cornerRadius: Theme.isPaper ? 0 : Theme.Radius.sm)
                    .fill(hovered ? Theme.surfaceHover : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityLabel(trailingText.map { "\(title)，\(subtitle)，\($0)" } ?? "\(title)，\(subtitle)")
    }

    /// 当前行文字：paper 用 signal-ink（红只给正在发声的行），glass 保持 brandText
    private var currentColor: Color {
        Theme.isPaper ? Theme.Paper.signalInk : Theme.brandText
    }
}

/// 列表行封面：glass = 圆角 6 / 圆形；paper = 圆形歌手的头像不变，专辑封面走套封框
private struct LibraryRowCover: ViewModifier {
    let isCircular: Bool

    func body(content: Content) -> some View {
        if isCircular {
            content.clipShape(Circle())
        } else if Theme.isPaper {
            content
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                .paperCoverFrame(true, cornerRadius: Theme.Radius.cover)
        } else {
            content.clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
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
    /// 表格容器：glass = 白卡 + radius-lg + borderSubtle；paper = 不套卡 ——
    /// 印刷品的表格靠表头强细线与行间 hairline 分层，卡片会把「纸面」再糊一层灰（§6.3 / §3 零投影）
    func libraryTableChrome() -> some View {
        modifier(LibraryTableChrome())
    }
}

private struct LibraryTableChrome: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
        } else {
            content
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
}
