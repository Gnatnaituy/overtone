import SwiftUI

/// 搜索页数据源：保留 300ms 防抖与 `isSearching`，数据取自 `MusicDataStore`。
///
/// 为什么不再自己发请求：多后端下「搜索」是**能力**而不是固定接口 —— 飞牛音乐没有搜索，
/// `MusicDataStore.search(term:limit:)` 内部已经做了「后端支持就走服务端、否则本地匹配」
/// 的降级，视图层不该再知道这件事。
@MainActor
final class MusicSearchViewModel: ObservableObject {
    @Published var tracks: [MediaItem] = []
    @Published var artists: [MediaItem] = []
    @Published var albums: [MediaItem] = []
    @Published var isSearching = false
    /// 结果是「已加载曲库的本地匹配」（后端不支持服务端搜索时为 true）
    @Published var isLocalFallback = false

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
            isLocalFallback = false
            isSearching = false
            return
        }
        isSearching = true
        task = Task {
            // 防抖
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            let results = await MusicDataStore.shared.search(term: trimmed, limit: 60)
            guard !Task.isCancelled else { return }
            tracks = results.tracks
            artists = results.artists
            albums = results.albums
            isLocalFallback = results.isLocalFallback
            isSearching = false
        }
    }
}
