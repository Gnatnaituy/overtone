import SwiftUI

enum ContentPage: Equatable {
    case library
    case playlists
    case nowPlaying
    case search
    case favorites
    case recentlyPlayed
    case mostPlayed
    case artist(BaseItemDto)
    case album(BaseItemDto)
    case playlist(Playlist)
}

/// 资料库分段（专辑/艺人/歌曲/播放列表，对齐设计稿顶栏分段控件）
enum LibrarySegment: String {
    case albums, artists, tracks, playlists
}

struct MainView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared

    @State private var stack: [ContentPage] = []
    @State private var librarySegment: LibrarySegment = .tracks
    @State private var sortMode: TrackSortMode = .name
    @State private var showQueue = false
    @State private var sidebarCollapsed = false
    /// 侧栏宽度（可拖动调整，记忆上次值；默认对齐设计稿 220pt）
    @State private var sidebarWidth: CGFloat = UserDefaults.standard.object(forKey: "sidebarWidth") as? CGFloat ?? 220
    /// ⌘F 聚焦搜索的一次性请求（搜索页消费后复位）
    @State private var searchFocusRequest = false
    @State private var sizeClass: LayoutSizeClass = .regular

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                if !sidebarCollapsed {
                    sidebar
                        .frame(width: sidebarWidth)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    SidebarDivider(sidebarWidth: $sidebarWidth)
                }
                VStack(spacing: 0) {
                    if sidebarCollapsed {
                        collapsedChrome
                    }
                    content
                        // 队列抽屉只覆盖内容区，不遮挡底部播放条
                        .overlay(alignment: .trailing) {
                            if showQueue {
                                QueuePanelView(onClose: { showQueue = false })
                                    .frame(width: 320)
                                    .transition(.move(edge: .trailing).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: showQueue)
                    miniPlayer(isCompact: sizeClass == .compact)
                }
            }
            .onAppear {
                sizeClass = LayoutSizeClass.from(width: geo.size.width)
            }
            .onChange(of: geo.size.width) { width in
                let newClass = LayoutSizeClass.from(width: width)
                if newClass != sizeClass {
                    sizeClass = newClass
                    // 多端适配：窄窗口自动收起侧栏，恢复宽度时展开
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
                        sidebarCollapsed = newClass == .compact
                    }
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .background(
            KeyboardShortcutHandler(
                onSpace: { MusicPlayerModel.shared.togglePlay() },
                onNext: { MusicPlayerModel.shared.next() },
                onPrevious: { MusicPlayerModel.shared.previous() },
                onFocusSearch: focusSearch
            )
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: sidebarCollapsed)
        .task {
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
                selectPage(.library)
            }
        }
    }

    // MARK: - 侧栏（设计稿：白底 + 右分隔线 + 主色激活项）

    private var sidebar: some View {
        VStack(spacing: 0) {
            // logo 行（兼作窗口拖拽区）
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text("Overtone")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                Spacer()
                Button {
                    sidebarCollapsed = true
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hoverFill))
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
                .help("收起侧栏")
                .accessibilityLabel("收起侧栏")
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            .background(WindowDragArea())
            .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    navRow(icon: "books.vertical", title: "资料库", selected: stack.last == .library) {
                        selectPage(.library)
                    }
                    navRow(icon: "music.note.list", title: "播放列表", selected: stack.last == .playlists) {
                        selectPage(.playlists)
                    }
                    navRow(icon: "opticaldisc", title: "正在播放", selected: stack.last == .nowPlaying) {
                        selectPage(.nowPlaying)
                    }
                    navRow(icon: "magnifyingglass", title: "搜索", selected: stack.last == .search) {
                        selectPage(.search)
                    }

                    sidebarSectionTitle("我的")
                        .padding(.top, 18)
                    navRow(icon: "heart", title: "收藏", selected: stack.last == .favorites) {
                        selectPage(.favorites)
                    }
                    navRow(icon: "clock.arrow.circlepath", title: "最近播放", selected: stack.last == .recentlyPlayed) {
                        selectPage(.recentlyPlayed)
                    }
                    navRow(icon: "flame", title: "最常播放", selected: stack.last == .mostPlayed) {
                        selectPage(.mostPlayed)
                    }

                    sidebarSectionTitle("播放列表")
                        .padding(.top, 18)

                    if playlistStore.playlists.isEmpty && playlistStore.smartPlaylists.isEmpty {
                        Text("暂无播放列表")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                    }

                    ForEach(playlistStore.playlists) { playlist in
                        navRow(
                            icon: "music.note",
                            title: playlist.name,
                            selected: isPlaylistSelected(playlist)
                        ) {
                            selectPage(.playlist(playlist))
                        }
                    }
                    ForEach(playlistStore.smartPlaylists) { playlist in
                        navRow(
                            icon: "sparkles",
                            title: playlist.name,
                            selected: isPlaylistSelected(playlist)
                        ) {
                            selectPage(.playlist(playlist))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            // 隐藏滚动指示器：它会叠在右侧 8pt 拖拽分割条上，抢占命中区域并造成双线/抖动。
            // SwiftUI 的 .scrollIndicators() 在部分 macOS 版本对传统样式滚动条不生效，
            // 这里再通过 NSScrollView 层强制关闭。
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())

            Spacer()

            userFooter
        }
        .background(WindowDragArea().background(Theme.sidebarBackground))
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }

    private func sidebarSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.tertiaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
    }

    /// 设计稿侧栏导航行：激活 = 主色实底白字，未激活 = 灰字悬停浅底
    private func navRow(
        icon: String,
        title: String,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        SidebarRowView(icon: icon, title: title, selected: selected, action: action)
    }

    private var userFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Theme.divider)
                .frame(height: 1)
            HStack(spacing: 8) {
                Circle()
                    .fill(Theme.accentGradient)
                    .frame(width: 30, height: 30)
                    .overlay(
                        Text(String(appState.user?.name?.prefix(1) ?? "?"))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(appState.user?.name ?? "")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                    Text(APIClient.shared.baseURL?.host ?? "")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button {
                    appState.logout()
                } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hoverFill))
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
                .help("退出登录")
                .accessibilityLabel("退出登录")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Theme.sidebarBackground)
    }

    private func isPlaylistSelected(_ playlist: Playlist) -> Bool {
        if case .playlist(let current)? = stack.last {
            return current.id == playlist.id
        }
        return false
    }

    // MARK: - 侧栏收起后的顶栏（展开按钮 + 拖拽区）

    private var collapsedChrome: some View {
        HStack(spacing: 8) {
            Button {
                sidebarCollapsed = false
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hoverFill))
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .help("展开侧栏")
            .accessibilityLabel("展开侧栏")
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(WindowDragArea().background(Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.divider).frame(height: 1)
        }
    }

    // MARK: - 内容区

    private var pageIdentity: String {
        switch stack.last {
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
        case nil: return "empty"
        }
    }

    private var content: some View {
        ZStack {
            if let page = stack.last {
                pageView(page)
                    .id(pageIdentity)
                    .transition(
                        // 推入/退出方向一致的导航转场：垂直上滑，距离短（16pt）不抢戏
                        .asymmetric(
                            insertion: .offset(y: 16).combined(with: .opacity),
                            removal: .offset(y: -16).combined(with: .opacity)
                        )
                    )
            } else {
                emptyState
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: pageIdentity)
    }

    @ViewBuilder
    private func pageView(_ page: ContentPage) -> some View {
        switch page {
        case .library:
            MusicLibraryView(
                segment: $librarySegment,
                sortMode: sortMode,
                onSortModeChange: { sortMode = $0 },
                onOpenArtist: { push(.artist($0)) },
                onOpenAlbum: { push(.album($0)) },
                onOpenPlaylist: { push(.playlist($0)) }
            )
        case .playlists:
            PlaylistsView(onOpenPlaylist: { push(.playlist($0)) })
        case .nowPlaying:
            NowPlayingView()
        case .search:
            MusicSearchView(
                focusRequest: $searchFocusRequest,
                onOpenAlbum: { push(.album($0)) },
                onOpenArtist: { push(.artist($0)) },
                onOpenPlaylist: { push(.playlist($0)) }
            )
        case .favorites:
            FavoritesView()
        case .recentlyPlayed:
            RecentlyPlayedView()
        case .mostPlayed:
            MostPlayedView()
        case .artist(let artist):
            MusicArtistView(artist: artist, onOpenAlbum: { push(.album($0)) }, onBack: pop)
        case .album(let album):
            MusicAlbumView(item: album, onBack: pop)
        case .playlist(let playlist):
            PlaylistDetailView(playlist: playlist, onBack: pop)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(Theme.tertiaryText)
            Text("从左侧选择浏览方式")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(WindowDragArea())
    }

    // MARK: - 底部播放条

    /// 正在播放页自带完整控制，进入该页时隐藏播放条避免重复
    private func miniPlayer(isCompact: Bool) -> some View {
        Group {
            if music.currentTrack != nil && stack.last != .nowPlaying {
                MiniPlayerBar(
                    onOpen: { selectPage(.nowPlaying) },
                    onToggleQueue: { showQueue.toggle() },
                    isQueueVisible: showQueue,
                    isCompact: isCompact
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: music.currentTrack?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: stack.last == .nowPlaying)
    }

    // MARK: - 导航

    private func selectPage(_ page: ContentPage) {
        withAnimation(.easeInOut(duration: 0.25)) {
            stack = [page]
        }
    }

    private func push(_ page: ContentPage) {
        withAnimation(.easeInOut(duration: 0.25)) {
            stack.append(page)
        }
    }

    private func pop() {
        withAnimation(.easeInOut(duration: 0.25)) {
            stack.removeLast()
        }
    }

    /// ⌘F：切到搜索页并请求聚焦输入框
    /// 聚焦请求由搜索页 onAppear/onChange 消费，无需等待转场结束
    private func focusSearch() {
        if stack.last != .search {
            selectPage(.search)
        }
        searchFocusRequest = true
    }
}

/// 侧栏导航行（设计稿样式）：激活 = 主色实底白字圆角条，未激活 = 灰字悬停浅底
private struct SidebarRowView: View {
    let icon: String
    let title: String
    let selected: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selected ? Color.white : Theme.primaryText)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(rowFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.15), value: selected)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private var rowFill: Color {
        if selected { return Theme.primaryBlue }
        if hovered { return Theme.hoverFill }
        return .clear
    }
}

/// 侧栏与内容区之间的可拖动分隔条（Finder 式调整侧栏宽度）
/// 默认透明无竖线，悬停时显示高亮细线
/// 拖拽用 NSView 原生实现（同 WindowDragArea）：SwiftUI DragGesture 依赖识别器事件流，
/// 会因悬停结构变化/窗口激活重投递而中断（宽度来回弹 = 抖动），原生 mouseDown/Dragged
/// 则稳定且锚点式 1:1 跟随
struct SidebarDivider: View {
    @Binding var sidebarWidth: CGFloat
    @State private var hovered = false

    private let range: ClosedRange<CGFloat> = 180...320

    var body: some View {
        // 稳定结构：蓝色高亮线始终存在，只切 opacity（结构分支会随 onHover 变化，
        // 拖拽中介入手势节点重建，宽度来回弹 = 抖动）
        // 热区 12pt（用户反馈 8pt 太窄抓不住）；拖拽 NSView 必须叠在最上层
        // （放在 .background 会被上层 SwiftUI 命中层吃掉鼠标事件）
        ZStack {
            Rectangle()
                .fill(Theme.primaryBlue.opacity(0.5))
                .frame(width: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(hovered ? 1 : 0)
            DividerDragView(
                sidebarWidth: $sidebarWidth,
                range: range,
                onHoverChange: { hovered = $0 }
            )
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .animation(.easeOut(duration: 0.15), value: hovered)
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
            let clamped = min(max(newWidth, range.lowerBound), range.upperBound)
            sidebarWidth = clamped
        }
        view.finishWidth = { width in
            UserDefaults.standard.set(width, forKey: "sidebarWidth")
        }
        view.hoverChanged = onHoverChange
        view.range = range
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}

    final class DragNSView: NSView {
        var readWidth: () -> CGFloat = { 0 }
        var writeWidth: (CGFloat) -> Void = { _ in }
        var finishWidth: (CGFloat) -> Void = { _ in }
        var hoverChanged: (Bool) -> Void = { _ in }
        var range: ClosedRange<CGFloat> = 180...320

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

/// 隐藏所在 ScrollView 的垂直滚动条（NSScrollView 层）：
/// SwiftUI 的 .scrollIndicators(.hidden) 在部分 macOS 版本上不生效，
/// 传统样式滚动条仍会渲染并叠加到相邻的拖拽分割条上
private struct ScrollBarHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ScrollBarHidingView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ScrollBarHidingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 等视图挂到窗口后，向 superview 链找最近的 NSScrollView
            DispatchQueue.main.async { self.hideScroller() }
        }

        private func hideScroller() {
            var candidate = superview
            while let view = candidate {
                if let scroll = view as? NSScrollView {
                    scroll.hasVerticalScroller = false
                    scroll.scrollerStyle = .overlay
                    return
                }
                candidate = view.superview
            }
        }
    }
}
