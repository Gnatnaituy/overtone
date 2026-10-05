import SwiftUI

/// 播放列表页（§2.2 列表页骨架 / §4.5 组件）：顶栏 + 「我创建的」「智能列表」两个区块的行式列表。
///
/// 行规格（预览 `.plrow`）：卡 `surface` + `Radius.lg` + `elevation(.e1, cornerRadius:)`，
/// 行高 72、hover `surfaceHover`、封面 52 圆角 10、名称 14/600、副标 12 `textSecondary`、
/// 右侧总时长 `monoSM`；智能列表行额外带 `brandTint` + `brandText` 的「智能」badge。
struct PlaylistsView: View {
    let sizeClass: LayoutSizeClass
    let onOpenPlaylist: (Playlist) -> Void
    @Binding var searchQuery: String
    let searchFocusRequest: Int
    let onSearchSubmit: () -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var store = MusicDataStore.shared
    /// 行式列表是播放列表页的默认形态（网格仍可切换）
    @State private var viewMode: LibraryViewMode = .list
    @State private var appeared = false
    @State private var showCreatePlaylist = false
    @State private var showCreateSmart = false
    @State private var newPlaylistName = ""
    @State private var newSmartName = ""
    @State private var newSmartKeyword = ""

    var body: some View {
        // 一次取用（拼接数组，每次访问都新建）：顶栏副标题要用到数量
        let all = playlistStore.allPlaylists
        return VStack(spacing: 0) {
            PageTopBar(
                sizeClass: sizeClass,
                title: "播放列表",
                subtitle: all.isEmpty ? nil : "\(all.count) 个",
                searchText: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: onSearchSubmit
            ) {
                ViewModeToggle(mode: $viewMode)
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
        .task { await store.loadIfNeeded() }
        .onAppear { appeared = true }
        .alert("新建播放列表", isPresented: $showCreatePlaylist) {
            TextField("播放列表名称", text: $newPlaylistName)
            Button("创建") {
                let created = playlistStore.create(name: newPlaylistName)
                newPlaylistName = ""
                ToastCenter.shared.show("已创建「\(created.name)」", systemImage: "music.note.list")
                onOpenPlaylist(created)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("新建智能播放列表", isPresented: $showCreateSmart) {
            TextField("播放列表名称", text: $newSmartName)
            TextField("艺术家关键字（如：坂本龍一）", text: $newSmartKeyword)
            Button("创建") {
                let created = playlistStore.createSmart(name: newSmartName, artistKeyword: newSmartKeyword)
                newSmartName = ""
                newSmartKeyword = ""
                ToastCenter.shared.show("已创建智能列表「\(created.name)」", systemImage: "sparkles")
                onOpenPlaylist(created)
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if playlistStore.allPlaylists.isEmpty {
            EmptyState(
                systemImage: "music.note.list",
                title: "还没有播放列表",
                message: "手动创建一个，或让「智能列表」按艺人关键字自动收集曲目"
            ) {
                Button {
                    startCreatePlaylist()
                } label: {
                    Label("新建播放列表", systemImage: "plus")
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                section(
                    title: "我创建的",
                    playlists: playlistStore.playlists,
                    emptyHint: "还没有手动创建的播放列表"
                ) {
                    Button {
                        startCreatePlaylist()
                    } label: {
                        Label("新建播放列表", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("新建播放列表")
                }

                section(
                    title: "智能列表",
                    playlists: playlistStore.smartPlaylists,
                    emptyHint: "还没有智能列表，按艺人关键字自动收集曲目"
                ) {
                    Button {
                        startCreateSmart()
                    } label: {
                        Label("新建智能列表", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("新建智能列表")
                }
            }
        }
    }

    /// 区块骨架：`SectionHeader`（右侧放新建按钮）+ 行式列表 / 网格 / 区块内空态
    @ViewBuilder
    private func section<Action: View>(
        title: String,
        playlists: [Playlist],
        emptyHint: String,
        @ViewBuilder action: @escaping () -> Action
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: title) { action() }

            if playlists.isEmpty {
                Text(emptyHint)
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Spacing.xl)
                    .padding(.vertical, Theme.Spacing.xl)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(Theme.surface)
                    )
                    .elevation(.e1, cornerRadius: Theme.Radius.lg)
            } else if viewMode == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                       spacing: sizeClass.gridSpacing.h)],
                    alignment: .leading,
                    spacing: sizeClass.gridSpacing.v
                ) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                        PlaylistCard(playlist: playlist, width: 320) { onOpenPlaylist(playlist) }
                            .staggerAppear(index: index, visible: appeared)
                    }
                }
            } else {
                // LazyVStack：列表模式下每行都会跑 `.task { recompute() }`（智能列表要全库匹配），
                // 用非惰性 VStack 会让所有行在首帧同时开工
                LazyVStack(spacing: 0) {
                    ForEach(Array(playlists.enumerated()), id: \.element.id) { index, playlist in
                        PlaylistRow(playlist: playlist) { onOpenPlaylist(playlist) }
                        if index < playlists.count - 1 {
                            Rectangle()
                                .fill(Theme.borderSubtle)
                                .frame(height: 1)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.surface)
                )
                .elevation(.e1, cornerRadius: Theme.Radius.lg)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            }
        }
    }

    // MARK: - 动作

    private func startCreatePlaylist() {
        newPlaylistName = ""
        showCreatePlaylist = true
    }

    private func startCreateSmart() {
        newSmartName = ""
        newSmartKeyword = ""
        showCreateSmart = true
    }
}

// MARK: - 播放列表行（高 72，封面 52 圆角 10，智能 badge，右侧总时长）

private struct PlaylistRow: View {
    let playlist: Playlist
    let onTap: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @State private var stats: Stats?
    @State private var hovered = false
    @FocusState private var focused: Bool

    /// 曲目统计缓存：曲目数据变化时重算，避免每次渲染都全量匹配
    private struct Stats {
        var count: Int
        var duration: Double
        var coverTracks: [BaseItemDto]
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.lg) {
                PlaylistCoverMosaic(
                    tracks: stats?.coverTracks ?? [],
                    size: 52,
                    cornerRadius: Theme.Radius.md,
                    fallbackIcon: playlist.isSmart ? "sparkles" : "music.note.list"
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(playlist.name)
                            .textStyle(.body, weight: .semibold, color: Theme.textPrimary)
                            .lineLimit(1)
                        if playlist.isSmart { smartBadge }
                    }
                    Text(subtitle)
                        .textStyle(.footnote, color: Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(durationText)
                    .textStyle(.monoSM, color: Theme.textSecondary)
                    .fixedSize()
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(height: 72)
            .background(hovered ? Theme.surfaceHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .help(playlist.name)
        .accessibilityLabel(accessibilityLabel)
        .task { recompute() }
        // O(1) 变更检测：`onChange(of: store.tracks)` 每次 body 更新都要比较整个曲库
        .onChange(of: store.dataRevision) { _ in recompute() }
    }

    /// 「智能」badge：`brandTint` 底 + `brandText` 字 + 11pt（§2.2 / 预览 `.badge`）
    private var smartBadge: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "sparkles")
                .textStyle(.caption, color: Theme.brandText)
            Text("智能")
                .textStyle(.caption, weight: .semibold, color: Theme.brandText)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .frame(height: 20)
        .background(Capsule().fill(Theme.brandTint))
        .accessibilityHidden(true)
    }

    private var durationText: String {
        guard let stats, stats.duration > 0 else { return "—" }
        return formatPlaybackTime(stats.duration)
    }

    private var subtitle: String {
        var parts = [playlist.isSmart ? "\(stats?.count ?? 0) 首" : "\(playlist.trackIds.count) 首"]
        if playlist.isSmart {
            if let keyword = playlist.smartRule?.artistKeyword, !keyword.isEmpty {
                parts.append("按「\(keyword)」自动匹配")
            } else {
                parts.append("自动更新")
            }
        } else {
            parts.append(playlist.serverId == nil ? "仅本地" : "已同步到服务器")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = [playlist.name]
        if playlist.isSmart { parts.append("智能播放列表") }
        parts.append(subtitle)
        if let stats, stats.duration > 0 {
            parts.append("总时长 \(formatPlaybackTime(stats.duration))")
        }
        return parts.joined(separator: "，")
    }

    private func recompute() {
        let tracks: [BaseItemDto]
        if playlist.isSmart {
            tracks = store.smartTracks(keyword: playlist.smartRule?.artistKeyword ?? "")
        } else {
            tracks = playlist.trackIds.compactMap { store.track(id: $0) }
        }
        stats = Stats(
            count: tracks.count,
            duration: tracks.reduce(0) { $0 + $1.runtimeSeconds },
            coverTracks: Array(tracks.prefix(4))
        )
    }
}

/// 播放列表网格 / 列表（资料库「播放列表」分段与本页共用）
struct PlaylistGrid: View {
    let sizeClass: LayoutSizeClass
    let onOpenPlaylist: (Playlist) -> Void
    var viewMode: LibraryViewMode = .grid

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var appeared = false

    private var metrics: TrackRowMetrics { TrackRowMetrics(sizeClass: sizeClass) }

    var body: some View {
        // 一次取用：`allPlaylists` 是 `playlists + smartPlaylists` 的拼接（每次访问都新建数组），
        // 原实现在 body 里读了 7 次，其中一次还在 ForEach 内部逐行读 —— 整体 O(P²)
        let all = playlistStore.allPlaylists
        return Group {
            if all.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "还没有播放列表",
                    message: "用顶栏的「新建」创建一个，或让「智能」按艺人关键字自动收集"
                )
            } else if viewMode == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                       spacing: sizeClass.gridSpacing.h)],
                    alignment: .leading,
                    spacing: sizeClass.gridSpacing.v
                ) {
                    ForEach(all.indices, id: \.self) { index in
                        PlaylistCard(playlist: all[index], width: 320) { onOpenPlaylist(all[index]) }
                            .staggerAppear(index: index, visible: appeared)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(all.indices, id: \.self) { index in
                        let playlist = all[index]
                        LibraryListRow(
                            title: playlist.name,
                            subtitle: playlist.isSmart ? "智能播放列表" : "\(playlist.trackIds.count) 首曲目",
                            artworkURL: nil,
                            isCurrent: false,
                            isPlaying: false,
                            metrics: metrics,
                            onTap: { onOpenPlaylist(playlist) }
                        )
                        if index < all.count - 1 {
                            RowDivider()
                        }
                    }
                }
                .libraryTableChrome()
            }
        }
        .onAppear { appeared = true }
    }
}
