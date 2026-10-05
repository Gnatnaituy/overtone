import SwiftUI

enum TrackSortMode: String, CaseIterable, Identifiable {
    case name = "按名称"
    case playCount = "按播放次数"
    var id: String { rawValue }
}

/// 全局音乐数据：曲目/艺术家/专辑一次加载，各页面共享（含播放列表映射、智能列表匹配）
@MainActor
final class MusicDataStore: ObservableObject {
    static let shared = MusicDataStore()

    @Published var tracks: [BaseItemDto] = [] {
        didSet { rebuildDerivedData() }
    }
    @Published var artists: [BaseItemDto] = []
    @Published var albums: [BaseItemDto] = [] {
        didSet { rebuildAlbumDerivedData() }
    }
    @Published var isLoading = false

    /// 数据版本号：每次派生数据重算时自增。
    ///
    /// 供视图用 `.onChange(of: store.dataRevision)` 代替 `.onChange(of: store.tracks)`：
    /// `[BaseItemDto]` 的相等性比较是 O(曲库)，而 `onChange` 在**每次 body 更新**时
    /// 都要做一次比较（悬停、搜索输入、播放状态变化都会触发），大曲库下白白烧掉
    /// 大量字符串比较。整数比较是 O(1)。
    private(set) var dataRevision = 0

    var libraryId: String?

    /// 派生数据缓存：tracks / albums 变化（含收藏状态原地更新）时一次重算，
    /// 避免收藏/最近/最常/继续播放页面每次渲染都全量过滤排序。
    ///
    /// 这一层是必须的：首页与资料库都在 `body` 里读这些派生值，而它们的 body
    /// 会因窗口尺寸、搜索框输入、播放状态变化等**高频原因**重跑；把 O(n log n)
    /// 留在 body 里等于每次重跑都对整个曲库排序一遍。
    private var trackIndex: [String: BaseItemDto] = [:]
    private var cachedFavoriteTracks: [BaseItemDto] = []
    private var cachedRecentlyPlayedTracks: [BaseItemDto] = []
    private var cachedMostPlayedTracks: [BaseItemDto] = []
    private var cachedTracksByPlayCount: [BaseItemDto] = []
    private var cachedContinueEntries: [ContinueEntry] = []
    private var cachedAlbumsByDateAdded: [BaseItemDto] = []
    private var cachedAlbumsByName: [BaseItemDto] = []
    private var cachedAlbumsByArtist: [BaseItemDto] = []
    /// 智能列表匹配缓存（关键字 → 命中曲目），随曲目变化整体失效
    private var smartMatchCache: [String: [BaseItemDto]] = [:]

    private static let isoFormatter = ISO8601DateFormatter()

    private init() {}

    // MARK: - 智能列表

    var favoriteTracks: [BaseItemDto] { cachedFavoriteTracks }

    var mostPlayedTracks: [BaseItemDto] { cachedMostPlayedTracks }

    var recentlyPlayedTracks: [BaseItemDto] { cachedRecentlyPlayedTracks }

    /// 首页「继续播放」：按专辑去重、最后播放时间倒序，最多 6 条
    var continueEntries: [ContinueEntry] { cachedContinueEntries }

    /// 首页「最近添加」三种排序的预排序结果（视图按当前排序模式 O(1) 取用）
    var albumsByDateAdded: [BaseItemDto] { cachedAlbumsByDateAdded }
    var albumsByName: [BaseItemDto] { cachedAlbumsByName }
    var albumsByArtist: [BaseItemDto] { cachedAlbumsByArtist }

    /// 「继续播放」条目：一张卡 = 一张专辑（去重键为专辑，无专辑时退回曲目自身）
    struct ContinueEntry: Identifiable {
        let track: BaseItemDto
        let albumKey: String

        var id: String { albumKey }

        var title: String { track.album ?? track.name ?? "未知专辑" }

        var subtitle: String {
            let artist = track.albumArtist ?? ""
            // §2.1：副标 = 艺人 · 剩余时长（多端续听时最关心的信息）
            let remaining = max(track.runtimeSeconds - track.resumeSeconds, 0)
            let remainText = remaining > 30
                ? "剩 \(max(Int((remaining / 60).rounded(.up)), 1)) 分钟"
                : ""
            return [artist, remainText].filter { !$0.isEmpty }.joined(separator: " · ")
        }

        var progress: Double {
            guard track.runtimeSeconds > 0 else { return 0 }
            return min(max(track.resumeSeconds / track.runtimeSeconds, 0), 1)
        }

        var timeText: String {
            "\(formatPlaybackTime(track.resumeSeconds)) / \(formatPlaybackTime(track.runtimeSeconds))"
        }
    }

    private func rebuildDerivedData() {
        trackIndex = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedFavoriteTracks = tracks.filter { $0.userData?.isFavorite == true }
        cachedMostPlayedTracks = tracks
            .filter { ($0.userData?.playCount ?? 0) > 0 }
            .sorted { ($0.userData?.playCount ?? 0) > ($1.userData?.playCount ?? 0) }
        cachedTracksByPlayCount = tracks.sorted {
            ($0.userData?.playCount ?? 0) > ($1.userData?.playCount ?? 0)
        }
        cachedRecentlyPlayedTracks = tracks
            .compactMap { track -> (BaseItemDto, Date)? in
                guard let date = track.userData?.lastPlayedDate.flatMap({ Self.isoFormatter.date(from: $0) }) else {
                    return nil
                }
                return (track, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        cachedContinueEntries = Self.buildContinueEntries(from: tracks)
        // 曲目变了，智能列表匹配结果全部失效
        smartMatchCache.removeAll(keepingCapacity: true)
        dataRevision &+= 1
    }

    /// 继续播放：未听完的曲目按最后播放时间倒序，按专辑取第一条，最多 6 张
    private static func buildContinueEntries(from tracks: [BaseItemDto]) -> [ContinueEntry] {
        let candidates = tracks
            .filter { $0.resumeSeconds > 5 && $0.runtimeSeconds > 0 }
            .sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }
        var seen = Set<String>()
        var result: [ContinueEntry] = []
        result.reserveCapacity(6)
        for track in candidates {
            let key = track.albumId ?? track.id
            guard seen.insert(key).inserted else { continue }
            result.append(ContinueEntry(track: track, albumKey: key))
            if result.count >= 6 { break }
        }
        return result
    }

    private func rebuildAlbumDerivedData() {
        cachedAlbumsByDateAdded = albums.sorted { ($0.dateCreated ?? "") > ($1.dateCreated ?? "") }
        cachedAlbumsByName = albums.sorted { ($0.name ?? "") < ($1.name ?? "") }
        cachedAlbumsByArtist = albums.sorted { ($0.albumArtist ?? "") < ($1.albumArtist ?? "") }
    }

    // MARK: - 收藏

    /// 切换收藏：先调服务端 API，成功后同步本地缓存（界面即时刷新）
    func toggleFavorite(_ item: BaseItemDto) async {
        let newFavorite = !(item.userData?.isFavorite ?? false)
        do {
            try await APIClient.shared.setFavorite(itemId: item.id, favorite: newFavorite)
            setFavoriteLocally(id: item.id, isFavorite: newFavorite)
        } catch {
            // 服务端失败时不动本地状态，避免多端不一致
        }
    }

    func setFavoriteLocally(id: String, isFavorite: Bool) {
        if let i = tracks.firstIndex(where: { $0.id == id }) {
            tracks[i].userData = (tracks[i].userData ?? UserDataDto()).mutating(isFavorite: isFavorite)
        }
        if let i = albums.firstIndex(where: { $0.id == id }) {
            albums[i].userData = (albums[i].userData ?? UserDataDto()).mutating(isFavorite: isFavorite)
        }
    }

    func sortedTracks(by mode: TrackSortMode) -> [BaseItemDto] {
        switch mode {
        case .name:
            // 服务端已按 SortName 返回，无需再排
            return tracks
        case .playCount:
            return cachedTracksByPlayCount
        }
    }

    func loadIfNeeded() async {
        guard tracks.isEmpty, !isLoading else { return }
        await load()
    }

    /// 等库 ID 就绪后加载。
    ///
    /// 启动页直接落在「资料库」时，视图的 `.task` 可能早于 `MainView.bootstrap` 的
    /// 媒体库解析跑完 —— 那时 `libraryId` 还是 nil，`load()` 会直接返回，页面就永远空着。
    func ensureLoaded() async {
        if libraryId == nil { await resolveLibraryId() }
        await loadIfNeeded()
    }

    /// 从 `AppState` 已加载的媒体库列表里解析音乐库 ID（启动早期解析失败时补一次）
    private func resolveLibraryId() async {
        if AppState.shared.libraries.isEmpty {
            await AppState.shared.loadLibraries()
        }
        if let lib = AppState.shared.libraries.first(where: { $0.collectionType == "music" })
            ?? AppState.shared.libraries.first {
            libraryId = lib.id
        }
    }

    func reload() async {
        // 库 ID 还没解析出来（服务器刚恢复 / 启动早期请求失败）时先补解析，否则刷新永远拿不到数据
        if libraryId == nil { await resolveLibraryId() }
        tracks = []
        artists = []
        albums = []
        await load()
    }

    private func load() async {
        guard let libraryId, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let userId = APIClient.shared.user?.id ?? ""
        async let tracksResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: Self.tracksQuery(libraryId: libraryId)
        )
        async let artistsResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: Self.artistQuery(libraryId: libraryId)
        )
        async let albumsResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: Self.albumQuery(libraryId: libraryId)
        )
        tracks = (try? await tracksResult)?.items ?? []
        artists = (try? await artistsResult)?.items ?? []
        albums = (try? await albumsResult)?.items ?? []
    }

    func track(id: String) -> BaseItemDto? {
        trackIndex[id]
    }

    /// 智能播放列表：按艺术家关键字匹配，基于最新曲目数据动态计算。
    ///
    /// 结果按关键字缓存（曲目变化时整体失效）：本函数是 O(曲库)，且每条曲目要做两次
    /// `localizedCaseInsensitiveContains`（ICU 区域感知折叠，约 0.5–3µs/次）。
    /// 同一个关键字会被播放列表卡片、列表行、详情页、同步服务各调一次 ——
    /// 上万条曲库时单次就是几十毫秒的主线程工作，缓存后每个
    /// 「关键字 × 数据版本」只付一次。
    func smartTracks(keyword: String) -> [BaseItemDto] {
        guard !keyword.isEmpty else { return [] }
        if let cached = smartMatchCache[keyword] { return cached }
        let matched = tracks.filter { track in
            track.albumArtist?.localizedCaseInsensitiveContains(keyword) == true
                || track.album?.localizedCaseInsensitiveContains(keyword) == true
        }
        smartMatchCache[keyword] = matched
        return matched
    }

    static func tracksQuery(libraryId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
    }

    static func artistQuery(libraryId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicArtist"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
    }

    static func albumQuery(libraryId: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            // DateCreated 供首页「最近添加」排序（Fields 需显式请求）
            URLQueryItem(name: "Fields", value: "Overview,DateCreated"),
        ]
    }
}

extension UserDataDto {
    func mutating(isFavorite: Bool) -> UserDataDto {
        var copy = self
        copy.isFavorite = isFavorite
        return copy
    }
}
