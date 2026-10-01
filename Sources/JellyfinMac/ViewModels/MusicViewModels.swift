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
        do {
            let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
                "/Users/\(userId)/Items",
                query: [
                    URLQueryItem(name: "ParentId", value: artistId),
                    URLQueryItem(name: "IncludeItemTypes", value: "MusicAlbum"),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "SortBy", value: "SortName"),
                    URLQueryItem(name: "SortOrder", value: "Ascending"),
                ]
            )
            albums = result.items ?? []
        } catch {
            // 忽略
        }
        // 艺术家全部曲目（头部"播放全部/随机播放"用）
        do {
            let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
                "/Users/\(userId)/Items",
                query: [
                    URLQueryItem(name: "ArtistIds", value: artistId),
                    URLQueryItem(name: "IncludeItemTypes", value: "Audio"),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "SortBy", value: "SortName"),
                    URLQueryItem(name: "SortOrder", value: "Ascending"),
                ]
            )
            tracks = result.items ?? []
        } catch {
            // 忽略
        }
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
        do {
            let detail: BaseItemDto = try await APIClient.shared.get(
                "/Users/\(userId)/Items/\(albumId)",
                query: [URLQueryItem(name: "Fields", value: "Overview,Genres")]
            )
            album = detail
        } catch {
            // 详情失败时用列表项兜底
        }
        do {
            let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
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
            tracks = result.items ?? []
        } catch {
            // 忽略
        }
    }
}
