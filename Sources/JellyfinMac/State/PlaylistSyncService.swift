import SwiftUI

/// 创建/更新播放列表请求体（Jellyfin 反序列化大小写不敏感，camelCase 可接受）
private struct PlaylistUpdateRequest: Codable {
    let name: String
    let ids: [String]
    let mediaType: String = "Audio"
}

/// Jellyfin 服务器播放列表双向同步：
/// - syncAll：以服务器为权威，拉取服务器播放列表合并到本地；本地未同步的列表上传创建
/// - 单项推送：创建/删除/重命名/添加/移除实时同步到服务器
@MainActor
final class PlaylistSyncService: ObservableObject {
    static let shared = PlaylistSyncService()

    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var lastSyncTime: Date?

    private var store: PlaylistStore { .shared }

    // MARK: - 全量同步

    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        print("[Sync] start, smart=\(store.smartPlaylists.count), playlists=\(store.playlists.count)")
        do {
            let userId = try requireUserId()

            // 1. 拉取服务器全部播放列表
            let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
                "/Users/\(userId)/Items",
                query: [
                    URLQueryItem(name: "IncludeItemTypes", value: "Playlist"),
                    URLQueryItem(name: "Recursive", value: "true"),
                ]
            )

            // 2. 服务器 → 本地（合并/导入，服务器为权威；智能列表镜像副本除外）
            for item in result.items ?? [] {
                let items = try await fetchItems(playlistId: item.id, userId: userId)
                let trackIds = items.map { $0.id }
                let itemMap = Dictionary(uniqueKeysWithValues: items.compactMap { track in
                    track.playlistItemId.map { (track.id, $0) }
                })
                if let local = store.allPlaylists.first(where: { $0.serverId == item.id }) {
                    // 智能列表的服务器副本：内容由本地动态生成，不反向覆盖
                    if local.isSmart { continue }
                    store.updateFromServer(
                        localId: local.id,
                        name: item.name ?? local.name,
                        trackIds: trackIds,
                        itemMap: itemMap
                    )
                } else {
                    store.importFromServer(
                        serverId: item.id,
                        name: item.name ?? "播放列表",
                        trackIds: trackIds,
                        itemMap: itemMap
                    )
                }
            }

            // 3. 本地未同步的普通列表 → 上传创建
            for local in store.playlists where local.serverId == nil {
                try await pushCreate(local)
            }

            // 4. 智能播放列表 → 镜像为服务器普通播放列表（匹配结果全量覆盖）
            for smart in store.smartPlaylists {
                print("[Sync] mirror smart: \(smart.name)")
                try await pushSmartMirror(smart)
            }

            lastError = nil
            lastSyncTime = Date()
        } catch {
            lastError = error.localizedDescription
            print("[Sync] \(error)")
        }
    }

    // MARK: - 单项推送

    func pushCreate(_ playlist: Playlist) async throws {
        let body = try JSONEncoder().encode(PlaylistUpdateRequest(name: playlist.name, ids: playlist.trackIds))
        let created: BaseItemDto = try await APIClient.shared.post("/Playlists", body: body)
        store.bindServerId(localId: playlist.id, serverId: created.id)
    }

    func pushRename(_ playlist: Playlist) async throws {
        guard let serverId = playlist.serverId else { return }
        var ids = playlist.trackIds
        if playlist.isSmart {
            // 智能列表的条目是动态匹配结果，重命名时保持镜像完整
            ids = smartTrackIds(playlist)
        }
        let body = try JSONEncoder().encode(PlaylistUpdateRequest(name: playlist.name, ids: ids))
        try await APIClient.shared.postEmpty("/Playlists/\(serverId)", body: body)
    }

    /// 智能播放列表镜像：匹配结果全量覆盖到服务器普通播放列表（不存在则创建）
    func pushSmartMirror(_ smart: Playlist) async throws {
        let ids = smartTrackIds(smart)
        if let serverId = smart.serverId {
            let body = try JSONEncoder().encode(PlaylistUpdateRequest(name: smart.name, ids: ids))
            try await APIClient.shared.postEmpty("/Playlists/\(serverId)", body: body)
        } else {
            let body = try JSONEncoder().encode(PlaylistUpdateRequest(name: smart.name, ids: ids))
            let created: BaseItemDto = try await APIClient.shared.post("/Playlists", body: body)
            store.bindServerId(localId: smart.id, serverId: created.id)
        }
    }

    private func smartTrackIds(_ smart: Playlist) -> [String] {
        MusicDataStore.shared.smartTracks(keyword: smart.smartRule?.artistKeyword ?? "").map { $0.id }
    }

    func pushDelete(serverId: String) async throws {
        // Jellyfin 10.10+ 播放列表删除走通用条目删除接口
        try await APIClient.shared.deleteEmpty("/Items/\(serverId)")
    }

    func pushAdd(serverId: String, trackId: String) async throws {
        let userId = try requireUserId()
        try await APIClient.shared.postEmpty(
            "/Playlists/\(serverId)/Items",
            query: [
                URLQueryItem(name: "Ids", value: trackId),
                URLQueryItem(name: "UserId", value: userId),
            ]
        )
    }

    func pushRemove(playlist: Playlist, trackId: String) async throws {
        guard let serverId = playlist.serverId else { return }
        let userId = try requireUserId()
        var entryId = playlist.itemMap?[trackId]
        if entryId == nil {
            entryId = try await fetchEntryId(playlistId: serverId, userId: userId, trackId: trackId)
        }
        guard let entryId else { return }
        try await APIClient.shared.deleteEmpty(
            "/Playlists/\(serverId)/Items",
            query: [URLQueryItem(name: "EntryIds", value: entryId)]
        )
    }

    // MARK: - 内部

    private func fetchItems(playlistId: String, userId: String) async throws -> [BaseItemDto] {
        let result: QueryResult<BaseItemDto> = try await APIClient.shared.get(
            "/Playlists/\(playlistId)/Items",
            query: [URLQueryItem(name: "UserId", value: userId)]
        )
        return result.items ?? []
    }

    private func fetchEntryId(playlistId: String, userId: String, trackId: String) async throws -> String? {
        let items = try await fetchItems(playlistId: playlistId, userId: userId)
        return items.first { $0.id == trackId }?.playlistItemId
    }

    private func requireUserId() throws -> String {
        guard let id = APIClient.shared.user?.id else { throw APIError.notConfigured }
        return id
    }
}
