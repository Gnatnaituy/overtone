import Foundation

// MARK: - 认证

/// 请求体编码用（Jellyfin 要求 PascalCase 字段名），不受解码策略影响
struct AuthRequest: Codable {
    let username: String
    let password: String
    enum CodingKeys: String, CodingKey {
        case username = "Username"
        case password = "Pw"
    }
}

struct AuthenticateResponse: Codable {
    let user: UserDto
    let accessToken: String
}

struct UserDto: Codable, Identifiable {
    let id: String
    let name: String?
}

// MARK: - 媒体条目

struct BaseItemDto: Codable, Identifiable {
    let id: String
    let name: String?
    let serverId: String?
    let type: String?
    let mediaType: String?
    let overview: String?
    let productionYear: Int?
    let premiereDate: String?
    let communityRating: Double?
    let officialRating: String?
    let genres: [String]?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let seasonName: String?
    let indexNumber: Int?
    let indexNumberEnd: Int?
    let parentIndexNumber: Int?
    var userData: UserDataDto?
    let mediaSources: [MediaSourceInfo]?
    let collectionType: String?
    let isFolder: Bool?
    let childCount: Int?
    let albumArtist: String?
    let albumId: String?
    let album: String?
    /// 播放列表条目 id（用于删除服务器播放列表中的条目）
    let playlistItemId: String?
    /// 入库时间（首页「最近添加」排序用，需在 Fields 中显式请求）
    let dateCreated: String?
}

extension BaseItemDto: Hashable {
    static func == (lhs: BaseItemDto, rhs: BaseItemDto) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension BaseItemDto {
    var isMovie: Bool { type == "Movie" }
    var isSeries: Bool { type == "Series" }
    var isEpisode: Bool { type == "Episode" }
    var isAudio: Bool { mediaType == "Audio" }
    var isMusicAlbum: Bool { type == "MusicAlbum" }
    var isMusicArtist: Bool { type == "MusicArtist" }
    var runtimeSeconds: Double { Double(runTimeTicks ?? 0) / 10_000_000 }
    var resumeSeconds: Double { Double(userData?.playbackPositionTicks ?? 0) / 10_000_000 }
    var primaryImageTag: String? { imageTags?["Primary"] }
    var backdropImageTag: String? { backdropImageTags?.first }

    /// 音乐封面：曲目无图时回退到所属专辑
    func artworkURL(width: Int) -> URL? {
        if let tag = primaryImageTag {
            return APIClient.shared.imageURL(itemId: id, width: width, tag: tag)
        }
        if let albumId {
            return APIClient.shared.imageURL(itemId: albumId, width: width)
        }
        return nil
    }

    var typeDisplayName: String {
        switch type {
        case "Movie": return "电影"
        case "Series": return "剧集"
        case "Episode": return "单集"
        case "Season": return "季"
        case "MusicArtist": return "艺术家"
        case "MusicAlbum": return "专辑"
        case "Audio": return "音乐"
        case "BoxSet": return "合集"
        default: return "媒体"
        }
    }
}

struct UserDataDto: Codable {
    var played: Bool?
    var playbackPositionTicks: Int64?
    var isFavorite: Bool?
    var playCount: Int?
    var lastPlayedDate: String?
}

// MARK: - 歌词（Jellyfin 10.9+，/Audio/{id}/Lyrics）

struct LyricsResponse: Codable {
    let lyrics: [LyricLine]?
}

struct LyricLine: Codable {
    let text: String?
    /// 起始时间（100ns ticks，无时间轴的纯文本歌词为 nil）
    let start: Double?
}

extension LyricLine {
    var startSeconds: Double? { start.map { $0 / 10_000_000 } }
}

struct MediaSourceInfo: Codable {
    let id: String?
    let container: String?
    let runTimeTicks: Int64?
    let size: Int64?
    let mediaStreams: [MediaStream]?
    let supportsDirectStream: Bool?
}

struct MediaStream: Codable {
    let type: String?
    let codec: String?
    let displayTitle: String?
    let bitRate: Int?
    let sampleRate: Int?
    let channels: Int?
}

struct QueryResult<T: Codable>: Codable {
    let items: [T]?
    let totalRecordCount: Int?
}
