import AppKit
import SwiftUI

/// 设置页（§2.4）：左侧分组导航 180 + 右侧表单 480，七组一切换。
///
/// 结构分层：`SettingsView`（窗口骨架 + 分组路由）→ `SettingsGroupCard`（`surface` 实底卡）
/// → `SettingsRow`（左标签 13/500 + 说明 11 + 右控件，行高 ≥44）。
/// 颜色 / 圆角 / 字号一律走 `Theme` 令牌；深色下由 `elevation(.e1, cornerRadius:)` 自动换成描边分层。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.appVisualStyle) private var visualStyle
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var scrobble = ScrobbleSettings.shared
    /// 待补报条数随队列变化（失败静默，只有这两个数字会出现在界面上）
    @ObservedObject private var scrobbleService = ScrobbleService.shared

    @State private var group: Group = .general
    @State private var isRefreshing = false
    @State private var cacheCleared = false
    @State private var cacheUsage: CacheUsage = .measuring
    /// 凭据输入草稿：Secret / 令牌读回后不回显，保存成功即清空
    @State private var lastFMSecretDraft = ""
    @State private var listenBrainzTokenDraft = ""

    /// 七个分组（§2.4：通用 / 播放 / 外观 / 媒体库 / 听歌记录 / 服务器与账号 / 关于）
    enum Group: String, CaseIterable, Identifiable {
        case general = "通用"
        case playback = "播放"
        case appearance = "外观"
        case library = "媒体库"
        case scrobble = "听歌记录"
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
            case .scrobble: return "waveform.path.ecg"
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
        // 风格切换必须重建内容：纸墨下圆角 14→4、玻璃材质→实底纸面、行间多出 hairline，
        // 都是**结构 / 布局**差异；只换色不会让已经布局过的子树重算，
        // 残留的旧尺寸会表现为「切了风格但卡片大小没变」。挂 id 等于换一个视图。
        //
        // 注意 id 只包 HStack（内容），`group` / 滚动位置等 @State 挂在 SettingsView 上，
        // 所以切换风格不会把用户踢回「通用」分组。
        .id(visualStyle)
        // 设置窗口：导航 180 + 内容列 640（窗口 880×560）。
        // 原先 720×480 的表单列太窄，行里「左侧标签 + 说明」与右侧控件经常挤在一起。
        .frame(
            width: Theme.Size.settingsWindowWidth,
            height: Theme.Size.settingsWindowHeight
        )
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
        case .scrobble: scrobbleGroup
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
            SettingsRow(
                label: "音质",
                detail: capabilities.transcode
                    ? settings.quality.detail
                    : "当前服务器不支持转码，将始终播放原始文件"
            ) {
                SettingsMenu(
                    selection: settings.quality.rawValue,
                    options: AppSettings.Quality.allCases.map(\.rawValue),
                    accessibilityLabel: "音质"
                ) { settings.quality = AppSettings.Quality(rawValue: $0) ?? .original }
                .disabled(!capabilities.transcode)
                .opacity(capabilities.transcode ? 1 : 0.45)
            }
            SettingsRow(label: "直连优先", detail: "容器兼容时直接播放原文件，不经过服务器转码") {
                SettingsSwitch(isOn: $settings.preferDirectPlay, label: "直连优先")
                    .disabled(!capabilities.transcode)
                    .opacity(capabilities.transcode ? 1 : 0.45)
            }
            SettingsRow(label: "交叉淡化", detail: "播完自动交叉淡化的时长；手动切歌用约 1 秒短过渡，0 表示关闭") {
                SettingsSlider(
                    value: $settings.crossfadeSeconds,
                    range: 0...12,
                    step: 0.5,
                    text: Self.crossfadeText(settings.crossfadeSeconds),
                    label: "交叉淡化时长"
                )
            }
            SettingsRow(
                label: "队列结束后自动续播",
                detail: capabilities.instantMix
                    ? "用当前歌曲的相似歌曲接着放（不再静音收尾）"
                    : "当前服务器没有相似歌曲接口，队列播完即停止"
            ) {
                SettingsSwitch(isOn: $settings.autoContinue, label: "队列结束后自动续播")
                    .disabled(!capabilities.instantMix)
                    .opacity(capabilities.instantMix ? 1 : 0.45)
            }
            SettingsRow(label: "音量归一化", detail: "统一不同专辑的响度") {
                SettingsSwitch(isOn: $settings.volumeNormalization, label: "音量归一化")
                    .disabled(!capabilities.transcode)
                    .opacity(capabilities.transcode ? 1 : 0.45)
            }
            SettingsRow(
                label: "进度上报间隔",
                detail: capabilities.playbackProgress
                    ? "多端同步频率"
                    : "当前服务器不支持进度上报，续播位置只保存在本机"
            ) {
                SettingsSlider(
                    value: $settings.reportInterval,
                    range: 5...60,
                    step: 5,
                    text: "\(Int(settings.reportInterval)) 秒",
                    label: "进度上报间隔"
                )
                .disabled(!capabilities.playbackProgress)
                .opacity(capabilities.playbackProgress ? 1 : 0.45)
            }
        }
    }

    // MARK: 外观

    private var appearanceGroup: some View {
        SettingsGroupCard(title: "外观") {
            // v3/v4 双轨总开关 —— 放在第一行，因为下面每一项的形态都由它决定
            SettingsRow(label: "视觉风格", detail: settings.visualStyle.detail) {
                SegmentedControl(
                    segments: VisualStyle.allCases.map { .init($0.rawValue, $0.title) },
                    selection: Binding(
                        get: { settings.visualStyle.rawValue },
                        set: { settings.visualStyle = VisualStyle(rawValue: $0) ?? .glass }
                    )
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("视觉风格")
            }
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
        if let lib = appState.libraries.first {
            store.libraryID = lib.id
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

    // MARK: 听歌记录

    /// 「听歌记录」：总开关 / 服务选择 / 对应凭据 / 连接状态 / 隐私说明。
    ///
    /// 凭据分成两类落点：非机密的 API Key 直接绑到 `ScrobbleSettings.lastFMAPIKey`
    /// （输入即存偏好设置），Secret 与用户令牌只写钥匙串、输入框保存后立即清空，
    /// 所以界面永远不会把已保存的密钥回显出来。
    private var scrobbleGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            SettingsGroupCard(title: "听歌记录") {
                SettingsRow(
                    label: "记录到音乐服务",
                    detail: "开启后把正在播放与听过的歌提交到 Last.fm / ListenBrainz"
                ) {
                    SettingsSwitch(isOn: $scrobble.enabled, label: "记录到音乐服务")
                }

                SettingsRow(label: "服务", detail: "同一时间只向一个服务提交") {
                    SettingsMenu(
                        selection: scrobble.service.displayName,
                        options: ScrobbleServiceKind.allCases.map(\.displayName),
                        accessibilityLabel: "听歌记录服务"
                    ) { name in
                        scrobble.service = ScrobbleServiceKind.allCases
                            .first { $0.displayName == name } ?? .lastFM
                    }
                }

                if scrobble.service == .lastFM {
                    lastFMRows
                } else {
                    listenBrainzRows
                }

                SettingsRow(
                    label: "隐私说明",
                    detail: "歌名、艺人、专辑与播放时间会发送到 \(scrobble.service.displayName)；凭据仅存本机钥匙串，不写入日志。"
                )

                if scrobbleService.pendingCount > 0 {
                    SettingsRow(
                        label: "待补报记录",
                        detail: "网络恢复后自动重试；最多保留 \(ScrobblePendingStore.capacity) 条"
                    ) {
                        Text("\(scrobbleService.pendingCount) 条")
                            .textStyle(.footnote, color: Theme.textSecondary)
                    }
                }
            }
        }
        // 进入分组时懒启动：结算上次运行遗留的会话 + 补报离线队列，并刷新钥匙串状态。
        // 全是异步任务，不会拖慢设置页；网络失败也只更新状态文案。
        .task {
            ScrobbleService.shared.bootstrap()
            await scrobble.refreshCredentialPresence()
        }
    }

    @ViewBuilder
    private var lastFMRows: some View {
        SettingsRow(label: "API Key", detail: lastFMKeyDetail) {
            ScrobbleField(
                placeholder: "32 位 API Key",
                text: $scrobble.lastFMAPIKey,
                accessibilityLabel: "Last.fm API Key"
            )
        }

        SettingsRow(
            label: "Shared Secret",
            detail: scrobble.hasLastFMSecret
                ? "已保存在本机钥匙串；留空保持不变"
                : "与 API Key 成对，保存到本机钥匙串"
        ) {
            HStack(spacing: Theme.Spacing.sm) {
                ScrobbleField(
                    placeholder: scrobble.hasLastFMSecret ? "已保存" : "粘贴 Secret",
                    text: $lastFMSecretDraft,
                    isSecure: true,
                    accessibilityLabel: "Last.fm Shared Secret"
                )
                Button("保存") {
                    scrobble.saveLastFMSecret(lastFMSecretDraft)
                    lastFMSecretDraft = ""
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(lastFMSecretDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        SettingsRow(label: "Last.fm 连接", detail: scrobble.lastFMStatusText) {
            HStack(spacing: Theme.Spacing.sm) {
                if scrobble.lastFMState == .awaitingAuthorization {
                    Button("完成授权") { scrobble.completeLastFMAuth() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                } else if scrobble.hasLastFMSession {
                    Button("验证") { scrobble.verifyLastFM() }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                } else {
                    Button("连接") {
                        scrobble.connectLastFM(secretInput: lastFMSecretDraft)
                        lastFMSecretDraft = ""
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                }
                if scrobble.hasLastFMSession || scrobble.lastFMState == .awaitingAuthorization {
                    Button("断开") { scrobble.disconnectLastFM() }
                        .buttonStyle(DangerButtonStyle(compact: true))
                }
            }
            .disabled(scrobble.lastFMState.isWorking)
        }
    }

    @ViewBuilder
    private var listenBrainzRows: some View {
        SettingsRow(
            label: "用户令牌",
            detail: scrobble.hasListenBrainzToken
                ? "已保存在本机钥匙串；可重新粘贴覆盖"
                : "在 listenbrainz.org/settings 复制"
        ) {
            HStack(spacing: Theme.Spacing.sm) {
                ScrobbleField(
                    placeholder: "粘贴用户令牌",
                    text: $listenBrainzTokenDraft,
                    isSecure: true,
                    accessibilityLabel: "ListenBrainz 用户令牌"
                )
                Button("保存并验证") {
                    scrobble.connectListenBrainz(tokenInput: listenBrainzTokenDraft)
                    listenBrainzTokenDraft = ""
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
                .disabled(listenBrainzTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }

        SettingsRow(label: "ListenBrainz 连接", detail: scrobble.listenBrainzStatusText) {
            HStack(spacing: Theme.Spacing.sm) {
                Button("验证") { scrobble.verifyListenBrainz() }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(!scrobble.hasListenBrainzToken)
                if scrobble.hasListenBrainzToken {
                    Button("断开") { scrobble.disconnectListenBrainz() }
                        .buttonStyle(DangerButtonStyle(compact: true))
                }
            }
            .disabled(scrobble.listenBrainzState.isWorking)
        }
    }

    private var lastFMKeyDetail: String {
        if scrobble.lastFMAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "在 last.fm/api 申请 API 账号获得；应用不内置任何密钥"
        }
        return scrobble.hasLastFMSecret
            ? "API Key 已填写；修改后需重新连接"
            : "已填 API Key，还需填写 Shared Secret"
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
                    label: "服务器类型",
                    detail: "切换后端会重新加载曲库；已保存的凭据按后端分别保留"
                ) {
                    SegmentedControl(
                        segments: BackendKind.allCases.map { .init($0.rawValue, $0.displayName) },
                        selection: Binding(
                            get: { appState.backendKind.rawValue },
                            set: { raw in
                                guard let kind = BackendKind(rawValue: raw) else { return }
                                Task { await appState.switchBackend(to: kind) }
                            }
                        )
                    )
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("服务器类型")
                }
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
                SettingsRow(label: "当前用户", detail: appState.backendKind.displayName) {
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
        appState.backend.session?.serverURL.absoluteString ?? "未连接"
    }

    /// 当前后端的能力声明（决定哪些设置在飞牛上要置灰）
    private var capabilities: BackendCapabilities {
        appState.capabilities
    }

    private func copyServerAddress() {
        guard let address = appState.backend.session?.serverURL.absoluteString else { return }
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
            Task { await appState.logout() }
        }
    }

    private func confirmLogout() {
        DialogCenter.shared.confirm(
            title: "退出登录？",
            message: "将清除本机会话与已保存的凭据，下次启动需要重新登录。本地播放列表会保留。",
            confirmTitle: "退出登录",
            isDestructive: true
        ) {
            Task { await appState.logout() }
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

// MARK: - 设置分组卡片（glass：surface 实底 + radius-lg + e1；paper：纸面 + 规则标签 + hairline）

private struct SettingsGroupCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            content
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.surface)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        // 深色下 e1 自动换成 borderSubtle 描边（§4.4）；纸墨下 `elevation` 不出投影，
        // 层次改由 hairline 与纸墨反差承担
        .elevation(.e1, cornerRadius: Theme.Radius.lg)
    }

    /// 组标题：玻璃是「13/600 次级色」；纸墨改用**规则标签**（─── 标题 ───）。
    ///
    /// 为什么纸墨要换形态：v4 §4.7 的区块标签是印刷目录的形态，一条横贯的细线同时
    /// 承担「分组开始」与「与上一组分开」两个职责 —— 纸面上没有卡片阴影可用。
    /// 直接复用 T2 的 `RuleLabel`（形态由组件库统一负责，这里只给标题）。
    @ViewBuilder
    private var header: some View {
        if Theme.isPaper {
            RuleLabel(title)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.xl)
                .padding(.bottom, Theme.Spacing.md)
        } else {
            Text(title)
                .textStyle(.bodySM, weight: .semibold, color: Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
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
        // 纸墨：行间 1px hairline（v4 §2.3「描边是主要分隔手段，不用斑马纹」）。
        //
        // 为什么画在行自己的顶部而不是数「第几行」：行的数量与排列由各分组自己决定，
        // 卡片这一层看不到子行（`Content` 泛型不可枚举），逐行画线是唯一不引入
        // AnyView / 变长遍历的写法。副作用是组标题下与整组底部各多出一条细线，
        // 观感上等于「表头下划线 + 表格外框」，与 v4 的印刷表格一致。
        .overlay(alignment: .top) {
            if Theme.isPaper {
                Rectangle()
                    .fill(Theme.Paper.hairline)
                    .frame(height: 1)
            }
        }
    }
}

extension SettingsRow where Control == EmptyView {
    /// 只有标签 / 说明、没有右控件的行
    init(label: String, detail: String? = nil) {
        self.init(label: label, detail: detail) { EmptyView() }
    }
}

// MARK: - 开关（glass §4.5：开关 36×20，开 = brand500；paper §4.2：32×18 方形开关）

private struct SettingsSwitch: View {
    @Binding var isOn: Bool
    let label: String

    var body: some View {
        if Theme.isPaper {
            // 纸墨：方形开关（v4 §4.2，直角轨道 + 方钮），胶囊只留给快速入口
            PaperSwitch(isOn: $isOn, label: label)
        } else {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.brand500)
                .controlSize(.small)
                .hitExpand(from: 20, to: 44)
                .accessibilityLabel(label)
        }
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

// MARK: - 听歌记录凭据输入（复用 `TokenField` 外框：高 32，玻璃 / 纸墨双风格）

/// 只读草稿 + 保存按钮的最小输入行：已保存的 Secret 永远不会回显到界面。
private struct ScrobbleField: View {
    let placeholder: String
    @Binding var text: String
    var isSecure = false
    let accessibilityLabel: String

    @FocusState private var focused: Bool

    var body: some View {
        TokenField(isFocused: focused) {
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.plain)
            .textStyle(.bodySM, color: Theme.textPrimary)
            .focused($focused)
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(width: 150)
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

    /// 固定色值：不随当前强调色变化（直接走 `AccentChoice.color`，保证与色阶定义同一处）
    private var color: Color { choice.color }

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
