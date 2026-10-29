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
        /// v4 纸墨的签名色（默认强调色的对应档）
        case signal = "信号红"
        case indigo = "靛蓝"
        case teal = "泛音青"
        case purple = "紫"

        var id: String { rawValue }

        var color: Color {
            // 色块用固定值：否则选中泛音青后，靛蓝色块会跟着变成青色
            switch self {
            case .signal: return Theme.accentSignal
            case .indigo: return Theme.accentIndigo
            case .teal: return Theme.accentTeal
            case .purple: return Theme.accentPurple
            }
        }

        /// 是否是某一套视觉风格的「签名色」。
        ///
        /// 切换风格时只搬这两个（见 `visualStyle` 的 didSet）：泛音青 / 紫是用户显式选的个性色，
        /// 风格切换不该动它。
        var isGlassSignature: Bool { self == .indigo }
        var isPaperSignature: Bool { self == .signal }
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

    /// 队列播完后自动续播相似歌曲（Jellyfin InstantMix；飞牛退化为服务端随机）。
    @Published var autoContinue: Bool { didSet { defaults.set(autoContinue, forKey: "settings.autoContinue") } }

    /// 歌词偏移（秒）：正值 = 歌词整体推迟显示，用来补偿蓝牙 / 外接音频的延迟。
    ///
    /// 存原始值，使用侧通过 `effectiveLyricsOffset` 夹到 ±2 秒；这样拖动滑杆时不会被
    /// 回写打断（与 `crossfadeSeconds` 的处理方式一致）。
    @Published var lyricsOffsetSeconds: Double { didSet { defaults.set(lyricsOffsetSeconds, forKey: "settings.lyricsOffset") } }

    /// 夹到 ±2 秒后的歌词偏移（UI 计算当前行时用这个）。
    var effectiveLyricsOffset: Double { min(max(lyricsOffsetSeconds, -2), 2) }

    // MARK: 外观

    @Published var theme: ThemeChoice {
        didSet {
            defaults.set(theme.rawValue, forKey: "settings.theme")
            // 令牌按外观在绘制时解析，换 NSApp.appearance 即全局生效（§4.5「主题」）
            Theme.applyTheme(theme)
        }
    }

    /// 视觉风格：玻璃（v3，默认）/ 纸墨（v4）。
    ///
    /// `Theme` 侧的令牌缓存重建 + 全局重解析都在 `Theme.applyVisualStyle` 里，
    /// 视图树则由持有呈现层的那一层（`MainView` / `SettingsView` / `RootView` 登录分支）
    /// 用 `.id(appVisualStyle)` 重建，旧布局与旧材质不会残留。
    @Published var visualStyle: VisualStyle {
        didSet {
            // `followSignatureAccent()` 会再写一次 `visualStyle`（同一个值），
            // 那次进入在这里直接收敛 —— 没有这个 guard 就会把色阶与令牌缓存白重建一遍
            // （令牌实例稳定性是硬约束，见 `AccentTokens`）。别删。
            guard visualStyle != oldValue else { return }
            defaults.set(visualStyle.rawValue, forKey: "settings.visualStyle")
            // ⚠️ 顺序不能反：强调色阶是**按风格取值**的（纸墨色阶 ≠ 玻璃色阶），
            // 所以必须先用**目标风格**重建色阶，再重建风格化令牌缓存 ——
            // `accentRamp` 的 didSet 会按「当时」的 `isPaper` 重建强调令牌，
            // 反过来（先切风格）会留下一份「新风格 + 旧色阶」的缓存：
            // 实测玻璃下选泛音青再切纸墨，侧栏选中条会是玻璃青 #12B8A6 而不是纸墨青 #2E6E66。
            Theme.accentRamp = AccentRamp.forChoice(accent, style: visualStyle)
            Theme.applyVisualStyle(visualStyle)
            followSignatureAccent()
        }
    }

    @Published var accent: AccentChoice {
        didSet {
            defaults.set(accent.rawValue, forKey: "settings.accent")
            // 品牌色是绘制时解析的动态色：写入色阶并触发一次全局重解析（§4.5「强调色即时生效」）。
            // 纸墨模式下强调色阶是另一套值（`AccentRamp.forChoice(_:style:)`），
            // 所以风格切换必须连带重建色阶 —— 由 `Theme.applyVisualStyle` 负责。
            Theme.accentRamp = AccentRamp.forChoice(accent, style: Theme.visualStyle)
            Theme.refreshAccent()
        }
    }
    @Published var reduceMotion: Bool { didSet { defaults.set(reduceMotion, forKey: "settings.reduceMotion") } }
    @Published var showLyrics: Bool { didSet { defaults.set(showLyrics, forKey: "settings.showLyrics") } }

    /// 风格切换时的签名色跟随（契约 §4）：只搬「另一套风格的签名色」。
    ///
    /// glass→paper 且当前是靛蓝 → 换信号红；paper→glass 且当前是信号红 → 换靛蓝。
    /// 泛音青 / 紫是用户显式选的个性色，不动。
    ///
    /// ⚠️ 必须**幂等**：本方法会再写一次 `visualStyle`（触发它的 didSet 第二遍）。
    /// 第二次进来时 `Theme.applyVisualStyle` 因值相等直接返回，而这里也找不到可搬的色，
    /// 于是自然收敛 —— 这个不变量别改（改错了就是无限递归）。
    private func followSignatureAccent() {
        switch (visualStyle, accent) {
        case (.paper, .indigo):
            accent = .signal
            visualStyle = .paper
        case (.glass, .signal):
            accent = .indigo
            visualStyle = .glass
        default:
            break
        }
    }

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
        autoContinue = defaults.object(forKey: "settings.autoContinue") as? Bool ?? true
        lyricsOffsetSeconds = defaults.object(forKey: "settings.lyricsOffset") as? Double ?? 0

        theme = ThemeChoice(rawValue: defaults.string(forKey: "settings.theme") ?? "") ?? .light
        accent = AccentChoice(rawValue: defaults.string(forKey: "settings.accent") ?? "") ?? .indigo
        visualStyle = VisualStyle(rawValue: defaults.string(forKey: "settings.visualStyle") ?? "") ?? .glass
        reduceMotion = defaults.object(forKey: "settings.reduceMotion") as? Bool ?? false
        showLyrics = defaults.object(forKey: "settings.showLyrics") as? Bool ?? false

        imageCacheLimitGB = defaults.object(forKey: "settings.cacheLimit") as? Int ?? 2
        lastLibraryRefresh = defaults.object(forKey: "settings.lastRefresh") as? Date

        // init 不触发 didSet，这里显式把风格与强调色色阶同步给 Theme。
        //
        // 顺序不能反：`applyVisualStyle` 会用「当前色阶」建令牌缓存，所以风格必须先进 Theme，
        // 色阶再覆盖；反过来会留下一份按旧色阶构造的缓存（玻璃/纸墨的染色浓度不同）。
        Theme.visualStyle = visualStyle
        Theme.accentRamp = AccentRamp.forChoice(accent, style: visualStyle)
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
