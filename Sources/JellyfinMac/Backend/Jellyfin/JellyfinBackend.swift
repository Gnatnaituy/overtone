import Foundation

/// Jellyfin 后端适配器。
///
/// 职责：把 Jellyfin 的 wire 协议（PascalCase JSON、`MediaBrowser` 授权头、
/// `/Users/{uid}/Items` 查询风格、`/Audio/{id}/stream` 播放地址）翻译成领域模型。
/// 状态层与 UI 不直接接触这里的任何类型。
@MainActor
final class JellyfinBackend: MusicBackend {
    let kind: BackendKind = .jellyfin
    let capabilities = BackendCapabilities.jellyfin
    var playbackPreferences = PlaybackPreferences()

    private(set) var session: BackendSession?

    private var client: HTTPClient?

    /// 跨启动稳定的设备 ID（Jellyfin 以 DeviceId 识别设备；每次启动换 ID
    /// 会让服务端设备列表无限增长、多端进度归并出错）
    private static let deviceId: String = {
        let key = "clientDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = "mac-\(UUID().uuidString)"
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    private let appVersion = "1.0.0"

    private var clientName: String {
        let custom = UserDefaults.standard.string(forKey: "clientName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false ? custom! : "Overtone")
    }

    // MARK: - 会话

    func signIn(_ request: SignInRequest) async throws -> BackendSession {
        let normalized = try normalizeServer(request.server)
        let client = makeClient(baseURL: normalized, token: nil)
        let body = try JSONEncoder().encode(JellyfinAuthRequest(
            username: request.username,
            password: request.password
        ))
        let response: JellyfinAuthResponse = try await client.post("/Users/AuthenticateByName", body: body)
        let session = BackendSession(
            backend: .jellyfin,
            serverURL: normalized,
            username: request.username,
            token: response.accessToken,
            userID: response.user.id,
            userDisplayName: response.user.name ?? request.username,
            extraCookie: nil
        )
        self.session = session
        self.client = makeClient(baseURL: normalized, token: response.accessToken)
        return session
    }

    func validateSession(_ session: BackendSession) async throws -> BackendUser {
        let client = makeClient(baseURL: session.serverURL, token: session.token)
        let me: JellyfinUserDto = try await client.get("/Users/Me")
        self.session = BackendSession(
            backend: .jellyfin,
            serverURL: session.serverURL,
            username: me.name ?? session.username,
            token: session.token,
            userID: me.id,
            userDisplayName: me.name ?? session.username,
            extraCookie: nil
        )
        self.client = client
        return BackendUser(id: me.id, name: me.name ?? session.username, backend: .jellyfin)
    }

    func signOut() async {
        if let client {
            // 主动注销会话（失败无妨：本地状态已清）
            try? await client.postIgnoringResponse("/Sessions/Logout")
        }
        session = nil
        client = nil
    }

    // MARK: - 媒体库

    func libraries() async throws -> [MusicLibrary] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get("/Users/\(userId)/Views")
        let allowed: Set<String> = ["music", "mixed"]
        return (result.items ?? []).compactMap { dto in
            guard let collectionType = dto.collectionType, allowed.contains(collectionType) else { return nil }
            return MusicLibrary(
                id: dto.id,
                name: dto.name ?? "音乐库",
                backend: .jellyfin
            )
        }
    }

    // MARK: - 浏览

    func items(
        in libraryID: String?,
        kind: MediaKind,
        sort: MediaSort,
        offset: Int,
        limit: Int
    ) async throws -> Paged<MediaItem> {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: Self.includeType(kind)),
            URLQueryItem(name: "Fields", value: kind == .album ? "Overview,DateCreated" : "Overview"),
            URLQueryItem(name: "EnableImages", value: "true"),
            URLQueryItem(name: "ImageTypeLimit", value: "1"),
        ]
        if let libraryID, !libraryID.isEmpty {
            query.append(URLQueryItem(name: "ParentId", value: libraryID))
        }
        for (name, value) in Self.sortParameters(sort) {
            query.append(URLQueryItem(name: name, value: value))
        }
        if limit > 0 {
            query.append(URLQueryItem(name: "Limit", value: String(limit)))
        }
        if offset > 0 {
            query.append(URLQueryItem(name: "StartIndex", value: String(offset)))
        }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items",
            query: query
        )
        let items = (result.items ?? []).map { mapItem($0, kind: kind) }
        return Paged(
            items: items,
            total: result.totalRecordCount ?? items.count,
            offset: offset,
            limit: limit
        )
    }

    func albumTracks(albumID: String) async throws -> [MediaItem] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: albumID),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "Overview"),
                URLQueryItem(name: "Limit", value: "1000"),
            ]
        )
        return (result.items ?? []).map { mapItem($0, kind: .track) }
    }

    func artistAlbums(artistID: String) async throws -> [MediaItem] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: artistID),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Fields", value: "Overview,DateCreated"),
                URLQueryItem(name: "Limit", value: "500"),
            ]
        )
        return (result.items ?? []).map { mapItem($0, kind: .album) }
    }

    func artistTracks(artistID: String) async throws -> [MediaItem] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ArtistIds", value: artistID),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "Fields", value: "Overview"),
                URLQueryItem(name: "Limit", value: "2000"),
            ]
        )
        return (result.items ?? []).map { mapItem($0, kind: .track) }
    }

    func search(term: String, limit: Int) async throws -> SearchResults {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items/Search",
            query: [
                URLQueryItem(name: "SearchTerm", value: term),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio,MusicAlbum,MusicArtist"),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
        )
        let items = (result.items ?? []).map { dto -> MediaItem in
            let kind: MediaKind
            switch dto.type {
            case "MusicArtist": kind = .artist
            case "MusicAlbum": kind = .album
            default: kind = .track
            }
            return mapItem(dto, kind: kind)
        }
        return SearchResults(
            tracks: items.filter { $0.kind == .track },
            albums: items.filter { $0.kind == .album },
            artists: items.filter { $0.kind == .artist }
        )
    }

    /// 相似歌曲 / 自动续播：Jellyfin 的 `/Items/{id}/InstantMix`。
    ///
    /// 返回顺序由服务端按相似度排序；`limit` 是**想要追加的曲目数**，
    /// 服务端会剔除种子本身与自己库里不可播的条目，实际数量可能略少。
    func instantMix(seedID: String, limit: Int) async throws -> [MediaItem] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Items/\(seedID)/InstantMix",
            query: [
                URLQueryItem(name: "userId", value: userId),
                URLQueryItem(name: "limit", value: String(max(limit, 1))),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Fields", value: "MediaSources,Genres"),
            ]
        )
        return (result.items ?? []).map { mapItem($0, kind: .track) }
    }

    // MARK: - 媒体

    func artworkURL(_ ref: ArtworkRef) -> URL? {
        guard let client else { return nil }
        var path = "/Items/\(ref.itemID)/Images/"
        switch ref.kind {
        case .primary: path += "Primary"
        case .thumbnail: path += "Thumb"
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "maxWidth", value: String(ref.maxWidth)),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let version = ref.version { query.append(URLQueryItem(name: "tag", value: version)) }
        if let token = session?.token { query.append(URLQueryItem(name: "api_key", value: token)) }
        return try? client.url(path: path, query: query)
    }

    func lyrics(trackID: String) async throws -> [LyricLine] {
        guard let client else { throw MusicBackendError.notSignedIn }
        let response: LyricsResponse = try await client.get("/Audio/\(trackID)/Lyrics")
        return response.domainLines()
    }

    func playableSource(for item: MediaItem) async throws -> PlayableSource {
        guard let client, session != nil else { throw MusicBackendError.notSignedIn }
        var query: [URLQueryItem] = []
        let preferences = playbackPreferences
        if preferences.requiresTranscode {
            // 交给服务器转码到目标码率（AVPlayer 能吃 mp3）
            query.append(URLQueryItem(name: "static", value: "false"))
            query.append(URLQueryItem(name: "audioCodec", value: "mp3"))
            query.append(URLQueryItem(name: "transcodeContainer", value: "mp3"))
            if let bitrate = preferences.targetBitrate {
                query.append(URLQueryItem(name: "maxAudioBitrate", value: String(bitrate * 1000)))
            }
            if preferences.normalizeVolume {
                query.append(URLQueryItem(name: "enableAudioNormalization", value: "true"))
            }
        } else {
            query.append(URLQueryItem(name: "static", value: "true"))
        }
        if let token = session?.token {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        guard let url = try? client.url(path: "/Audio/\(item.id)/stream", query: query) else {
            throw MusicBackendError.invalidServer("无法构造播放地址")
        }
        return PlayableSource(
            url: url,
            authorization: nil,
            isHLS: false,
            playMethod: preferences.requiresTranscode ? .transcode : .directPlay
        )
    }

    // MARK: - 写

    func setFavorite(itemID: String, kind: MediaKind, favorite: Bool) async throws {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        if favorite {
            try await client.postIgnoringResponse("/Users/\(userId)/FavoriteItems/\(itemID)")
        } else {
            try await client.deleteIgnoringResponse("/Users/\(userId)/FavoriteItems/\(itemID)")
        }
    }

    func report(_ event: PlaybackEvent) async {
        guard let client else { return }
        let kind: String
        switch event.kind {
        case .started: kind = "/Sessions/Playing"
        case .progress: kind = "/Sessions/Playing/Progress"
        case .stopped: kind = "/Sessions/Playing/Stopped"
        }
        let body = JellyfinPlaybackReport(
            itemID: event.itemID,
            positionTicks: Int64(event.position * 10_000_000),
            playMethod: event.playMethod.rawValue,
            isPaused: event.isPaused && event.kind != .stopped
        )
        guard let data = try? JSONEncoder().encode(body) else { return }
        // 上报失败静默：进度不是关键路径，不值得把错误抛到 UI
        try? await client.postIgnoringResponse(kind, body: data)
    }

    // MARK: - 远程播放列表

    func remotePlaylists() async throws -> [RemotePlaylist] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                URLQueryItem(name: "Recursive", value: "true"),
            ]
        )
        return (result.items ?? []).map {
            RemotePlaylist(id: $0.id, name: $0.name ?? "播放列表", trackCount: $0.childCount ?? 0)
        }
    }

    func remotePlaylistEntries(id: String) async throws -> [RemotePlaylistEntry] {
        guard let userId = session?.userID, let client else { throw MusicBackendError.notSignedIn }
        let result: JellyfinQueryResult<JellyfinItemDto> = try await client.get(
            "/Playlists/\(id)/Items",
            query: [URLQueryItem(name: "UserId", value: userId)]
        )
        return (result.items ?? []).map { dto in
            RemotePlaylistEntry(track: mapItem(dto, kind: .track), entryID: dto.playlistItemID)
        }
    }

    func createRemotePlaylist(name: String, trackIDs: [String]) async throws -> RemotePlaylist {
        guard let client else { throw MusicBackendError.notSignedIn }
        let body = try JSONEncoder().encode(
            JellyfinPlaylistRequest(name: name, ids: trackIDs, mediaType: "Audio")
        )
        let created: JellyfinItemDto = try await client.post("/Playlists", body: body)
        return RemotePlaylist(id: created.id, name: created.name ?? name, trackCount: trackIDs.count)
    }

    func updateRemotePlaylist(id: String, name: String, trackIDs: [String]) async throws {
        guard let client else { throw MusicBackendError.notSignedIn }
        let body = try JSONEncoder().encode(
            JellyfinPlaylistRequest(name: name, ids: trackIDs, mediaType: "Audio")
        )
        try await client.postIgnoringResponse("/Playlists/\(id)", body: body)
    }

    func deleteRemotePlaylist(id: String) async throws {
        guard let client else { throw MusicBackendError.notSignedIn }
        // Jellyfin 10.10+ 播放列表删除走通用条目删除接口
        try await client.deleteIgnoringResponse("/Items/\(id)")
    }

    func addRemotePlaylistTracks(id: String, trackIDs: [String]) async throws {
        guard let client, let userId = session?.userID else { throw MusicBackendError.notSignedIn }
        try await client.postIgnoringResponse(
            "/Playlists/\(id)/Items",
            query: [
                URLQueryItem(name: "Ids", value: trackIDs.joined(separator: ",")),
                URLQueryItem(name: "UserId", value: userId),
            ]
        )
    }

    func removeRemotePlaylistEntries(id: String, entryIDs: [String]) async throws {
        guard let client else { throw MusicBackendError.notSignedIn }
        try await client.deleteIgnoringResponse(
            "/Playlists/\(id)/Items",
            query: [URLQueryItem(name: "EntryIds", value: entryIDs.joined(separator: ","))]
        )
    }

    // MARK: - 内部

    private func makeClient(baseURL: URL, token: String?) -> HTTPClient {
        let client = HTTPClient(baseURL: baseURL)
        client.keyDecodingStrategy = HTTPClient.pascalToCamel
        let name = clientName
        let deviceId = Self.deviceId
        let version = appVersion
        client.prepare = { request in
            var fields = [
                "Client=\"\(name)\"",
                "Device=\"Mac\"",
                "DeviceId=\"\(deviceId)\"",
                "Version=\"\(version)\"",
            ]
            if let token { fields.append("Token=\"\(token)\"") }
            request.setValue("MediaBrowser " + fields.joined(separator: ", "), forHTTPHeaderField: "Authorization")
        }
        return client
    }

    private func normalizeServer(_ raw: String) throws -> URL {
        let normalized = SessionPersistence.shared.normalize(server: raw)
        guard let url = URL(string: normalized) else {
            throw MusicBackendError.invalidServer("无法解析服务器地址")
        }
        return url
    }

    private static func includeType(_ kind: MediaKind) -> String {
        switch kind {
        case .track: return "Audio"
        case .album: return "MusicAlbum"
        case .artist: return "MusicArtist"
        case .playlist: return "Playlist"
        case .folder: return "Folder"
        }
    }

    private static func sortParameters(_ sort: MediaSort) -> [(String, String)] {
        switch sort {
        case .name:
            return [("SortBy", "SortName"), ("SortOrder", "Ascending")]
        case .dateAdded:
            return [("SortBy", "DateCreated"), ("SortOrder", "Descending")]
        case .playCount:
            return [("SortBy", "PlayCount"), ("SortOrder", "Descending")]
        case .albumOrder:
            return [("SortBy", "ParentIndexNumber,IndexNumber,SortName"), ("SortOrder", "Ascending")]
        }
    }

    private func mapItem(_ dto: JellyfinItemDto, kind: MediaKind) -> MediaItem {
        let artwork = ArtworkRef(
            backend: .jellyfin,
            itemID: dto.id,
            kind: .primary,
            version: dto.imageTags?["Primary"],
            maxWidth: 400
        )
        var userData = MediaUserData()
        if let data = dto.userData {
            userData.isFavorite = data.isFavorite ?? false
            userData.playCount = data.playCount ?? 0
            userData.lastPlayed = data.lastPlayedDate.flatMap(Self.parseDate)
            userData.resumePosition = Double(data.playbackPositionTicks ?? 0) / 10_000_000
            userData.isPlayed = data.played ?? false
        }
        let duration = Double(dto.runTimeTicks ?? 0) / 10_000_000
        return MediaItem(
            id: dto.id,
            backend: .jellyfin,
            kind: kind,
            title: dto.name ?? "未知",
            subtitle: kind == .artist ? nil : (dto.albumArtist ?? dto.artists?.first),
            albumID: dto.albumID,
            albumTitle: dto.album,
            artistID: dto.artistItems?.first?.id,
            artistName: dto.albumArtist ?? dto.artistItems?.first?.name,
            duration: duration,
            trackNumber: dto.indexNumber,
            discNumber: dto.parentIndexNumber,
            year: dto.productionYear,
            dateAdded: dto.dateCreated.flatMap(Self.parseDate),
            artwork: artwork,
            genres: dto.genres ?? [],
            childCount: dto.childCount,
            format: dto.mediaSources?.first?.container,
            bitrate: dto.mediaSources?.first?.bitrate,
            sampleRate: dto.mediaSources?.first?.mediaStreams?.first?.sampleRate,
            bitDepth: nil,
            channels: dto.mediaSources?.first?.mediaStreams?.first?.channels,
            userData: userData
        )
    }

    /// Jellyfin 的时间字符串可能是带小数秒的 ISO8601，也可能没有时区
    static func parseDate(_ raw: String) -> Date? {
        if let date = isoWithFractional.date(from: raw) { return date }
        if let date = isoPlain.date(from: raw) { return date }
        return nil
    }

    private static let isoWithFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
