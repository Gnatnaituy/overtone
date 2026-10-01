import SwiftUI

/// 播放列表（本地存储，JSON 持久化到 Application Support；普通列表与 Jellyfin 服务器双向同步）
struct Playlist: Codable, Identifiable, Equatable {
    let id: UUID
    /// 服务器播放列表 id（nil 表示尚未同步到服务器；智能列表恒为 nil）
    var serverId: String?
    var name: String
    var trackIds: [String]
    /// 曲目 id → 服务器条目 id（PlaylistItemId），用于删除条目
    var itemMap: [String: String]?
    var createdAt: Date
    var isSmart: Bool
    var smartRule: SmartRule?

    struct SmartRule: Codable, Equatable {
        var artistKeyword: String
    }
}

@MainActor
final class PlaylistStore: ObservableObject {
    static let shared = PlaylistStore()

    @Published private(set) var playlists: [Playlist] = []
    @Published private(set) var smartPlaylists: [Playlist] = []

    var allPlaylists: [Playlist] { playlists + smartPlaylists }

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinMac", isDirectory: true)
        return dir.appendingPathComponent("playlists.json")
    }

    private init() { load() }

    // MARK: - 增删改（本地变更 + 实时推送到服务器）

    @discardableResult
    func create(name: String) -> Playlist {
        let p = Playlist(
            id: UUID(),
            serverId: nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新播放列表" : name,
            trackIds: [],
            itemMap: nil,
            createdAt: Date(),
            isSmart: false,
            smartRule: nil
        )
        playlists.append(p)
        save()
        let snapshot = p
        Task { try? await PlaylistSyncService.shared.pushCreate(snapshot) }
        return p
    }

    @discardableResult
    func createSmart(name: String, artistKeyword: String) -> Playlist {
        let p = Playlist(
            id: UUID(),
            serverId: nil,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "智能播放列表" : name,
            trackIds: [],
            itemMap: nil,
            createdAt: Date(),
            isSmart: true,
            smartRule: Playlist.SmartRule(artistKeyword: artistKeyword)
        )
        smartPlaylists.append(p)
        save()
        // 立即镜像到服务器普通播放列表
        let snapshot = p
        Task { try? await PlaylistSyncService.shared.pushSmartMirror(snapshot) }
        return p
    }

    func delete(_ playlist: Playlist) {
        if playlist.isSmart {
            smartPlaylists.removeAll { $0.id == playlist.id }
            if let serverId = playlist.serverId {
                Task { try? await PlaylistSyncService.shared.pushDelete(serverId: serverId) }
            }
        } else {
            playlists.removeAll { $0.id == playlist.id }
            if let serverId = playlist.serverId {
                Task { try? await PlaylistSyncService.shared.pushDelete(serverId: serverId) }
            }
        }
        save()
    }

    func rename(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if playlist.isSmart {
            if let i = smartPlaylists.firstIndex(where: { $0.id == playlist.id }) {
                smartPlaylists[i].name = trimmed
            }
        } else {
            if let i = playlists.firstIndex(where: { $0.id == playlist.id }) {
                playlists[i].name = trimmed
            }
        }
        save()
        if let updated = allPlaylists.first(where: { $0.id == playlist.id }), let serverId = updated.serverId {
            Task { try? await PlaylistSyncService.shared.pushRename(updated) }
        }
    }

    func add(track: BaseItemDto, to playlist: Playlist) {
        guard !playlist.isSmart else { return }
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard !playlists[i].trackIds.contains(track.id) else { return }
        playlists[i].trackIds.append(track.id)
        save()
        if let serverId = playlists[i].serverId {
            let trackId = track.id
            Task { try? await PlaylistSyncService.shared.pushAdd(serverId: serverId, trackId: trackId) }
        }
    }

    func remove(trackId: String, from playlist: Playlist) {
        guard !playlist.isSmart else { return }
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].trackIds.removeAll { $0 == trackId }
        playlists[i].itemMap?[trackId] = nil
        save()
        if let serverId = playlists[i].serverId {
            let snapshot = playlists[i]
            Task { try? await PlaylistSyncService.shared.pushRemove(playlist: snapshot, trackId: trackId) }
        }
    }

    /// 拖动排序 / ⌘↑⌘↓ 上下移（仅本地播放列表；顺序变更后整表推送到服务器）
    func moveTracks(in playlist: Playlist, from source: IndexSet, to destination: Int) {
        guard !playlist.isSmart else { return }
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        playlists[i].trackIds.move(fromOffsets: source, toOffset: destination)
        save()
        if playlists[i].serverId != nil {
            let snapshot = playlists[i]
            Task { try? await PlaylistSyncService.shared.pushRename(snapshot) }
        }
    }

    /// 上移 / 下移一位（键盘 ⌘↑ / ⌘↓ 用）
    func shiftTrack(in playlist: Playlist, trackId: String, offset: Int) {
        guard !playlist.isSmart else { return }
        guard let i = playlists.firstIndex(where: { $0.id == playlist.id }) else { return }
        guard let current = playlists[i].trackIds.firstIndex(of: trackId) else { return }
        let target = current + offset
        guard target >= 0, target < playlists[i].trackIds.count else { return }
        playlists[i].trackIds.swapAt(current, target)
        save()
        if playlists[i].serverId != nil {
            let snapshot = playlists[i]
            Task { try? await PlaylistSyncService.shared.pushRename(snapshot) }
        }
    }

    // MARK: - 同步导入 / 更新 / 绑定

    func importFromServer(serverId: String, name: String, trackIds: [String], itemMap: [String: String]) {
        guard !playlists.contains(where: { $0.serverId == serverId }) else { return }
        let p = Playlist(
            id: UUID(),
            serverId: serverId,
            name: name,
            trackIds: trackIds,
            itemMap: itemMap,
            createdAt: Date(),
            isSmart: false,
            smartRule: nil
        )
        playlists.append(p)
        save()
    }

    func updateFromServer(localId: UUID, name: String, trackIds: [String], itemMap: [String: String]) {
        guard let i = playlists.firstIndex(where: { $0.id == localId }) else { return }
        playlists[i].name = name
        playlists[i].trackIds = trackIds
        playlists[i].itemMap = itemMap
        save()
    }

    func bindServerId(localId: UUID, serverId: String) {
        if let i = playlists.firstIndex(where: { $0.id == localId }) {
            playlists[i].serverId = serverId
        } else if let i = smartPlaylists.firstIndex(where: { $0.id == localId }) {
            smartPlaylists[i].serverId = serverId
        }
        save()
    }

    // MARK: - 持久化

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(allPlaylists)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("[PlaylistStore] save failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let all = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = all.filter { !$0.isSmart }
        smartPlaylists = all.filter { $0.isSmart }
    }
}
