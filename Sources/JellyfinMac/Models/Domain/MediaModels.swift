import Foundation

// MARK: - 后端标识

/// 支持的媒体后端。运行时一次只有一个「活动后端」，但数据模型与状态层
/// 不做单后端假设（为将来「多服务器并存」留出形状）。
enum BackendKind: String, Codable, CaseIterable, Identifiable {
    case jellyfin
    case feiniu

    var id: String { rawValue }

    /// 登录页 / 设置页展示名
    var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .feiniu: return "飞牛音乐"
        }
    }

    /// 服务器地址输入框的占位文案
    var serverPlaceholder: String {
        switch self {
        case .jellyfin: return "http://192.168.1.10:8096"
        case .feiniu: return "FN ID（如 ravooo）或 NAS 地址"
        }
    }

    /// 该后端是否支持「服务器地址可省略 http:// 前缀」的宽松写法。
    var needsSchemeHint: Bool { self == .jellyfin }

    /// 地址输入框下方的说明（飞牛支持 FN ID / 地址两种写法）
    var serverHint: String? {
        switch self {
        case .jellyfin: return nil
        case .feiniu: return "填 FN ID（如 ravooo）可走 FN Connect 远程访问；也可直接填 NAS 地址，如 192.168.1.10:5666"
        }
    }
}

// MARK: - 条目种类

/// 领域层统一条目种类。
///
/// 为什么是「一个 struct + kind」而不是 `Track`/`Album`/`Artist` 三个类型：
/// Overtone 的界面从一开始就把条目当**多态**用 —— 播放列表混装、搜索结果按种类分组、
/// 封面卡/曲目表都只读同一批字段（标题/副标题/封面/收藏/时长）。拆成三个类型会让
/// 47 处 UI 调用点全部变成泛型或协议存在类型，收益（类型上不可能把专辑当曲目传）
/// 远小于成本（每个组件都要泛型化）。真正的边界在**后端**：后端把各自的 wire 格式
/// 映射成这一种领域条目，UI 与状态层只认它。
enum MediaKind: String, Codable, CaseIterable {
    case track
    case album
    case artist
    case playlist
    case folder

    var displayName: String {
        switch self {
        case .track: return "歌曲"
        case .album: return "专辑"
        case .artist: return "艺人"
        case .playlist: return "播放列表"
        case .folder: return "文件夹"
        }
    }
}

// MARK: - 封面引用

enum ArtworkKind: String, Codable, Hashable {
    case primary
    case thumbnail
}

/// 封面引用：**URL 的替代品**。
///
/// 直接用 `URL` 有三个问题：① 飞牛的封面地址可能逐请求签名，URL 每次都不同 →
/// 现有 `ImageCache` 以 `absoluteString` 为键会全部 miss（滚动即重下）；
/// ② 不同后端 URL 构造方式不同，模型层不该知道；③ 换后端后旧缓存应失效。
/// 所以领域层只传「引用」，由活动后端在渲染前解析成 URL，缓存键用 `cacheKey`
/// （与签名无关的稳定值）。
struct ArtworkRef: Codable, Hashable {
    let backend: BackendKind
    let itemID: String
    var kind: ArtworkKind = .primary
    /// 服务端版本标记（Jellyfin 的 ImageTag）；飞牛没有则为 nil
    var version: String?
    /// 请求宽度（后端可据此选图，或仅用作缓存分档）
    var maxWidth: Int = 400
    /// 视觉身份（与后端无关，见 `ContentIdentity.visualKey`）。
    ///
    /// 用于**跨后端共用一份封面缓存**：同一首歌在 Jellyfin 与飞牛各有一份图，
    /// 没必要下载两遍。`nil` 表示不参与共享。
    var visualKey: String?

    /// 稳定缓存键：不含签名/时间戳，换标题图后靠 `version` 失效
    var cacheKey: String {
        "\(backend.rawValue)|\(itemID)|\(kind.rawValue)|\(version ?? "-")|\(maxWidth)"
    }

    /// 跨后端共享缓存键（`ImageCache` 的别名键）。没有视觉身份时为 nil。
    var contentCacheKey: String? {
        guard let visualKey else { return nil }
        return "content|\(visualKey)|\(maxWidth)"
    }
}

// MARK: - 用户数据

/// 用户维度数据（收藏 / 播放统计 / 续播位置）。
///
/// 飞牛音乐只提供收藏，没有播放次数与续播位置 —— 那两项由本地存储兜底
/// （`LocalLibraryState`），但**字段位置不变**，UI 无需区分数据来自服务端还是本地。
struct MediaUserData: Codable, Hashable {
    var isFavorite: Bool = false
    var playCount: Int = 0
    var lastPlayed: Date?
    /// 续播位置（秒）；0 表示没有进度
    var resumePosition: Double = 0
    var isPlayed: Bool = false

    static let empty = MediaUserData()

    /// 进度比例（0…1）
    func progressRatio(duration: Double) -> Double {
        guard duration > 0, resumePosition > 0 else { return 0 }
        return min(max(resumePosition / duration, 0), 1)
    }
}

// MARK: - 领域条目

/// 统一的媒体条目（曲目 / 专辑 / 艺人 / 播放列表）。
struct MediaItem: Identifiable, Hashable, Codable {
    /// 后端内唯一 id（Jellyfin 的 BaseItemDto.Id / 飞牛的 GUID）
    let id: String
    let backend: BackendKind
    let kind: MediaKind

    var title: String
    /// 副标题：曲目 = 艺人，专辑 = 专辑艺人，艺人 = 「N 张专辑」
    var subtitle: String?
    /// 归属专辑（曲目与专辑自身）
    var albumID: String?
    var albumTitle: String?
    /// 归属艺人
    var artistID: String?
    var artistName: String?

    /// 时长（秒）
    var duration: Double = 0
    var trackNumber: Int?
    var discNumber: Int?
    var year: Int?
    var dateAdded: Date?

    var artwork: ArtworkRef?
    /// 流派（可能为空；飞牛与 Jellyfin 都能给）
    var genres: [String] = []
    /// 子项数量：专辑 = 曲目数，艺人 = 专辑数（后端不提供时 nil，UI 需自行降级）
    var childCount: Int?
    /// 音频格式（flac/mp3/…），用于播放能力判定与信息页
    var format: String?
    /// 比特率 **bps**（Jellyfin `MediaSources.BitRate` 即 bps；飞牛侧需换算到 bps）
    var bitrate: Int?
    var sampleRate: Int?
    var bitDepth: Int?
    var channels: Int?

    var userData: MediaUserData = .empty

    // MARK: 便捷判定（替代原先散落的 `dto.type == "Audio"` 字符串比较）

    var isTrack: Bool { kind == .track }
    var isAlbum: Bool { kind == .album }
    var isArtist: Bool { kind == .artist }
    var isPlaylist: Bool { kind == .playlist }

    var isFavorite: Bool {
        get { userData.isFavorite }
        set { userData.isFavorite = newValue }
    }

    /// 与后端无关的内容身份（本地状态与封面缓存以此跨后端共享，见 `ContentIdentity`）
    var contentKey: String { ContentIdentity.key(for: self) }

    /// 展示用封面引用（默认 400pt 档）。
    ///
    /// 顺带把**视觉身份**写进引用：`ImageCache` 用它做跨后端别名，
    /// 于是同一首歌/同一张专辑在 Jellyfin / 飞牛之间只会存一份图。
    func artworkRef(width: Int = 400) -> ArtworkRef? {
        guard let artwork else { return nil }
        var ref = artwork
        ref.maxWidth = width
        ref.visualKey = ContentIdentity.visualKey(for: self)
        return ref
    }

    /// 去掉用户数据的副本（用于本地兜底覆盖后再合并）
    var withoutUserData: MediaItem {
        var copy = self
        copy.userData = .empty
        return copy
    }
}

// MARK: - 媒体库

/// 媒体库（Jellyfin 的 CollectionFolder；飞牛音乐只有一个「全库」或按授权目录拆分）
struct MusicLibrary: Identifiable, Hashable {
    let id: String
    let name: String
    let backend: BackendKind
}

// MARK: - 用户

struct BackendUser: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let backend: BackendKind
}

// MARK: - 分页

/// 分页结果。`total` 未知时由实现方给 `items.count` 的保守值。
struct Paged<Element> {
    var items: [Element]
    var total: Int
    var offset: Int
    var limit: Int

    var hasMore: Bool { offset + items.count < total }

    static func single(_ items: [Element]) -> Paged<Element> {
        Paged(items: items, total: items.count, offset: 0, limit: max(items.count, 1))
    }

    static var empty: Paged<Element> { Paged(items: [], total: 0, offset: 0, limit: 0) }
}

// MARK: - 排序

/// 列表排序方式（跨后端统一语义，后端各自翻译成自己的参数）
enum MediaSort: String, CaseIterable, Identifiable {
    case name
    case dateAdded
    case playCount
    case albumOrder

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name: return "按名称"
        case .dateAdded: return "按添加时间"
        case .playCount: return "按播放次数"
        case .albumOrder: return "按唱片顺位"
        }
    }
}

// MARK: - 搜索

struct SearchResults {
    var tracks: [MediaItem] = []
    var albums: [MediaItem] = []
    var artists: [MediaItem] = []
    /// true = 服务端不支持搜索，结果是「已加载曲库」的本地匹配（UI 应提示范围有限）
    var isLocalFallback: Bool = false

    var isEmpty: Bool { tracks.isEmpty && albums.isEmpty && artists.isEmpty }

    static let empty = SearchResults()
}

// MARK: - 歌词

struct LyricLine: Codable, Hashable {
    var text: String
    /// 起始秒；纯文本歌词为 nil
    var start: Double?

    var textOrPlaceholder: String { text.isEmpty ? "♪" : text }
}

// MARK: - 播放列表（远程）

/// 远程播放列表（服务器侧）。本地 `Playlist` 通过 `remoteID` 与之绑定。
struct RemotePlaylist: Identifiable, Hashable {
    let id: String
    var name: String
    var trackCount: Int
}

/// 远程播放列表里的一条目（`entryID` 用于按条目删除，Jellyfin 需要）
struct RemotePlaylistEntry {
    let track: MediaItem
    let entryID: String?
}
