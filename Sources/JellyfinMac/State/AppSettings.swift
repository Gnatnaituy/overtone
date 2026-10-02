import SwiftUI

/// 应用设置（§4.5 设置页的数据源）。
///
/// 全部落到 `UserDefaults`，`@Published` 保证设置页即时刷新。
/// 只保留真正生效的项：音质/直连优先 → 播放地址；淡入时长 → 换曲过渡；
/// 上报间隔 → 进度上报；降低动效 → `\.appReduceMotion`；默认打开页面 → 启动落点。
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: 枚举

    enum Quality: String, CaseIterable, Identifiable {
        case original = "原始"
        case high = "高"
        case medium = "中"
        case low = "低"

        var id: String { rawValue }

        /// 目标比特率（kbps）；nil = 不转码
        var bitrate: Int? {
            switch self {
            case .original: return nil
            case .high: return 320
            case .medium: return 192
            case .low: return 128
            }
        }

        var detail: String {
            switch self {
            case .original: return "不转码，直接播放原始文件"
            case .high: return "约 320 kbps"
            case .medium: return "约 192 kbps，弱网更稳"
            case .low: return "约 128 kbps，最省流量"
            }
        }
    }

    enum ThemeChoice: String, CaseIterable, Identifiable {
        case light = "浅色"
        case dark = "深色"
        case system = "跟随系统"

        var id: String { rawValue }

        /// 对应的 AppKit 外观；`nil` = 跟随系统
        var appearance: NSAppearance? {
            switch self {
            case .light: return NSAppearance(named: .aqua)
            case .dark: return NSAppearance(named: .darkAqua)
            case .system: return nil
            }
        }

        /// 从持久化字符串还原（启动早期在非隔离上下文使用）
        init(storedRawValue: String) {
            self = ThemeChoice(rawValue: storedRawValue) ?? .light
        }
    }

    enum AccentChoice: String, CaseIterable, Identifiable {
        case indigo = "靛蓝"
        case teal = "泛音青"
        case purple = "紫"

        var id: String { rawValue }

        var color: Color {
            // 色块用固定值：否则选中泛音青后，靛蓝色块会跟着变成青色
            switch self {
            case .indigo: return Theme.accentIndigo
            case .teal: return Theme.accentTeal
            case .purple: return Theme.accentPurple
            }
        }
    }

    enum StartPage: String, CaseIterable, Identifiable {
        case home = "首页"
        case library = "资料库"
        case playlists = "播放列表"
        case nowPlaying = "正在播放"

        var id: String { rawValue }
    }

    enum Language: String, CaseIterable, Identifiable {
        case system = "跟随系统"
        case chinese = "简体中文"
        case english = "English"

        var id: String { rawValue }
    }

    // MARK: 通用

    @Published var autoConnect: Bool { didSet { defaults.set(autoConnect, forKey: "settings.autoConnect") } }
    @Published var startPage: StartPage { didSet { defaults.set(startPage.rawValue, forKey: "settings.startPage") } }
    @Published var continuePlayingOnClose: Bool { didSet { defaults.set(continuePlayingOnClose, forKey: "settings.continueOnClose") } }
    @Published var language: Language { didSet { defaults.set(language.rawValue, forKey: "settings.language") } }

    // MARK: 播放

    @Published var quality: Quality { didSet { defaults.set(quality.rawValue, forKey: "settings.quality") } }
    @Published var preferDirectPlay: Bool { didSet { defaults.set(preferDirectPlay, forKey: "settings.directPlay") } }
    @Published var crossfadeSeconds: Double { didSet { defaults.set(crossfadeSeconds, forKey: "settings.crossfade") } }
    @Published var volumeNormalization: Bool { didSet { defaults.set(volumeNormalization, forKey: "settings.normalization") } }
    @Published var reportInterval: Double { didSet { defaults.set(reportInterval, forKey: "settings.reportInterval") } }

    // MARK: 外观

    @Published var theme: ThemeChoice {
        didSet {
            defaults.set(theme.rawValue, forKey: "settings.theme")
            // 令牌按外观在绘制时解析，换 NSApp.appearance 即全局生效（§4.5「主题」）
            Theme.applyTheme(theme)
        }
    }
    @Published var accent: AccentChoice {
        didSet {
            defaults.set(accent.rawValue, forKey: "settings.accent")
            // 品牌色是绘制时解析的动态色：写入色阶并触发一次全局重解析（§4.5「强调色即时生效」）
            Theme.accentRamp = AccentRamp.forChoice(accent)
            Theme.refreshAccent()
        }
    }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "settings.reduceMotion") } }
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: "settings.showLyrics") } }

    // MARK: 媒体库

    @Published var imageCacheLimitGB: Int { didSet { defaults.set(imageCacheLimitGB, forKey: "settings.cacheLimit") } }
    @Published var lastLibraryRefresh: Date? { didSet { defaults.set(lastLibraryRefresh, forKey: "settings.lastRefresh") } }

    private let defaults = UserDefaults.standard

    private init() {
        autoConnect = defaults.object(forKey: "settings.autoConnect") as? Bool ?? true
        startPage = StartPage(rawValue: defaults.string(forKey: "settings.startPage") ?? "") ?? .home
        continuePlayingOnClose = defaults.object(forKey: "settings.continueOnClose") as? Bool ?? true
        language = Language(rawValue: defaults.string(forKey: "settings.language") ?? "") ?? .system

        quality = Quality(rawValue: defaults.string(forKey: "settings.quality") ?? "") ?? .original
        preferDirectPlay = defaults.object(forKey: "settings.directPlay") as? Bool ?? true
        crossfadeSeconds = defaults.object(forKey: "settings.crossfade") as? Double ?? 0
        volumeNormalization = defaults.object(forKey: "settings.normalization") as? Bool ?? false
        reportInterval = defaults.object(forKey: "settings.reportInterval") as? Double ?? 10

        theme = ThemeChoice(rawValue: defaults.string(forKey: "settings.theme") ?? "") ?? .light
        accent = AccentChoice(rawValue: defaults.string(forKey: "settings.accent") ?? "") ?? .indigo
        reduceMotion = defaults.object(forKey: "settings.reduceMotion") as? Bool ?? false
        showLyrics = defaults.object(forKey: "settings.showLyrics") as? Bool ?? false

        imageCacheLimitGB = defaults.object(forKey: "settings.cacheLimit") as? Int ?? 2
        lastLibraryRefresh = defaults.object(forKey: "settings.lastRefresh") as? Date

        // init 不触发 didSet，这里显式把强调色色阶同步给 Theme
        Theme.accentRamp = AccentRamp.forChoice(accent)
    }

    /// 是否需要走服务器转码（音质非原始，或关闭了直连优先）
    var requiresTranscode: Bool {
        !preferDirectPlay || quality != .original
    }

    /// 换曲淡入时长（0 = 不淡入）
    var fadeDuration: Double {
        min(max(crossfadeSeconds, 0), 12)
    }

    func clearImageCache() {
        ImageCache.shared.removeAll()
    }
}

// MARK: - 应用级「减少动态效果」

private struct AppReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 系统「减少动态效果」或应用内设置的合并结果（§7）。
    var appReduceMotion: Bool {
        get { self[AppReduceMotionKey.self] }
        set { self[AppReduceMotionKey.self] = newValue }
    }
}
