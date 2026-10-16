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

    /// 详情页兜底归属的一级页（只在面包屑拿不到上级时用，见 `parentTitle`）。
    ///
    /// **侧栏高亮不再走这里**：详情页该归哪个一级页，由导航栈（`sidebarHighlightRoot`）
    /// 与列表行自己认领（`SidebarPanel`）决定 —— 否则「首页点开专辑」会错亮资料库，
    /// 「选中我的列表里那一行」会错亮一级「播放列表」。
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

/// 侧栏固定的一级页。
///
/// 单独抽出来是为了给「一级页常驻」一个可哈希的粒度：`ContentPage` 带关联值
/// （专辑 / 艺人 / 播放列表详情），不适合做常驻挂载的键。
enum RootTab: String, CaseIterable, Hashable {
    case home, library, playlists, nowPlaying, search

    var page: ContentPage {
        switch self {
        case .home: return .home
        case .library: return .library
        case .playlists: return .playlists
        case .nowPlaying: return .nowPlaying
        case .search: return .search
        }
    }

    init?(page: ContentPage) {
        switch page {
        case .home: self = .home
        case .library: self = .library
        case .playlists: self = .playlists
        case .nowPlaying: self = .nowPlaying
        case .search: self = .search
        default: return nil
        }
    }
}

// MARK: - 主界面

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appReduceMotion) private var reduceMotion
    /// 订阅视觉风格。
    ///
    /// 两件事都靠它：① `Theme.isPaper` 是全局镜像、读了**不订阅**，而这棵树里有大量按风格
    /// 分支的结构（侧栏/分组标签/播放条），不读环境值就可能在切风格后不重绘；
    /// ② 它同时当 `.id`，把「换风格重建」限制在呈现层（见 body 末尾）。
    @Environment(\.appVisualStyle) private var appStyle
    /// 观察设置：**只为强调色**。
    ///
    /// 强调色是绘制时解析的动态色，`Theme.refreshAccent()` 那套「切一次外观再切回来」
    /// 在 macOS 27 上已经不再让 SwiftUI 重绘内容 —— 实测改强调色后主窗口**逐像素不变**，
    /// 而改动前的二进制同样如此（既有缺陷，不是本次引入）。所以这里把强调色并进
    /// 呈现层的 `.id`：换强调色与换风格走同一条确定性重建路径。
    @ObservedObject private var settings = AppSettings.shared
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
                // 换视觉风格 / 强调色只重建这棵「呈现子树」（侧栏 + 内容列 + 迷你播放条 + 抽屉）。
                //
                // 为什么挂在 HStack 而不是 MainView 的 body 最外层：`.id` 变化会丢掉**被它覆盖的
                // 子树所持有的全部状态**。挂在最外层会把 MainView 自己的 @State（导航栈 stack、
                // 抽屉、搜索词、排序、侧栏宽度）一起清掉 —— 换风格等于被弹回首页；挂在 HStack 上
                // 则只复位呈现层的瞬态（滚动位置、行内 hover），业务状态全部存活。
                //
                // 为什么 id 里带强调色：强调色的动态色重解析在 macOS 27 上不触发 SwiftUI 重绘
                // （见 `settings` 的注释），只有换视图身份才能让新色阶落到已布局的视图上。
                //
                // 前置条件：`AppSettings` 侧不再对 scene 挂 `.id`，改由这里承担重建职责
                // （见 JellyfinApp / RootView 的注释）。
                .id("\(appStyle.rawValue)-\(settings.accent.rawValue)")
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
                    highlightRoot: sidebarHighlightRoot,
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
                    highlightRoot: sidebarHighlightRoot,
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
        // 悬浮面板：外边距 10 + 统一圆角。paper 下 `glassPanel` 已由 Theme 换成
        // 不透明纸面（`Paper.sheet`）+ hairline 描边 + 零投影（契约 §1 映射表），
        // 所以这里不另写 paper 分支 —— 悬浮边距与断点策略保持与 v3 完全一致，
        // 红黄绿三键的位置（WindowManager）与内容列宽度计算都不用改。
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
                    highlightRoot: sidebarHighlightRoot,
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

    /// 已挂载过的一级页：首次进入后常驻视图树。
    ///
    /// 原实现用 `ZStack { pageView(currentPage).id(pageIdentity).transition(...) }`，
    /// 每次切页都会把上一页整棵视图树丢掉、把新一页重建 —— 实测一次切换要烧
    /// 0.20–0.37s 主线程 CPU（曲库「歌曲」分段更贵：0.27s，且随可见行数线性增长）。
    /// 现在只改可见性：列表已实现的行、滚动位置、图片缓存全部保留，切回几乎不花钱
    /// （实测空页面地板价 0.07s，页面重建占了剩下的 60–75%）。
    @State private var mountedTabs: Set<RootTab> = []
    /// 每个一级页各自的 ⌘F 聚焦请求：隐藏页不参与聚焦，
    /// 否则常驻的隐藏搜索框会去抢第一响应者，打字打进了看不见的输入框。
    @State private var tabFocusRequest: [RootTab: Int] = [:]

    /// 当前高亮的一级页：栈顶是一级页时取栈顶，否则取栈底（详情页下面压着的那层）
    private var activeTab: RootTab? {
        if let top = stack.last, let tab = RootTab(page: top) { return tab }
        if let root = stack.first, let tab = RootTab(page: root) { return tab }
        // bootstrap 结束（stack 落位）之前：先按启动落点挂载，避免内容区空白
        return RootTab(page: initialPage)
    }

    /// 压在栈顶的二级详情页（专辑 / 艺人 / 播放列表 / 首页下沉页）
    private var topDetailPage: ContentPage? {
        guard let top = stack.last, RootTab(page: top) == nil else { return nil }
        return top
    }

    /// 侧栏一级项的高亮归属：栈里那一层一级页。
    ///
    /// 详情页归属它**下面压着**的那一层 —— 与内容区常驻层的 `activeTab` 同一套归属，
    /// 也就与面包屑（`parentTitle`）指向同一个页面：从首页点开的专辑，侧栏亮「首页」
    /// 而不是「资料库」（旧实现按 `navRoot` 硬映射，必然错亮资料库）。
    ///
    /// 播放列表详情是唯一例外：完整侧栏下高亮归「我的列表」里那一行（§4.3 单点高亮），
    /// 图标栏没有列表行可亮，才由一级「播放列表」承担（见 `SidebarPanel.isPrimarySelected`）。
    ///
    /// 兜底取 `currentPage.navRoot`：bootstrap 把 `stack` 落位之前栈是空的，那时内容区
    /// 显示的是 `currentPage`（首页）那一层，侧栏跟着它才不会出现「内容首页、侧栏亮播放列表」。
    private var sidebarHighlightRoot: ContentPage {
        stack.first(where: { RootTab(page: $0) != nil }) ?? currentPage.navRoot
    }

    /// 本次渲染要出现的一级页：已挂载的 + 当前活跃的（首次进入即挂载）
    private var renderedTabs: [RootTab] {
        var tabs = mountedTabs
        if let activeTab { tabs.insert(activeTab) }
        return RootTab.allCases.filter { tabs.contains($0) }
    }

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
            // 一级页常驻层：切换只改可见性 + 命中/无障碍开关
            ZStack {
                ForEach(renderedTabs, id: \.self) { tab in
                    let visible = topDetailPage == nil && tab.page == currentPage
                    pageView(tab.page, sizeClass: sizeClass, searchFocus: tabFocusRequest[tab] ?? 0)
                        .opacity(visible ? 1 : 0)
                        // 只给「进入」的那一页做淡入，离场页瞬时切掉。
                        // 交叉淡入会让两整页（含玻璃层）在转场期间逐帧重绘 —— 实测每次
                        // 切换多花 ~0.09s 主线程 CPU；一级页常驻之后切换本身几乎不花钱，
                        // 这笔账不值得。想彻底不要转场就把下面这行换成 `.animation(nil, …)`。
                        .animation(visible ? pageFadeIn : nil, value: visible)
                        // 当前页必须在最上层：ZStack 的最后一项才在顶部，而 `.opacity(0)`
                        // 不参与点击/滚动命中——不抬 zIndex 的话，压在顶上的隐藏页会吃掉
                        // 可见页的滚轮事件（表现为「列表滚不动」）。
                        .zIndex(visible ? 1 : 0)
                        .disabled(!visible)
                        .accessibilityHidden(!visible)
                }
            }
            .animation(nil, value: activeTab)

            // 栈顶详情页：生命周期短，仍按原先的推入 / 移除 + 转场处理
            if let detail = topDetailPage {
                pageView(detail, sizeClass: sizeClass, searchFocus: searchFocusRequest)
                    .id(pageIdentity)
                    // 页面切换：260ms，位移 8pt + 淡入（§7）；Reduce Motion 下只保留透明度
                    .transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.page, value: pageIdentity)
        .onChange(of: activeTab) { newValue in
            // 记住访问过的一级页：切走后仍然常驻
            if let newValue { mountedTabs.insert(newValue) }
        }
    }

    /// 一级页「进入」时的淡入时长（§7 页面转场；Reduce Motion 下同样只保留透明度）
    private var pageFadeIn: Animation {
        reduceMotion ? Theme.Motion.reduced : Theme.Motion.page
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(y: 8).combined(with: .opacity),
            removal: .offset(y: -8).combined(with: .opacity)
        )
    }

    @ViewBuilder
    private func pageView(_ page: ContentPage, sizeClass: LayoutSizeClass, searchFocus: Int) -> some View {
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
                searchFocusRequest: searchFocus,
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
                searchFocusRequest: searchFocus,
                onSearchSubmit: { selectPage(.search) }
            )
        case .playlists:
            PlaylistsView(
                sizeClass: sizeClass,
                onOpenPlaylist: { push(.playlist($0)) },
                searchQuery: $searchQuery,
                searchFocusRequest: searchFocus,
                onSearchSubmit: { selectPage(.search) }
            )
        case .nowPlaying:
            NowPlayingView(sizeClass: sizeClass)
        case .search:
            MusicSearchView(
                sizeClass: sizeClass,
                query: $searchQuery,
                focusRequest: searchFocus,
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
                searchFocusRequest: searchFocus,
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
                searchFocusRequest: searchFocus,
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
                searchFocusRequest: searchFocus,
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
        // 只有搜索页消费 ⌘F：其它常驻页拿到的是各自最后一次的请求值，不会被隐藏聚焦
        tabFocusRequest[.search] = searchFocusRequest
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
    /// 当前页（播放列表行按 id 认领高亮）
    let selected: ContentPage
    /// 一级项的高亮归属：栈里那一层一级页（详情页归它下面压着的一级页）
    let highlightRoot: ContentPage
    let userName: String
    let serverHost: String
    let onSelect: (ContentPage) -> Void
    var onCollapse: (() -> Void)?
    var onExpand: (() -> Void)?
    let onOpenSettings: () -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared

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
            if Theme.isPaper {
                // v4 版头（§2.4 谐波线母题）：～波形～ + 字距拉开的 OVERTONE，
                // 不再用品牌渐变方块 —— 信号红只做波形（品牌图形首演），不做色块
                HarmonicLines(count: 1)
                    .stroke(
                        Theme.Paper.signal,
                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    )
                    .frame(width: 34, height: 12)
                Text("Overtone")
                    .textStyle(.caption, weight: .bold, color: Theme.Paper.ink)
                    .tracking(2.6)
                    .lineLimit(1)
            } else {
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
            }

            Spacer(minLength: 0)

            if let onCollapse {
                PlainIconButton(systemName: "sidebar.left", label: "收起侧栏", action: onCollapse)
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: 56)
    }

    // MARK: 播放列表分组（全部展开，超出靠侧栏自身滚动）

    @ViewBuilder
    private var playlistGroup: some View {
        let all = playlistStore.allPlaylists

        playlistGroupHeader

        if all.isEmpty {
            Text("暂无播放列表")
                .textStyle(.footnote, color: Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, Theme.Spacing.sm)
        } else {
            // 新建 / 智能列表入口在「播放列表」一级页的顶栏，这里不重复放「管理播放列表」。
            // 列表**全部列出**，不再有「显示全部 / 收起」：条数多到一屏放不下时，
            // 由侧栏自身的 ScrollView 上下滚动（用户 2026-10-14）。
            ForEach(all) { playlist in
                SidebarNavRow(
                    icon: playlist.isSmart ? "sparkles" : "music.note",
                    title: playlist.name,
                    isSelected: isPlaylistRowSelected(playlist),
                    style: .full,
                    action: { onSelect(.playlist(playlist)) }
                )
            }
        }
    }

    /// 分组标签（§4.3）：glass = caption 小型大写；paper = 规则标签（细线延伸至容器缘）。
    /// 只在 paper 下换成 `RuleLabel`，glass 的排版一个像素都不动。
    /// 不再挂「显示全部 / 收起」按钮 —— 列表恒定全展开（见 `playlistGroup`）。
    @ViewBuilder
    private var playlistGroupHeader: some View {
        if Theme.isPaper {
            RuleLabel("我的列表")
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.sm)
        } else {
            HStack {
                Text("我的列表")
                    .sectionCaption()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.sm)
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
            isSelected: isPrimarySelected(page),
            style: .full,
            action: { onSelect(page) }
        )
    }

    private func railRow(page: ContentPage, icon: String, title: String) -> some View {
        SidebarNavRow(
            icon: icon,
            title: title,
            isSelected: isPrimarySelected(page),
            style: .rail,
            action: { onSelect(page) }
        )
    }

    private func railRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        SidebarNavRow(icon: icon, title: title, isSelected: false, style: .rail, action: action)
    }

    // MARK: 高亮归属（§4.3「选中 = 墨块填充 + 纸字 + 左缘红条」，一次只亮一行）

    /// 一级项是否高亮：取栈里那一层一级页（`highlightRoot`）。
    ///
    /// 播放列表详情是例外：完整侧栏下高亮归「我的列表」里那一行 —— 用户点的是列表行，
    /// 指示器就必须落在那一行上，而不能停在上方的一级「播放列表」（2026-10-14 修复）。
    /// 只有图标栏退回一级「播放列表」：窄窗只有 5 个图标，没有列表行可亮。
    /// （完整侧栏的列表恒定全展开，不存在「选中的那条没渲染出来」的情况。）
    private func isPrimarySelected(_ page: ContentPage) -> Bool {
        if case .playlist = selected {
            return isRail && page == .playlists
        }
        return page == highlightRoot
    }

    /// 播放列表行是否高亮：当前页就是这一条列表（按 **id** 比，不整值比）。
    ///
    /// 为什么不整值比：详情页压在栈里的 `Playlist` 是入栈那一刻的快照，之后增删曲目 /
    /// 服务器同步都会让 store 里的值变化，整值比较会让高亮在编辑过程中突然掉线。
    private func isPlaylistRowSelected(_ playlist: Playlist) -> Bool {
        guard case .playlist(let current) = selected else { return false }
        return current.id == playlist.id
    }

    // MARK: 账号信息

    /// 底部只放「设置」一级入口 + 账号只读信息。
    /// 账号行不再挂弹出菜单：退出登录只走「设置 → 服务器与账号」。
    private var accountFooter: some View {
        VStack(spacing: 2) {
            // 设置（⌘,）：一级入口，不藏在账号菜单里
            navRow(icon: "slider.horizontal.3", title: "设置", action: onOpenSettings)

            HStack(spacing: Theme.Spacing.md) {
                if Theme.isPaper {
                    // paper 下头像块改墨底纸字方块（圆角 3）：品牌渐变在这里会变成一块信号红，
                    // 违反「红只属于声音」
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Paper.ink)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Text(String(userName.prefix(1)).uppercased())
                                .textStyle(.caption, weight: .bold, color: Theme.Paper.sheet)
                        )
                } else {
                    Circle()
                        .fill(Theme.brandGradient)
                        .frame(width: 26, height: 26)
                        .overlay(
                            Text(String(userName.prefix(1)).uppercased())
                                .textStyle(.caption, weight: .bold, color: .white)
                        )
                }

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
        // 图标栏只显示图标，标签走 tooltip；完整侧栏（尤其 paper 下）已经有文字，再挂 tooltip 是重复
        .modifier(SidebarTooltip(text: title, enabled: !Theme.isPaper || style == .rail))
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
                    .textStyle(.bodySM, weight: isSelected ? .semibold : .medium, color: labelColor)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            // 选中 = 墨块填充 + 纸字（§4.3）；glass 是 brandTint 底 + 强调色图标 + 深色字
            .foregroundStyle(foreground)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(fill)
            )
            .modifier(SelectionEdgeBar(isSelected: isSelected))

        case .rail:
            // 图标栏只显示图标（名称走 tooltip 与 VoiceOver）
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 44, height: 44)
                .foregroundStyle(foreground)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(fill)
                )
                .modifier(SelectionEdgeBar(isSelected: isSelected))
        }
    }

    /// 文字色：paper 下选中 = 墨块上的纸字、静止 = ink-2、hover 提亮到 ink；glass 保持原取值
    private var foreground: Color {
        if Theme.isPaper {
            if isSelected { return Theme.Paper.sheet }
            return hovered ? Theme.Paper.ink : Theme.Paper.ink2
        }
        if isSelected { return Theme.brandText }
        return style == .rail ? Theme.textSecondary : Theme.textPrimary
    }

    /// 标签色 —— 与图标色**分开**给。
    ///
    /// - 纸墨：跟图标同色（选中 = 墨块上的纸字 `Paper.sheet`，静止 = `ink2`，hover = `ink`，§4.3「选中 = 墨块
    ///   填充 + 纸字」）。旧实现让 `textStyle` 兜底成 `textPrimary` = 墨，**墨块上的墨字**：选中行文字
    ///   整个消失（2026-10-14 截图复现，issue「纸墨主题选中后无法看清文字」）。
    /// - 玻璃：标签保持既有取值 `textPrimary`，只有图标走 `foreground` 的强调色。这是**故意的**：
    ///   README 与 v3 契约把玻璃模式的取值冻结成「与 v3 逐字节一致」，v3 的实机截图里选中项就是
    ///   深色字 + 强调色图标；v3 预览 CSS（`.sb-item.active{color:var(--brand-text)}`）与本文
    ///   旧注释说的是强调色字，两者不一致 —— 这次只修纸墨，不改玻璃观感（要不要统一另议）。
    ///   显式传色的另一个好处：本行不受 `textStyle` 默认语义（`color == nil` 时继承外层）变化影响。
    private var labelColor: Color {
        Theme.isPaper ? foreground : Theme.textPrimary
    }

    private var fill: AnyShapeStyle {
        if Theme.isPaper {
            if isSelected { return AnyShapeStyle(Theme.Paper.ink) }
            if hovered { return AnyShapeStyle(Theme.Paper.hover) }
            return AnyShapeStyle(Color.clear)
        }
        if isSelected { return AnyShapeStyle(Theme.brandTint) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

/// 侧栏 tooltip 开关：`enabled == false` 时完全不挂 `.help`，
/// 免得纸上侧栏弹出与行内文字重复的气泡（§4.3「tooltip = 标签（宽窗不挂）」）。
private struct SidebarTooltip: ViewModifier {
    let text: String
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.help(text)
        } else {
            content
        }
    }
}

/// 选中行左缘 3px 信号红条（§4.3 / §4.4）。
///
/// 为什么用 overlay 而不是 `inset` 阴影：阴影色无法走动态令牌缓存（会破坏 SwiftUI 的
/// 相等性跳过），而这里只是一块矩形。先 overlay 再 clip，方块的直角才会被行圆角裁掉。
private struct SelectionEdgeBar: ViewModifier {
    let isSelected: Bool

    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
                .overlay(alignment: .leading) {
                    if isSelected {
                        Rectangle()
                            .fill(Theme.Paper.signal)
                            .frame(width: 3)
                            .accessibilityHidden(true)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        } else {
            content
        }
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

// MARK: - 页面级纸墨排版辅助（T4 各页共用）

/// paper 下的「卡片级衬线标题」。
///
/// 契约的字形映射只把 display / title1–3 切到衬线，而预览里 15pt 的续播卡标题、
/// 播放列表行标题同样是衬线（§2.2「专辑名、艺人名」）。这里按**令牌字号**取衬线字形
/// ——不新增字号常量，动态字号缩放基准与 `textStyle` 同源；glass 分支原样走 `textStyle`，
/// 取值与改动前完全一致。
struct PaperSerifTitle: ViewModifier {
    let style: Theme.TextStyle
    let weight: Font.Weight
    let color: Color?

    @ScaledMetric private var scale: CGFloat

    init(_ style: Theme.TextStyle, weight: Font.Weight = .semibold, color: Color? = nil) {
        self.style = style
        self.weight = weight
        self.color = color
        _scale = ScaledMetric(wrappedValue: 1, relativeTo: style.relativeTo)
    }

    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
                .font(.system(size: style.size * scale, weight: weight, design: .serif))
                .lineSpacing(style.lineSpacing * scale)
                .foregroundStyle(color ?? Theme.textPrimary)
        } else {
            // 显式补上 `Theme.textPrimary`：`textStyle` 自 2026-10-14 起在 `color == nil`
            // 时**不再**写颜色（改为继承外层，见 `ScaledTextStyleModifier`）。这里补回默认值，
            // 玻璃模式的取值才与改动前逐像素一致 —— 本类型的契约就是「glass 分支原样走 textStyle」。
            content.textStyle(style, weight: weight, color: color ?? Theme.textPrimary)
        }
    }
}

extension View {
    /// 卡片级衬线标题（paper）/ 原字号令牌（glass）
    func paperSerifTitle(
        _ style: Theme.TextStyle,
        weight: Font.Weight = .semibold,
        color: Color? = nil
    ) -> some View {
        modifier(PaperSerifTitle(style, weight: weight, color: color))
    }
}

/// 封面外观（§4.6）。
///
/// glass = `elevation(level)`（深色下该修饰符会自动补 `borderSubtle` 描边；`level == nil`
/// 表示 glass 侧本来就没有投影，原样返回）；paper = 印刷套封内描边 + 零投影 ——
/// 投影虽然已被 Theme 层关掉，但**深色下那圈描边**仍在，与套封内框叠在一起会变成双框，
/// 所以这里必须整体分支。
struct PagesCoverChrome: ViewModifier {
    let radius: CGFloat
    let level: Theme.Elevation?

    func body(content: Content) -> some View {
        if Theme.isPaper {
            content.paperCoverFrame(true, cornerRadius: radius)
        } else if let level {
            content.elevation(level, cornerRadius: radius)
        } else {
            content
        }
    }
}

extension View {
    /// 封面统一外观：paper 套封 / glass 投影（`level: nil` = glass 侧无投影）
    func pagesCoverChrome(radius: CGFloat, level: Theme.Elevation? = .e1) -> some View {
        modifier(PagesCoverChrome(radius: radius, level: level))
    }
}
