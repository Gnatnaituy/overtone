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
                // paper：问候语降到 caption 小型大写（§6.2「问候语在顶栏」），用户名走衬线 title3
                Text(greeting)
                    .textStyle(Theme.isPaper ? .caption : .footnote, color: Theme.textSecondary)
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
            if Theme.isPaper {
                // paper 顶栏账号：纸底方块 + 强细线描边（预览 `.acct`），不用品牌渐变圆
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Paper.sheet)
                    .frame(width: 32, height: 32)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .strokeBorder(Theme.Paper.hairlineStrong)
                    )
                    .overlay(
                        Text(String((appState.user?.name ?? "?").prefix(1)).uppercased())
                            .textStyle(.bodySM, weight: .bold, color: Theme.Paper.ink)
                    )
            } else {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(String((appState.user?.name ?? "?").prefix(1)).uppercased())
                            .textStyle(.bodySM, weight: .bold, color: .white)
                    )
            }
        }
    }

    // MARK: - 继续播放（卡 220×132：封面 88 + 标题 + 进度条 3pt）

    /// 区块右侧「全部 →」：paper 下动作文字降到 ink-2（红只属于声音）；
    /// 显示文案与无障碍标签保持与改动前一致（无障碍标签按区块区分）
    private func viewAllButton(accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xs) {
                Text("全部")
                    .textStyle(.bodySM, weight: .medium,
                               color: Theme.isPaper ? Theme.Paper.ink2 : Theme.brandText)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.isPaper ? Theme.Paper.ink2 : Theme.brandText)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "继续播放") {
                viewAllButton(accessibility: "查看全部继续播放") { onOpenRecentlyPlayed() }
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
                viewAllButton(accessibility: "查看全部最常播放") { onOpenMostPlayed() }
            }

            if topTracks.isEmpty {
                EmptyState(
                    systemImage: "flame",
                    title: "还没有播放数据",
                    message: "多听几次，这里会出现你最常播放的曲目"
                )
            } else {
                topTracksList
            }
        }
    }

    /// Top 10 行组：paper 下点线行自带 hairline 底边，直接落在纸面上；
    /// glass 仍是「卡片 + 行间分隔线」的原有形态（取值与结构不变）
    private var topTracksList: some View {
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
                if !Theme.isPaper && index < topTracks.count - 1 {
                    Rectangle()
                        .fill(Theme.borderSubtle)
                        .frame(height: 1)
                        .padding(.leading, 16)
                }
            }
        }
        .modifier(TopTracksChrome())
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

    /// 封面尺寸：paper 用 72（预览 `.s72`），glass 保持 88
    private var coverSize: CGFloat { Theme.isPaper ? 72 : 88 }
    /// 卡片圆角：paper 控件圆角 3，glass 保持 Radius.lg
    private var cardRadius: CGFloat { Theme.isPaper ? Theme.Radius.sm : Theme.Radius.lg }

    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(url: item.track.artworkURL(width: 200), contentMode: .fill)
                    .frame(width: coverSize, height: coverSize)
                    .clipShape(RoundedRectangle(cornerRadius: coverRadius))
                    .pagesCoverChrome(radius: coverRadius)
                    .overlay {
                        if hovered || focused {
                            ZStack {
                                RoundedRectangle(cornerRadius: coverRadius)
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
                        // paper 卡片标题 15pt 衬线（预览 `.hero-meta b`）；glass 保持 13/600
                        .paperSerifTitle(Theme.isPaper ? .bodyLG : .bodySM, color: Theme.textPrimary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(item.subtitle)
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)

                    // 进度：paper 用 VU 段条（§4.5 全局唯一进度形态），glass 仍是 3pt 胶囊
                    HStack(spacing: Theme.Spacing.sm) {
                        if Theme.isPaper {
                            VUProgress(value: item.progress, height: 6)
                        } else {
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
                        }
                        // 数字永不跳动：百分比一律 mono + tabular-nums
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
                RoundedRectangle(cornerRadius: cardRadius)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    // paper 无投影，hover 只能靠细线加深表达「可点」（§3 零投影）
                    .strokeBorder(
                        Theme.isPaper
                            ? (hovered ? Theme.Paper.hairlineStrong : Theme.Paper.hairline)
                            : Theme.borderSubtle
                    )
            )
            .modifier(ContinueCardElevation(hovered: hovered))
            .contentShape(RoundedRectangle(cornerRadius: cardRadius))
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: cardRadius)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        .animation(Theme.Motion.spring, value: hovered)
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("继续播放 \(item.title)，\(item.subtitle)，\(item.timeText)")
    }

    /// 封面圆角：paper = `Radius.cover`（2），glass 保持 `Radius.md`
    private var coverRadius: CGFloat { Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md }
}

/// 续播卡投影：paper 零投影（§3），glass 保持 e1/e2 换挡
private struct ContinueCardElevation: ViewModifier {
    let hovered: Bool

    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
        } else {
            content.elevation(hovered ? .e2 : .e1)
        }
    }
}

/// Top 10 容器：glass = 卡片（surface + hairline + radius-lg）；paper = 不套卡 ——
/// 点线行自带 hairline 底边，印刷品没有卡片堆叠（§3 零投影）
private struct TopTracksChrome: ViewModifier {
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
            Group {
                if Theme.isPaper { paperLayout } else { glassLayout }
            }
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

    /// 点线行（§4.4）：序号 mono 12 · 封面 40 · 标题/艺人 · 点线引导 · 次数 mono · 时长 mono。
    /// 当前行 = 信号红序号 + ON AIR 灯牌 + 迷你 VU 段条替代时长（颜色不单独承载信息）。
    private var paperLayout: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Text("\(index + 1)")
                .textStyle(.mono, weight: isCurrent ? .bold : .regular,
                           color: isCurrent ? Theme.Paper.signal : Theme.Paper.ink3)
                .frame(width: Theme.Spacing.xxl, alignment: .trailing)
                .layoutPriority(2)

            RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                .paperCoverFrame(true, cornerRadius: Theme.Radius.cover)

            // 2026-10-14 用户裁决：不再画点线引导（「横线太多了」）——
            // 原本「标题按理想宽度取位、点线吃掉剩余」改成弹性空白，右侧次数 / 徽标列不动
            HStack(spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name ?? "")
                        .textStyle(.body, weight: isCurrent ? .semibold : .medium,
                                   color: isCurrent ? Theme.Paper.signalInk : Theme.Paper.ink)
                        .lineLimit(1)
                    Text(track.albumArtist ?? track.album ?? "")
                        .textStyle(.footnote, color: Theme.Paper.ink2)
                        .lineLimit(1)
                }
                // 标题先按理想宽度取位（超长标题 1 行截断 + tooltip，§7）
                .layoutPriority(1)
                .help(track.name ?? "")

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if sizeClass >= .w2 {
                Text("\(track.userData?.playCount ?? 0) 次")
                    .textStyle(.mono, color: Theme.Paper.ink2)
                    .layoutPriority(2)
            }

            if isCurrent {
                OnAirBadge(isPlaying: isPlaying, compact: sizeClass <= .w1)
                    .layoutPriority(2)
                CurrentRowVU(isPlaying: isPlaying)
                    .layoutPriority(2)
            } else {
                Text(formatPlaybackTime(track.runtimeSeconds))
                    .textStyle(.mono, color: Theme.Paper.ink2)
                    .frame(width: 64, alignment: .trailing)
                    .layoutPriority(2)
            }
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: Theme.Size.listRowHeight)
        .background(hovered ? Theme.Paper.hover : (isCurrent ? Theme.Paper.signalTint : Color.clear))
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle()
                    .fill(Theme.Paper.signal)
                    .frame(width: 3)
                    .accessibilityHidden(true)
            }
        }
    }

    /// glass 行（原样保留）
    private var glassLayout: some View {
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
    }
}

/// 当前行的迷你 VU（§4.5）。
///
/// 单独抽出来观察 `PlaybackProgress`：position 每 0.5s 发布一次，
/// 若由 TopTrackRow 直接观察，整张 Top 10 会跟着 tick 重算。
private struct CurrentRowVU: View {
    let isPlaying: Bool

    @ObservedObject private var progress = MusicPlayerModel.shared.progress

    private var value: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }

    var body: some View {
        VUMiniProgress(value: value, isPlaying: isPlaying)
            .frame(width: 64)
            .accessibilityHidden(true)
    }
}
