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
        if let image = cache[key] { return image }

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
        guard let data, let image = NSImage(data: data) else { return nil }
        store(image: image, key: key)
        return image
    }

    private func store(image: NSImage, key: String) {
        cache[key] = image
        order.append(key)
        if order.count > 400 {
            let oldest = order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

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
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholder
                    .transition(.opacity)
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

    var body: some View {
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
            .focusRing(focused, cornerRadius: Theme.Radius.md)
            .help("打开 \(item.name ?? "专辑")")
            .accessibilityLabel("\(item.name ?? "未知标题")，\(subtitle)")

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name ?? "未知标题")
                    .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .textStyle(.footnote, color: Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        .animation(Theme.Motion.spring, value: hovered)
        .onHover { hovered = $0 }
    }

    private var cover: some View {
        RemoteImage(url: item.artworkURL(width: Int(width)), contentMode: .fill)
            .aspectRatio(posterAspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .elevation(hovered ? .e2 : .e1)
            .overlay {
                // hover / 键盘聚焦：压暗 + 中央播放角标
                if hovered || focused {
                    ZStack {
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .fill(Theme.coverScrim)
                        Image(systemName: "play.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .transition(.opacity)
                    .allowsHitTesting(false)
                }
            }
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

                Text(artist.name ?? "未知艺术家")
                    .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.md)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        .animation(Theme.Motion.spring, value: hovered)
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

// MARK: - 列表模式曲目行（高 48；选中 = surfaceSelected + 3pt 指示条 + 主色标题）

struct MusicRow: View {
    let track: BaseItemDto
    let index: Int
    let metrics: TrackRowMetrics
    var isCurrent = false
    var isPlaying = false
    var onRemove: (() -> Void)?
    var onTap: () -> Void

    @State private var hovered = false
    @FocusState private var rowFocused: Bool

    var body: some View {
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

    @ViewBuilder
    private var indexColumn: some View {
        ZStack {
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
}

/// 曲目行集合（不含表头，供详情页拼进吸顶 Section）
struct TrackTableRows: View {
    let tracks: [BaseItemDto]
    let sizeClass: LayoutSizeClass
    var showsArtist = false
    let onTap: (Int) -> Void

    @ObservedObject private var music = MusicPlayerModel.shared

    var body: some View {
        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
            TrackTableRow(
                track: track,
                index: index,
                sizeClass: sizeClass,
                isCurrent: music.currentTrack?.id == track.id,
                isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                showArtist: showsArtist,
                onTap: { onTap(index) }
            )
            if index < tracks.count - 1 {
                Rectangle()
                    .fill(Theme.borderSubtle)
                    .frame(height: 1)
                    .padding(.leading, 56)
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
    @State private var hovered = false
    /// 智能列表封面缓存：曲目数据变化时重算，避免每次渲染都全量过滤匹配
    @State private var smartCoverTracks: [BaseItemDto] = []
    @Environment(\.appReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    private var coverTracks: [BaseItemDto] {
        if playlist.isSmart { return smartCoverTracks }
        return Array(playlist.trackIds.compactMap { store.track(id: $0) }.prefix(4))
    }

    /// 智能列表与手动列表一致：取匹配结果前 4 首的封面拼图
    private func recomputeSmartCover() {
        guard playlist.isSmart, let keyword = playlist.smartRule?.artistKeyword else {
            smartCoverTracks = []
            return
        }
        smartCoverTracks = Array(store.smartTracks(keyword: keyword).prefix(4))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                cover
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .elevation(hovered ? .e2 : .e1, cornerRadius: Theme.Radius.md)
                    .overlay {
                        if hovered || focused {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.coverScrim)
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(playlist.name)
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .textStyle(.footnote, color: Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .acceptClickThrough()
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.md)
        .offset(y: Theme.lift(hovered, reduceMotion: reduceMotion))
        .animation(Theme.Motion.spring, value: hovered)
        .onHover { hovered = $0 }
        .task { recomputeSmartCover() }
        .onChange(of: store.tracks) { _ in recomputeSmartCover() }
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
