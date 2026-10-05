import AppKit
import SwiftUI

/// 设置页（§2.4）：左侧分组导航 180 + 右侧表单 480，六组一切换。
///
/// 结构分层：`SettingsView`（窗口骨架 + 分组路由）→ `SettingsGroupCard`（`surface` 实底卡）
/// → `SettingsRow`（左标签 13/500 + 说明 11 + 右控件，行高 ≥44）。
/// 颜色 / 圆角 / 字号一律走 `Theme` 令牌；深色下由 `elevation(.e1, cornerRadius:)` 自动换成描边分层。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = MusicDataStore.shared

    @State private var group: Group = .general
    @State private var isRefreshing = false
    @State private var cacheCleared = false
    @State private var cacheUsage: CacheUsage = .measuring

    /// 六个分组（§2.4：通用 / 播放 / 外观 / 媒体库 / 服务器与账号 / 关于）
    enum Group: String, CaseIterable, Identifiable {
        case general = "通用"
        case playback = "播放"
        case appearance = "外观"
        case library = "媒体库"
        case account = "服务器与账号"
        case about = "关于"

        var id: String { rawValue }

        /// 导航图标（线框图 ▣ ▶ ◐ ▦ ⇄ ⓘ）
        var systemImage: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .playback: return "play.circle"
            case .appearance: return "circle.lefthalf.filled"
            case .library: return "square.grid.2x2"
            case .account: return "server.rack"
            case .about: return "info.circle"
            }
        }
    }

    // MARK: - 窗口骨架

    var body: some View {
        HStack(spacing: 0) {
            navigation

            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(width: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    Text(group.rawValue)
                        .textStyle(.title3, color: Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)

                    groupContent
                }
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.xxxl)
                .frame(maxWidth: Theme.Size.settingsFormWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
        }
        // macOS 标准设置窗口：固定 720×560（§4.5）
        .frame(width: 720, height: 560)
        .background(Theme.canvas)
        // 设置是独立 scene：挂一份共享 `DialogCenter` 的呈现层，让二次确认落在当前窗口。
        // 弹窗 UI 本身在 Components.swift（`ConfirmDialog`），这里只是把它接到设置窗口上。
        .dialogHost()
    }

    // MARK: - 分组导航（180，行高 36 / 圆角 6）

    private var navigation: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ForEach(Group.allCases) { item in
                SettingsNavRow(
                    title: item.rawValue,
                    systemImage: item.systemImage,
                    isSelected: group == item
                ) {
                    group = item
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xl)
        .frame(width: Theme.Size.settingsNavWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.canvas)
    }

    // MARK: - 分组内容

    @ViewBuilder
    private var groupContent: some View {
        switch group {
        case .general: generalGroup
        case .playback: playbackGroup
        case .appearance: appearanceGroup
        case .library: libraryGroup
        case .account: accountGroup
        case .about: aboutGroup
        }
    }

    // MARK: 通用

    private var generalGroup: some View {
        SettingsGroupCard(title: "启动与窗口") {
            SettingsRow(label: "启动时自动连接", detail: "使用已保存的凭据免登录") {
                SettingsSwitch(isOn: $settings.autoConnect, label: "启动时自动连接")
            }
            SettingsRow(label: "默认打开页面", detail: "启动后落到的一级页面") {
                SettingsMenu(
                    selection: settings.startPage.rawValue,
                    options: AppSettings.StartPage.allCases.map(\.rawValue),
                    accessibilityLabel: "默认打开页面"
                ) { settings.startPage = AppSettings.StartPage(rawValue: $0) ?? .home }
            }
            SettingsRow(label: "关闭窗口时继续播放", detail: "关掉窗口不打断当前曲目") {
                SettingsSwitch(isOn: $settings.continuePlayingOnClose, label: "关闭窗口时继续播放")
            }
            SettingsRow(label: "语言", detail: "界面语言（重启后生效）") {
                SettingsMenu(
                    selection: settings.language.rawValue,
                    options: AppSettings.Language.allCases.map(\.rawValue),
                    accessibilityLabel: "界面语言"
                ) { settings.language = AppSettings.Language(rawValue: $0) ?? .system }
            }
        }
    }

    // MARK: 播放

    private var playbackGroup: some View {
        SettingsGroupCard(title: "播放") {
            SettingsRow(label: "音质", detail: settings.quality.detail) {
                SettingsMenu(
                    selection: settings.quality.rawValue,
                    options: AppSettings.Quality.allCases.map(\.rawValue),
                    accessibilityLabel: "音质"
                ) { settings.quality = AppSettings.Quality(rawValue: $0) ?? .original }
            }
            SettingsRow(label: "直连优先", detail: "容器兼容时直接播放原文件，不经过服务器转码") {
                SettingsSwitch(isOn: $settings.preferDirectPlay, label: "直连优先")
            }
            SettingsRow(label: "交叉淡入", detail: "换曲时平滑过渡，0 表示关闭") {
                SettingsSlider(
                    value: $settings.crossfadeSeconds,
                    range: 0...12,
                    step: 0.5,
                    text: Self.crossfadeText(settings.crossfadeSeconds),
                    label: "交叉淡入时长"
                )
            }
            SettingsRow(label: "音量归一化", detail: "统一不同专辑的响度") {
                SettingsSwitch(isOn: $settings.volumeNormalization, label: "音量归一化")
            }
            SettingsRow(label: "进度上报间隔", detail: "多端同步频率") {
                SettingsSlider(
                    value: $settings.reportInterval,
                    range: 5...60,
                    step: 5,
                    text: "\(Int(settings.reportInterval)) 秒",
                    label: "进度上报间隔"
                )
            }
        }
    }

    // MARK: 外观

    private var appearanceGroup: some View {
        SettingsGroupCard(title: "外观") {
            SettingsRow(label: "主题", detail: "浅色 / 深色 / 跟随系统") {
                SegmentedControl(
                    segments: AppSettings.ThemeChoice.allCases.map { .init($0.rawValue, $0.rawValue) },
                    selection: Binding(
                        get: { settings.theme.rawValue },
                        set: { settings.theme = AppSettings.ThemeChoice(rawValue: $0) ?? .light }
                    )
                )
                // 三段中文标签不能被压缩，否则「跟随系统」会被截成「跟…」
                .fixedSize(horizontal: true, vertical: false)
            }
            SettingsRow(label: "强调色", detail: "主色与选中态，切换即时全局生效") {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(AppSettings.AccentChoice.allCases) { choice in
                        AccentSwatch(choice: choice, isSelected: settings.accent == choice) {
                            settings.accent = choice
                        }
                    }
                }
            }
            SettingsRow(label: "降低动效", detail: "关闭位移动画与频谱律动") {
                SettingsSwitch(isOn: $settings.reduceMotion, label: "降低动效")
            }
            SettingsRow(label: "显示歌词", detail: "在正在播放页默认展开歌词") {
                SettingsSwitch(isOn: $settings.showLyrics, label: "显示歌词")
            }
        }
    }

    // MARK: 媒体库

    private var libraryGroup: some View {
        SettingsGroupCard(title: "媒体库") {
            SettingsRow(label: "上次刷新", detail: lastRefreshText) {
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    if isRefreshing {
                        HStack(spacing: Theme.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("刷新中…")
                        }
                    } else {
                        Label("立即刷新", systemImage: "arrow.clockwise")
                    }
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(isRefreshing)
                .accessibilityLabel("立即刷新媒体库")
            }
            SettingsRow(label: "缓存占用", detail: cacheUsageDetail) {
                CacheBar(fraction: cacheFraction)
            }
            SettingsRow(label: "缓存上限", detail: "超出后自动淘汰最旧的封面") {
                Stepper(value: $settings.imageCacheLimitGB, in: 1...100) {
                    Text("\(settings.imageCacheLimitGB) GB")
                        .textStyle(.bodySM, color: Theme.textPrimary)
                        .frame(width: 48, alignment: .leading)
                }
                .controlSize(.small)
                .accessibilityLabel("图片缓存上限")
                .accessibilityValue("\(settings.imageCacheLimitGB) GB")
            }
            SettingsRow(label: "清除缓存", detail: cacheCleared ? "已清除内存缓存" : "封面缩略图将重新下载") {
                Button {
                    confirmClearCache()
                } label: {
                    Label("清除缓存", systemImage: "trash")
                }
                .buttonStyle(DangerButtonStyle(compact: true))
            }
            SettingsRow(label: "曲目数量", detail: "当前媒体库已载入的内容") {
                Text("\(store.tracks.count) 首 · \(store.albums.count) 张专辑 · \(store.artists.count) 位艺人")
                    .textStyle(.footnote, color: Theme.textSecondary)
            }
        }
        // 进入媒体库分组时测量缓存占用（§2.4 边界：计算中显示占位）
        .task { await refreshCacheUsage() }
    }

    private var lastRefreshText: String {
        guard let date = settings.lastLibraryRefresh else { return "—" }
        return Self.lastRefreshFormatter.string(from: date)
    }

    /// `DateFormatter` 的构造（含 `dateFormat` 赋值）要建 ICU 格式器，代价在 0.1–1ms 量级，
    /// 不能放在每次 body 求值都会跑的计算属性里 —— 媒体库分组会随设置项与曲库发布重渲染。
    private static let lastRefreshFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    @MainActor
    private func refreshLibrary() async {
        isRefreshing = true
        await appState.loadLibraries()
        if let lib = appState.libraries.first(where: { $0.collectionType == "music" })
            ?? appState.libraries.first {
            store.libraryId = lib.id
            await store.reload()
        }
        await PlaylistSyncService.shared.syncAll()
        settings.lastLibraryRefresh = Date()
        isRefreshing = false
        await refreshCacheUsage()
        ToastCenter.shared.show("媒体库已刷新", systemImage: "arrow.clockwise")
    }

    private func confirmClearCache() {
        DialogCenter.shared.confirm(
            title: "清除图片缓存？",
            message: "将删除已下载的封面缓存（当前 \(cacheUsageText)），浏览资料库时封面会重新从服务器下载，可能短暂显示占位图。",
            confirmTitle: "清除缓存",
            isDestructive: true
        ) {
            ImageCache.shared.removeAll()
            cacheCleared = true
            ToastCenter.shared.show("图片缓存已清除", systemImage: "trash")
            Task { await refreshCacheUsage() }
        }
    }

    // MARK: 服务器与账号

    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            if appState.user == nil {
                InlineBanner(
                    kind: .info,
                    message: "当前未登录，服务器地址与账号操作需要先登录。"
                )
            }

            SettingsGroupCard(title: "服务器与账号") {
                SettingsRow(
                    label: "服务器地址",
                    detail: appState.user != nil ? "已登录 · 修改地址需重新登录" : "未登录"
                ) {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(serverAddress)
                            .textStyle(.mono, color: Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.horizontal, Theme.Spacing.md)
                            .frame(height: Theme.Size.fieldHeight)
                            .frame(maxWidth: 220, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.surfaceSunken)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .strokeBorder(Theme.borderDefault)
                            )
                        PlainIconButton(systemName: "doc.on.doc", label: "复制服务器地址") {
                            copyServerAddress()
                        }
                    }
                }
                SettingsRow(label: "当前用户", detail: APIClient.shared.baseURL?.host ?? "") {
                    HStack(spacing: Theme.Spacing.lg) {
                        Text(appState.user?.name ?? "—")
                            .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                        Button {
                            confirmSwitchUser()
                        } label: {
                            Label("切换用户", systemImage: "person.2")
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
                SettingsRow(label: "退出登录", detail: "清除本机会话，本地播放列表保留") {
                    Button {
                        confirmLogout()
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(DangerButtonStyle(compact: true))
                }
            }
        }
    }

    private var serverAddress: String {
        APIClient.shared.baseURL?.absoluteString ?? "未连接"
    }

    private func copyServerAddress() {
        guard let address = APIClient.shared.baseURL?.absoluteString else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        ToastCenter.shared.show("已复制服务器地址", systemImage: "doc.on.doc")
    }

    /// 切换用户 = 退出当前会话（沿用现有行为），同样走二次确认
    private func confirmSwitchUser() {
        DialogCenter.shared.confirm(
            title: "切换用户？",
            message: "将退出当前账号并返回登录页，重新登录后可换用其他用户。本地播放列表与设置会保留。",
            confirmTitle: "切换用户",
            isDestructive: false
        ) {
            appState.logout()
        }
    }

    private func confirmLogout() {
        DialogCenter.shared.confirm(
            title: "退出登录？",
            message: "将清除本机会话与已保存的凭据，下次启动需要重新登录。本地播放列表会保留。",
            confirmTitle: "退出登录",
            isDestructive: true
        ) {
            appState.logout()
        }
    }

    // MARK: 关于

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            SettingsGroupCard(title: "关于 Overtone") {
                SettingsRow(
                    label: "Overtone",
                    detail: "版本 \(appVersion) · 原生 macOS Jellyfin 音乐客户端 · 与 Jellyfin 项目无隶属关系"
                )
                SettingsRow(label: "开源许可", detail: "仅用于个人学习使用") {
                    Link("查看说明", destination: URL(string: "https://jellyfin.org")!)
                        .textStyle(.bodySM, color: Theme.brandText)
                }
            }

            SettingsGroupCard(title: "快捷键速查") {
                ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { index, shortcut in
                    ShortcutRow(shortcut: shortcut, showsDivider: index < Self.shortcuts.count - 1)
                }
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    /// 快捷键速查（§3.2 全表）
    private static let shortcuts: [Shortcut] = [
        Shortcut(title: "聚焦搜索", keys: ["⌘F"]),
        Shortcut(title: "播放 / 暂停", keys: ["空格"]),
        Shortcut(title: "下一曲 / 上一曲", keys: ["⌘→", "⌘←"]),
        Shortcut(title: "返回上一级 / 收起抽屉", keys: ["⌘[", "Esc"]),
        Shortcut(title: "切换一级页", keys: ["⌘1", "⌘5"], joiner: "…"),
        Shortcut(title: "打开设置", keys: ["⌘,"]),
        Shortcut(title: "上移 / 下移选中曲目", keys: ["⌘↑", "⌘↓"]),
        Shortcut(title: "刷新媒体库", keys: ["⌘R"]),
        Shortcut(title: "删除选中项", keys: ["⌫"])
    ]

    private static func crossfadeText(_ seconds: Double) -> String {
        seconds == seconds.rounded() ? "\(Int(seconds))s" : String(format: "%.1fs", seconds)
    }

    // MARK: - 缓存占用（§2.4：进度条 + 上限）

    /// 缓存占用测量状态：计算中显示占位，完成后显示「已用 / 上限」
    private enum CacheUsage {
        case measuring
        case measured(bytes: Double)
    }

    private var cacheUsageText: String {
        switch cacheUsage {
        case .measuring: return "计算中…"
        case .measured(let bytes): return Self.byteText(bytes)
        }
    }

    private var cacheUsageDetail: String {
        switch cacheUsage {
        case .measuring:
            return "计算中…"
        case .measured(let bytes):
            return "\(Self.byteText(bytes)) / \(settings.imageCacheLimitGB) GB 上限"
        }
    }

    private var cacheFraction: Double {
        guard case .measured(let bytes) = cacheUsage else { return 0 }
        let limit = Double(settings.imageCacheLimitGB) * 1_073_741_824
        guard limit > 0 else { return 0 }
        return min(max(bytes / limit, 0), 1)
    }

    /// 测量缓存占用：应用 Caches 目录里落盘的封面 + 内存封面缓存估算（取较大值，避免重复计数）。
    @MainActor
    private func refreshCacheUsage() async {
        cacheUsage = .measuring
        let disk = await Task.detached(priority: .utility) { SettingsView.cachesDirectoryBytes() }.value
        guard !Task.isCancelled else { return }
        let memory = Double(ImageCache.shared.count) * Self.averageCoverBytes
        cacheUsage = .measured(bytes: max(disk, memory))
    }

    /// 解码后封面（约 600×600 RGBA）的单张估算值
    private static let averageCoverBytes: Double = 1.5 * 1_048_576

    /// 已下载封面在磁盘上的占用（在后台线程调用，故显式 `nonisolated`；目录不存在时返回 0）
    private nonisolated static func cachesDirectoryBytes() -> Double {
        let manager = FileManager.default
        guard let bundleId = Bundle.main.bundleIdentifier,
              let root = manager.urls(for: .cachesDirectory, in: .userDomainMask).first?
                  .appendingPathComponent(bundleId),
              manager.fileExists(atPath: root.path) else { return 0 }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return 0 }

        var total: Double = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else {
                continue
            }
            total += Double(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    private static func byteText(_ bytes: Double) -> String {
        let megabytes = bytes / 1_048_576
        if megabytes >= 1024 { return String(format: "%.1f GB", megabytes / 1024) }
        return String(format: "%.1f MB", megabytes)
    }
}

// MARK: - §2.4 尺寸（规范值，非令牌覆盖范围）

private enum SettingsMetrics {
    /// 分组导航行高（§2.4：36）
    static let navRowHeight: CGFloat = 36
    /// 缓存进度条（§2.4：宽 140 高 6）
    static let cacheBarWidth: CGFloat = 140
    static let cacheBarHeight: CGFloat = 6
}

// MARK: - 设置导航行（高 36 / 圆角 6；选中 = brandTint 底 + brandText 字 + semibold）

private struct SettingsNavRow: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .textStyle(.bodySM, color: isSelected ? Theme.brandText : Theme.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .textStyle(
                        .bodySM,
                        weight: isSelected ? .semibold : .medium,
                        color: isSelected ? Theme.brandText : (hovered ? Theme.textPrimary : Theme.textSecondary)
                    )
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: SettingsMetrics.navRowHeight)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            // 视觉 36 / 命中区 44（§5.3）
            .hitExpand(from: SettingsMetrics.navRowHeight, to: 44)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.brandTint) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - 设置分组卡片（surface 实底 + radius-lg + e1；组标题 13/600 textSecondary）

private struct SettingsGroupCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.bodySM, weight: .semibold, color: Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

            content
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        // 深色下 e1 自动换成 borderSubtle 描边（§4.4）
        .elevation(.e1, cornerRadius: Theme.Radius.lg)
    }
}

// MARK: - 设置行（左标签 13/500 + 说明 11 textSecondary，右控件；行高 ≥44、内距 16）

private struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(label)
                    .textStyle(.bodySM, weight: .medium, color: Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            control
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(minHeight: 44)
    }
}

extension SettingsRow where Control == EmptyView {
    /// 只有标签 / 说明、没有右控件的行
    init(label: String, detail: String? = nil) {
        self.init(label: label, detail: detail) { EmptyView() }
    }
}

// MARK: - 开关（§4.5：开关 36×20，开 = brand500；命中区 44）

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.brand500)
            .controlSize(.small)
            .hitExpand(from: 20, to: 44)
            .accessibilityLabel(label)
    }
}

// MARK: - 滑杆（轨道 140，数值 mono 不跳动）

private struct SettingsSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let text: String
    let label: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Slider(value: $value, in: range, step: step)
                .tint(Theme.brand500)
                .frame(width: 140)
                .accessibilityLabel(label)
                .accessibilityValue(text)
            Text(text)
                .textStyle(.mono, color: Theme.textSecondary)
                .frame(width: 48, alignment: .leading)
        }
    }
}

// MARK: - 下拉（§4.5：高 32、圆角 10，选中打勾；弹出层用共享 `TokenMenu`）

private struct SettingsMenu: View {
    let selection: String
    let options: [String]
    let accessibilityLabel: String
    let onSelect: (String) -> Void

    var body: some View {
        TokenMenu(accessibilityLabel: accessibilityLabel) {
            ForEach(options, id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == selection {
                        Label(option, systemImage: "checkmark")
                    } else {
                        Text(option)
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Text(selection)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .textStyle(.caption, color: Theme.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: Theme.Size.fieldHeight)
            .frame(minWidth: 108, alignment: .leading)
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

// MARK: - 强调色色块（选中加 brandText 描边环；命中区 44）

private struct AccentSwatch: View {
    let choice: AppSettings.AccentChoice
    let isSelected: Bool
    let action: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 18, height: 18)
                .padding(Theme.Spacing.xs)
                .overlay(
                    Circle()
                        .strokeBorder(ring, lineWidth: 2)
                )
                .contentShape(Circle())
                .hitExpand(from: 26, to: 44)
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.full)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .animation(Theme.Motion.micro, value: isSelected)
        .help(choice.rawValue)
        .accessibilityLabel("强调色：\(choice.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// 固定色值：不随当前强调色变化
    private var color: Color {
        switch choice {
        case .indigo: return Theme.accentIndigo
        case .teal: return Theme.accentTeal
        case .purple: return Theme.accentPurple
        }
    }

    private var ring: Color {
        if isSelected { return Theme.brandText }
        return hovered ? Theme.borderDefault : .clear
    }
}

// MARK: - 缓存占用进度条（宽 140 高 6，warning 填充）

private struct CacheBar: View {
    /// 0…1
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Theme.surfaceSunken)
            .frame(width: SettingsMetrics.cacheBarWidth, height: SettingsMetrics.cacheBarHeight)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.warning)
                    .frame(width: SettingsMetrics.cacheBarWidth * fraction, height: SettingsMetrics.cacheBarHeight)
            }
            .clipShape(Capsule())
            .accessibilityElement()
            .accessibilityLabel("缓存占用")
            .accessibilityValue("\(Int((fraction * 100).rounded()))%")
    }
}

// MARK: - 快捷键速查（§3.2）

private struct Shortcut {
    let title: String
    let keys: [String]
    /// 两枚键位之间的连接符（「⌘1 … ⌘5」）
    var joiner: String? = nil
}

private struct ShortcutRow: View {
    let shortcut: Shortcut
    let showsDivider: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.lg) {
                Text(shortcut.title)
                    .textStyle(.footnote, color: Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.md)
                HStack(spacing: Theme.Spacing.xs) {
                    ForEach(Array(shortcut.keys.enumerated()), id: \.offset) { index, key in
                        if index > 0, let joiner = shortcut.joiner {
                            Text(joiner)
                                .textStyle(.monoSM, color: Theme.textTertiary)
                        }
                        KeyCap(text: key)
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .frame(minHeight: 32)

            if showsDivider {
                DashedDivider()
                    .padding(.horizontal, Theme.Spacing.xl)
            }
        }
    }
}

/// 键位小底（monoSM + surfaceSunken + borderSubtle）
private struct KeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.monoSM, color: Theme.textSecondary)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                    .fill(Theme.surfaceSunken)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.xs)
                    .strokeBorder(Theme.borderSubtle)
            )
    }
}

/// 1px 虚线分隔（行间，§2.4）
private struct DashedDivider: View {
    var body: some View {
        DashedLine()
            .stroke(Theme.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }
}

private struct DashedLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}
