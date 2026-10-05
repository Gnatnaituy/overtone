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

    /// 变更版本号：任何一次改动（都经由 `save()`）自增。
    ///
    /// 视图用 `.onChange(of: playlistStore.revision)` 代替
    /// `.onChange(of: playlistStore.allPlaylists)`：后者每次 body 更新都要把
    /// `playlists + smartPlaylists` 拼一遍再逐项比较 `trackIds`（O(Σ 曲目数)），
    /// 而它挂在会随播放状态频繁重渲染的详情页上。
    private(set) var revision = 0

    /// 数据文件位置。**只解析一次**：`FileManager.urls(for:in:)` 会走系统目录查询，
    /// 而原实现把它放在计算属性里，每次 `save()` / `load()` 都要查两遍。
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("JellyfinMac", isDirectory: true)
        return dir.appendingPathComponent("playlists.json")
    }()

    /// 后台写入状态：见 `save()` 的合并策略
    private var isWriting = false
    private var pendingWrite = false

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
        // 先取出服务器条目 id 再清理本地映射：`pushRemove` 靠它定位服务器条目，
        // 提前把 itemMap[trackId] 清掉会让它退化成「拉取整个播放列表条目再查找」——
        // 每次从已同步列表移除一首都要多一次全量 GET + JSON 解码。
        let knownEntryId = playlists[i].itemMap?[trackId]
        let serverId = playlists[i].serverId
        // 一次性赋值：分开改 trackIds 与 itemMap 会触发两次 @Published，白重绘两轮
        var updated = playlists[i]
        updated.trackIds.removeAll { $0 == trackId }
        updated.itemMap?[trackId] = nil
        playlists[i] = updated
        save()
        if let serverId {
            Task {
                try? await PlaylistSyncService.shared.pushRemove(
                    serverId: serverId,
                    trackId: trackId,
                    knownEntryId: knownEntryId
                )
            }
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

    /// 持久化：**编码与落盘放到后台**，并合并写入期间的连续变更。
    ///
    /// 原实现每次变更都在主线程同步跑 `JSONEncoder().encode(全表)` + 原子写
    /// （建临时文件 + rename）。而 `PlaylistSyncService.syncAll` 会对每个服务器播放列表
    /// 调一次 `importFromServer` / `updateFromServer`，各自触发一次 `save()` ——
    /// N 个列表就是 N 次「编码全表 + 落盘」，写放大是 O(N²)，且全程卡住主线程
    /// （同步发生在启动阶段，直接表现为启动后界面卡顿）。
    ///
    /// 现在：第一次变更立即写（不延迟，保持原有"改完即落盘"的时效），
    /// 写入期间的后续变更只打标记，写完再补一次 —— 连续同步最多两次落盘。
    private func save() {
        // 所有变更路径都会走到这里，版本号在此统一自增（供视图做 O(1) 变更检测）
        revision &+= 1
        guard !isWriting else {
            pendingWrite = true
            return
        }
        isWriting = true
        let snapshot = allPlaylists
        let url = fileURL
        // 主 actor 上的轻量任务：真正的编码/落盘在 nonisolated async 里跳到协作线程池执行
        Task { @MainActor in
            await Self.write(snapshot, to: url)
            isWriting = false
            if pendingWrite {
                pendingWrite = false
                save()
            }
        }
    }

    /// 实际落盘（nonisolated async：从主 actor 调用时会切到后台执行）
    private nonisolated static func write(_ playlists: [Playlist], to url: URL) async {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(playlists)
            try data.write(to: url, options: .atomic)
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
