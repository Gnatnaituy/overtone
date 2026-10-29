import Foundation

// MARK: - 错误

enum MusicBackendError: LocalizedError {
    case notSignedIn
    case unsupported(String)
    case invalidServer(String)
    case unauthorized(String)
    case server(String)
    case network(Error)
    case decoding
    case unplayable(reason: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "尚未登录"
        case .unsupported(let feature): return "当前服务器不支持\(feature)"
        case .invalidServer(let message): return "服务器地址无效：\(message)"
        case .unauthorized(let message): return message.isEmpty ? "账号或密码错误" : message
        case .server(let message): return "服务器错误：\(message)"
        case .network(let error): return "无法连接到服务器：\(error.localizedDescription)"
        case .decoding: return "数据解析失败"
        case .unplayable(let reason): return reason
        }
    }
}

// MARK: - 能力声明

/// 后端能力声明。
///
/// 这是「飞牛没有的功能留在本地」的开关：UI 与状态层读这份声明决定
/// 是走服务端还是本地兜底，而不是靠 `if backend == .feiniu` 硬编码。
struct BackendCapabilities {
    /// 列表服务端分页（飞牛强制分页；Jellyfin 不靠它也能全量）
    var serverPaging: Bool = false
    /// 播放进度上报（飞牛只有 track_play 事件，没有位置）
    var playbackProgress: Bool = false
    /// 播放统计（播放次数 / 最近播放时间）
    var playStats: Bool = false
    /// 曲目收藏读写
    var trackFavorites: Bool = true
    /// 专辑 / 艺人收藏
    var albumArtistFavorites: Bool = false
    /// 服务端转码
    var transcode: Bool = false
    /// 歌词
    var lyrics: Bool = false
    /// 远程播放列表读写
    var remotePlaylists: Bool = false
    /// 远程播放列表重排
    var playlistReorder: Bool = false
    /// 搜索
    var search: Bool = true
    /// 艺人 → 专辑 / 曲目浏览
    var artistBrowsing: Bool = true
    /// 相似歌曲 / 自动续播（Jellyfin InstantMix；飞牛只有服务端随机 roam）
    var instantMix: Bool = false

    static let jellyfin = BackendCapabilities(
        serverPaging: false,
        playbackProgress: true,
        playStats: true,
        trackFavorites: true,
        albumArtistFavorites: true,
        transcode: true,
        lyrics: true,
        remotePlaylists: true,
        playlistReorder: true,
        search: true,
        artistBrowsing: true,
        instantMix: true
    )

    static let feiniu = BackendCapabilities(
        serverPaging: true,
        playbackProgress: false,
        playStats: false,
        trackFavorites: true,
        albumArtistFavorites: false,
        transcode: true,
        lyrics: true,
        remotePlaylists: true,
        playlistReorder: false,
        search: false,
        artistBrowsing: true
    )
}

// MARK: - 会话

/// 登录凭据（后端各自解释 `server` 的形态：Jellyfin 是 http(s) 基址，
/// 飞牛是 NAS 地址 / 自定义域名 / FN ID）
struct SignInRequest {
    var server: String
    var username: String
    var password: String
    /// 可选：飞牛的安全码（`x-access-code`）
    var accessCode: String?
    /// 客户端显示名（Jellyfin 用于会话列表）
    var clientName: String?
}

struct BackendSession: Codable, Hashable {
    let backend: BackendKind
    /// 规范化后的服务基址（Jellyfin：`http://host:8096`；飞牛：`https://host/music`）
    let serverURL: URL
    let username: String
    /// 服务端会话凭据（Jellyfin 的 AccessToken；飞牛的 music-token Cookie 值）
    let token: String
    let userID: String
    let userDisplayName: String
    /// 飞牛 FN Connect 中继路由需要额外 Cookie
    var extraCookie: String?
    /// 通过 FN Connect 解析出来的 FN ID（直连为 nil）。
    /// 存下来是为了**中继地址变化 / 中继失效时能重新定位**（FN Connect 的基址并不稳定）。
    var fnID: String?
}

// MARK: - 播放授权与播放源

/// 媒体请求的凭据注入策略。
///
/// 飞牛的 `authx` 是**逐请求**签名（nonce + timestamp + path 参与 MD5），
/// 且广播时 AVPlayer 会自己发起 Range 请求 —— 所以播放器拿到的不能只是「一个 URL」，
/// 而必须是「URL + 按需重算请求头的能力」。
struct RequestAuthorization: Sendable {
    /// 给定绝对 URL 返回本次请求应带的头
    let headers: @Sendable (_ url: URL) -> [String: String]
    /// true = 头随时间变化（必须每请求重算 → 走 AVAssetResourceLoader）
    /// false = 头是常量（可以一次性塞进 AVURLAsset 的 HTTPHeaderFields）
    let isDynamic: Bool

    static func fixed(_ headers: [String: String]) -> RequestAuthorization {
        RequestAuthorization(headers: { _ in headers }, isDynamic: false)
    }
}

enum PlayMethod: String, Codable {
    case directPlay = "DirectPlay"
    case transcode = "Transcode"
}

/// 可播放源：播放器唯一需要的东西。
struct PlayableSource {
    let url: URL
    var authorization: RequestAuthorization?
    /// HLS 播放列表（`.m3u8`）
    var isHLS: Bool = false
    var playMethod: PlayMethod = .directPlay
    /// 服务端/客户端判定该格式无法播放时的说明（nil = 可播）
    var unplayableReason: String?
    /// 直连失败时可回退到的转码源（由播放器决定是否使用）
    var transcodeFallback: URL?
}

// MARK: - 播放事件

struct PlaybackEvent {
    enum Kind {
        case started
        case progress
        case stopped
    }

    var kind: Kind
    var itemID: String
    var position: Double
    var duration: Double
    var isPaused: Bool
    var playMethod: PlayMethod
}

// MARK: - 播放偏好

/// 播放偏好（由设置页写入，播放时由后端翻译成各自参数）。
struct PlaybackPreferences {
    /// 直连优先：true 时优先播放原始文件
    var preferDirectPlay: Bool = true
    /// 目标比特率（kbps）；nil = 不转码
    var targetBitrate: Int?
    /// 音量均衡
    var normalizeVolume: Bool = false

    var requiresTranscode: Bool { !preferDirectPlay || targetBitrate != nil }
}

// MARK: - 后端协议

/// 一个媒体后端的全部能力。状态层只认这个协议，不认具体实现。
///
/// 约定：
/// - 所有方法都是 `async throws`，实现方负责把各自的 wire 错误映射成 `MusicBackendError`；
/// - 不支持的能力用协议扩展的默认实现抛 `.unsupported`，实现方只实现自己真有的；
/// - 返回的 `MediaItem` 已映射成领域模型（含 `backend` 字段），UI 不需要知道来源格式。
@MainActor
protocol MusicBackend: AnyObject {
    var kind: BackendKind { get }
    var capabilities: BackendCapabilities { get }
    /// 当前会话（未登录为 nil）
    var session: BackendSession? { get }
    /// 播放偏好（设置页写入；后端据此决定直连还是转码）
    var playbackPreferences: PlaybackPreferences { get set }

    // MARK: 会话

    func signIn(_ request: SignInRequest) async throws -> BackendSession
    /// 校验已存会话是否仍有效，并返回服务端用户信息（失败抛错 → 触发重新登录）
    func validateSession(_ session: BackendSession) async throws -> BackendUser
    func signOut() async

    // MARK: 媒体库

    func libraries() async throws -> [MusicLibrary]

    // MARK: 浏览

    /// 统一列表接口：曲目 / 专辑 / 艺人
    func items(
        in libraryID: String?,
        kind: MediaKind,
        sort: MediaSort,
        offset: Int,
        limit: Int
    ) async throws -> Paged<MediaItem>

    /// 专辑内曲目（按唱片顺位排序）
    func albumTracks(albumID: String) async throws -> [MediaItem]
    /// 艺人名下专辑
    func artistAlbums(artistID: String) async throws -> [MediaItem]
    /// 艺人名下曲目
    func artistTracks(artistID: String) async throws -> [MediaItem]
    /// 搜索
    func search(term: String, limit: Int) async throws -> SearchResults
    /// 相似歌曲 / 自动续播：以 seed 曲目为种子取一批相似曲目（Jellyfin InstantMix）。
    /// 飞牛只有服务端随机 `roam`，无相似度端点 → 默认实现抛 `.unsupported`。
    func instantMix(seedID: String, limit: Int) async throws -> [MediaItem]

    // MARK: 媒体

    /// 把封面引用解析成可直接请求的 URL（飞牛可在此签名）
    func artworkURL(_ ref: ArtworkRef) -> URL?
    /// 给封面等**非 API 请求**补凭据（Jellyfin 把 token 放在 URL query 里，返回 nil 即可）。
    /// 飞牛的封面同样要 Cookie / authx，且经中继时还要 `mode=relay`。
    func authorizedImageRequest(for url: URL) -> URLRequest?
    func lyrics(trackID: String) async throws -> [LyricLine]
    func playableSource(for item: MediaItem) async throws -> PlayableSource

    // MARK: 写

    func setFavorite(itemID: String, kind: MediaKind, favorite: Bool) async throws
    /// 播放事件 / 进度上报（`capabilities.playbackProgress == false` 时实现方只记播放事件）
    func report(_ event: PlaybackEvent) async

    // MARK: 远程播放列表（可选能力）

    func remotePlaylists() async throws -> [RemotePlaylist]
    func remotePlaylistEntries(id: String) async throws -> [RemotePlaylistEntry]
    func createRemotePlaylist(name: String, trackIDs: [String]) async throws -> RemotePlaylist
    func updateRemotePlaylist(id: String, name: String, trackIDs: [String]) async throws
    func deleteRemotePlaylist(id: String) async throws
    func addRemotePlaylistTracks(id: String, trackIDs: [String]) async throws
    func removeRemotePlaylistEntries(id: String, entryIDs: [String]) async throws
}

// MARK: - 默认实现（不支持即抛错）

extension MusicBackend {
    func libraries() async throws -> [MusicLibrary] {
        [MusicLibrary(id: "default", name: kind.displayName, backend: kind)]
    }

    func albumTracks(albumID: String) async throws -> [MediaItem] {
        throw MusicBackendError.unsupported("专辑曲目浏览")
    }

    func artistAlbums(artistID: String) async throws -> [MediaItem] {
        throw MusicBackendError.unsupported("艺人专辑浏览")
    }

    func artistTracks(artistID: String) async throws -> [MediaItem] {
        throw MusicBackendError.unsupported("艺人曲目浏览")
    }

    func search(term: String, limit: Int) async throws -> SearchResults {
        throw MusicBackendError.unsupported("搜索")
    }

    func instantMix(seedID: String, limit: Int) async throws -> [MediaItem] {
        throw MusicBackendError.unsupported("自动续播")
    }

    func lyrics(trackID: String) async throws -> [LyricLine] {
        throw MusicBackendError.unsupported("歌词")
    }

    func setFavorite(itemID: String, kind: MediaKind, favorite: Bool) async throws {
        throw MusicBackendError.unsupported("收藏")
    }

    func report(_ event: PlaybackEvent) async {}

    /// 默认不需要额外凭据（Jellyfin 把 token 放进 URL query）
    func authorizedImageRequest(for url: URL) -> URLRequest? { nil }

    func remotePlaylists() async throws -> [RemotePlaylist] {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func remotePlaylistEntries(id: String) async throws -> [RemotePlaylistEntry] {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func createRemotePlaylist(name: String, trackIDs: [String]) async throws -> RemotePlaylist {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func updateRemotePlaylist(id: String, name: String, trackIDs: [String]) async throws {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func deleteRemotePlaylist(id: String) async throws {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func addRemotePlaylistTracks(id: String, trackIDs: [String]) async throws {
        throw MusicBackendError.unsupported("服务器播放列表")
    }

    func removeRemotePlaylistEntries(id: String, entryIDs: [String]) async throws {
        throw MusicBackendError.unsupported("服务器播放列表")
    }
}
