import Foundation

// MARK: - Jellyfin 线上格式（wire DTO）
//
// 这一层是**协议私有**的：只被 `JellyfinBackend` 使用，不出现在状态层与 UI。
// 解码策略统一由 `HTTPClient.keyDecodingStrategy = .custom(camelize)` 处理
// （`Items`→`items`、`ParentId`→`parentId`）。

struct JellyfinUserDto: Codable {
    let id: String
    let name: String?
}

struct JellyfinAuthRequest: Codable {
    let username: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

struct JellyfinAuthResponse: Codable {
    let user: JellyfinUserDto
    let accessToken: String
}

struct JellyfinArtistRef: Codable {
    let id: String
    let name: String?
}

struct JellyfinUserDataDto: Codable {
    let played: Bool?
    let playbackPositionTicks: Int64?
    let isFavorite: Bool?
    let playCount: Int?
    let lastPlayedDate: String?
}

struct JellyfinStreamDto: Codable {
    let type: String?
    let codec: String?
    let displayTitle: String?
    let bitRate: Int?
    let sampleRate: Int?
    let channels: Int?
    let bitDepth: Int?
}

struct JellyfinMediaSourceDto: Codable {
    let id: String?
    let container: String?
    let runTimeTicks: Int64?
    let size: Int64?
    let bitrate: Int?
    let supportsDirectStream: Bool?
    let mediaStreams: [JellyfinStreamDto]?
}

/// 条目（曲目 / 专辑 / 艺人 / 播放列表 / 文件夹）
struct JellyfinItemDto: Codable {
    let id: String
    let name: String?
    let type: String?
    let collectionType: String?
    let imageTags: [String: String]?
    let albumID: String?
    let album: String?
    let albumArtist: String?
    let artists: [String]?
    let artistItems: [JellyfinArtistRef]?
    let runTimeTicks: Int64?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let productionYear: Int?
    let dateCreated: String?
    let childCount: Int?
    let genres: [String]?
    let playlistItemID: String?
    let userData: JellyfinUserDataDto?
    let mediaSources: [JellyfinMediaSourceDto]?
    let primaryImageTag: String?
}

struct JellyfinQueryResult<Item: Codable>: Codable {
    let items: [Item]?
    let totalRecordCount: Int?
}

// MARK: - 请求体

/// 播放进度上报（Jellyfin 的字段名是 PascalCase）
struct JellyfinPlaybackReport: Codable {
    let itemID: String
    let positionTicks: Int64
    let playMethod: String
    let isPaused: Bool

    enum CodingKeys: String, CodingKey {
        case itemID = "ItemId"
        case positionTicks = "PositionTicks"
        case playMethod = "PlayMethod"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(itemID, forKey: .itemID)
        try container.encode(positionTicks, forKey: .positionTicks)
        try container.encode(playMethod, forKey: .playMethod)
        try container.encode(isPaused, forKey: .isPaused)
        try container.encode(true, forKey: .canSeek)
    }

    init(itemID: String, positionTicks: Int64, playMethod: String, isPaused: Bool) {
        self.itemID = itemID
        self.positionTicks = positionTicks
        self.playMethod = playMethod
        self.isPaused = isPaused
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemID = try container.decode(String.self, forKey: .itemID)
        positionTicks = try container.decode(Int64.self, forKey: .positionTicks)
        playMethod = try container.decode(String.self, forKey: .playMethod)
        isPaused = try container.decode(Bool.self, forKey: .isPaused)
    }
}

/// 创建/更新播放列表（Jellyfin 反序列化大小写不敏感，camelCase 可接受）
struct JellyfinPlaylistRequest: Codable {
    let name: String
    let ids: [String]
    let mediaType: String
}

// MARK: - 歌词（Jellyfin 10.9+，`/Audio/{id}/Lyrics`）
//
// 线上格式：`{ Lyrics: [{ Text, Start(100ns ticks) }] }`。
// 领域层的 `LyricLine.start` 统一是**秒**，ticks→秒 的换算只发生在适配器里。

struct LyricsResponse: Codable {
    let lyrics: [LyricsWireLine]?
}

struct LyricsWireLine: Codable {
    let text: String?
    /// 起始时间（100ns ticks，无时间轴的纯文本歌词为 nil）
    let start: Double?
}

extension LyricsResponse {
    /// 转成领域歌词（秒时间轴）
    func domainLines() -> [LyricLine] {
        (lyrics ?? []).map { line in
            LyricLine(
                text: line.text ?? "",
                start: line.start.map { $0 / 10_000_000 }
            )
        }
    }
}
