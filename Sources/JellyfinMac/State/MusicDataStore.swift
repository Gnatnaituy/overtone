import SwiftUI

/// 全局音乐数据：曲目 / 艺人 / 专辑一次加载，各页面共享（含播放列表映射、智能列表匹配）。
///
/// 改造要点：
/// 1. 只依赖 `MediaBackend` 协议，不再认识 Jellyfin 的 DTO；
/// 2. 加载走**分页循环**（飞牛强制分页，Jellyfin 也能接受 `Limit`/`StartIndex`），
///    而不是「一次把全库拉回来」；
/// 3. 服务端没有的用户数据（播放次数 / 续播位置 / 专辑艺人收藏）由
///    `LocalLibraryState` 合并进来 —— 字段位置不变，UI 不区分来源。
@MainActor
final class MusicDataStore: ObservableObject {
    static let shared = MusicDataStore()

    @Published private(set) var tracks: [MediaItem] = [] {
        didSet { rebuildDerivedData() }
    }
    @Published private(set) var artists: [MediaItem] = []
    @Published private(set) var albums: [MediaItem] = [] {
        didSet { rebuildAlbumDerivedData() }
    }
    @Published private(set) var isLoading = false
    /// 整库加载失败（三种条目全空时才置值；部分失败见 `isPartialFailure`）
    @Published private(set) var loadError: String?
    /// 有部分分页请求失败（仍有数据可用）
    @Published private(set) var isPartialFailure = false
    /// 曲库是否被截断（超过单次加载上限时提示用户）
    @Published private(set) var isTruncated = false

    /// 数据版本号：每次派生数据重算时自增（视图用 O(1) 比较替代全量数组比较）
    private(set) var dataRevision = 0

    var libraryID: String?

    /// 当前后端能力（UI 用它决定置灰 / 空态文案）
    var capabilities: BackendCapabilities {
        BackendRegistry.shared.active.capabilities
    }

    private var backend: MusicBackend { BackendRegistry.shared.active }

    // MARK: 派生数据缓存

    private var trackIndex: [String: MediaItem] = [:]
    private var albumIndex: [String: MediaItem] = [:]
    private var artistIndex: [String: MediaItem] = [:]
    private var cachedFavoriteTracks: [MediaItem] = []
    private var cachedRecentlyPlayedTracks: [MediaItem] = []
    private var cachedMostPlayedTracks: [MediaItem] = []
    private var cachedTracksByPlayCount: [MediaItem] = []
    private var cachedContinueEntries: [ContinueEntry] = []
    private var cachedAlbumsByDateAdded: [MediaItem] = []
    private var cachedAlbumsByName: [MediaItem] = []
    private var cachedAlbumsByArtist: [MediaItem] = []
    private var smartMatchCache: [String: [MediaItem]] = [:]

    /// 单次加载上限（防止上万首曲库把首屏拖垮；UI 会提示「已加载 N 首」）
    private let trackLimit = 5_000
    private let albumLimit = 3_000
    private let artistLimit = 3_000
    private let pageSize = 500

    private init() {}

    // MARK: - 派生数据

    var favoriteTracks: [MediaItem] { cachedFavoriteTracks }
    var mostPlayedTracks: [MediaItem] { cachedMostPlayedTracks }
    var recentlyPlayedTracks: [MediaItem] { cachedRecentlyPlayedTracks }
    var continueEntries: [ContinueEntry] { cachedContinueEntries }
    var albumsByDateAdded: [MediaItem] { cachedAlbumsByDateAdded }
    var albumsByName: [MediaItem] { cachedAlbumsByName }
    var albumsByArtist: [MediaItem] { cachedAlbumsByArtist }

    /// 「继续播放」条目：一张卡 = 一张专辑（去重键为专辑，无专辑时退回曲目自身）
    struct ContinueEntry: Identifiable {
        let track: MediaItem
        let albumKey: String

        var id: String { albumKey }

        var title: String { track.albumTitle ?? track.title }

        var subtitle: String {
            let artist = track.artistName ?? ""
            let remaining = max(track.duration - track.userData.resumePosition, 0)
            let remainText = remaining > 30
                ? "剩 \(max(Int((remaining / 60).rounded(.up)), 1)) 分钟"
                : ""
            return [artist, remainText].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        var progress: Double {
            track.userData.progressRatio(duration: track.duration)
        }

        var timeText: String {
            "\(formatPlaybackTime(track.userData.resumePosition)) / \(formatPlaybackTime(track.duration))"
        }
    }

    private func rebuildDerivedData() {
        trackIndex = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedFavoriteTracks = tracks.filter { $0.userData.isFavorite }
        cachedMostPlayedTracks = tracks
            .filter { $0.userData.playCount > 0 }
            .sorted { $0.userData.playCount > $1.userData.playCount }
        cachedTracksByPlayCount = tracks.sorted { $0.userData.playCount > $1.userData.playCount }
        cachedRecentlyPlayedTracks = tracks
            .compactMap { track -> (MediaItem, Date)? in
                guard let date = track.userData.lastPlayed else { return nil }
                return (track, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        cachedContinueEntries = Self.buildContinueEntries(from: tracks)
        smartMatchCache.removeAll(keepingCapacity: true)
        dataRevision &+= 1
    }

    /// 继续播放：未听完的曲目按最后播放时间倒序，按专辑取第一条，最多 6 张
    private static func buildContinueEntries(from tracks: [MediaItem]) -> [ContinueEntry] {
        let candidates = tracks
            .filter { $0.userData.resumePosition > 5 && $0.duration > 0 }
            .filter { $0.userData.resumePosition < $0.duration - 5 }
            .sorted { ($0.userData.lastPlayed ?? .distantPast) > ($1.userData.lastPlayed ?? .distantPast) }
        var seen = Set<String>()
        var result: [ContinueEntry] = []
        result.reserveCapacity(6)
        for track in candidates {
            let key = track.albumID ?? track.id
            guard seen.insert(key).inserted else { continue }
            result.append(ContinueEntry(track: track, albumKey: key))
            if result.count >= 6 { break }
        }
        return result
    }

    private func rebuildAlbumDerivedData() {
        albumIndex = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        artistIndex = Dictionary(artists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedAlbumsByDateAdded = albums.sorted {
            ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast)
        }
        cachedAlbumsByName = albums.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        cachedAlbumsByArtist = albums.sorted {
            ($0.artistName ?? "").localizedStandardCompare($1.artistName ?? "") == .orderedAscending
        }
    }

    // MARK: - 收藏

    /// 切换收藏：能力允许时先写服务端，成功后同步本地；不支持（如飞牛的专辑）则只写本地。
    func toggleFavorite(_ item: MediaItem) async {
        let newValue = !item.userData.isFavorite
        let supported: Bool
        switch item.kind {
        case .track: supported = capabilities.trackFavorites
        case .album, .artist: supported = capabilities.albumArtistFavorites
        case .playlist, .folder: supported = false
        }

        if supported {
            do {
                try await backend.setFavorite(itemID: item.id, kind: item.kind, favorite: newValue)
            } catch {
                // 服务端失败时不动本地状态，避免多端不一致
                return
            }
        } else {
            LocalLibraryState.shared.setFavorite(
                contentKey: item.contentKey,
                profileKey: AppState.shared.profileKey,
                favorite: newValue
            )
        }
        setFavoriteLocally(id: item.id, isFavorite: newValue)
    }

    func setFavoriteLocally(id: String, isFavorite: Bool) {
        if let i = tracks.firstIndex(where: { $0.id == id }) {
            tracks[i].userData.isFavorite = isFavorite
        }
        if let i = albums.firstIndex(where: { $0.id == id }) {
            albums[i].userData.isFavorite = isFavorite
        }
        if let i = artists.firstIndex(where: { $0.id == id }) {
            artists[i].userData.isFavorite = isFavorite
        }
    }

    func sortedTracks(by sort: MediaSort) -> [MediaItem] {
        switch sort {
        case .name:
            // 服务端已按名称返回，无需再排（飞牛的排序参数也支持字段,方向）
            return tracks
        case .playCount:
            return cachedTracksByPlayCount
        case .dateAdded:
            return tracks.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        case .albumOrder:
            return tracks.sorted {
                ($0.discNumber ?? 0, $0.trackNumber ?? 0) < ($1.discNumber ?? 0, $1.trackNumber ?? 0)
            }
        }
    }

    // MARK: - 加载

    func loadIfNeeded() async {
        guard tracks.isEmpty, !isLoading else { return }
        await load()
    }

    /// 等库 ID 就绪后加载（启动页直接落在资料库时可能早于 bootstrap）
    func ensureLoaded() async {
        if libraryID == nil { await resolveLibraryID() }
        await loadIfNeeded()
    }

    private func resolveLibraryID() async {
        if AppState.shared.libraries.isEmpty {
            await AppState.shared.loadLibraries()
        }
        libraryID = AppState.shared.libraries.first?.id
    }

    /// 切换后端后重置：库 ID 与全部缓存都要重新解析，否则会拿旧后端的 id 去新后端查
    func resetForBackendSwitch() async {
        libraryID = nil
        cachedProfileKey = nil
        cachedLocalOverrides = [:]
        tracks = []
        artists = []
        albums = []
        isTruncated = false
        isPartialFailure = false
        loadError = nil
        await reload()
    }

    /// 登出：清空内存态（本地兜底数据按账号作用域保留在磁盘上，重新登录同一账号还能续播）
    func clearAll() {
        libraryID = nil
        cachedProfileKey = nil
        cachedLocalOverrides = [:]
        tracks = []
        artists = []
        albums = []
        isTruncated = false
        isPartialFailure = false
        loadError = nil
    }

    func reload() async {
        if libraryID == nil { await resolveLibraryID() }
        tracks = []
        artists = []
        albums = []
        await load()
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        prepareLocalOverrides()
        defer { isLoading = false }
        if libraryID == nil { await resolveLibraryID() }
        let library = libraryID

        async let trackPage = loadAll(kind: .track, library: library, sort: .name, cap: trackLimit)
        async let albumPage = loadAll(kind: .album, library: library, sort: .name, cap: albumLimit)
        async let artistPage = loadAll(kind: .artist, library: library, sort: .name, cap: artistLimit)

        let (loadedTracks, trackTruncated, trackFailure) = await trackPage
        let (loadedAlbums, _, albumFailure) = await albumPage
        let (loadedArtists, _, artistFailure) = await artistPage
        let pageFailure = trackFailure ?? albumFailure ?? artistFailure

        tracks = loadedTracks.map(applyLocalOverrides)
        albums = loadedAlbums.map(applyLocalOverrides)
        artists = loadedArtists.map(applyLocalOverrides)
        isTruncated = trackTruncated
        if loadedTracks.isEmpty && loadedAlbums.isEmpty && loadedArtists.isEmpty {
            loadError = loadError ?? "没有取到曲库内容（服务器未授权音乐目录，或该账号没有可访问的音乐库）"
            isPartialFailure = false
        } else {
            loadError = nil
            isPartialFailure = pageFailure != nil
        }
    }

    /// 分页循环取全量（上限 cap）。返回是否被上限截断。
    private func loadAll(
        kind: MediaKind,
        library: String?,
        sort: MediaSort,
        cap: Int
    ) async -> ([MediaItem], Bool, String?) {
        var all: [MediaItem] = []
        var offset = 0
        var failure: String?
        while all.count < cap {
            let limit = min(pageSize, cap - all.count)
            do {
                let page = try await backend.items(
                    in: library,
                    kind: kind,
                    sort: sort,
                    offset: offset,
                    limit: limit
                )
                if page.items.isEmpty { break }
                all.append(contentsOf: page.items)
                offset += page.items.count
                // 服务端已经到底（total 可信时按 total 判断，避免多余请求）
                if page.total > 0 && offset >= page.total { break }
                if !page.hasMore && page.total <= 0 { break }
            } catch {
                failure = error.localizedDescription
                break
            }
        }
        return (all, all.count >= cap, failure)
    }

    /// 当前账号档案（本地兜底数据的键前缀）。加载期间不变，缓存一次避免每条目拼字符串。
    private var cachedProfileKey: String?
    /// 本地覆盖表（内容身份 → 用户数据）。**一次加载只取一次**：
    /// 原来在每个条目里取整张表，等于 O(曲目数 × 记录数) 的字典拷贝。
    private var cachedLocalOverrides: [String: MediaUserData] = [:]
    private var needsLocalOverrides = false

    /// 加载前准备：缓存账号档案，并一次性取出本地覆盖表
    private func prepareLocalOverrides() {
        let profileKey = AppState.shared.profileKey
        cachedProfileKey = profileKey
        let capabilities = self.capabilities
        // 服务端既有播放统计又有进度上报（Jellyfin）时本地表没有增量，跳过
        needsLocalOverrides = !capabilities.playStats || !capabilities.playbackProgress
        cachedLocalOverrides = needsLocalOverrides
            ? LocalLibraryState.shared.overrides(profileKey: profileKey)
            : [:]
    }

    /// 把本地兜底数据合并进服务端条目（跨后端共享：按内容身份查表）
    private func applyLocalOverrides(_ item: MediaItem) -> MediaItem {
        guard needsLocalOverrides else { return item }
        let profileKey = cachedProfileKey ?? "anonymous"
        // 曲目按时长 ±2 秒探测（两个服务端的时长可能差几百毫秒）；其它种类只有一个键
        var override: MediaUserData?
        for candidate in ContentIdentity.candidates(for: item) {
            if let hit = cachedLocalOverrides[candidate] {
                override = hit
                break
            }
        }
        if override == nil {
            // 旧版（按后端 + 条目 id）记录：看到这个条目时顺手迁移成内容身份
            if LocalLibraryState.shared.legacyUserData(backend: item.backend, itemID: item.id) != nil {
                LocalLibraryState.shared.adoptLegacy(
                    backend: item.backend,
                    itemID: item.id,
                    contentKey: item.contentKey,
                    profileKey: profileKey
                )
                override = LocalLibraryState.shared.userData(
                    contentKey: item.contentKey,
                    profileKey: profileKey
                )
            }
        }
        guard let override else { return item }
        var merged = item
        merged.userData = LocalLibraryState.merge(server: item.userData, local: override)
        return merged
    }

    func track(id: String) -> MediaItem? {
        trackIndex[id]
    }

    /// 专辑详情（深链时曲库可能尚未加载 → 回落到 nil，由视图用传入 item 兜底）
    func album(id: String) -> MediaItem? {
        albumIndex[id]
    }

    func artist(id: String) -> MediaItem? {
        artistIndex[id]
    }

    /// 歌词（带能力门控；后端不支持时抛 `.unsupported` 而不是让视图自己去猜）
    func lyrics(trackID: String) async throws -> [LyricLine] {
        guard capabilities.lyrics else {
            throw MusicBackendError.unsupported("歌词")
        }
        return try await backend.lyrics(trackID: trackID)
    }

    // MARK: - 详情页数据

    func albumTracks(albumID: String) async -> [MediaItem] {
        do {
            return try await backend.albumTracks(albumID: albumID).map(applyLocalOverrides)
        } catch {
            // 后端不支持或失败时，用已加载的曲库兜底（保证详情页不空）
            return tracks.filter { $0.albumID == albumID }
        }
    }

    func artistAlbums(artistID: String) async -> [MediaItem] {
        do {
            return try await backend.artistAlbums(artistID: artistID).map(applyLocalOverrides)
        } catch {
            return albums.filter { $0.artistID == artistID }
        }
    }

    func artistTracks(artistID: String) async -> [MediaItem] {
        do {
            return try await backend.artistTracks(artistID: artistID).map(applyLocalOverrides)
        } catch {
            return tracks.filter { $0.artistID == artistID }
        }
    }

    func search(term: String, limit: Int = 60) async -> SearchResults {
        guard capabilities.search else {
            // 后端不支持搜索：退化为本地匹配（范围限于已加载曲库，UI 会据此提示）
            return localSearch(term: term, limit: limit)
        }
        do {
            let results = try await backend.search(term: term, limit: limit)
            return SearchResults(
                tracks: results.tracks.map(applyLocalOverrides),
                albums: results.albums.map(applyLocalOverrides),
                artists: results.artists.map(applyLocalOverrides)
            )
        } catch {
            return localSearch(term: term, limit: limit)
        }
    }

    private func localSearch(term: String, limit: Int) -> SearchResults {
        let matches: (MediaItem) -> Bool = { item in
            item.title.localizedCaseInsensitiveContains(term)
                || (item.artistName?.localizedCaseInsensitiveContains(term) ?? false)
                || (item.albumTitle?.localizedCaseInsensitiveContains(term) ?? false)
        }
        return SearchResults(
            tracks: Array(tracks.filter(matches).prefix(limit)),
            albums: Array(albums.filter(matches).prefix(limit)),
            artists: Array(artists.filter(matches).prefix(limit)),
            isLocalFallback: true
        )
    }

    // MARK: - 播放统计回写（本地兜底）

    /// 播放开始：本地记一次播放次数与时间（服务端有统计能力的后端也会记服务端）
    func notePlaybackStarted(_ item: MediaItem) {
        LocalLibraryState.shared.recordPlayStart(
            contentKey: item.contentKey,
            profileKey: AppState.shared.profileKey
        )
        bumpLocalUserData(itemID: item.id, playCount: 1, lastPlayed: Date())
        // 听歌数据：统计事件 + 外部记录（Scrobble）。两者都自带「先收尾上一条」语义。
        PlaybackHistoryStore.shared.noteStarted(item)
        ScrobbleService.shared.noteStarted(item)
    }

    /// 播放进度变化：更新本地续播位置（服务端支持进度上报时由后端自己报，本地仍存一份用于离线续播）
    func noteProgress(_ item: MediaItem, position: Double) {
        LocalLibraryState.shared.recordProgress(
            contentKey: item.contentKey,
            profileKey: AppState.shared.profileKey,
            position: position,
            duration: item.duration,
            playedToEnd: false
        )
        bumpLocalUserData(itemID: item.id, resumePosition: position)
        PlaybackHistoryStore.shared.noteProgress(item, position: position)
        ScrobbleService.shared.noteProgress(item, position: position)
    }

    func notePlaybackFinished(_ item: MediaItem) {
        LocalLibraryState.shared.recordProgress(
            contentKey: item.contentKey,
            profileKey: AppState.shared.profileKey,
            position: 0,
            duration: item.duration,
            playedToEnd: true
        )
        bumpLocalUserData(itemID: item.id, resumePosition: 0, isPlayed: true)
        PlaybackHistoryStore.shared.noteFinished(item)
        ScrobbleService.shared.noteFinished(item)
    }

    private func bumpLocalUserData(
        itemID: String,
        playCount: Int = 0,
        lastPlayed: Date? = nil,
        resumePosition: Double? = nil,
        isPlayed: Bool? = nil
    ) {
        guard let i = tracks.firstIndex(where: { $0.id == itemID }) else { return }
        var data = tracks[i].userData
        data.playCount += playCount
        if let lastPlayed { data.lastPlayed = lastPlayed }
        if let resumePosition { data.resumePosition = resumePosition }
        if let isPlayed { data.isPlayed = isPlayed }
        tracks[i].userData = data
    }

    // MARK: - 智能播放列表

    /// 按艺术家 / 专辑关键字匹配（结果按关键字缓存，曲目变化即失效）
    func smartTracks(keyword: String) -> [MediaItem] {
        guard !keyword.isEmpty else { return [] }
        if let cached = smartMatchCache[keyword] { return cached }
        let matched = tracks.filter { track in
            track.artistName?.localizedCaseInsensitiveContains(keyword) == true
                || track.albumTitle?.localizedCaseInsensitiveContains(keyword) == true
        }
        smartMatchCache[keyword] = matched
        return matched
    }
}
