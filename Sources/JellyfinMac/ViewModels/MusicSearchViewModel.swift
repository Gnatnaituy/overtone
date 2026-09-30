import SwiftUI

@MainActor
final class MusicSearchViewModel: ObservableObject {
    @Published var tracks: [BaseItemDto] = []
    @Published var artists: [BaseItemDto] = []
    @Published var albums: [BaseItemDto] = []
    @Published var isSearching = false

    private var task: Task<Void, Never>?

    var isEmpty: Bool {
        tracks.isEmpty && artists.isEmpty && albums.isEmpty
    }

    func search(_ term: String) {
        task?.cancel()
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tracks = []
            artists = []
            albums = []
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            // 防抖
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            do {
                let userId = APIClient.shared.user?.id ?? ""
                let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
                    "/Users/\(userId)/Items/Search",
                    query: [
                        URLQueryItem(name: "SearchTerm", value: trimmed),
                        URLQueryItem(name: "Limit", value: "60"),
                        URLQueryItem(name: "Recursive", value: "true"),
                        URLQueryItem(name: "IncludeItemTypes", value: "Audio,MusicAlbum,MusicArtist"),
                        URLQueryItem(name: "Fields", value: "Overview"),
                    ]
                )
                guard !Task.isCancelled else { return }
                partition(result.items ?? [])
            } catch {
                // 搜索失败保留空结果
            }
            isSearching = false
        }
    }

    private func partition(_ items: [BaseItemDto]) {
        tracks = items.filter { $0.type == "Audio" }
        artists = items.filter { $0.type == "MusicArtist" }
        albums = items.filter { $0.type == "MusicAlbum" }
    }
}
