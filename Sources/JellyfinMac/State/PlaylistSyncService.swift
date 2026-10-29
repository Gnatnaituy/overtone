import SwiftUI

/// 服务器播放列表双向同步（后端无关）。
///
/// - `syncAll`：以服务器为权威，拉取服务器播放列表合并到本地；本地未同步的列表上传创建
/// - 单项推送：创建 / 删除 / 重命名 / 添加 / 移除实时同步
///
/// 后端没有播放列表能力时（`capabilities.remotePlaylists == false`）整个服务静默降级为
/// 「纯本地播放列表」，UI 用 `isAvailable` 决定是否展示同步入口。
@MainActor
final class PlaylistSyncService: ObservableObject {
    static let shared = PlaylistSyncService()

    @Published var isSyncing = false
    @Published var lastError: String?
    @Published var lastSyncTime: Date?

    private var store: PlaylistStore { .shared }
    private var backend: MusicBackend { BackendRegistry.shared.active }

    /// 当前后端是否支持服务器播放列表
    var isAvailable: Bool { backend.capabilities.remotePlaylists }

    // MARK: - 全量同步

    func syncAll() async {
        guard isAvailable, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let remote = try await backend.remotePlaylists()

            // 服务器 → 本地：先建 serverId → 本地列表 索引，避免循环里 O(K²)
            var localByServerID: [String: Playlist] = [:]
            for local in store.allPlaylists {
                if let sid = local.serverId { localByServerID[sid] = local }
            }
            for playlist in remote {
                let entries = try await backend.remotePlaylistEntries(id: playlist.id)
                let trackIDs = entries.map { $0.track.id }
                let itemMap = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
                    entry.entryID.map { (entry.track.id, $0) }
                })
                if let local = localByServerID[playlist.id] {
                    // 智能列表的服务器副本：内容由本地动态生成，不反向覆盖
                    if local.isSmart { continue }
                    store.updateFromServer(
                        localId: local.id,
                        name: playlist.name,
                        trackIds: trackIDs,
                        itemMap: itemMap
                    )
                } else {
                    store.importFromServer(
                        serverId: playlist.id,
                        name: playlist.name,
                        trackIds: trackIDs,
                        itemMap: itemMap
                    )
                }
            }

            // 本地未同步的普通列表 → 上传创建
            for local in store.playlists where local.serverId == nil && belongsToActiveBackend(local) {
                try await pushCreate(local)
            }

            // 智能播放列表 → 镜像为服务器普通播放列表
            for smart in store.smartPlaylists where belongsToActiveBackend(smart) {
                try await pushSmartMirror(smart)
            }

            lastError = nil
            lastSyncTime = Date()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            print("[Sync] \(error)")
        }
    }

    // MARK: - 单项推送

    func pushCreate(_ playlist: Playlist) async throws {
        guard isAvailable else { return }
        let created = try await backend.createRemotePlaylist(
            name: playlist.name,
            trackIDs: playlist.trackIds
        )
        store.bindServerId(localId: playlist.id, serverId: created.id)
    }

    func pushRename(_ playlist: Playlist) async throws {
        guard isAvailable, let serverId = playlist.serverId else { return }
        let ids = playlist.isSmart ? smartTrackIDs(playlist) : playlist.trackIds
        try await backend.updateRemotePlaylist(id: serverId, name: playlist.name, trackIDs: ids)
    }

    /// 智能播放列表镜像：匹配结果全量覆盖到服务器普通播放列表（不存在则创建）
    func pushSmartMirror(_ smart: Playlist) async throws {
        guard isAvailable else { return }
        let ids = smartTrackIDs(smart)
        if let serverId = smart.serverId {
            try await backend.updateRemotePlaylist(id: serverId, name: smart.name, trackIDs: ids)
        } else {
            let created = try await backend.createRemotePlaylist(name: smart.name, trackIDs: ids)
            store.bindServerId(localId: smart.id, serverId: created.id)
        }
    }

    func pushDelete(serverId: String) async throws {
        guard isAvailable else { return }
        try await backend.deleteRemotePlaylist(id: serverId)
    }

    func pushAdd(serverId: String, trackId: String) async throws {
        guard isAvailable else { return }
        try await backend.addRemotePlaylistTracks(id: serverId, trackIDs: [trackId])
    }

    /// 移除条目。`knownEntryID` 由调用方在清理本地映射**之前**取出 ——
    /// 没有它就要先拉整个播放列表条目再查找（每次移除一次全量 GET）。
    /// 没有 entryId 概念的后端（飞牛）会把 trackId 当作条目标识传下去。
    func pushRemove(serverId: String, trackId: String, knownEntryId: String? = nil) async throws {
        guard isAvailable else { return }
        var entryID = knownEntryId
        if entryID == nil {
            let entries = try await backend.remotePlaylistEntries(id: serverId)
            entryID = entries.first { $0.track.id == trackId }?.entryID ?? trackId
        }
        guard let entryID else { return }
        try await backend.removeRemotePlaylistEntries(id: serverId, entryIDs: [entryID])
    }

    // MARK: - 内部

    private func smartTrackIDs(_ smart: Playlist) -> [String] {
        MusicDataStore.shared.smartTracks(keyword: smart.smartRule?.artistKeyword ?? "").map { $0.id }
    }

    private func belongsToActiveBackend(_ playlist: Playlist) -> Bool {
        guard let backend = playlist.backend else { return true }
        return backend == BackendRegistry.shared.activeKind
    }
}
