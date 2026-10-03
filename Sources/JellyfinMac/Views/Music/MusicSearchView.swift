import SwiftUI

/// 搜索页（§2.2 列表页骨架）：顶栏常驻搜索框 + 搜索历史胶囊行 + 按类型分组的结果。
///
/// - 历史：`QuickPill` + `textTertiary` 的「历史：」标签，本地持久化（最多 8 条）。
/// - 结果：歌曲 `MusicRow`，专辑 `PosterCard` / 艺人 `ArtistCard` 网格（列宽 `sizeClass.gridMin`）。
/// - 边界：加载 `SkeletonList` + `SkeletonGrid`；无结果 `EmptyState`（含「清除筛选」）。
struct MusicSearchView: View {
    let sizeClass: LayoutSizeClass
    /// 与顶栏搜索框共用同一份查询
    @Binding var query: String
    /// ⌘F 一次性聚焦请求（消费后由顶栏搜索框自行处理）
    let focusRequest: Int
    let onOpenAlbum: (BaseItemDto) -> Void
    let onOpenArtist: (BaseItemDto) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @StateObject private var vm = MusicSearchViewModel()
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var filter = "all"
    @State private var appeared = false

    /// 搜索历史（`\u{1F}` 分隔的扁平串，避免为一个字符串数组引入额外持久化层）
    @AppStorage("searchHistory") private var historyRaw = ""

    private static let historySeparator = "\u{1F}"
    private static let historyLimit = 8

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasQuery: Bool { !trimmedQuery.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            PageTopBar(
                sizeClass: sizeClass,
                title: "搜索",
                searchText: $query,
                searchFocusRequest: focusRequest
            ) {
                SegmentedControl(
                    segments: [
                        .init("all", "全部"),
                        .init("tracks", "歌曲"),
                        .init("albums", "专辑"),
                        .init("artists", "艺人"),
                        .init("playlists", "播放列表")
                    ],
                    selection: $filter
                )
            }

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
        .task(id: trimmedQuery) {
            vm.search(trimmedQuery)
            // 停顿 1.2s 未继续输入才记为一次「搜索历史」，避免记录每个中间态
            guard hasQuery else { return }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            recordHistory(trimmedQuery)
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.section) {
            if !history.isEmpty { historyRow }
            results
        }
        .onAppear { appeared = true }
    }

    @ViewBuilder
    private var results: some View {
        if !hasQuery {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "搜索你的音乐库",
                message: "输入曲目、专辑或艺人名称；⌘F 可随时聚焦搜索框"
            )
        } else if vm.isSearching && !hasVisibleResults {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                SkeletonList(count: 6)
                SkeletonGrid(count: 4, minWidth: sizeClass.gridMin, spacing: sizeClass.gridSpacing)
            }
        } else if !hasVisibleResults {
            EmptyState(
                systemImage: "magnifyingglass",
                title: "未找到「\(trimmedQuery)」",
                message: "检查拼写，或清除筛选条件"
            ) {
                if filter != "all" {
                    Button("清除筛选") { filter = "all" }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                }
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                if shows(.tracks), !vm.tracks.isEmpty { trackSection }
                if shows(.albums), !vm.albums.isEmpty { albumSection }
                if shows(.artists), !vm.artists.isEmpty { artistSection }
                if shows(.playlists), !matchedPlaylists.isEmpty { playlistSection }
            }
        }
    }

    /// 当前筛选下是否有可展示的结果（分组为空即视为无结果）
    private var hasVisibleResults: Bool {
        (shows(.tracks) && !vm.tracks.isEmpty)
            || (shows(.albums) && !vm.albums.isEmpty)
            || (shows(.artists) && !vm.artists.isEmpty)
            || (shows(.playlists) && !matchedPlaylists.isEmpty)
    }

    private enum Kind { case tracks, albums, artists, playlists }

    private func shows(_ kind: Kind) -> Bool {
        switch (filter, kind) {
        case ("all", _): return true
        case ("tracks", .tracks): return true
        case ("albums", .albums): return true
        case ("artists", .artists): return true
        case ("playlists", .playlists): return true
        default: return false
        }
    }

    /// 本地播放列表按名称匹配（服务端搜索不含播放列表）
    private var matchedPlaylists: [Playlist] {
        let term = trimmedQuery.lowercased()
        guard !term.isEmpty else { return [] }
        return playlistStore.allPlaylists.filter { $0.name.lowercased().contains(term) }
    }

    // MARK: - 搜索历史

    private var history: [String] {
        guard !historyRaw.isEmpty else { return [] }
        return historyRaw
            .components(separatedBy: Self.historySeparator)
            .filter { !$0.isEmpty }
    }

    private func recordHistory(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var items = history.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        items.insert(trimmed, at: 0)
        historyRaw = items.prefix(Self.historyLimit).joined(separator: Self.historySeparator)
    }

    private var historyRow: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("历史：")
                .textStyle(.bodySM, color: Theme.textTertiary)
                .fixedSize()

            ScrollView(.horizontal) {
                // 间距 12 > 命中区外扩的 6+6，避免相邻胶囊热区互相覆盖（§5.3 规则 2）
                HStack(spacing: Theme.Spacing.lg) {
                    ForEach(history, id: \.self) { term in
                        QuickPill(
                            title: term,
                            systemImage: "clock.arrow.circlepath",
                            iconColor: Theme.textTertiary
                        ) {
                            query = term
                        }
                    }
                }
                // 给 44pt 命中区留出边界，避免被滚动容器裁掉
                .padding(.vertical, Theme.Spacing.sm)
            }
            .scrollIndicators(.hidden)

            PlainIconButton(systemName: "xmark", label: "清空搜索历史") {
                historyRaw = ""
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - 分组

    /// 分组标题右侧的「· N」计数（12 / textTertiary）
    private func countLabel(_ count: Int) -> some View {
        Text("· \(count)")
            .textStyle(.footnote, color: Theme.textTertiary)
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "歌曲") {
                countLabel(vm.tracks.count)
            }
            let metrics = TrackRowMetrics(sizeClass: sizeClass)
            LazyVStack(spacing: 0) {
                ForEach(Array(vm.tracks.enumerated()), id: \.element.id) { index, track in
                    MusicRow(
                        track: track,
                        index: index,
                        metrics: metrics,
                        isCurrent: MusicPlayerModel.shared.currentTrack?.id == track.id,
                        isPlaying: MusicPlayerModel.shared.isPlaying
                            && MusicPlayerModel.shared.currentTrack?.id == track.id,
                        onTap: { MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: index) }
                    )
                    .staggerAppear(index: index, visible: appeared)
                }
            }
            .libraryTableChrome()
        }
    }

    private var albumSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "专辑") {
                countLabel(vm.albums.count)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(vm.albums) { album in
                    PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                }
            }
        }
    }

    private var artistSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "艺人") {
                countLabel(vm.artists.count)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(vm.artists) { artist in
                    ArtistCard(artist: artist, width: 300, onTap: { onOpenArtist(artist) })
                }
            }
        }
    }

    private var playlistSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "播放列表") {
                countLabel(matchedPlaylists.count)
            }
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(matchedPlaylists) { playlist in
                    PlaylistCard(playlist: playlist, width: 320) { onOpenPlaylist(playlist) }
                }
            }
        }
    }
}
