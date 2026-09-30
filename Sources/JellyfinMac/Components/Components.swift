import SwiftUI

// MARK: - 窗口拖拽区（无边框窗口手动拖动）

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class DragView: NSView {
        /// 锚点式拖拽：记录按下瞬间的鼠标位置与窗口原点，
        /// 之后每次事件都按"相对按下点"的绝对量重算窗口位置。
        /// 不能改成增量式（window.frame.origin + delta）——顶栏区同时存在系统标题栏
        /// 拖拽路径，任何一帧被系统先移动后，增量式会基于被污染的基线继续累加/纠正，
        /// 表现为窗口来回抖动（2026-08-24 定位）。
        private var anchorMouse: NSPoint = .zero
        private var anchorOrigin: NSPoint = .zero

        override func mouseDown(with event: NSEvent) {
            anchorMouse = NSEvent.mouseLocation
            anchorOrigin = window?.frame.origin ?? .zero
        }

        override func mouseDragged(with event: NSEvent) {
            guard let window else { return }
            let current = NSEvent.mouseLocation
            let newOrigin = NSPoint(
                x: anchorOrigin.x + (current.x - anchorMouse.x),
                y: anchorOrigin.y + (current.y - anchorMouse.y)
            )
            window.setFrameOrigin(newOrigin)
        }
    }
}

// MARK: - 均衡器动效（正在播放指示）

/// 三根跳动的频谱柱，TimelineView 驱动（无 Timer 泄漏，暂停时静止）
struct EqualizerBars: View {
    var active: Bool = true
    var color: Color = .white
    var barWidth: CGFloat = 2.5
    var height: CGFloat = 12

    /// 每根柱子的相位偏移，让三根柱子错落跳动
    private let phases: [Double] = [0, 1.7, 3.1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40.0, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: barWidth * 0.8) {
                ForEach(0..<3, id: \.self) { i in
                    Capsule()
                        .fill(color)
                        .frame(width: barWidth, height: barHeight(t: t, phase: phases[i]))
                }
            }
        }
        .frame(height: height)
        .opacity(active ? 1 : 0.35)
        .animation(.easeInOut(duration: 0.25), value: active)
    }

    /// 双正弦叠加，模拟音乐律动（不规则但平滑）
    private func barHeight(t: Double, phase: Double) -> CGFloat {
        let wave = (sin(t * 6.0 + phase) + sin(t * 9.3 + phase * 1.6)) / 2.0
        let ratio = 0.5 + 0.38 * wave // 0.12 ~ 0.88
        return max(height * 0.18, height * ratio)
    }
}

// MARK: - 错落入场动画

/// 列表/网格逐项错落淡入上浮：扁平风的"轻"入场
struct StaggerAppear: ViewModifier {
    let index: Int
    var maxDelay: Double = 0.3
    var visible: Bool = true

    func body(content: Content) -> some View {
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .animation(
                .easeOut(duration: 0.32).delay(Double(min(index, 12)) / 12.0 * maxDelay),
                value: visible
            )
    }
}

extension View {
    func staggerAppear(index: Int, maxDelay: Double = 0.3) -> some View {
        modifier(StaggerAppear(index: index, maxDelay: maxDelay))
    }
}

// MARK: - 圆形图标按钮（悬停浮现底色 + 按压回弹）

struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = 30
    var iconColor: Color = Theme.secondaryText
    var background: Color = Theme.hoverFill

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.45))
            .foregroundStyle(iconColor)
            .frame(width: size, height: size)
            .background(Circle().fill(background))
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(Theme.micro, value: configuration.isPressed)
    }
}

// MARK: - 首击穿透

/// 注意：本视图（作为按钮的 background）在当前 macOS 上并不会被命中——
/// SwiftUI 的 hosting view 拦截了按钮区域的 hit-test，acceptsFirstMouse
/// 永远不会被询问，因此"未激活窗口需点两次"的问题由 AppDelegate 的
/// 窗口级点击穿透 monitor（先激活窗口再直接投递命中视图）统一解决。
/// 这里保留 acceptClickThrough() 仅为历史兼容，实际不再生效。
private final class ClickThroughView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

struct AcceptClickThrough: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ClickThroughView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// 让控件在窗口未激活时也能响应第一次点击（贴近按钮使用，勿加在滚动容器上）
    func acceptClickThrough() -> some View {
        background(AcceptClickThrough())
    }
}

// MARK: - 扁平输入框

struct FlatFieldBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

// MARK: - 页面头

/// 列表页统一头部：大标题 + 元信息，右侧放操作按钮；兼作窗口拖拽区
struct PageHeader<Actions: View>: View {
    let title: String
    var meta: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                if let meta, !meta.isEmpty {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
            }
            Spacer()
            actions()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowDragArea())
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, meta: String? = nil) {
        self.init(title: title, meta: meta) { EmptyView() }
    }
}

// MARK: - 返回导航行（设计稿专辑详情顶栏）

/// 返回按钮 + 窗口拖拽区 + 底部分隔线
struct BackBar: View {
    let label: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Theme.secondaryText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .acceptClickThrough()
            .help("返回\(label)")
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(WindowDragArea().background(Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

// MARK: - 分段控件（设计稿：描边容器 + 主色激活段）

struct SegmentedControl: View {
    struct Segment: Identifiable {
        let id: String
        let title: String

        init(_ id: String, _ title: String) {
            self.id = id
            self.title = title
        }
    }

    let segments: [Segment]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let isSelected = segment.id == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        selection = segment.id
                    }
                } label: {
                    Text(segment.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? .white : Theme.secondaryText)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isSelected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.clear))
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }
}

// MARK: - 按钮样式

/// 主操作按钮：主色实底 + 白字（设计稿「播放」）
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(Theme.accentGradient)
                    .opacity(isEnabled ? 1 : 0.45)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.micro, value: configuration.isPressed)
    }
}

/// 次级操作按钮：描边白底（设计稿「随机播放」）
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.primaryText)
            .padding(.horizontal, 20)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.border))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.micro, value: configuration.isPressed)
    }
}

// MARK: - 通用小部件

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Theme.primaryText)
    }
}

/// 标签胶囊（设计稿专辑详情流派标签：描边 + 浅字）
struct Chip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.border))
    }
}

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
}

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
        .animation(.easeOut(duration: 0.28), value: image == nil)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            image = await ImageCache.shared.image(for: url)
        }
    }

    /// 扁平占位图：浅灰渐变 + 极淡图标（设计稿 surface → surface-2）
    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xF9FAFB), Color(hex: 0xF3F4F6)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "music.note")
                .font(.system(size: 20))
                .foregroundStyle(Color(hex: 0xC7C7CC))
        }
    }
}

// MARK: - 专辑卡片（设计稿资料库网格）

/// 方形封面 + 标题 + 副标题；悬停轻微上浮 + 播放角标（自适应网格弹性宽度）
struct PosterCard: View {
    let item: BaseItemDto
    /// 仅用于请求合适分辨率的封面图
    var width: CGFloat = 320
    var posterAspect: CGFloat = 1.0
    var onTap: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        Button {
            onTap?()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                RemoteImage(url: item.artworkURL(width: Int(width)), contentMode: .fill)
                    .aspectRatio(posterAspect, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
                    .shadow(color: Theme.cardShadow, radius: 4, y: 2)
                    // 悬停：封面变暗 + 中央播放按钮
                    .overlay {
                        if hovered {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.radiusMd)
                                    .fill(Color.black.opacity(0.32))
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .transition(.opacity)
                        }
                    }

                Text(item.name ?? "未知标题")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(y: hovered ? -2 : 0)
        .shadow(color: Theme.hoverShadow, radius: hovered ? 10 : 0, y: hovered ? 6 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: hovered)
        .onHover { hovered = $0 }
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

// MARK: - 曲目表格（设计稿专辑详情曲目列表）

/// 描边圆角表格：序号列悬停变播放、当前曲目主色高亮；行内保留收藏/更多操作
struct TrackTable: View {
    let tracks: [BaseItemDto]
    /// 是否显示副标题（艺术家）——资料库歌曲视图用
    var showArtist = false
    /// 是否显示表头
    var showHeader = true
    var onTap: (Int) -> Void

    @ObservedObject private var music = MusicPlayerModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                headerRow
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            LazyVStack(spacing: 0) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    row(track: track, index: index)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg).strokeBorder(Theme.border))
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("#")
                .frame(width: 56)
            Text("标题")
                .frame(maxWidth: .infinity, alignment: .leading)
            // 预留悬停操作列宽度，与行内操作列对齐
            Color.clear.frame(width: 72, height: 1)
            Text("时长")
                .frame(width: 72, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.secondaryText)
        .padding(.vertical, 10)
        .padding(.trailing, 16)
        .background(Theme.surface)
    }

    private func row(track: BaseItemDto, index: Int) -> some View {
        TrackTableRow(
            track: track,
            index: index,
            isCurrent: music.currentTrack?.id == track.id,
            isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
            showArtist: showArtist,
            onTap: { onTap(index) }
        )
    }
}

/// 单行曲目：序号 ⇄ 播放图标切换、当前行主色高亮、悬停浮现收藏/更多
private struct TrackTableRow: View {
    let track: BaseItemDto
    let index: Int
    let isCurrent: Bool
    let isPlaying: Bool
    let showArtist: Bool
    let onTap: () -> Void

    @ObservedObject private var playlists = PlaylistStore.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            // 主区（序号/标题/时长）：点击播放；Button 保证键盘与 VoiceOver 可激活
            Button(action: onTap) {
                HStack(spacing: 0) {
                    // 序号列：默认序号，悬停换播放图标，当前曲目显示音量图标
                    ZStack {
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accentText)
                        } else if hovered {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.accentText)
                                .transition(.opacity)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.secondaryText)
                                .transition(.opacity)
                        }
                    }
                    .frame(width: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.name ?? "")
                            .font(.system(size: 13, weight: isCurrent ? .semibold : .regular))
                            .foregroundStyle(isCurrent ? Theme.accentText : Theme.primaryText)
                            .lineLimit(1)
                        if showArtist, let artist = track.albumArtist ?? track.album, !artist.isEmpty {
                            Text(artist)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Text(formatPlaybackTime(track.runtimeSeconds))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 72, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 悬停操作：收藏 + 更多（保留原功能入口）
            HStack(spacing: 2) {
                if hovered {
                    favoriteButton
                        .transition(.opacity)
                    overflowMenu
                        .transition(.opacity)
                } else {
                    Color.clear.frame(width: 60, height: 1)
                }
            }
            .frame(width: 72)
        }
        .padding(.vertical, 9)
        .padding(.leading, 0)
        .padding(.trailing, 16)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(rowBackground)
        )
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }

    private var rowBackground: Color {
        if isCurrent { return Theme.selectedFill }
        if hovered { return Theme.hoverFill }
        return .clear
    }

    private var favoriteButton: some View {
        let isFavorite = track.userData?.isFavorite == true
        return Button {
            Task { await MusicDataStore.shared.toggleFavorite(track) }
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: 11))
                .foregroundStyle(isFavorite ? Color(hex: 0xFF5C8A) : Theme.secondaryText)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(isFavorite ? "取消收藏" : "收藏")
        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏")
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                MusicPlayerModel.shared.playNext(track)
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            Button {
                MusicPlayerModel.shared.enqueue([track])
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
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多操作")
        .accessibilityLabel("更多操作")
    }
}

// MARK: - 时间格式化

func formatPlaybackTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

func formatRuntime(_ seconds: Double) -> String {
    let total = Int(seconds)
    if total >= 3600 { return "\(total / 3600)小时\(total % 3600 / 60)分钟" }
    if total >= 60 { return "\(total / 60)分钟" }
    return "\(total)秒"
}

/// 曲目集合总时长（页面头元信息用）：小时为单位紧凑显示
func formatTotalDuration(_ seconds: Double) -> String {
    let hours = seconds / 3600
    if hours >= 10 { return String(format: "%.0f 小时", hours) }
    if hours >= 1 { return String(format: "%.1f 小时", hours) }
    return "\(Int(seconds / 60)) 分钟"
}

// MARK: - 全局键盘快捷键

/// 本地按键监听：空格 播放/暂停、⌘F 聚焦搜索、⌘→/⌘← 上下曲
/// 焦点在文本输入框（搜索/表单）时除 ⌘F 外全部放行给输入框
struct KeyboardShortcutHandler: NSViewRepresentable {
    var onSpace: () -> Void
    var onNext: () -> Void
    var onPrevious: () -> Void
    var onFocusSearch: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.actions = (
            space: onSpace,
            next: onNext,
            previous: onPrevious,
            focusSearch: onFocusSearch
        )
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            coordinator?.handle(event) ?? event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.actions = (
            space: onSpace,
            next: onNext,
            previous: onPrevious,
            focusSearch: onFocusSearch
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var monitor: Any?
        var actions: (space: () -> Void, next: () -> Void, previous: () -> Void, focusSearch: () -> Void)!

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }

        func handle(_ event: NSEvent) -> NSEvent? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isTyping = isTextInputFocused

            // ⌘F：任何场景都聚焦搜索
            if event.charactersIgnoringModifiers?.lowercased() == "f", flags == .command {
                actions.focusSearch()
                return nil
            }

            guard !isTyping else { return event }

            // 空格：播放/暂停（无修饰键）
            if event.charactersIgnoringModifiers == " ", flags.isEmpty {
                actions.space()
                return nil
            }
            // ⌘→ / ⌘←：下一曲 / 上一曲
            if flags == .command {
                if event.keyCode == 124 { actions.next(); return nil }
                if event.keyCode == 123 { actions.previous(); return nil }
            }
            return event
        }

        /// 首响应者是 NSTextView（TextField/SecureField 的底层）时视为正在输入
        private var isTextInputFocused: Bool {
            NSApplication.shared.keyWindow?.firstResponder is NSTextView
        }
    }
}
