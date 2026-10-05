import SwiftUI

/// 首页（新增，§4.2）：继续播放 / 快速入口 / 最近添加 / 最常播放。
/// 目标是「冷启动 → 开始播放 ≤ 2 次点击」。
struct HomeView: View {
    let sizeClass: LayoutSizeClass
    let onOpenAlbum: (BaseItemDto) -> Void
    let onOpenArtist: (BaseItemDto) -> Void
    let onOpenPlaylist: (Playlist) -> Void
    let onOpenFavorites: () -> Void
    let onOpenRecentlyPlayed: () -> Void
    let onOpenMostPlayed: () -> Void
    let onOpenNowPlaying: () -> Void
    @Binding var searchQuery: String
    let searchFocusRequest: Int
    let onSearchSubmit: () -> Void

    @EnvironmentObject private var appState: AppState
    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var music = MusicPlayerModel.shared

    @State private var appeared = false
    @State private var recentSort: RecentSort = .dateAdded

    private enum RecentSort: String, CaseIterable {
        case dateAdded = "按添加时间"
        case name = "按名称"
        case artist = "按艺人"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                PageContent(sizeClass: sizeClass) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        if !continueItems.isEmpty { continueSection }
                        quickSection
                        recentlyAddedSection
                        mostPlayedSection
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
            // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
            .pageBodyWidthClamp()
        }
        .onAppear {
            withAnimation(Theme.Motion.base) { appeared = true }
        }
    }

    // MARK: - 顶栏（问候语 + 用户名 / 搜索 + 账号头像）

    private var topBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: 0) {
                Text(greeting)
                    .textStyle(.footnote, color: Theme.textSecondary)
                Text(appState.user?.name ?? "")
                    .textStyle(.title3, color: Theme.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.md)

            SearchField(
                text: $searchQuery,
                width: sizeClass.topBarSearchWidth,
                focusRequest: searchFocusRequest,
                showsShortcutBadge: sizeClass.topBarShowsSearch,
                onSubmit: onSearchSubmit
            )

            avatarMenu
        }
        .padding(.horizontal, sizeClass.isNarrow ? Theme.Spacing.xl : Theme.Spacing.xxl)
        .frame(height: Theme.Size.topBarHeight)
        // 顶栏属于 chrome 层：悬浮玻璃面板（§7.2 规则 2）
        .background(WindowDragArea())
        .glassPanel(.regular, cornerRadius: Theme.Size.panelRadius, elevation: .e2)
        .padding(.top, Theme.Size.panelMargin)
        .padding(.horizontal, Theme.Size.panelGap)
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }

    private var avatarMenu: some View {
        TokenMenu(accessibilityLabel: "账号菜单", help: "账号") {
            Button {
                onOpenFavorites()
            } label: {
                Label("收藏", systemImage: "heart")
            }
            Button {
                onOpenRecentlyPlayed()
            } label: {
                Label("最近播放", systemImage: "clock.arrow.circlepath")
            }
            Button {
                onOpenMostPlayed()
            } label: {
                Label("最常播放", systemImage: "flame")
            }
        } label: {
            Circle()
                .fill(Theme.brandGradient)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String((appState.user?.name ?? "?").prefix(1)).uppercased())
                        .textStyle(.bodySM, weight: .bold, color: .white)
                )
        }
    }

    // MARK: - 继续播放（卡 220×132：封面 88 + 标题 + 进度条 3pt）

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "继续播放") {
                Button {
                    onOpenRecentlyPlayed()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("全部")
                            .textStyle(.bodySM, weight: .medium, color: Theme.brandText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.brandText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看全部继续播放")
            }

            ScrollView(.horizontal) {
                HStack(spacing: Theme.Spacing.xl) {
                    ForEach(Array(continueItems.enumerated()), id: \.element.id) { index, item in
                        ContinueCard(item: item) {
                            playContinue(item)
                        }
                        .staggerAppear(index: index, visible: appeared)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func playContinue(_ item: MusicDataStore.ContinueEntry) {
        let albumTracks = store.tracks
            .filter { ($0.albumId ?? $0.id) == item.albumKey }
            .sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) }
        let list = albumTracks.isEmpty ? [item.track] : albumTracks
        let start = list.firstIndex(where: { $0.id == item.track.id }) ?? 0
        MusicPlayerModel.shared.play(tracks: list, startAt: start)
        onOpenNowPlaying()
    }

    // MARK: - 快速入口（4 个胶囊；窄窗横向滚动不换行）

    @ViewBuilder
    private var quickSection: some View {
        if sizeClass.isNarrow {
            ScrollView(.horizontal) {
                quickPills.padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
        } else {
            quickPills
        }
    }

    private var quickPills: some View {
        HStack(spacing: Theme.Spacing.lg) {
            QuickPill(title: "收藏", systemImage: "heart", iconColor: Theme.favorite, action: onOpenFavorites)
            QuickPill(title: "最近播放", systemImage: "clock", action: onOpenRecentlyPlayed)
            QuickPill(title: "最常播放", systemImage: "flame", iconColor: Theme.warning, action: onOpenMostPlayed)
            QuickPill(title: "随机播放全部", systemImage: "shuffle", iconColor: Theme.brandText) {
                guard !store.tracks.isEmpty else { return }
                MusicPlayerModel.shared.play(tracks: store.tracks.shuffled(), startAt: 0)
                onOpenNowPlaying()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 最近添加（专辑网格）

    private var recentlyAddedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "最近添加") {
                SortMenu(
                    current: recentSort.rawValue,
                    options: RecentSort.allCases.map(\.rawValue),
                    onSelect: { recentSort = RecentSort(rawValue: $0) ?? .dateAdded }
                )
            }

            if store.isLoading && store.albums.isEmpty {
                SkeletonGrid(
                    count: 8,
                    minWidth: sizeClass.gridMin,
                    spacing: sizeClass.gridSpacing
                )
            } else if recentAlbums.isEmpty {
                EmptyState(
                    systemImage: "square.stack.3d.up",
                    title: "该媒体库还没有专辑",
                    message: "检查服务器上的音乐库配置，或刷新媒体库重新拉取"
                ) {
                    Button {
                        Task { await store.reload() }
                    } label: {
                        Label("刷新媒体库", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                }
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                       spacing: sizeClass.gridSpacing.h)],
                    alignment: .leading,
                    spacing: sizeClass.gridSpacing.v
                ) {
                    ForEach(Array(recentAlbums.prefix(12).enumerated()), id: \.element.id) { index, album in
                        PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                            .staggerAppear(index: index, visible: appeared)
                    }
                }
            }
        }
    }

    private var recentAlbums: [BaseItemDto] {
        // 三种排序都由 MusicDataStore 预排好：这里 O(1) 取用，
        // 不再每次渲染都对整个专辑库排序（首页 body 会因搜索输入/窗口尺寸/播放状态高频重跑）
        switch recentSort {
        case .dateAdded: return store.albumsByDateAdded
        case .name: return store.albumsByName
        case .artist: return store.albumsByArtist
        }
    }

    // MARK: - 最常播放（Top 10：序号 48 / 封面 40 / 标题 flex / 次数 80 / 时长 64）

    private var mostPlayedSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "最常播放") {
                Button {
                    onOpenMostPlayed()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("全部")
                            .textStyle(.bodySM, weight: .medium, color: Theme.brandText)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.brandText)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看全部最常播放")
            }

            if topTracks.isEmpty {
                EmptyState(
                    systemImage: "flame",
                    title: "还没有播放数据",
                    message: "多听几次，这里会出现你最常播放的曲目"
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(topTracks.enumerated()), id: \.element.id) { index, track in
                        TopTrackRow(
                            track: track,
                            index: index,
                            sizeClass: sizeClass,
                            isCurrent: music.currentTrack?.id == track.id,
                            isPlaying: music.isPlaying && music.currentTrack?.id == track.id
                        ) {
                            MusicPlayerModel.shared.play(tracks: topTracks, startAt: index)
                        }
                        if index < topTracks.count - 1 {
                            Rectangle()
                                .fill(Theme.borderSubtle)
                                .frame(height: 1)
                                .padding(.leading, 16)
                        }
                    }
                }
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

    private var topTracks: [BaseItemDto] {
        Array(store.mostPlayedTracks.prefix(10))
    }

    // MARK: - 继续播放数据

    /// 由 `MusicDataStore` 在曲目变化时算好（按专辑去重 + 倒序），这里只读缓存。
    /// 原来每次渲染都要对全库过滤 + 排序，而本视图的 body 会被搜索输入、
    /// 播放状态、窗口尺寸变化反复触发。
    private var continueItems: [MusicDataStore.ContinueEntry] {
        store.continueEntries
    }
}

// MARK: - 继续播放卡片（220×132）

private struct ContinueCard: View {
    let item: MusicDataStore.ContinueEntry
    let onPlay: () -> Void

    @State private var hovered = false
    @Environment(\.appReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(url: item.track.artworkURL(width: 200), contentMode: .fill)
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .elevation(.e1, cornerRadius: Theme.Radius.md)
                    .overlay {
                        if hovered || focused {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.coverScrim)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.subtitle)
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)

                    // 进度条 3pt + 百分比（§2.1：进度是这张卡的第三层信息）
                    HStack(spacing: Theme.Spacing.sm) {
                        Capsule()
                            .fill(Theme.borderSubtle)
                            .frame(height: 3)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule()
                                        .fill(Theme.brand500)
                                        .frame(width: max(3, geo.size.width * item.progress))
                                }
                            }
                        Text("\(Int((item.progress * 100).rounded()))%")
                            .textStyle(.monoSM, color: Theme.textTertiary)
                            .fixedSize()
                    }
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Theme.Spacing.lg)
            .frame(width: 220, height: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .strokeBorder(Theme.borderSubtle)
            )
            .elevation(hovered ? .e2 : .e1)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.lg)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        .animation(Theme.Motion.spring, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("继续播放 \(item.title)，\(item.subtitle)，\(item.timeText)")
    }
}

// MARK: - 最常播放行（高 56）

private struct TopTrackRow: View {
    let track: BaseItemDto
    let index: Int
    let sizeClass: LayoutSizeClass
    let isCurrent: Bool
    let isPlaying: Bool
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Theme.Spacing.lg) {
                ZStack {
                    if isCurrent {
                        EqualizerBars(active: isPlaying, color: Theme.brandText, barWidth: 2.5, height: 12)
                    } else {
                        Text("\(index + 1)")
                            .textStyle(.mono, color: Theme.textTertiary)
                    }
                }
                .frame(width: 28, alignment: .leading)

                RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name ?? "")
                        .textStyle(.bodySM, weight: isCurrent ? .semibold : .medium,
                                   color: isCurrent ? Theme.brandText : Theme.textPrimary)
                        .lineLimit(1)
                    Text(track.albumArtist ?? track.album ?? "")
                        .textStyle(.footnote, color: Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if sizeClass >= .w2 {
                    Text("\(track.userData?.playCount ?? 0) 次")
                        .textStyle(.footnote, color: Theme.textTertiary)
                        .frame(width: 80, alignment: .trailing)
                }

                Text(formatPlaybackTime(track.runtimeSeconds))
                    .textStyle(.mono, color: Theme.textSecondary)
                    .frame(width: 64, alignment: .trailing)
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(height: 56)
            .background(
                hovered ? Theme.surfaceHover : (isCurrent ? Theme.surfaceSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(index + 1) 名，\(track.name ?? "")，\(track.albumArtist ?? "")，播放 \(track.userData?.playCount ?? 0) 次")
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
    }
}
