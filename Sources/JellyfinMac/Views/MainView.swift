import SwiftUI

// MARK: - 页面模型

enum ContentPage: Equatable {
    // 一级导航（侧栏固定 5 项）
    case home
    case library
    case playlists
    case nowPlaying
    case search
    // 从首页模块 / 快速入口下沉的页面
    case favorites
    case recentlyPlayed
    case mostPlayed
    // 二级详情
    case artist(BaseItemDto)
    case album(BaseItemDto)
    case playlist(Playlist)

    /// ⌘1…⌘5 对应的一级页
    static func primary(_ index: Int) -> ContentPage? {
        switch index {
        case 1: return .home
        case 2: return .library
        case 3: return .playlists
        case 4: return .nowPlaying
        case 5: return .search
        default: return nil
        }
    }

    /// 侧栏高亮的归属项（详情页归属其上级）
    var navRoot: ContentPage {
        switch self {
        case .artist, .album: return .library
        case .playlist: return .playlists
        case .favorites, .recentlyPlayed, .mostPlayed: return .home
        default: return self
        }
    }
}

/// 资料库分段（专辑/艺人/歌曲/播放列表）
enum LibrarySegment: String, CaseIterable {
    case albums, artists, tracks, playlists

    var title: String {
        switch self {
        case .albums: return "专辑"
        case .artists: return "艺人"
        case .tracks: return "歌曲"
        case .playlists: return "播放列表"
        }
    }
}

// MARK: - 主界面

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appReduceMotion) private var reduceMotion
    // 注意：这里**不**观察 MusicPlayerModel / PlaylistStore。
    // 观察它们会让播放/暂停、切歌、队列变化、播放列表增删都重建整个界面
    // （侧栏 + 当前页 + 播放条），而 MainView 本身只需要知道「要不要显示播放条」——
    // 那个判断已下沉到 MiniPlayerSlot，播放列表列表由 SidebarPanel 自己观察。

    /// 导航栈：一级切换 = 替换栈；二级推进 = push
    @State private var stack: [ContentPage] = []
    @State private var librarySegment: LibrarySegment = .albums
    @State private var libraryViewMode: LibraryViewMode = .grid
    @State private var sortMode: TrackSortMode = .name
    @State private var showQueue = false
    /// 图标栏临时展开的 240pt 抽屉（W1）
    @State private var drawerOpen = false
    /// 侧栏宽度（可拖动调整，记忆上次值）
    @State private var sidebarWidth: CGFloat =
        UserDefaults.standard.object(forKey: "sidebarWidth") as? CGFloat ?? Theme.Size.sidebarWidth
    /// 用户手动把完整侧栏收成图标栏（点 logo 行的侧栏按钮切换）
    @State private var railOverride = false
    /// 常驻搜索（顶栏与搜索页共用同一份查询）
    @State private var searchQuery = ""
    /// ⌘F 聚焦请求：自增即请求聚焦
    @State private var searchFocusRequest = 0

    var body: some View {
        GeometryReader { geo in
            let sizeClass = LayoutSizeClass.from(windowWidth: geo.size.width)
            let rail = usesIconRail(sizeClass)
            // 侧栏块 = 悬浮面板外边距 + 面板本体；内容列 = 窗口宽 − 侧栏块。
            //
            // 这里显式给内容列宽度是**硬约束**：HStack 在子视图最小宽度超过可用宽度时
            // 会把整列按最小宽度铺开并溢出到窗口右侧（顶栏搜索框、播放条右半、页面右边缘
            // 全部被裁掉）。给定宽度后，任何超宽子视图只会在列内溢出，不会顶破窗口。
            //
            // 光有这一层不够：页面内部还有一次最小宽度协商（滚动体 → 页面 VStack →
            // 顶栏 / 面包屑），滚动体把内容最小宽度上报给页面，chrome 会被一起撑宽 ——
            // 表现为顶部玻璃面板右缘连同 12pt 外边距与圆角被窗口右缘裁掉（2026-10-03
            // 截图复现）。所以每个页面的滚动体都要 `.pageBodyWidthClamp()`（见 Theme.swift）。
            let sidebarBlock = (rail ? Theme.Size.railWidth : sidebarWidth) + Theme.Size.panelMargin
            let contentWidth = max(geo.size.width - sidebarBlock, 0)
            ZStack {
                // 氛围层（§7.2 规则 3）：玻璃之下必须有可透的内容
                AmbientWash()

                HStack(spacing: 0) {
                    sidebar(sizeClass: sizeClass)

                    VStack(spacing: 0) {
                        content(sizeClass: sizeClass)
                            // 列级兜底：页面各自钳住了滚动体宽度（`pageBodyWidthClamp`），
                            // 这里再钉一次内容列宽度，队列抽屉 overlay 与迷你播放条就永远
                            // 按内容列对齐，不会被某个超宽页面推到窗口右缘之外。
                            .pageBodyWidthClamp()
                            // 队列抽屉只覆盖内容区，不遮挡底部播放条
                            .overlay(alignment: .trailing) {
                                if showQueue {
                                    QueuePanelView(onClose: { showQueue = false })
                                        .frame(width: Theme.Size.queuePanelWidth)
                                        .transition(.move(edge: .trailing).combined(with: .opacity))
                                }
                            }
                            .animation(Theme.Motion.spring, value: showQueue)

                        miniPlayer
                    }
                    // 硬约束宽度见下方 sidebarBlock 注释；alignment 用 leading：
                    // 内容列左缘始终钉在侧栏一侧，即便出现瞬态超宽也只会向右溢出，
                    // 不会以居中方式同时向左压到侧栏上。
                    .frame(width: contentWidth > 0 ? contentWidth : nil, alignment: .leading)
                }
                .overlay(alignment: .leading) {
                    // 拖拽分隔条**不占布局宽度**：12pt 热区跨在侧栏边界上。
                    // 若作为 HStack 的一项，它会在两块面板之间露出一条竖带。
                    if !rail {
                        SidebarDivider(sidebarWidth: $sidebarWidth)
                            .offset(x: sidebarWidth + Theme.Size.panelMargin - 6)
                    }
                }
                .overlay(alignment: .leading) {
                    if drawerOpen && sizeClass.railOffersDrawer {
                        drawer(sizeClass: sizeClass)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .animation(Theme.Motion.base, value: sizeClass)
                .animation(Theme.Motion.base, value: rail)
                .animation(Theme.Motion.base, value: drawerOpen)
                .onChange(of: sizeClass) { newValue in
                    // 档位切换时收起抽屉与手动收起状态，避免残留在新布局之上
                    if !newValue.railOffersDrawer { drawerOpen = false }
                    if newValue.usesIconRail { railOverride = false }
                }
                // 红黄绿三键要跟着侧栏形态走：图标栏面板只有 64pt 宽，
                // 三键得收得更紧才不会露到面板外（见 WindowManager.moveTrafficLights）
                .onAppear {
                    WindowManager.sidebarUsesRail = rail
                    WindowManager.refreshTrafficLights()
                }
                .onChange(of: rail) { newValue in
                    WindowManager.sidebarUsesRail = newValue
                    WindowManager.refreshTrafficLights()
                }
            }
        }
        .background(Theme.canvas.ignoresSafeArea())
        .background(shortcutHandler)
        // 把 SwiftUI 的 openSettings 环境动作捞进 SettingsOpener（macOS 14+）
        .background {
            if #available(macOS 14.0, *) {
                OpenSettingsCatcher()
            }
        }
        .task { await bootstrap() }
    }

    /// 是否显示为 64pt 图标栏：档位强制（W0/W1）或用户手动收起
    private func usesIconRail(_ sizeClass: LayoutSizeClass) -> Bool {
        sizeClass.usesIconRail || railOverride
    }

    // MARK: - 侧栏

    @ViewBuilder
    private func sidebar(sizeClass: LayoutSizeClass) -> some View {
        Group {
            if usesIconRail(sizeClass) {
                // 可展开的条件：W1 的抽屉，或用户手动收起（点「展开」还原完整侧栏）
                let canExpand = sizeClass.railOffersDrawer || railOverride
                SidebarPanel(
                    mode: .rail(offersDrawer: canExpand),
                    selected: currentPage,
                    userName: appState.user?.name ?? "",
                    serverHost: APIClient.shared.baseURL?.host ?? "",
                    onSelect: handleSidebarSelect,
                    onCollapse: nil,
                    onExpand: {
                        if railOverride {
                            railOverride = false
                        } else {
                            drawerOpen = true
                        }
                    },
                    onOpenSettings: openSettings
                )
                .frame(width: Theme.Size.railWidth)
            } else {
                SidebarPanel(
                    mode: .full,
                    selected: currentPage,
                    userName: appState.user?.name ?? "",
                    serverHost: APIClient.shared.baseURL?.host ?? "",
                    onSelect: handleSidebarSelect,
                    onCollapse: { railOverride = true },
                    onExpand: nil,
                    onOpenSettings: openSettings
                )
                .frame(width: sidebarWidth)
            }
        }
        // 悬浮玻璃面板（§7.2 规则 2）：外边距 10 + 统一圆角 10。
        //
        // 顺序要紧：padding 必须在 glassPanel **之外**，玻璃才会缩进 10pt 成为悬浮面板；
        // 写在里面时玻璃会铺满含 padding 的整块（面板贴住窗口左/上/下边缘，观感与
        // 「贴边侧栏」无异，红黄绿三键也失去面板依托）。
        .glassPanel(.regular, cornerRadius: Theme.Size.panelRadius, elevation: .e2)
        .padding(.leading, Theme.Size.panelMargin)
        .padding(.vertical, Theme.Size.panelMargin)
        // 注意：这里**不能**对 sidebarWidth 加动画。内容列宽度由同一状态即时重算
        // （frame(width: contentWidth)），若侧栏面板对宽度变化再做 200ms 动画，
        // 拖拽分隔条时「画出来的面板」会滞后于「布局槽位」，而内容列已经瞬间就位 ——
        // 面板在动画期间直接压到内容列上（封面 / 序号 / 面包屑被盖住的根因，
        // 2026-10-02 截图复现）。分隔条拖拽本身就该 1:1 跟手（见 SidebarDivider 注释）；
        // 侧栏折叠 / 展开与断点切换的平滑过渡由 HStack 上的
        // .animation(value: rail / sizeClass) 统一驱动，侧栏与内容列同帧协同变化。
    }

    /// 图标栏临时展开的抽屉：240pt 玻璃面板覆盖内容区 + 遮罩，点击外部或 Esc 收起
    private func drawer(sizeClass: LayoutSizeClass) -> some View {
        HStack(spacing: 0) {
            // 图标栏本身保持可点（不被遮罩吃掉）
            Color.clear.frame(width: Theme.Size.railWidth + Theme.Size.panelMargin)

            ZStack(alignment: .leading) {
                Theme.scrim
                    .contentShape(Rectangle())
                    .onTapGesture { drawerOpen = false }
                    .accessibilityHidden(true)

                SidebarPanel(
                    mode: .full,
                    selected: currentPage,
                    userName: appState.user?.name ?? "",
                    serverHost: APIClient.shared.baseURL?.host ?? "",
                    onSelect: { page in
                        drawerOpen = false
                        handleSidebarSelect(page)
                    },
                    onCollapse: { drawerOpen = false },
                    onExpand: nil,
                    onOpenSettings: {
                        drawerOpen = false
                        openSettings()
                    }
                )
                .frame(width: Theme.Size.sidebarWidth)
                .glassPanel(.thick, cornerRadius: Theme.Size.panelRadius, elevation: .e3)
                .padding(.vertical, Theme.Size.panelMargin)
                .padding(.leading, Theme.Spacing.xs)
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - 内容区

    private var currentPage: ContentPage { stack.last ?? .home }

    private var pageIdentity: String {
        switch currentPage {
        case .home: return "home"
        case .library: return "library"
        case .playlists: return "playlists"
        case .nowPlaying: return "nowPlaying"
        case .search: return "search"
        case .favorites: return "favorites"
        case .recentlyPlayed: return "recentlyPlayed"
        case .mostPlayed: return "mostPlayed"
        case .artist(let artist): return "artist-\(artist.id)"
        case .album(let album): return "album-\(album.id)"
        case .playlist(let playlist): return "playlist-\(playlist.id.uuidString)"
        }
    }

    private func content(sizeClass: LayoutSizeClass) -> some View {
        ZStack {
            pageView(currentPage, sizeClass: sizeClass)
                .id(pageIdentity)
                // 页面切换：260ms，位移 8pt + 淡入（§7）；Reduce Motion 下只保留透明度
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.page, value: pageIdentity)
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .offset(y: -8).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func pageView(_ page: ContentPage, sizeClass: LayoutSizeClass) -> some View {
        switch page {
        case .home:
            HomeView(
                sizeClass: sizeClass,
                onOpenAlbum: { push(.album($0)) },
                onOpenArtist: { push(.artist($0)) },
                onOpenPlaylist: { push(.playlist($0)) },
                onOpenFavorites: { openFromHome(.favorites) },
                onOpenRecentlyPlayed: { openFromHome(.recentlyPlayed) },
                onOpenMostPlayed: { openFromHome(.mostPlayed) },
                onOpenNowPlaying: { selectPage(.nowPlaying) },
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .library:
            MusicLibraryView(
                sizeClass: sizeClass,
                segment: $librarySegment,
                viewMode: $libraryViewMode,
                sortMode: sortMode,
                onSortModeChange: { sortMode = $0 },
                onOpenArtist: { push(.artist($0)) },
                onOpenAlbum: { push(.album($0)) },
                onOpenPlaylist: { push(.playlist($0)) },
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .playlists:
            PlaylistsView(
                sizeClass: sizeClass,
                onOpenPlaylist: { push(.playlist($0)) },
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .nowPlaying:
            NowPlayingView(sizeClass: sizeClass)
        case .search:
            MusicSearchView(
                sizeClass: sizeClass,
                query: $searchQuery,
                focusRequest: searchFocusRequest,
                onOpenAlbum: { push(.album($0)) },
                onOpenArtist: { push(.artist($0)) },
                onOpenPlaylist: { push(.playlist($0)) }
            )
        case .favorites:
            TrackListPage(
                sizeClass: sizeClass,
                title: "收藏",
                tracks: MusicDataStore.shared.favoriteTracks,
                emptyIcon: "heart",
                emptyText: "还没有收藏的曲目",
                emptyHint: "在曲目行上点击 ♥ 即可收藏",
                parentTitle: "首页",
                onBack: pop,
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .recentlyPlayed:
            TrackListPage(
                sizeClass: sizeClass,
                title: "最近播放",
                tracks: MusicDataStore.shared.recentlyPlayedTracks,
                emptyIcon: "clock.arrow.circlepath",
                emptyText: "还没有播放记录",
                parentTitle: "首页",
                onBack: pop,
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .mostPlayed:
            TrackListPage(
                sizeClass: sizeClass,
                title: "最常播放",
                tracks: MusicDataStore.shared.mostPlayedTracks,
                emptyIcon: "flame",
                emptyText: "还没有播放数据",
                emptyHint: "多听几次就会出现在这里",
                parentTitle: "首页",
                onBack: pop,
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { selectPage(.search) }
            )
        case .artist(let artist):
            MusicArtistView(
                artist: artist,
                sizeClass: sizeClass,
                parentTitle: parentTitle(for: .artist(artist)),
                onOpenAlbum: { push(.album($0)) },
                onBack: pop
            )
        case .album(let album):
            MusicAlbumView(
                item: album,
                sizeClass: sizeClass,
                parentTitle: parentTitle(for: .album(album)),
                onBack: pop
            )
        case .playlist(let playlist):
            PlaylistDetailView(
                playlist: playlist,
                sizeClass: sizeClass,
                parentTitle: parentTitle(for: .playlist(playlist)),
                onBack: pop
            )
        }
    }

    /// 面包屑上级标题：深链保护——从搜索进入详情，返回时回到搜索结果
    private func parentTitle(for page: ContentPage) -> String {
        guard stack.count >= 2 else {
            return page.navRoot == .playlists ? "播放列表" : "资料库"
        }
        switch stack[stack.count - 2] {
        case .search: return "搜索"
        case .library: return "资料库"
        case .playlists: return "播放列表"
        case .home: return "首页"
        case .favorites: return "收藏"
        case .recentlyPlayed: return "最近播放"
        case .mostPlayed: return "最常播放"
        case .artist: return "艺人"
        case .album: return "专辑"
        case .playlist: return "播放列表"
        default: return "返回"
        }
    }

    // MARK: - 底部迷你播放条

    /// 只把「显示 / 隐藏」的判断交给 MiniPlayerSlot，
    /// 播放状态变化就不会波及 MainView 的整个视图树。
    @ViewBuilder
    private var miniPlayer: some View {
        MiniPlayerSlot(
            isNowPlayingPage: currentPage == .nowPlaying,
            onOpen: { selectPage(.nowPlaying) },
            onToggleQueue: { showQueue.toggle() },
            isQueueVisible: showQueue
        )
    }

    // MARK: - 快捷键

    private var shortcutHandler: some View {
        KeyboardShortcutHandler(
            actions: KeyboardShortcutHandler.Actions(
                onSpace: { MusicPlayerModel.shared.togglePlay() },
                onNext: { MusicPlayerModel.shared.next() },
                onPrevious: { MusicPlayerModel.shared.previous() },
                onFocusSearch: focusSearch,
                onPrimaryPage: { index in
                    if let page = ContentPage.primary(index) { selectPage(page) }
                },
                onBack: { if stack.count > 1 { pop() } },
                onDelete: {},
                onEscape: { if drawerOpen { drawerOpen = false } }
            )
        )
    }

    // MARK: - 导航动作

    private func handleSidebarSelect(_ page: ContentPage) {
        switch page {
        case .home, .library, .playlists, .nowPlaying, .search:
            selectPage(page)
        default:
            push(page)
        }
    }

    /// 首页模块 / 快速入口打开的二级页：栈压成 [首页, 目标]，保证返回回到首页
    private func openFromHome(_ page: ContentPage) {
        guard currentPage != page else { return }
        stack = [.home, page]
    }

    private func selectPage(_ page: ContentPage) {
        guard currentPage != page else { return }
        stack = [page]
    }

    private func push(_ page: ContentPage) {
        stack.append(page)
    }

    private func pop() {
        guard stack.count > 1 else { return }
        stack.removeLast()
    }

    private func focusSearch() {
        if currentPage != .search { selectPage(.search) }
        searchFocusRequest += 1
    }

    /// 打开设置窗口。实现见文件末尾的 `SettingsOpener`：
    /// macOS 14+ 走 SwiftUI 的 openSettings 环境动作，macOS 13 回退到 AppKit 选择子。
    private func openSettings() {
        SettingsOpener.shared.open()
    }

    // MARK: - 启动装载

    private func bootstrap() async {
        // 等待会话就绪（自动登录进行中时 APIClient 尚未配置）
        for _ in 0..<100 {
            if APIClient.shared.baseURL != nil, APIClient.shared.user != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await appState.loadLibraries()
        // 冷启动时 /Views 偶发失败（服务器刚唤醒 / 本地域名解析未就绪）：
        // 失败后不重试会让整个音乐模块永久空白，所以这里退避重试几次
        var attempt = 0
        while appState.libraries.isEmpty && attempt < 5 {
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 600_000_000)
            await appState.loadLibraries()
        }
        if let lib = appState.libraries.first(where: { $0.collectionType == "music" })
            ?? appState.libraries.first {
            MusicDataStore.shared.libraryId = lib.id
            await MusicDataStore.shared.loadIfNeeded()
        }
        // 登录后自动与服务器播放列表同步
        await PlaylistSyncService.shared.syncAll()
        if stack.isEmpty {
            stack = [initialPage]
        }
    }

    /// 启动落点（设置页「默认打开页面」）
    private var initialPage: ContentPage {
        switch AppSettings.shared.startPage {
        case .home: return .home
        case .library: return .library
        case .playlists: return .playlists
        case .nowPlaying: return .nowPlaying
        }
    }
}

// MARK: - 迷你播放条槽位（隔离播放状态观察）

/// 决定迷你播放条显隐的最小视图。
///
/// `MusicPlayerModel` 的 `queue` / `currentIndex` / `isPlaying` 都会频繁发布，
/// 若由 `MainView` 直接观察，每次播放/暂停、切歌、增删队列都会重建整个界面。
/// 把观察收在这一个零布局成本的槽位里，重算范围就只剩播放条本身。
private struct MiniPlayerSlot: View {
    let isNowPlayingPage: Bool
    let onOpen: () -> Void
    let onToggleQueue: () -> Void
    let isQueueVisible: Bool

    @ObservedObject private var music = MusicPlayerModel.shared
    @Environment(\.appReduceMotion) private var reduceMotion

    var body: some View {
        if music.currentTrack != nil && !isNowPlayingPage {
            MiniPlayerBar(
                onOpen: onOpen,
                onToggleQueue: onToggleQueue,
                isQueueVisible: isQueueVisible
            )
            .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
            .animation(Theme.Motion.spring, value: music.currentTrack?.id)
        }
    }
}

// MARK: - 侧栏（完整 240 / 图标栏 64）

private struct SidebarPanel: View {
    enum Mode: Equatable {
        case full
        /// 图标栏；`offersDrawer` 为真时底部提供「展开」入口（W1）
        case rail(offersDrawer: Bool)
    }

    let mode: Mode
    let selected: ContentPage
    let userName: String
    let serverHost: String
    let onSelect: (ContentPage) -> Void
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?
    let onOpenSettings: () -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var playlistGroupExpanded = false

    private var isRail: Bool { mode != .full }

    private static let primaryItems: [(ContentPage, String, String)] = [
        (.home, "house", "首页"),
        (.library, "square.grid.2x2", "资料库"),
        (.playlists, "music.note.list", "播放列表"),
        (.nowPlaying, "opticaldisc", "正在播放"),
        (.search, "magnifyingglass", "搜索")
    ]

    var body: some View {
        Group {
            if isRail { railLayout } else { fullLayout }
        }
        // 顶部让出红黄绿三键的位置：悬浮面板外边距 10 后，三键正好落在面板内
        .padding(.top, Theme.Size.windowChromeHeight)
        .background(WindowDragArea())
    }

    // MARK: 完整侧栏

    private var fullLayout: some View {
        VStack(spacing: 0) {
            logoRow

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Self.primaryItems, id: \.2) { item in
                        navRow(page: item.0, icon: item.1, title: item.2)
                    }

                    playlistGroup
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())

            accountFooter
        }
    }

    private var logoRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.brandGradient)
                .frame(width: 26, height: 26)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                )
            Text("Overtone")
                .textStyle(.body, weight: .semibold, color: Theme.textPrimary)

            Spacer(minLength: 0)

            if let onCollapse {
                PlainIconButton(systemName: "sidebar.left", label: "收起侧栏", action: onCollapse)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: 56)
    }

    // MARK: 播放列表分组（默认折叠，6 项 + 显示全部）

    @ViewBuilder
    private var playlistGroup: some View {
        let all = playlistStore.allPlaylists
        let visible = playlistGroupExpanded ? all : Array(all.prefix(6))

        HStack {
            Text("我的列表")
                .sectionCaption()
            Spacer(minLength: 0)
            if all.count > 6 {
                Button {
                    playlistGroupExpanded.toggle()
                } label: {
                    Text(playlistGroupExpanded ? "收起" : "显示全部")
                        .textStyle(.caption, weight: .medium, color: Theme.brandText)
                }
                .buttonStyle(.plain)
                .hitExpand(from: 16, to: 32)
                .accessibilityLabel(playlistGroupExpanded ? "收起播放列表分组" : "显示全部播放列表")
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.sm)

        if all.isEmpty {
            Text("暂无播放列表")
                .textStyle(.footnote, color: Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.Spacing.sm)
        } else {
            // 新建 / 智能列表入口在「播放列表」一级页的顶栏，这里不重复放「管理播放列表」
            ForEach(visible) { playlist in
                navRow(
                    page: .playlist(playlist),
                    icon: playlist.isSmart ? "sparkles" : "music.note",
                    title: playlist.name
                )
            }
        }
    }

    // MARK: 图标栏

    private var railLayout: some View {
        VStack(spacing: Theme.Spacing.xs) {
            // W1 抽屉入口（§3.2）：图标栏顶部汉堡按钮
            if case .rail(let offersDrawer) = mode, offersDrawer, let onExpand {
                railRow(icon: "line.3.horizontal", title: "展开导航", action: onExpand)
                    .padding(.bottom, Theme.Spacing.sm)
            }

            ForEach(Self.primaryItems, id: \.2) { item in
                railRow(page: item.0, icon: item.1, title: item.2)
            }

            Spacer(minLength: 0)

            // 退出登录不在侧栏给入口，只留在「设置 → 服务器与账号」
            railRow(icon: "slider.horizontal.3", title: "设置", action: onOpenSettings)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.bottom, Theme.Spacing.lg)
    }

    // MARK: 行

    private func navRow(page: ContentPage, icon: String, title: String) -> some View {
        SidebarNavRow(
            icon: icon,
            title: title,
            isSelected: selected.navRoot == page,
            style: .full,
            action: { onSelect(page) }
        )
    }

    private func railRow(page: ContentPage, icon: String, title: String) -> some View {
        SidebarNavRow(
            icon: icon,
            title: title,
            isSelected: selected.navRoot == page,
            style: .rail,
            action: { onSelect(page) }
        )
    }

    private func railRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        SidebarNavRow(icon: icon, title: title, isSelected: false, style: .rail, action: action)
    }

    // MARK: 账号信息

    /// 底部只放「设置」一级入口 + 账号只读信息。
    /// 账号行不再挂弹出菜单：退出登录只走「设置 → 服务器与账号」。
    private var accountFooter: some View {
        VStack(spacing: 2) {
            // 设置（⌘,）：一级入口，不藏在账号菜单里
            navRow(icon: "slider.horizontal.3", title: "设置", action: onOpenSettings)

            HStack(spacing: Theme.Spacing.md) {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 26, height: 26)
                    .overlay(
                        Text(String(userName.prefix(1)).uppercased())
                            .textStyle(.caption, weight: .bold, color: .white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(userName)
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                        .lineLimit(1)
                    Text(serverHost)
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 40)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("当前账号 \(userName)，服务器 \(serverHost)")
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.lg)
    }

    private func navRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        SidebarNavRow(icon: icon, title: title, isSelected: false, style: .full, action: action)
    }
}

// MARK: - 侧栏导航行（完整 / 图标栏两种形态）

private struct SidebarNavRow: View {
    enum Style { case full, rail }

    let icon: String
    let title: String
    let isSelected: Bool
    let style: Style
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            content
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.md)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .animation(Theme.Motion.micro, value: isSelected)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .full:
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .textStyle(.bodySM, weight: isSelected ? .semibold : .medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            // 选中 = brandTint 底 + brandText 文字 + 字重 600（§4.5 列表行状态机）
            .foregroundStyle(isSelected ? Theme.brandText : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(fill)
            )

        case .rail:
            // 图标栏只显示图标（名称走 tooltip 与 VoiceOver）
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(isSelected ? Theme.brandText : Theme.textSecondary)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(fill)
                )
        }
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.brandTint) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - 侧栏与内容区之间的可拖动分隔条（Finder 式调整侧栏宽度）

/// 拖拽用 NSView 原生实现（同 WindowDragArea）：SwiftUI DragGesture 依赖识别器事件流，
/// 会因悬停结构变化/窗口激活重投递而中断（宽度来回弹 = 抖动），原生 mouseDown/Dragged
/// 则稳定且锚点式 1:1 跟随。
///
/// **不画任何可见分隔线**（悬停、拖动时都不画）：悬浮侧栏面板与内容区之间本来就有 12pt
/// 间隙，再叠一条竖线只会显脏。可发现性全部交给鼠标指针 —— 进入 12pt 热区即变
/// `resizeLeftRight`，按下即拖。
struct SidebarDivider: View {
    @Binding var sidebarWidth: CGFloat

    private let range: ClosedRange<CGFloat> = Theme.Size.sidebarMin...Theme.Size.sidebarMax

    var body: some View {
        // 热区 12pt，跨在侧栏右边界上（由调用方 offset 定位），拖拽 NSView 叠在最上层
        DividerDragView(sidebarWidth: $sidebarWidth, range: range)
            .frame(width: 12)
            .frame(maxHeight: .infinity)
    }
}

/// 分隔条拖拽 NSView：锚点式（按下时宽度 + 自按下以来的鼠标位移），
/// 每次鼠标事件从锚点重算，不做增量累加；悬停自动切换调整光标
private struct DividerDragView: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat
    let range: ClosedRange<CGFloat>

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.readWidth = { sidebarWidth }
        view.writeWidth = { newWidth in
            sidebarWidth = min(max(newWidth, range.lowerBound), range.upperBound)
        }
        view.finishWidth = { width in
            UserDefaults.standard.set(width, forKey: "sidebarWidth")
        }
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        var readWidth: () -> CGFloat = { 0 }
        var writeWidth: (CGFloat) -> Void = { _ in }
        var finishWidth: (CGFloat) -> Void = { _ in }

        private var anchorWidth: CGFloat = 0
        private var anchorMouseX: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? {
            super.hitTest(point)
        }

        override func mouseDown(with event: NSEvent) {
            anchorWidth = readWidth()
            anchorMouseX = NSEvent.mouseLocation.x
        }

        override func mouseDragged(with event: NSEvent) {
            let target = (anchorWidth + (NSEvent.mouseLocation.x - anchorMouseX)).rounded()
            writeWidth(target)
        }

        override func mouseUp(with event: NSEvent) {
            finishWidth(readWidth())
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            addTrackingArea(
                NSTrackingArea(
                    rect: bounds,
                    options: [.mouseEnteredAndExited, .activeAlways],
                    owner: self
                )
            )
        }

        override func mouseEntered(with event: NSEvent) {
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            NSCursor.arrow.set()
        }
    }
}

// MARK: - 设置窗口打开器

/// 打开设置窗口的唯一入口。
///
/// 为什么需要这个桥：
/// - `showSettingsWindow:` 选择子在新版 macOS 上会被 responder chain「接受」
///   （`sendAction` 返回 true）却什么都不做，窗口根本不出现 —— 返回 true 极具误导性。
///   2026-10-01 用最小 App 复现：选择子 true 且无窗口，`openSettings()` 正常开窗。
/// - 正确的 `openSettings` 是 SwiftUI 的**环境动作**，只能在 View 环境里取，
///   而侧栏菜单项等 AppKit 侧代码拿不到环境，于是用一个零尺寸视图把它捞进全局。
@MainActor
final class SettingsOpener {
    static let shared = SettingsOpener()

    /// macOS 14+ 由 `OpenSettingsCatcher` 注入；macOS 13 保持 nil 走选择子回退
    var action: (() -> Void)?

    func open() {
        if let action {
            action()
            return
        }
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }
}

@available(macOS 14.0, *)
private struct OpenSettingsCatcher: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear { SettingsOpener.shared.action = { openSettings() } }
            .accessibilityHidden(true)
    }
}
