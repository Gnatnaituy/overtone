import SwiftUI

/// 设置页（新增，§4.5）：左侧分组导航 180 + 右侧表单 480 居中，6 个分组。
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var store = MusicDataStore.shared

    @State private var group: Group = .general
    @State private var showLogoutConfirm = false
    @State private var isRefreshing = false
    @State private var cacheCleared = false

    enum Group: String, CaseIterable, Identifiable {
        case general = "通用"
        case playback = "播放"
        case appearance = "外观"
        case library = "媒体库"
        case account = "服务器与账号"
        case about = "关于"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .general: return "gearshape"
            case .playback: return "play.circle"
            case .appearance: return "square.grid.2x2"
            case .library: return "folder"
            case .account: return "server.rack"
            case .about: return "music.note"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(Theme.borderSubtle).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
                    Text(group.rawValue)
                        .textStyle(.title3, color: Theme.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    groupContent
                }
                .padding(.horizontal, Theme.Spacing.xxxl)
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
        .alert("退出登录", isPresented: $showLogoutConfirm) {
            Button("退出登录", role: .destructive) { appState.logout() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清除本机会话与已保存的凭据，下次启动需要重新登录。本地播放列表会保留。")
        }
    }

    // MARK: - 分组导航（180）

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                Toggle("", isOn: $settings.autoConnect)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.brand500)
                    .controlSize(.small)
            }
            SettingsRow(label: "默认打开页面", detail: "启动后落到的一级页面") {
                SettingsMenu(
                    selection: settings.startPage.rawValue,
                    options: AppSettings.StartPage.allCases.map(\.rawValue)
                ) { settings.startPage = AppSettings.StartPage(rawValue: $0) ?? .home }
            }
            SettingsRow(label: "关闭窗口时继续播放", detail: "关掉窗口不打断当前曲目") {
                Toggle("", isOn: $settings.continuePlayingOnClose)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.brand500)
                    .controlSize(.small)
            }
            SettingsRow(label: "语言", detail: "界面语言（重启后生效）") {
                SettingsMenu(
                    selection: settings.language.rawValue,
                    options: AppSettings.Language.allCases.map(\.rawValue)
                ) { settings.language = AppSettings.Language(rawValue: $0) ?? .system }
            }
        }
    }

    // MARK: 播放

    private var playbackGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
            SettingsGroupCard(title: "音质与直连") {
                SettingsRow(label: "音质", detail: settings.quality.detail) {
                    SettingsMenu(
                        selection: settings.quality.rawValue,
                        options: AppSettings.Quality.allCases.map(\.rawValue)
                    ) { settings.quality = AppSettings.Quality(rawValue: $0) ?? .original }
                }
                SettingsRow(label: "直连优先", detail: "容器兼容时直接播放原文件，不经过服务器转码") {
                    Toggle("", isOn: $settings.preferDirectPlay)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.brand500)
                        .controlSize(.small)
                }
                SettingsRow(label: "进度上报间隔", detail: "多端同步频率") {
                    HStack(spacing: Theme.Spacing.md) {
                        Slider(value: $settings.reportInterval, in: 5...60, step: 5)
                            .tint(Theme.brand500)
                            .frame(width: 140)
                            .accessibilityLabel("进度上报间隔")
                        Text("\(Int(settings.reportInterval)) 秒")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .frame(width: 44, alignment: .leading)
                    }
                }
            }

            SettingsGroupCard(title: "播放行为") {
                SettingsRow(label: "交叉淡入", detail: "换曲时平滑过渡，0 表示关闭") {
                    HStack(spacing: Theme.Spacing.md) {
                        Slider(value: $settings.crossfadeSeconds, in: 0...12, step: 1)
                            .tint(Theme.brand500)
                            .frame(width: 140)
                            .accessibilityLabel("交叉淡入时长")
                        Text("\(Int(settings.crossfadeSeconds))s")
                            .textStyle(.footnote, color: Theme.textSecondary)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                SettingsRow(label: "音量归一化", detail: "统一不同专辑的响度") {
                    Toggle("", isOn: $settings.volumeNormalization)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(Theme.brand500)
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: 外观

    private var appearanceGroup: some View {
        SettingsGroupCard(title: "外观") {
            SettingsRow(label: "主题", detail: "深色主题将在后续版本提供") {
                SegmentedControl(
                    segments: AppSettings.ThemeChoice.allCases.map { .init($0.rawValue, $0.rawValue) },
                    selection: Binding(
                        get: { settings.theme.rawValue },
                        set: { settings.theme = AppSettings.ThemeChoice(rawValue: $0) ?? .light }
                    )
                )
            }
            SettingsRow(label: "强调色", detail: "主色与选中态") {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(AppSettings.AccentChoice.allCases) { choice in
                        AccentSwatch(choice: choice, isSelected: settings.accent == choice) {
                            settings.accent = choice
                        }
                    }
                }
            }
            SettingsRow(label: "降低动效", detail: "关闭位移动画与频谱律动") {
                Toggle("", isOn: $settings.reduceMotion)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.brand500)
                    .controlSize(.small)
            }
            SettingsRow(label: "显示歌词", detail: "在正在播放页默认展开歌词") {
                Toggle("", isOn: $settings.showLyrics)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.brand500)
                    .controlSize(.small)
            }
        }
    }

    // MARK: 媒体库

    private var libraryGroup: some View {
        SettingsGroupCard(title: "媒体库与缓存") {
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
            }
            SettingsRow(label: "图片缓存上限", detail: "超出后自动淘汰最旧的封面") {
                HStack(spacing: Theme.Spacing.md) {
                    Stepper(value: $settings.imageCacheLimitGB, in: 1...20) {
                        Text("\(settings.imageCacheLimitGB) GB")
                            .textStyle(.bodySM, color: Theme.textPrimary)
                            .frame(width: 48, alignment: .leading)
                    }
                    .controlSize(.small)
                }
            }
            SettingsRow(label: "清除缓存", detail: cacheCleared ? "已清除内存缓存" : "释放已下载的封面") {
                Button {
                    settings.clearImageCache()
                    cacheCleared = true
                } label: {
                    Label("清除缓存", systemImage: "trash")
                }
                .buttonStyle(SecondaryButtonStyle(compact: true))
            }
            SettingsRow(label: "曲目数量", detail: "当前媒体库已载入的内容") {
                Text("\(store.tracks.count) 首 · \(store.albums.count) 张专辑 · \(store.artists.count) 位艺人")
                    .textStyle(.footnote, color: Theme.textSecondary)
            }
        }
    }

    private var lastRefreshText: String {
        guard let date = settings.lastLibraryRefresh else { return "尚未刷新" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

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
        ToastCenter.shared.show("媒体库已刷新", systemImage: "arrow.clockwise")
    }

    // MARK: 服务器与账号

    private var accountGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
            SettingsGroupCard(title: "服务器") {
                SettingsRow(label: "服务器地址", detail: "修改地址需要重新登录") {
                    Text(APIClient.shared.baseURL?.absoluteString ?? "未连接")
                        .textStyle(.bodySM, color: Theme.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 240, alignment: .trailing)
                        .textSelection(.enabled)
                }
                SettingsRow(label: "连接状态", detail: appState.user != nil ? "已登录" : "未登录") {
                    HStack(spacing: Theme.Spacing.sm) {
                        Circle()
                            .fill(appState.user != nil ? Theme.success : Theme.textTertiary)
                            .frame(width: 8, height: 8)
                        Text(appState.user != nil ? "正常" : "离线")
                            .textStyle(.bodySM, color: Theme.textSecondary)
                    }
                }
            }

            SettingsGroupCard(title: "账号") {
                SettingsRow(label: "当前用户", detail: APIClient.shared.baseURL?.host ?? "") {
                    HStack(spacing: Theme.Spacing.lg) {
                        Text(appState.user?.name ?? "—")
                            .textStyle(.bodySM, color: Theme.textPrimary)
                        Button {
                            appState.logout()
                        } label: {
                            Label("切换用户", systemImage: "person.2")
                        }
                        .buttonStyle(SecondaryButtonStyle(compact: true))
                    }
                }
                SettingsRow(label: "退出登录", detail: "清除本机会话，本地播放列表保留") {
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .buttonStyle(DangerButtonStyle(compact: true))
                }
            }
        }
    }

    // MARK: 关于

    private var aboutGroup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxxl) {
            SettingsGroupCard(title: "关于 Overtone") {
                SettingsRow(label: "版本", detail: "原生 macOS Jellyfin 音乐客户端") {
                    Text(appVersion)
                        .textStyle(.bodySM, color: Theme.textPrimary)
                }
                SettingsRow(label: "开源许可", detail: "仅用于个人学习使用") {
                    Link("查看说明", destination: URL(string: "https://jellyfin.org")!)
                        .textStyle(.bodySM, color: Theme.brand500)
                }
                SettingsRow(label: "非官方声明", detail: "Jellyfin 是 Jellyfin 团队的商标") {
                    Text("本项目与 Jellyfin 项目无隶属关系")
                        .textStyle(.footnote, color: Theme.textSecondary)
                }
            }

            SettingsGroupCard(title: "快捷键速查") {
                ForEach(Array(Self.shortcuts.enumerated()), id: \.offset) { _, item in
                    SettingsRow(label: item.0, detail: nil) {
                        Text(item.1)
                            .textStyle(.mono, color: Theme.textSecondary)
                    }
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

    private static let shortcuts: [(String, String)] = [
        ("聚焦搜索", "⌘F"),
        ("播放 / 暂停", "空格"),
        ("下一曲 / 上一曲", "⌘→ / ⌘←"),
        ("返回上一级", "⌘["),
        ("切换一级页", "⌘1 … ⌘5"),
        ("打开设置", "⌘,")
    ]
}

// MARK: - 设置导航行

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
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .textStyle(.bodySM, weight: .medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .foregroundStyle(isSelected ? Theme.textOnAccent : Theme.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(fill)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(focused, cornerRadius: Theme.Radius.sm)
        .onHover { hovered = $0 }
        .animation(Theme.Motion.micro, value: hovered)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Theme.brandGradient) }
        if hovered { return AnyShapeStyle(Theme.surfaceHover) }
        return AnyShapeStyle(Color.clear)
    }
}

// MARK: - 设置分组卡片（白卡 radius-lg + borderSubtle）

private struct SettingsGroupCard<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                .padding(.horizontal, Theme.Spacing.xl)
                .frame(height: 40, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surfaceSunken)
                .accessibilityAddTraits(.isHeader)

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            content
        }
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

// MARK: - 设置行（左标签 13 + 说明 11，右控件；行高 ≥ 44）

private struct SettingsRow<Control: View>: View {
    let label: String
    var detail: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xl) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                if let detail {
                    Text(detail)
                        .textStyle(.caption, color: Theme.textTertiary)
                }
            }

            Spacer(minLength: Theme.Spacing.md)

            control
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(minHeight: 44)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(height: 1)
                .padding(.leading, Theme.Spacing.xl)
        }
    }
}

// MARK: - 下拉控件（高 32）

private struct SettingsMenu: View {
    let selection: String
    let options: [String]
    let onSelect: (String) -> Void

    var body: some View {
        TokenMenu(accessibilityLabel: selection) {
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
            HStack(spacing: Theme.Spacing.md) {
                Text(selection)
                    .textStyle(.bodySM, color: Theme.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 11)
            .frame(height: Theme.Size.fieldHeight)
            .frame(minWidth: 120, alignment: .leading)
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

// MARK: - 强调色色块

private struct AccentSwatch: View {
    let choice: AppSettings.AccentChoice
    let isSelected: Bool
    let action: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(choice.color)
                .frame(width: 22, height: 22)
                .overlay(
                    Circle()
                        .strokeBorder(Theme.surface, lineWidth: 2)
                        .padding(3)
                        .opacity(isSelected ? 1 : 0)
                )
                .overlay(
                    Circle().strokeBorder(isSelected ? Theme.brand500 : Theme.borderDefault, lineWidth: isSelected ? 2 : 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focused($focused)
        .focusRing(focused, cornerRadius: 11)
        .help(choice.rawValue)
        .accessibilityLabel("强调色：\(choice.rawValue)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
