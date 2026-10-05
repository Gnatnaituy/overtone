import SwiftUI

@MainActor
final class MusicArtistViewModel: ObservableObject {
    @Published var albums: [BaseItemDto] = []
    @Published var tracks: [BaseItemDto] = []
    @Published var isLoading = false

    private let artistId: String

    init(artistId: String) {
        self.artistId = artistId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let userId = APIClient.shared.user?.id ?? ""
        // 两个请求互不依赖（都以 artistId 为条件，谁也不等谁的结果）：
        // 并发发出后页面等待从 RTT1+RTT2 降到 max(RTT1,RTT2)。
        // 串行时远程服务器上一次打开艺人页要多等一整个往返。
        async let albumsResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: artistId),
                URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        )
        // 艺术家全部曲目（头部"播放全部/随机播放"用）
        async let tracksResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ArtistIds", value: artistId),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
            ]
        )
        albums = (try? await albumsResult)?.items ?? []
        tracks = (try? await tracksResult)?.items ?? []
    }
}

@MainActor
final class MusicAlbumViewModel: ObservableObject {
    @Published var album: BaseItemDto?
    @Published var tracks: [BaseItemDto] = []
    @Published var isLoading = false

    private let albumId: String

    init(albumId: String) {
        self.albumId = albumId
    }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let userId = APIClient.shared.user?.id ?? ""
        // 详情与曲目表互不依赖（都只用到 albumId）：并发发出，页面等待减半
        async let detailResult: BaseItemDto = APIClient.shared.get(
            "/Users/\(userId)/Items/\(albumId)",
            query: [URLQueryItem(name: "Fields", value: "Overview,Genres")]
        )
        async let tracksResult: QueryResult<BaseItemDto> = APIClient.shared.get(
            "/Users/\(userId)/Items",
            query: [
                URLQueryItem(name: "ParentId", value: albumId),
                URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                // 专辑内按碟号 + 音轨号排序（曲目表顺序与唱片一致）
                URLQueryItem(name: "SortBy", value: "ParentIndexNumber,IndexNumber,SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending"),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
        )
        // 详情失败时用列表项兜底（`album` 保持 nil，调用方回落到传入的 item）
        if let detail = try? await detailResult { album = detail }
        tracks = (try? await tracksResult)?.items ?? []
    }
}
