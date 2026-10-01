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
    @Published var albums: [BaseItemDto] = []
    @Published var isLoading = false

    var libraryId: String?

    /// 派生数据缓存：tracks 变化（含收藏状态原地更新）时一次重算，
    /// 避免收藏/最近/最常页面每次渲染都全量过滤排序
    private var trackIndex: [String: BaseItemDto] = [:]
    private var cachedFavoriteTracks: [BaseItemDto] = []
    private var cachedRecentlyPlayedTracks: [BaseItemDto] = []
    private var cachedMostPlayedTracks: [BaseItemDto] = []

    private static let isoFormatter = ISO8601DateFormatter()

    private init() {}

    // MARK: - 智能列表

    var favoriteTracks: [BaseItemDto] { cachedFavoriteTracks }

    var mostPlayedTracks: [BaseItemDto] { cachedMostPlayedTracks }

    var recentlyPlayedTracks: [BaseItemDto] { cachedRecentlyPlayedTracks }

    private func rebuildDerivedData() {
        trackIndex = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        cachedFavoriteTracks = tracks.filter { $0.userData?.isFavorite == true }
        cachedMostPlayedTracks = tracks
            .filter { ($0.userData?.playCount ?? 0) > 0 }
            .sorted { ($0.userData?.playCount ?? 0) > ($1.userData?.playCount ?? 0) }
        cachedRecentlyPlayedTracks = tracks
            .compactMap { track -> (BaseItemDto, Date)? in
                guard let date = track.userData?.lastPlayedDate.flatMap({ Self.isoFormatter.date(from: $0) }) else {
                    return nil
                }
                return (track, date)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
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
            return tracks
        case .playCount:
            return tracks.sorted {
                ($0.userData?.playCount ?? 0) > ($1.userData?.playCount ?? 0)
            }
        }
    }

    func loadIfNeeded() async {
        guard tracks.isEmpty, !isLoading else { return }
        await load()
    }

    func reload() async {
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

    /// 智能播放列表：按艺术家关键字匹配，基于最新曲目数据动态计算
    func smartTracks(keyword: String) -> [BaseItemDto] {
        guard !keyword.isEmpty else { return [] }
        return tracks.filter { track in
            track.albumArtist?.localizedCaseInsensitiveContains(keyword) == true
                || track.album?.localizedCaseInsensitiveContains(keyword) == true
        }
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
