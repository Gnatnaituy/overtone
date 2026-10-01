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
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared

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
            HStack(spacing: 0) {
                sidebar(sizeClass: sizeClass)

                VStack(spacing: 0) {
                    // 窗口标题栏条：红黄绿三键浮在这里，底色与侧栏/顶栏同为 surface
                    Theme.surface
                        .frame(height: Theme.Size.windowChromeHeight)
                        .overlay(WindowDragArea())

                    content(sizeClass: sizeClass)
                        // 队列抽屉只覆盖内容区，不遮挡底部播放条
                        .overlay(alignment: .trailing) {
                            if showQueue {
                                QueuePanelView(onClose: { showQueue = false })
                                    .frame(width: Theme.Size.queuePanelWidth)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .animation(Theme.Motion.spring, value: showQueue)

                    miniPlayer(sizeClass: sizeClass)
                }
            }
            .overlay(alignment: .leading) {
                // 拖拽分隔条**不占布局宽度**：12pt 热区跨在侧栏边界上。
                // 若作为 HStack 的一项，它会在白色侧栏与白色顶栏之间露出一条 canvas 底色的
                // 竖带（窗口全高），看起来像一道莫名的空隙。
                if !rail {
                    SidebarDivider(sidebarWidth: $sidebarWidth)
                        .offset(x: sidebarWidth - 6)
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
        }
        .background(Theme.canvas.ignoresSafeArea())
        .background(shortcutHandler)
        .task { await bootstrap() }
    }

    /// 是否显示为 64pt 图标栏：档位强制（W0/W1）或用户手动收起
    private func usesIconRail(_ sizeClass: LayoutSizeClass) -> Bool {
        sizeClass.usesIconRail || railOverride
    }

    // MARK: - 侧栏

    @ViewBuilder
    private func sidebar(sizeClass: LayoutSizeClass) -> some View {
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
                onOpenSettings: openSettings,
                onLogout: { appState.logout() }
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
                onOpenSettings: openSettings,
                onLogout: { appState.logout() }
            )
            .frame(width: sidebarWidth)
        }
    }

    /// 图标栏临时展开的抽屉：240pt 覆盖内容区 + 遮罩，点击外部或 Esc 收起
    private func drawer(sizeClass: LayoutSizeClass) -> some View {
        HStack(spacing: 0) {
            // 图标栏本身保持可点（不被遮罩吃掉）
            Color.clear.frame(width: Theme.Size.railWidth)

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
                    },
                    onLogout: { appState.logout() }
                )
                .frame(width: Theme.Size.sidebarWidth)
                .elevation(.e3)
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

    @ViewBuilder
    private func miniPlayer(sizeClass: LayoutSizeClass) -> some View {
        if music.currentTrack != nil && currentPage != .nowPlaying {
            MiniPlayerBar(
                sizeClass: sizeClass,
                onOpen: { selectPage(.nowPlaying) },
                onToggleQueue: { showQueue.toggle() },
                isQueueVisible: showQueue
            )
            .transition(reduceMotion ? .opacity : .offset(y: 12).combined(with: .opacity))
            .animation(Theme.Motion.spring, value: music.currentTrack?.id)
        }
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

    private func openSettings() {
        // `Settings` 场景没有 openWindow 入口，走 AppKit 的标准动作
        // （macOS 13+ 是 showSettingsWindow:，更早是 showPreferencesWindow:）
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) { return }
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    // MARK: - 启动装载

    private func bootstrap() async {
        // 等待会话就绪（自动登录进行中时 APIClient 尚未配置）
        for _ in 0..<100 {
            if APIClient.shared.baseURL != nil { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        await appState.loadLibraries()
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
    let onLogout: () -> Void

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
        // 顶部让出红黄绿三键的位置（侧栏白底仍铺满整高，只有内容下移）
        .padding(.top, Theme.Size.windowChromeHeight)
        .background(WindowDragArea().background(Theme.surface))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.borderSubtle).frame(width: 1)
        }
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
            Text("播放列表")
                .sectionCaption()
            Spacer(minLength: 0)
            if all.count > 6 {
                Button {
                    playlistGroupExpanded.toggle()
                } label: {
                    Text(playlistGroupExpanded ? "收起" : "显示全部")
                        .textStyle(.caption, weight: .medium, color: Theme.brand500)
                }
                .buttonStyle(.plain)
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
            ForEach(visible) { playlist in
                navRow(
                    page: .playlist(playlist),
                    icon: playlist.isSmart ? "sparkles" : "music.note",
                    title: playlist.name
                )
            }
            Button {
                onSelect(.playlists)
            } label: {
                HStack(spacing: Theme.Spacing.lg) {
                    Image(systemName: "plus")
                        .font(.system(size: 13))
                        .frame(width: 18)
                    Text("管理播放列表")
                        .textStyle(.bodySM, weight: .medium, color: Theme.textTertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("管理播放列表")
        }
    }

    // MARK: 图标栏

    private var railLayout: some View {
        VStack(spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.brandGradient)
                .frame(width: 34, height: 34)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.sm)

            ForEach(Self.primaryItems, id: \.2) { item in
                railRow(page: item.0, icon: item.1, title: item.2)
            }

            Spacer(minLength: 0)

            if case .rail(let offersDrawer) = mode, offersDrawer, let onExpand {
                railRow(icon: "sidebar.left", title: "展开", action: onExpand)
            }
            railRow(icon: "gearshape", title: "设置", action: onOpenSettings)
            railRow(icon: "rectangle.portrait.and.arrow.right", title: "退出", action: onLogout)
        }
        .padding(.horizontal, Theme.Spacing.md)
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

    // MARK: 账号菜单

    private var accountFooter: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.borderSubtle).frame(height: 1)
            HStack(spacing: Theme.Spacing.md) {
                Circle()
                    .fill(Theme.brandGradient)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(String(userName.prefix(1)).uppercased())
                            .textStyle(.footnote, weight: .bold, color: .white)
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(userName)
                        .textStyle(.footnote, weight: .semibold, color: Theme.textPrimary)
                        .lineLimit(1)
                    Text(serverHost)
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Menu {
                    Button {
                        onOpenSettings()
                    } label: {
                        Label("设置…", systemImage: "gearshape")
                    }
                    Divider()
                    Button(role: .destructive) {
                        onLogout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("账号与设置")
                .accessibilityLabel("账号与设置")
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.vertical, Theme.Spacing.md)
        }
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
                    .textStyle(.bodySM, weight: .medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(fill)
            )
            .overlay(alignment: .leading) {
                // 选中：左侧 3pt 主色指示条（位于侧栏内边距之外）
                if isSelected {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.brand500)
                        .frame(width: 3, height: 20)
                        .offset(x: -Theme.Spacing.lg)
                }
            }

        case .rail:
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                Text(title)
                    .textStyle(.caption, weight: .medium)
                    .lineLimit(1)
            }
            .frame(width: 48, height: 48)
            .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textSecondary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(fill)
            )
        }
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.brandGradient) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - 侧栏与内容区之间的可拖动分隔条（Finder 式调整侧栏宽度）

/// 拖拽用 NSView 原生实现（同 WindowDragArea）：SwiftUI DragGesture 依赖识别器事件流，
/// 会因悬停结构变化/窗口激活重投递而中断（宽度来回弹 = 抖动），原生 mouseDown/Dragged
/// 则稳定且锚点式 1:1 跟随
struct SidebarDivider: View {
    @Binding var sidebarWidth: CGFloat
    @State private var hovered = false

    private let range: ClosedRange<CGFloat> = Theme.Size.sidebarMin...Theme.Size.sidebarMax

    var body: some View {
        // 稳定结构：蓝色高亮线始终存在，只切 opacity（结构分支会随 onHover 变化，
        // 拖拽中介入手势节点重建，宽度来回弹 = 抖动）
        // 热区 12pt，跨在侧栏右边界上（由调用方 offset 定位），拖拽 NSView 叠在最上层
        ZStack {
            Rectangle()
                .fill(Theme.brand500.opacity(0.6))
                .frame(width: 2)
                .opacity(hovered ? 1 : 0)
            DividerDragView(
                sidebarWidth: $sidebarWidth,
                range: range,
                onHoverChange: { hovered = $0 }
            )
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .animation(Theme.Motion.micro, value: hovered)
    }
}

/// 分隔条拖拽 NSView：锚点式（按下时宽度 + 自按下以来的鼠标位移），
/// 每次鼠标事件从锚点重算，不做增量累加；悬停自动切换调整光标
private struct DividerDragView: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat
    let range: ClosedRange<CGFloat>
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.readWidth = { sidebarWidth }
        view.writeWidth = { newWidth in
            sidebarWidth = min(max(newWidth, range.lowerBound), range.upperBound)
        }
        view.finishWidth = { width in
            UserDefaults.standard.set(width, forKey: "sidebarWidth")
        }
        view.hoverChanged = onHoverChange
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        var readWidth: () -> CGFloat = { 0 }
        var writeWidth: (CGFloat) -> Void = { _ in }
        var finishWidth: (CGFloat) -> Void = { _ in }
        var hoverChanged: (Bool) -> Void = { _ in }

        private var anchorWidth: CGFloat = 0
        private var anchorMouseX: CGFloat = 0

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
            hoverChanged(true)
            NSCursor.resizeLeftRight.set()
        }

        override func mouseExited(with event: NSEvent) {
            hoverChanged(false)
            NSCursor.arrow.set()
        }
    }
}
