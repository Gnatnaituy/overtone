import SwiftUI

// MARK: - 图片缓存

/// 图片缓存：并发去重（同一 URL 只有一个下载任务），缓存解码后的 NSImage
/// （避免滚动回来时反复解析图片数据）。所有调用方都在主线程，故用 @MainActor 而非 actor。
@MainActor
final class ImageCache {
    static let shared = ImageCache()

    private var cache: [String: NSImage] = [:]
    private var tasks: [String: Task<Data?, Never>] = [:]
    private var order: [String] = []

    func image(for url: URL) async -> NSImage? {
        let key = url.absoluteString
        if let image = cache[key] {
            // 命中即刷新 LRU 位置
            touch(key)
            return image
        }

        let data: Data?
        if let task = tasks[key] {
            data = await task.value
        } else {
            let task = Task<Data?, Never> {
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
                return data
            }
            tasks[key] = task
            data = await task.value
            tasks[key] = nil
        }
        // 并发去重只覆盖下载：两个调用方等的是同一个下载任务，但都会走到这里各自解码。
        // 先复查一次缓存，避免同一张图被解码成两个 NSImage 并写入两次
        // （同一 URL 的调用方在「正在播放」页同时出现：大封面 + 封面取色）。
        if let image = cache[key] {
            touch(key)
            return image
        }
        guard let data, let image = NSImage(data: data) else { return nil }
        store(image: image, key: key)
        return image
    }

    /// 命中缓存时把键移到队尾（LRU 新鲜度）
    private func touch(_ key: String) {
        guard let existing = order.firstIndex(of: key), existing != order.count - 1 else { return }
        order.remove(at: existing)
        order.append(key)
    }

    private func store(image: NSImage, key: String) {
        // LRU：命中过的键移到队尾，淘汰的永远是最久没用到的封面。
        //
        // 原来是纯插入序（FIFO）：一个 1000 首的列表滚过去之后，**屏幕上还在显示**的
        // 封面会因为"插入得早"被淘汰，滚回来又要重新下载 + 解码。
        // 同时这里先移除同键旧位置，避免并发调用方重复入队导致 order 与 cache 失配
        // （失配时淘汰会删错键，缓存条目数虚高）。
        if cache[key] != nil, let existing = order.firstIndex(of: key) {
            order.remove(at: existing)
        }
        cache[key] = image
        order.append(key)
        while order.count > Self.capacity {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// 内存中保留的封面数量上限
    private static let capacity = 400

    /// 清空内存缓存（设置页「清除缓存」）
    func removeAll() {
        cache.removeAll()
        order.removeAll()
    }

    /// 当前缓存的图片数量（设置页展示）
    var count: Int { cache.count }
}

/// 远端封面：加载中显示 `surfaceSunken` 占位 + 极淡音符图标
struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    @State private var image: NSImage?

    var body: some View {
        // 用 if/else 直接切内容（默认转场就是淡入），不再套一层 ZStack + 显式 transition：
        // 这个视图在曲库 / 专辑 / 艺人 / 播放列表里每个格子（以及每一行封面）都有一个，
        // 少一层容器就是每页少几十个视图节点。
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .animation(Theme.Motion.base, value: image == nil)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ImageCache.shared.image(for: url)
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.surfaceSunken
            Image(systemName: "music.note")
                .font(.system(size: 18))
                .foregroundStyle(Theme.borderStrong)
        }
    }
}

// MARK: - 页面内容容器（页面边距随断点 + W4 内容最大 1440 居中）

struct PageContent<Content: View>: View {
    let sizeClass: LayoutSizeClass
    var topPadding: CGFloat = Theme.Spacing.xxxl
    var bottomPadding: CGFloat = Theme.Spacing.section
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, sizeClass.pageMargin)
            .padding(.top, topPadding)
            .padding(.bottom, bottomPadding)
            .frame(maxWidth: sizeClass.contentMaxWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 内容区顶栏（64pt，兼作窗口拖拽区）

struct PageTopBar<Trailing: View>: View {
    let sizeClass: LayoutSizeClass
    var title: String?
    var subtitle: String?
    var searchText: Binding<String>?
    /// ⌘F 聚焦请求（自增即聚焦）
    var searchFocusRequest: Int = 0
    var onSearchSubmit: (() -> Void)?
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            if let title {
                Text(title)
                    .textStyle(sizeClass.isNarrow ? .title3 : .title2, color: Theme.textPrimary)
                    // paper 的页面标题走衬线（§2.2：展示衬线承担「印刷」气质）。
                    // 不依赖 TextStyle.design 的映射而显式声明一次：glass 侧 `.default` 与改动前同值
                    .fontDesign(Theme.isPaper ? .serif : .default)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            if let subtitle {
                Text(subtitle)
                    .textStyle(.footnote, color: Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Theme.Spacing.md)

            if let searchText {
                SearchField(
                    text: searchText,
                    width: sizeClass.topBarSearchWidth,
                    focusRequest: searchFocusRequest,
                    showsShortcutBadge: sizeClass.topBarShowsSearch,
                    onSubmit: onSearchSubmit
                )
            }

            trailing()
        }
        // 内边距与页面内容边距同源（pageMargin 16/20/24/28/32 随断点），
        // 顶栏标题 / 搜索框与下方页面内容始终左对齐；不再用写死的 16/20
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: Theme.Size.topBarHeight)
        // 顶栏属于 chrome 层：悬浮玻璃面板（§7.2 规则 2）
        .background(WindowDragArea())
        .glassPanel(.regular, cornerRadius: Theme.Size.panelRadius, elevation: .e2)
        .padding(.top, Theme.Size.panelMargin)
        .padding(.horizontal, Theme.Size.panelGap)
    }
}

// MARK: - 面包屑返回栏（44pt，可点击分段）

struct BreadcrumbBar: View {
    let sizeClass: LayoutSizeClass
    /// 可点击的上级（如「资料库」）；nil 表示只显示当前项
    var parentTitle: String?
    var onParent: (() -> Void)?
    let title: String
    var showsShortcutHint = true

    /// paper 下上级按钮的 hover 底（§6.4 面包屑是幽灵按钮，不是 sunken 胶囊）
    @State private var parentHovered = false

    var body: some View {
        if Theme.isPaper {
            paperBody
        } else {
            glassBody
        }
    }

    /// glass（v3）形态：与改动前逐字一致
    private var glassBody: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: { onParent?() }) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(parentTitle ?? "返回")
                        .textStyle(.bodySM, weight: .medium, color: Theme.textSecondary)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.surfaceSunken)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .disabled(onParent == nil)
            .help("返回上一级（⌘[）")
            .accessibilityLabel("返回\(parentTitle ?? "上一级")")

            Text("/")
                .textStyle(.bodySM, color: Theme.textTertiary)

            Text(title)
                .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 0)

            if showsShortcutHint && !sizeClass.isNarrow {
                Text("⌘[ 返回")
                    .textStyle(.caption, color: Theme.textTertiary)
            }
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: Theme.Size.crumbBarHeight)
        .background(WindowDragArea())
        .glassPanel(.thin, cornerRadius: Theme.Size.panelRadius, elevation: nil)
        // 与 PageTopBar 同一悬浮节奏：顶部留 panelMargin，不再贴住窗口上缘
        .padding(.top, Theme.Size.panelMargin)
        .padding(.horizontal, Theme.Size.panelGap)
    }

    /// paper 形态（§6.4）：‹ 资料库 ›—— 上级是幽灵按钮，当前项是衬线标题，分隔符 ink-3
    private var paperBody: some View {
        HStack(spacing: Theme.Spacing.md) {
            Button(action: { onParent?() }) {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(parentTitle ?? "返回")
                        .textStyle(.bodySM, weight: .medium, color: Theme.Paper.ink2)
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(parentHovered ? Theme.Paper.hover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .disabled(onParent == nil)
            .help("返回上一级（⌘[）")
            .accessibilityLabel("返回\(parentTitle ?? "上一级")")
            .onHover { parentHovered = $0 }

            Text("›")
                .textStyle(.bodySM, color: Theme.Paper.ink3)

            Text(title)
                .textStyle(.title4, weight: .bold, color: Theme.Paper.ink)
                .fontDesign(.serif)
                .lineLimit(1)

            Spacer(minLength: 0)

            if showsShortcutHint && !sizeClass.isNarrow {
                Text("⌘[ 返回")
                    .textStyle(.caption, color: Theme.Paper.ink3)
            }
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: Theme.Size.crumbBarHeight)
        .background(WindowDragArea())
        .glassPanel(.thin, cornerRadius: Theme.Size.panelRadius, elevation: nil)
        .padding(.top, Theme.Size.panelMargin)
        .padding(.horizontal, Theme.Size.panelGap)
    }
}

// MARK: - 视图切换（网格 / 列表，图标分段 32×32）

enum LibraryViewMode: String, CaseIterable {
    case grid, list

    var systemImage: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }

    var title: String {
        switch self {
        case .grid: return "网格"
        case .list: return "列表"
        }
    }
}

struct ViewModeToggle: View {
    @Binding var mode: LibraryViewMode

    private var selection: Binding<String> {
        Binding(get: { mode.rawValue }, set: { mode = LibraryViewMode(rawValue: $0) ?? .grid })
    }

    var body: some View {
        SegmentedControl(
            segments: LibraryViewMode.allCases.map { .init($0.rawValue, $0.title, systemImage: $0.systemImage) },
            selection: selection,
            iconOnly: true
        )
        .accessibilityLabel("视图切换")
    }
}

// MARK: - 排序菜单（高 32）

struct SortMenu: View {
    let current: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        TokenMenu(accessibilityLabel: "排序方式：\(current)") {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == current {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(current)
                    .textStyle(.footnote, weight: .medium, color: Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: Theme.Size.fieldHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .strokeBorder(Theme.borderDefault)
            )
        }
    }
}

// MARK: - 专辑卡片（封面 1:1 圆角 10 + e1；hover → e2 + 上移 2 + 播放角标）

struct PosterCard: View {
    let item: BaseItemDto
    /// 仅用于请求合适分辨率的封面图
    var width: CGFloat = 320
    var posterAspect: CGFloat = 1.0
    var onTap: (() -> Void)?
    var onPlay: (() -> Void)?

    @State private var hovered = false
    @Environment(\.appReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Button {
                onTap?()
            } label: {
                cover
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .focused($focused)
            .focusRing(focused, cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md)
            .help("打开 \(item.name ?? "专辑")")
            .accessibilityLabel("\(item.name ?? "未知标题")，\(subtitle)")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name ?? "未知标题")
                    .textStyle(Theme.isPaper ? .body : .bodySM, weight: .semibold, color: Theme.textPrimary)
                    // 专辑名走衬线（§4.6 网格卡：封面 + 衬线专辑名 14/600）
                    .fontDesign(Theme.isPaper ? .serif : .default)
                    .lineLimit(1)
                Text(subtitle)
                    .textStyle(.footnote, color: Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        // hover 上浮用 micro（120ms）而不是 0.35s 弹簧：卡片有 2pt 位移 + 阴影换挡，
        // 弹簧尾巴要跑 1s 以上，实测悬停一张卡片会让主线程连续出帧 1.7s。
        // 位移只有 2pt，120ms 已经足够顺，且"跟手"感更好。
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
    }

    private var cover: some View {
        RemoteImage(url: item.artworkURL(width: Int(width)), contentMode: .fill)
            .aspectRatio(posterAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md))
            // paper：印刷套封（§4.6 2px 圆角 + 3px 内描边）；glass 下该方法原样返回
            .paperCoverFrame(Theme.isPaper)
            .elevation(hovered ? .e2 : .e1)
            .overlay {
                // hover / 键盘聚焦：压暗 + 中央播放角标
                if hovered || focused {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md)
                            .fill(Theme.coverScrim)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
            // paper 不用上浮（§4.6）：hover 让封面下移 1px，像活版压下去
            .offset(y: Theme.isPaper && hovered && !reduceMotion ? 1 : 0)
            .animation(Theme.Motion.micro, value: hovered)
    }

    private var subtitle: String {
        switch item.type {
        case "MusicAlbum":
            if let artist = item.albumArtist, let year = item.productionYear {
                return "\(artist) · \(year)"
            }
            return item.albumArtist ?? item.productionYear.map(String.init) ?? ""
        case "MusicArtist":
            return "艺人"
        case "Audio":
            return item.album ?? item.albumArtist ?? ""
        default:
            return item.productionYear.map(String.init) ?? ""
        }
    }
}

// MARK: - 艺人卡片（圆形头像 + 居中名 13/500）

struct ArtistCard: View {
    let artist: BaseItemDto
    var width: CGFloat = 300
    let onTap: () -> Void

    @State private var hovered = false
    @Environment(\.appReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: Theme.Spacing.md) {
                RemoteImage(url: APIClient.shared.primaryImageURL(for: artist, width: Int(width)), contentMode: .fill)
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(Circle())
                    .elevation(hovered ? .e2 : .e1)
                    .overlay {
                        // paper：圆形头像没有「套封框」，改用 1px 强 hairline 描边（§2.3 描边是主要分隔手段）
                        if Theme.isPaper {
                            Circle().strokeBorder(Theme.Paper.hairlineStrong, lineWidth: 1)
                        }
                    }
                    .overlay {
                        if hovered || focused {
                            Circle()
                                .fill(Theme.coverScrim)
                                .overlay(
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 20, weight: .semibold))
                                        .foregroundStyle(.white)
                                )
                                .transition(.opacity)
                        }
                    }
                    // paper 不用上浮（§4.6）：hover 下沉 1px 的活版按压感
                    .offset(y: Theme.isPaper && hovered && !reduceMotion ? 1 : 0)

                Text(artist.name ?? "未知艺术家")
                    .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                    .fontDesign(Theme.isPaper ? .serif : .default)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        // hover 上浮用 micro（120ms）而不是 0.35s 弹簧：卡片有 2pt 位移 + 阴影换挡，
        // 弹簧尾巴要跑 1s 以上，实测悬停一张卡片会让主线程连续出帧 1.7s。
        // 位移只有 2pt，120ms 已经足够顺，且"跟手"感更好。
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
        .help(artist.name ?? "艺人")
    }
}

// MARK: - 曲目行操作（收藏 / 更多；hover 与键盘 focus 等价，均可 Tab 到达）

struct TrackRowActions: View {
    let track: BaseItemDto
    /// 是否常显（收藏状态为真时常显）
    var alwaysVisible = false
    var revealed: Bool
    var onInfo: (() -> Void)?
    var onRemove: (() -> Void)?

    @ObservedObject private var playlists = PlaylistStore.shared
    @FocusState private var focusedAction: Action?

    private enum Action: Hashable { case favorite, more, info, remove }

    private var isFavorite: Bool { track.userData?.isFavorite == true }
    private var visible: Bool { revealed || alwaysVisible || isFavorite || focusedAction != nil }

    var body: some View {
        HStack(spacing: 2) {
            actionButton(
                systemName: isFavorite ? "heart.fill" : "heart",
                tint: isFavorite ? Theme.favorite : Theme.textSecondary,
                label: isFavorite ? "取消收藏" : "收藏",
                focus: .favorite
            ) {
                Task { await MusicDataStore.shared.toggleFavorite(track) }
            }

            if let onInfo {
                actionButton(systemName: "info.circle", tint: Theme.textSecondary, label: "曲目信息", focus: .info) {
                    onInfo()
                }
            }

            if let onRemove {
                actionButton(systemName: "minus.circle", tint: Theme.textSecondary, label: "从播放列表移除", focus: .remove) {
                    onRemove()
                }
            }

            overflowMenu
        }
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(Theme.Motion.micro, value: visible)
    }

    private func actionButton(
        systemName: String,
        tint: Color,
        label: String,
        focus: Action,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focused($focusedAction, equals: focus)
        .help(label)
        .accessibilityLabel(label)
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                MusicPlayerModel.shared.playNext(track)
                ToastCenter.shared.show("已设为下一首播放", systemImage: "arrow.up.circle")
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            Button {
                MusicPlayerModel.shared.enqueue([track])
                ToastCenter.shared.show("已添加到播放队列", systemImage: "text.badge.plus")
            } label: {
                Label("添加到队列", systemImage: "text.badge.plus")
            }
            Divider()
            if playlists.playlists.isEmpty {
                Text("暂无播放列表，请先创建")
            } else {
                ForEach(playlists.playlists) { playlist in
                    Button(playlist.name) {
                        playlists.add(track: track, to: playlist)
                        ToastCenter.shared.show("已添加到「\(playlist.name)」", systemImage: "music.note.list")
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Size.iconButtonSm, height: Theme.Size.iconButtonSm)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .focused($focusedAction, equals: .more)
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }
}

// MARK: - 曲目行列宽（随断点降级）

struct TrackRowMetrics {
    let sizeClass: LayoutSizeClass

    /// 序号列（hover → 播放图标，当前 → 频谱）
    var index: CGFloat { sizeClass == .w0 ? 32 : 40 }
    /// 封面列（列表模式）
    var cover: CGFloat { 40 }
    var showsCover: Bool { sizeClass >= .w2 }
    /// 专辑列
    var album: CGFloat? { sizeClass >= .w3 ? 200 : nil }
    /// 操作列（收藏 + 更多）
    var actions: CGFloat { 62 }
    /// 时长列
    var duration: CGFloat { sizeClass == .w0 ? 48 : 64 }
    var rowHeight: CGFloat { Theme.Size.listRowHeight }
    var horizontalPadding: CGFloat { sizeClass == .w0 ? 8 : 12 }
}

// MARK: - 纸墨列表行（§4.4 两种：标题弹性行 / 定宽对齐列）

/// 纸墨曲目行的两种形态（§4.4）。
///
/// 两种的差别只在**列宽怎么定**：`.leaderDots` 是「标题弹性 + 艺人定宽列」（详情表 / 队列 /
/// Top10 这类可变长内容），`.alignedTable` 是「专辑 + 艺人都是定宽列」（资料库列表视图 §6.3）。
///
/// 名字里的 `leaderDots` 是历史：这一行原本还会画 v4 的「点线引导」，
/// 2026-10-14 用户裁决撤掉点线（「横线太多了」，见 `PaperTrackRow` 内的注释），
/// 行几何完全没变，所以保留旧名不做大面积改名（改名要动 20+ 处注释与文档）。
enum TrackRowStyle {
    case leaderDots
    case alignedTable
}

/// paper 列表行的列宽与行高。表头与行必须同源取值，否则列会错位。
enum PaperRowMetrics {
    /// 序号列（mono 12，右对齐；对齐列下数字不跳动）
    static let index: CGFloat = 32
    static let cover: CGFloat = 40
    static let duration: CGFloat = 56
    /// 操作列（收藏 / 更多，hover 或键盘聚焦才显形）
    static let actions: CGFloat = 62
    /// 详情表行（§4.4「行高 56（详情表）」）
    static let detailRowHeight: CGFloat = 56
    /// 资料库列表 / 队列行（§4.4「48（队列）」）
    static let listRowHeight: CGFloat = 48
}

/// 列表行右端的 VU 迷你段条（§4.5）。
///
/// 单独成视图：`PlaybackProgress` 每 0.5s 发布一次，若由行视图直接观察，整张表
/// （可能上千行）都会跟着 2Hz 重算。观察收在这里，重算范围只剩这一根段条。
struct RowMiniVU: View {
    let isPlaying: Bool
    var width: CGFloat = 64

    @ObservedObject private var progress = MusicPlayerModel.shared.progress

    var body: some View {
        VUMiniProgress(value: ratio, isPlaying: isPlaying)
            .frame(width: width)
    }

    private var ratio: Double {
        guard progress.duration > 0 else { return 0 }
        return min(max(progress.position / progress.duration, 0), 1)
    }
}

/// 纸墨曲目行：曲目列表 / 详情表 / 队列 / 搜索结果共用同一形态。
///
/// 三处调用在 paper 下长得一样，做成一个视图而不是复制三份 —— 点线、左缘红条、
/// ON AIR、VU 段条这四处一旦各写一遍，任何一处的微调都会让同一个「标志性组件」
/// 在三个页面里不一致。
struct PaperTrackRow<Actions: View>: View {
    let track: BaseItemDto
    let index: Int
    var showsIndex = true
    var isCurrent = false
    var isPlaying = false
    var style: TrackRowStyle = .leaderDots
    /// 行高：详情表 56 / 列表与队列 48（§4.4）
    var rowHeight: CGFloat = PaperRowMetrics.listRowHeight
    var horizontalPadding: CGFloat = Theme.Spacing.lg
    /// `.alignedTable` 的「专辑 · 艺人」列宽
    var albumColumnWidth: CGFloat?
    /// 点线行的「艺人」列宽（§4.4 `曲名 …… 艺人 时长`）。
    /// nil = 放不下这么多列（w0 / 队列面板），艺人退回标题下的副标题行，信息不丢
    var artistColumnWidth: CGFloat?
    /// 极窄列（320pt 队列面板 / 迷你播放条降级档）用紧凑徽标，只留红方块
    var compactBadge = false
    /// 宽断点（w3+）把播放次数抽成独立的 mono 列（§3「数字一律 mono + tabular-nums」）
    var showsPlayCount = false
    let onTap: () -> Void
    /// 右端操作列；参数 = 是否显形（hover 或键盘聚焦），保持 v3 的可达性约定
    @ViewBuilder var actions: (_ revealed: Bool) -> Actions

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    if showsIndex || isCurrent {
                        indexColumn
                    }

                    RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                        .frame(width: PaperRowMetrics.cover, height: PaperRowMetrics.cover)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.cover))
                        .paperCoverFrame(true)
                        .padding(.trailing, Theme.Spacing.lg)

                    if style == .leaderDots {
                        // 2026-10-14 用户裁决：列表不再画点线引导（「横线太多了」）。
                        // 点线原本吃掉的那段宽度改成纯弹性空白 —— 标题列 ≤260 + 艺人定宽列 +
                        // 次数 / 时长列的对齐关系与画点线时完全一致，只是不再画点。
                        HStack(spacing: 0) {
                            titleColumn
                            Spacer(minLength: 12)
                        }
                        if let artistColumnWidth {
                            // §4.4 / §6.4：标题之后是「艺人」定宽列，表头同源对齐
                            Text(artistText)
                                .textStyle(.footnote, color: Theme.Paper.ink2)
                                .lineLimit(1)
                                .frame(width: artistColumnWidth, alignment: .leading)
                                .padding(.leading, Theme.Spacing.lg)
                        }
                    } else {
                        titleColumn
                        // 窄断点不给专辑列（与 glass 表格同一降级规则）：320pt 下硬塞 200pt 列
                        // 会把标题挤没，列宽自适应比「对齐」更重要
                        if let albumColumnWidth {
                            Text(albumArtistText)
                                .textStyle(.footnote, color: Theme.Paper.ink2)
                                .lineLimit(1)
                                .frame(width: albumColumnWidth, alignment: .leading)
                                .padding(.leading, Theme.Spacing.lg)
                        }
                    }

                    valueColumn
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .focused($focused)
            // 行信息合并为单元素朗读；收藏 / 更多仍是独立可达元素
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)

            actions(hovered || focused)
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, Theme.Spacing.xs)
        // 用 minHeight 而不是定高：xxLarge 字号下右侧数值允许换行，行高自适应（§8）
        .frame(minHeight: rowHeight)
        .background(rowBackground)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Paper.hairline).frame(height: 1)
        }
        .overlay(alignment: .leading) {
            // 当前行：左缘 3px 信号红条（与 ON AIR 徽标、VU 段条一起，颜色不单独承载信息）
            if isCurrent {
                Rectangle().fill(Theme.brand500).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
    }

    @ViewBuilder
    private var indexColumn: some View {
        Group {
            if isCurrent {
                // 当前曲保留序号并染成信号色（§4.4：印刷品的「正在播放」是圈出来的那一行）
                Text("\(index + 1)")
                    .textStyle(.mono, weight: .bold, color: Theme.brandText)
            } else if hovered || focused {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brandText)
            } else {
                Text("\(index + 1)")
                    .textStyle(.mono, color: Theme.Paper.ink3)
            }
        }
        .frame(width: PaperRowMetrics.index, alignment: .trailing)
        .padding(.trailing, Theme.Spacing.lg)
    }

    private var titleColumn: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(track.name ?? "")
                .textStyle(.body, weight: .semibold,
                           color: isCurrent ? Theme.brandText : Theme.Paper.ink)
                .lineLimit(1)
            // 只有「艺人」列放不下时才把艺人 / 专辑压成副标题行；对齐列则抽成独立列
            if style == .leaderDots, artistColumnWidth == nil, !subtitleText.isEmpty {
                Text(subtitleText)
                    .textStyle(.footnote, color: Theme.Paper.ink2)
                    .lineLimit(1)
            }
        }
        // 有上限地吃掉可用宽度：标题过长时截断（§7 超长标题），不把点线和数值挤出窗口
        .frame(maxWidth: style == .leaderDots ? 260 : .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var valueColumn: some View {
        if isCurrent {
            HStack(spacing: Theme.Spacing.md) {
                OnAirBadge(isPlaying: isPlaying, compact: compactBadge)
                RowMiniVU(isPlaying: isPlaying)
            }
            .padding(.leading, Theme.Spacing.lg)
        } else {
            HStack(spacing: 0) {
                if showsPlayCount, let count = track.userData?.playCount, count > 0 {
                    Text("\(count) 次")
                        .textStyle(.mono, color: Theme.Paper.ink3)
                        .padding(.trailing, Theme.Spacing.lg)
                }
                Text(formatPlaybackTime(track.runtimeSeconds))
                    .textStyle(.mono, color: Theme.Paper.ink2)
                    .frame(width: PaperRowMetrics.duration, alignment: .trailing)
            }
            .padding(.leading, Theme.Spacing.lg)
        }
    }

    private var rowBackground: Color {
        // 当前行底 = 信号红 8%（§2.1：红只属于声音）
        if isCurrent { return Theme.Paper.signalTint }
        if hovered { return Theme.Paper.hover }
        return .clear
    }

    /// 点线行副标题：艺人 · 专辑（播放次数在宽断点是独立的 mono 列）
    private var subtitleText: String {
        var parts: [String] = []
        if let artist = track.albumArtist, !artist.isEmpty {
            parts.append(artist)
        } else if let album = track.album, !album.isEmpty {
            parts.append(album)
        }
        if let album = track.album, !album.isEmpty, album != track.albumArtist {
            parts.append(album)
        }
        if !showsPlayCount, let count = track.userData?.playCount, count > 0 {
            parts.append("播放 \(count) 次")
        }
        return parts.joined(separator: " · ")
    }

    private var albumArtistText: String {
        [track.albumArtist, track.album]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// 点线行「艺人」列的文字（没有 albumArtist 时退回专辑名，避免出现空列）
    private var artistText: String {
        if let artist = track.albumArtist, !artist.isEmpty { return artist }
        return track.album ?? ""
    }

    private var accessibilityLabel: String {
        var parts: [String] = []
        if showsIndex { parts.append("第 \(index + 1) 首") }
        parts.append(track.name ?? "未知曲目")
        let sub = style == .alignedTable ? albumArtistText : (artistColumnWidth == nil ? subtitleText : artistText)
        if !sub.isEmpty { parts.append(sub) }
        parts.append(formatPlaybackTime(track.runtimeSeconds))
        if isCurrent { parts.append(isPlaying ? "播放中" : "已暂停") }
        return parts.joined(separator: "，")
    }
}

/// paper 点线行的「艺人」列宽（§4.4 / §6.4）。
///
/// w0（内容列可低至 320pt）整列不出现 —— 硬塞 120pt 艺人列会让曲名只剩十几个点，
/// 这时艺人退回标题下的副标题行。表头与行都用这条规则，列才不会错位。
extension LayoutSizeClass {
    var paperArtistColumnWidth: CGFloat? {
        switch self {
        case .w0: return nil
        case .w1: return 120
        default: return 160
        }
    }
}

// MARK: - 列表模式曲目行（高 48；选中 = surfaceSelected + 3pt 指示条 + 主色标题）

struct MusicRow: View {
    let track: BaseItemDto
    let index: Int
    let metrics: TrackRowMetrics
    var isCurrent = false
    var isPlaying = false
    /// 纸墨变体（§4.4）：资料库列表视图由 pages 显式传 `.alignedTable`（§6.3 定宽对齐列），
    /// 其余调用点（搜索歌曲组 / 播放列表详情 / DiscoverPages）保持默认点线行
    var rowStyle: TrackRowStyle = .leaderDots
    var onRemove: (() -> Void)?
    var onTap: () -> Void

    @State private var hovered = false
    @FocusState private var rowFocused: Bool

    var body: some View {
        if Theme.isPaper {
            paperRow
        } else {
            glassBody
        }
    }

    /// glass（v3）形态：与改动前逐字一致，paper 分支不得改这里的任何取值
    private var glassBody: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    indexColumn

                    if metrics.showsCover {
                        RemoteImage(url: track.artworkURL(width: 96), contentMode: .fill)
                            .frame(width: metrics.cover, height: metrics.cover)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .padding(.trailing, Theme.Spacing.lg)
                    }

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name ?? "")
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

                    if let albumWidth = metrics.album {
                        Text(track.album ?? "")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                            .frame(width: albumWidth, alignment: .leading)
                            .padding(.trailing, Theme.Spacing.md)
                    }

                    Text(formatPlaybackTime(track.runtimeSeconds))
                        .textStyle(.mono, color: Theme.textSecondary)
                        .frame(width: metrics.duration, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .focused($rowFocused)
            // 行信息合并为单元素朗读；收藏 / 更多仍是独立可达元素
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)

            TrackRowActions(
                track: track,
                revealed: hovered || rowFocused,
                onInfo: nil,
                onRemove: onRemove
            )
            // 移除按钮会多占一档宽度
            .frame(width: metrics.actions + (onRemove == nil ? 0 : Theme.Size.iconButtonSm + 2))
        }
        .padding(.horizontal, metrics.horizontalPadding)
        .frame(height: metrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(rowBackground)
        )
        .overlay(alignment: .leading) {
            // 当前行：左侧 3pt 主色指示条
            if isCurrent {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.brand500)
                    .frame(width: 3, height: metrics.rowHeight - 14)
                    .padding(.leading, 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
        .contextMenu { contextMenuItems }
    }

    /// paper 形态（§4.4）：点线行 / 定宽对齐列两种，行间由 `PaperTrackRow` 画 hairline
    private var paperRow: some View {
        PaperTrackRow(
            track: track,
            index: index,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            style: rowStyle,
            rowHeight: metrics.rowHeight,
            horizontalPadding: metrics.horizontalPadding,
            albumColumnWidth: rowStyle == .alignedTable ? metrics.album : nil,
            // §4.4/§6.4：点线行右侧是「艺人」定宽列（w0 放不下时退回副标题）
            artistColumnWidth: rowStyle == .leaderDots ? metrics.sizeClass.paperArtistColumnWidth : nil,
            // 极窄档（w0，内容列可低至 320pt）用紧凑徽标：完整的 ON AIR 灯牌要 ~48pt，
            // 加上 VU 段条 64pt 会把标题挤到只剩十几个点
            compactBadge: metrics.sizeClass == .w0,
            // 宽断点（w3+，glass 下才有专辑列）才把播放次数抽成 mono 列
            showsPlayCount: metrics.album != nil,
            onTap: onTap
        ) { revealed in
            TrackRowActions(
                track: track,
                revealed: revealed,
                onInfo: nil,
                onRemove: onRemove
            )
            // 移除按钮会多占一档宽度
            .frame(width: metrics.actions + (onRemove == nil ? 0 : Theme.Size.iconButtonSm + 2))
        }
        .contextMenu { contextMenuItems }
    }

    @ViewBuilder
    private var indexColumn: some View {
        // 只可能显示一个分支，不需要 ZStack 撑一层容器
        Group {
            if isCurrent {
                EqualizerBars(
                    active: isPlaying,
                    color: Theme.brandText,
                    barWidth: 2.5,
                    height: 12
                )
            } else if hovered || rowFocused {
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brandText)
            } else {
                Text("\(index + 1)")
                    .textStyle(.mono, color: Theme.textTertiary)
            }
        }
        .frame(width: metrics.index, alignment: .leading)
        .padding(.trailing, Theme.Spacing.sm)
    }

    private var rowBackground: Color {
        if isCurrent { return Theme.surfaceSelected }
        if hovered { return Theme.surfaceHover }
        return .clear
    }

    private var subtitle: String {
        var parts: [String] = []
        if let sub = track.albumArtist ?? track.album, !sub.isEmpty {
            parts.append(sub)
        }
        if metrics.album == nil, let album = track.album, album != track.albumArtist {
            parts.append(album)
        }
        if let count = track.userData?.playCount, count > 0 {
            parts.append("播放 \(count) 次")
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        var parts = ["第 \(index + 1) 首", track.name ?? "未知曲目"]
        if let artist = track.albumArtist ?? track.album { parts.append(artist) }
        parts.append(formatPlaybackTime(track.runtimeSeconds))
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        Button {
            MusicPlayerModel.shared.playNext(track)
            ToastCenter.shared.show("已设为下一首播放", systemImage: "arrow.up.circle")
        } label: {
            Label("下一首播放", systemImage: "arrow.up.circle")
        }
        Button {
            MusicPlayerModel.shared.enqueue([track])
            ToastCenter.shared.show("已添加到播放队列", systemImage: "text.badge.plus")
        } label: {
            Label("添加到队列", systemImage: "text.badge.plus")
        }
        Button {
            Task { await MusicDataStore.shared.toggleFavorite(track) }
        } label: {
            Label(track.userData?.isFavorite == true ? "取消收藏" : "收藏",
                  systemImage: track.userData?.isFavorite == true ? "heart.slash" : "heart")
        }
    }
}

// MARK: - 详情页曲目表（行高 44；表头吸顶；序号 hover → 播放；当前曲指示条）

/// 曲目表表头（§2.3「表头吸顶」）。
///
/// 放在 `LazyVStack(pinnedViews: [.sectionHeaders])` 的 `Section` header 位上即可吸顶；
/// 吸顶表头按 §7.2 规则 4 用 `glass.thick`（滚动内容从下面穿过时必须不透明）。
struct TrackTableHeader: View {
    let sizeClass: LayoutSizeClass
    var showsArtist = false

    var body: some View {
        if Theme.isPaper {
            paperHeader
        } else {
            glassBody
        }
    }

    /// glass（v3）形态：与改动前逐字一致
    private var glassBody: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 56, alignment: .leading)
            Text("标题")
                .frame(maxWidth: .infinity, alignment: .leading)
            if showsArtist {
                Text("艺人")
                    .frame(width: 180, alignment: .leading)
            }
            Color.clear.frame(width: 62, height: 1)
            Text("时长")
                .frame(width: 64, alignment: .trailing)
        }
        .textStyle(.caption, weight: .semibold, color: Theme.textTertiary)
        .padding(.horizontal, 16)
        .frame(height: 36)
        .glassPanel(.thick, cornerRadius: 0, elevation: nil)
        .accessibilityHidden(true)
    }

    /// paper 表头（§6.4「表头：caption 级 + 细线」）：列宽与 `PaperTrackRow` 同源，
    /// 因此「时长」列的右边缘与行的时长列严格对齐（行右侧还留着 62pt 操作列）
    private var paperHeader: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: PaperRowMetrics.index, alignment: .trailing)
                .padding(.trailing, Theme.Spacing.lg)
            Color.clear.frame(width: PaperRowMetrics.cover, height: 1)
                .padding(.trailing, Theme.Spacing.lg)
            Text("标题")
                .frame(maxWidth: .infinity, alignment: .leading)
            if let artistWidth = sizeClass.paperArtistColumnWidth {
                // §6.4 表头含「艺人」列：与行同源取值，点线行右侧的艺人名才会落在表头正下方
                Text("艺人")
                    .frame(width: artistWidth, alignment: .leading)
                    .padding(.leading, Theme.Spacing.lg)
            }
            Text("时长")
                .frame(width: PaperRowMetrics.duration, alignment: .trailing)
                .padding(.leading, Theme.Spacing.lg)
            Color.clear.frame(width: PaperRowMetrics.actions, height: 1)
        }
        .textStyle(.caption, weight: .semibold, color: Theme.Paper.ink3)
        .tracking(0.66)
        .padding(.horizontal, Theme.Spacing.xl)
        .frame(height: 32)
        // 吸顶表头必须有底：纸面 canvas（滚动内容从下面穿过时不能透出来）
        .background(Theme.Paper.canvas)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.Paper.hairlineStrong).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

/// 曲目行集合（不含表头，供详情页拼进吸顶 Section）
struct TrackTableRows: View {
    let tracks: [BaseItemDto]
    let sizeClass: LayoutSizeClass
    var showsArtist = false
    let onTap: (Int) -> Void

    @ObservedObject private var music = MusicPlayerModel.shared

    var body: some View {
        // 用 indices + 下标，而不是 `Array(tracks.enumerated())`：
        // 后者每次渲染都要物化一个 (offset, BaseItemDto) 元组数组 —— BaseItemDto 约 272 字节，
        // 整库（数千首）就是每次渲染 1MB 级别的 memcpy 加逐元素 ARC 保留/释放（实测 1 万条约 1ms）。
        // 这里的 ForEach 只用于渲染行，位置即身份，不依赖稳定 id 做增删动画。
        ForEach(tracks.indices, id: \.self) { index in
            TrackTableRow(
                track: tracks[index],
                index: index,
                sizeClass: sizeClass,
                isCurrent: music.currentTrack?.id == tracks[index].id,
                isPlaying: music.isPlaying && music.currentTrack?.id == tracks[index].id,
                showArtist: showsArtist,
                onTap: { onTap(index) }
            )
            if index < tracks.count - 1 {
                if Theme.isPaper {
                    // paper 点线行自带底部 hairline（`PaperTrackRow`），这里不再画一条，否则成双线
                    EmptyView()
                } else {
                    Rectangle()
                        .fill(Theme.borderSubtle)
                        .frame(height: 1)
                        .padding(.leading, 56)
                }
            }
        }
    }
}

/// 表头 + 曲目行（非吸顶场景的便捷组合）
struct TrackTable: View {
    let tracks: [BaseItemDto]
    let sizeClass: LayoutSizeClass
    /// 是否显示副标题（艺术家）
    var showArtist = false
    var showHeader = true
    var onTap: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if showHeader { TrackTableHeader(sizeClass: sizeClass, showsArtist: showArtist) }
            TrackTableRows(tracks: tracks, sizeClass: sizeClass, showsArtist: showArtist, onTap: onTap)
        }
    }
}

private struct TrackTableRow: View {
    let track: BaseItemDto
    let index: Int
    let sizeClass: LayoutSizeClass
    let isCurrent: Bool
    let isPlaying: Bool
    let showArtist: Bool
    let onTap: () -> Void

    @State private var hovered = false
    @FocusState private var rowFocused: Bool

    var body: some View {
        if Theme.isPaper {
            paperRow
        } else {
            glassBody
        }
    }

    /// glass（v3）形态：与改动前逐字一致
    private var glassBody: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 0) {
                    ZStack {
                        if isCurrent {
                            EqualizerBars(active: isPlaying, color: Theme.brand500, barWidth: 2.5, height: 12)
                        } else if hovered || rowFocused {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.brandText)
                        } else {
                            Text("\(index + 1)")
                                .textStyle(.mono, color: Theme.textTertiary)
                        }
                    }
                    .frame(width: 56, alignment: .leading)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.name ?? "")
                            .textStyle(.bodySM, weight: isCurrent ? .semibold : .regular,
                                       color: isCurrent ? Theme.brandText : Theme.textPrimary)
                            .lineLimit(1)
                        if showArtist, let artist = track.albumArtist ?? track.album, !artist.isEmpty {
                            Text(artist)
                                .textStyle(.caption, color: Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if showArtist {
                        Text(track.album ?? "")
                            .textStyle(.caption, color: Theme.textSecondary)
                            .lineLimit(1)
                            .frame(width: 180, alignment: .leading)
                    }

                    Text(formatPlaybackTime(track.runtimeSeconds))
                        .textStyle(.mono, color: Theme.textSecondary)
                        .frame(width: 64, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .focused($rowFocused)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)

            TrackRowActions(track: track, revealed: hovered || rowFocused)
                .frame(width: 62)
        }
        .padding(.horizontal, 16)
        .frame(height: Theme.Size.trackRowHeight)
        .background(rowBackground)
        .overlay(alignment: .leading) {
            if isCurrent {
                Rectangle().fill(Theme.brand500).frame(width: 3)
            }
        }
        .contentShape(Rectangle())
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
        .contextMenu {
            Button {
                MusicPlayerModel.shared.playNext(track)
                ToastCenter.shared.show("已设为下一首播放", systemImage: "arrow.up.circle")
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            Button {
                MusicPlayerModel.shared.enqueue([track])
                ToastCenter.shared.show("已添加到播放队列", systemImage: "text.badge.plus")
            } label: {
                Label("添加到队列", systemImage: "text.badge.plus")
            }
        }
    }

    /// paper 形态（§4.4「行高 56（详情表）」）：点线行 + 表头细线，
    /// 当前曲把时长列换成 ON AIR 徽标 + VU 迷你段条
    private var paperRow: some View {
        PaperTrackRow(
            track: track,
            index: index,
            isCurrent: isCurrent,
            isPlaying: isPlaying,
            rowHeight: PaperRowMetrics.detailRowHeight,
            horizontalPadding: Theme.Spacing.xl,
            artistColumnWidth: sizeClass.paperArtistColumnWidth,
            // w0（内容列可低至 320pt）：详情表也在窄列里，徽标同样降级成红方块
            compactBadge: sizeClass == .w0,
            onTap: onTap
        ) { revealed in
            TrackRowActions(track: track, revealed: revealed)
                .frame(width: PaperRowMetrics.actions)
        }
        .contextMenu {
            Button {
                MusicPlayerModel.shared.playNext(track)
                ToastCenter.shared.show("已设为下一首播放", systemImage: "arrow.up.circle")
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            Button {
                MusicPlayerModel.shared.enqueue([track])
                ToastCenter.shared.show("已添加到播放队列", systemImage: "text.badge.plus")
            } label: {
                Label("添加到队列", systemImage: "text.badge.plus")
            }
        }
    }

    private var rowBackground: Color {
        if isCurrent { return Theme.surfaceSelected }
        if hovered { return Theme.surfaceHover }
        return .clear
    }

    private var accessibilityLabel: String {
        var parts = ["第 \(index + 1) 首", track.name ?? "未知曲目"]
        if let artist = track.albumArtist { parts.append(artist) }
        parts.append(formatPlaybackTime(track.runtimeSeconds))
        return parts.joined(separator: "，")
    }
}

// MARK: - 播放列表卡片（前 4 首封面拼图 + 名称 + 曲目数）

struct PlaylistCard: View {
    let playlist: Playlist
    var width: CGFloat = 320
    let onTap: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    /// 播放列表自身的变化（增删 / 排序 / 重命名）也走 `revision`，用它做封面缓存失效
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var hovered = false
    /// 封面拼图的 4 首曲目缓存：数据变化时重算一次
    @State private var coverTracks: [BaseItemDto] = []
    @Environment(\.appReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    /// 智能列表与手动列表一致：取匹配结果前 4 首的封面拼图。
    ///
    /// 这里必须缓存：`coverTracks` 在一次 body 里会被读 5 次（1 次判空 + 4 张缩略图），
    /// 若做成计算属性，每次都要把整个 `trackIds`（可能上千条）过一遍字典查找 ——
    /// 单次渲染 5×N 次查找，而卡片会因悬停、曲库发布、播放列表同步反复重渲染。
    private func recomputeCoverTracks() {
        if playlist.isSmart {
            guard let keyword = playlist.smartRule?.artistKeyword else {
                coverTracks = []
                return
            }
            coverTracks = Array(store.smartTracks(keyword: keyword).prefix(4))
            return
        }
        // 取满 4 首即停：与「全量 compactMap 后 prefix(4)」结果一致，
        // 但命中时只做 4 次查找（曲目 id 失效时会继续往后找，语义不变）
        var picked: [BaseItemDto] = []
        picked.reserveCapacity(4)
        for id in playlist.trackIds {
            guard let track = store.track(id: id) else { continue }
            picked.append(track)
            if picked.count == 4 { break }
        }
        coverTracks = picked
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md))
                    // paper：印刷套封（§4.6）
                    .paperCoverFrame(Theme.isPaper)
                    .elevation(hovered ? .e2 : .e1, cornerRadius: Theme.Radius.md)
                    .overlay {
                        if hovered || focused {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md)
                                    .fill(Theme.coverScrim)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }
                    // paper 不用上浮（§4.6）：hover 下沉 1px 的活版按压感
                    .offset(y: Theme.isPaper && hovered && !reduceMotion ? 1 : 0)

                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .textStyle(Theme.isPaper ? .body : .bodySM, weight: .semibold, color: Theme.textPrimary)
                        // 列表名走衬线（§6.5 播放列表行用衬线大标题）
                        .fontDesign(Theme.isPaper ? .serif : .default)
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.sm) {
                        // §6.5：智能列表用泛音青小方点、本地列表用 ink-3 方点 —— 同步状态
                        // 同时有彩色点 + 文字，颜色不单独承载信息
                        if Theme.isPaper {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(playlist.isSmart ? Theme.Paper.teal : Theme.Paper.ink3)
                                .frame(width: 7, height: 7)
                        }
                        Text(subtitle)
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        // hover 上浮用 micro（120ms）而不是 0.35s 弹簧：卡片有 2pt 位移 + 阴影换挡，
        // 弹簧尾巴要跑 1s 以上，实测悬停一张卡片会让主线程连续出帧 1.7s。
        // 位移只有 2pt，120ms 已经足够顺，且"跟手"感更好。
        .animation(Theme.Motion.micro, value: hovered)
        .onHover { hovered = $0 }
        .task { recomputeCoverTracks() }
        // 都是 O(1) 变更检测：`onChange(of: store.tracks)` 每次 body 更新都要比较整个曲库。
        // 播放列表侧用 revision 而不是 trackIds.count —— 后者漏掉「重排顺序」
        // （前 4 首会变，但数量不变，封面就停在旧数据上了）
        .onChange(of: store.dataRevision) { _ in recomputeCoverTracks() }
        .onChange(of: playlistStore.revision) { _ in recomputeCoverTracks() }
        .help(playlist.name)
    }

    private var subtitle: String {
        if playlist.isSmart { return "智能播放列表" }
        let count = playlist.trackIds.count
        return count > 0 ? "\(count) 首曲目" : "空播放列表"
    }

    @ViewBuilder
    private var cover: some View {
        if coverTracks.count >= 2 {
            GeometryReader { geo in
                let gap: CGFloat = 2
                let size = (geo.size.width - gap) / 2
                VStack(spacing: gap) {
                    HStack(spacing: gap) {
                        coverThumb(coverTracks[safe: 0], size: size)
                        coverThumb(coverTracks[safe: 1], size: size)
                    }
                    HStack(spacing: gap) {
                        coverThumb(coverTracks[safe: 2], size: size)
                        coverThumb(coverTracks[safe: 3], size: size)
                    }
                }
            }
        } else {
            ZStack {
                Theme.surfaceSunken
                Image(systemName: playlist.isSmart ? "sparkles" : "music.note.list")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(Theme.brandText.opacity(0.5))
            }
        }
    }

    private func coverThumb(_ track: BaseItemDto?, size: CGFloat) -> some View {
        Group {
            if let track {
                RemoteImage(url: track.artworkURL(width: 200), contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipped()
            } else {
                Rectangle()
                    .fill(Theme.surfaceSunken)
                    .frame(width: size, height: size)
            }
        }
    }
}

// MARK: - 播放列表图标（2×2 拼图，详情页头部用）

struct PlaylistCoverMosaic: View {
    let tracks: [BaseItemDto]
    var size: CGFloat
    var cornerRadius: CGFloat = Theme.Radius.lg
    var fallbackIcon: String = "music.note.list"

    var body: some View {
        Group {
            if tracks.count >= 2 {
                GeometryReader { geo in
                    let gap: CGFloat = 2
                    let cell = (geo.size.width - gap) / 2
                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            thumb(tracks[safe: 0], size: cell)
                            thumb(tracks[safe: 1], size: cell)
                        }
                        HStack(spacing: gap) {
                            thumb(tracks[safe: 2], size: cell)
                            thumb(tracks[safe: 3], size: cell)
                        }
                    }
                }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(Theme.brandGradient)
                    Image(systemName: fallbackIcon)
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: size, height: size)
            }
        }
        .elevation(.e2, cornerRadius: cornerRadius)
        // paper：拼图封面同样压印刷套封框（§4.6）
        .paperCoverFrame(Theme.isPaper, cornerRadius: cornerRadius)
    }

    private func thumb(_ track: BaseItemDto?, size: CGFloat) -> some View {
        RemoteImage(url: track?.artworkURL(width: 200), contentMode: .fill)
            .frame(width: size, height: size)
            .clipped()
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
