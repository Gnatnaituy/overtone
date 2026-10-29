import Foundation

// MARK: - 单条目记录

/// 本地兜底的单条目用户数据（内存与磁盘共用）。
///
/// 为什么不直接落盘 `MediaUserData`：
/// - 「继续播放」判定需要**时长**（`resumePosition > 5 && resumePosition < duration - 10`），
///   而 `MediaUserData` 里没有时长；
/// - `updatedAt` 用来排查「这条记录是谁、什么时候写的」，出问题时能对上播放日志。
struct LocalLibraryRecord: Codable, Hashable, Sendable {
    var isFavorite: Bool = false
    var playCount: Int = 0
    var lastPlayed: Date?
    var resumePosition: Double = 0
    /// 最近一次上报进度时已知的条目时长（秒）；0 = 未知。
    var duration: Double = 0
    var isPlayed: Bool = false
    var updatedAt: Date?

    init() {}

    /// 手写解码：字段缺失 / 类型不符时退化成默认值，而不是让整份文件解码失败。
    ///
    /// 这条是「文件损坏不崩」的第二道保险：第一道是调用方 `try?` 整体解码，
    /// 但旧版本文件少一两个字段（或人工编辑过）不该丢掉整份本地兜底数据。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        lastPlayed = try container.decodeIfPresent(Date.self, forKey: .lastPlayed)
        resumePosition = try container.decodeIfPresent(Double.self, forKey: .resumePosition) ?? 0
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        isPlayed = try container.decodeIfPresent(Bool.self, forKey: .isPlayed) ?? false
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    /// 换算成领域模型（`MediaItem.userData`）
    var userData: MediaUserData {
        MediaUserData(
            isFavorite: isFavorite,
            playCount: playCount,
            lastPlayed: lastPlayed,
            resumePosition: resumePosition,
            isPlayed: isPlayed
        )
    }

    /// 没有任何有效信息 → 内存里删掉、不落盘。
    ///
    /// 典型场景：用户点了一下收藏又立刻取消，不该给这条目留一份空记录，
    /// 否则 `userData(itemID:)` 会返回「存在但全空」，调用方难以区分「从没碰过」。
    var isEmpty: Bool {
        !isFavorite
            && playCount == 0
            && lastPlayed == nil
            && resumePosition == 0
            && duration == 0
            && !isPlayed
    }
}

// MARK: - 账号作用域

/// 一个**跨后端共享**的账号档案作用域。
///
/// 改造前是「后端 + 账号」两元组 —— 于是同一首歌在 Jellyfin 与飞牛各存一份记录、
/// 各下一份封面。现在按**账号档案**（归一化用户名）分文件，条目键用
/// `ContentIdentity` 的内容身份，同一首歌两边共用一条记录。
///
/// `profileKey` 由调用方给（见 `AppState.profileKey`）：取用户名做归一化，
/// 这样「Jellyfin 的 ravooo」和「飞牛的 ravooo」被视为同一个人。
/// 文件名只用它的 sha256 前 16 位：文件名会出现在崩溃日志、截图、备份工具里，
/// 不该把用户名明文写进去。
private struct LocalLibraryScope: Hashable, Sendable {
    let profileKey: String

    /// 文件名里的账号指纹（sha256 前 16 个 hex 字符）
    var accountKeyHash: String {
        LocalLibrarySHA256.hexPrefix(profileKey, characters: 16)
    }

    /// 落盘文件名：`profile-<sha256 前 16 位>.json`
    var fileName: String {
        "profile-\(accountKeyHash).json"
    }
}

// MARK: - SHA-256

/// 自带的 SHA-256（只用于文件名散列）。
///
/// 为什么不用 CryptoKit：本文件约定只 import Foundation（不引入额外框架依赖），
/// 而这里需要的只是「稳定、定长、抗碰撞的短标识」，不涉及任何安全用途
/// （不用于加密、签名、口令）。实现是 FIPS 180-4 的标准流程，已用官方测试向量校验。
private enum LocalLibrarySHA256 {
    /// 前 `characters` 个 hex 字符（小写）
    static func hexPrefix(_ text: String, characters: Int) -> String {
        String(hex(Array(text.utf8)).prefix(max(0, characters)))
    }

    /// 完整 64 位 hex（小写）
    static func hex(_ bytes: [UInt8]) -> String {
        var state: [UInt32] = [
            0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
            0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
        ]

        // 填充：0x80 + 若干 0，直到长度 % 64 == 56，再补 8 字节大端 bit 长度
        var message = bytes
        let bitLength = UInt64(message.count) * 8
        message.append(0x80)
        while message.count % 64 != 56 {
            message.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
        }

        var schedule = [UInt32](repeating: 0, count: 64)
        for chunkStart in stride(from: 0, to: message.count, by: 64) {
            for index in 0..<16 {
                let base = chunkStart + index * 4
                schedule[index] = UInt32(message[base]) << 24
                    | UInt32(message[base + 1]) << 16
                    | UInt32(message[base + 2]) << 8
                    | UInt32(message[base + 3])
            }
            for index in 16..<64 {
                let s0 = rotateRight(schedule[index - 15], 7)
                    ^ rotateRight(schedule[index - 15], 18)
                    ^ (schedule[index - 15] >> 3)
                let s1 = rotateRight(schedule[index - 2], 17)
                    ^ rotateRight(schedule[index - 2], 19)
                    ^ (schedule[index - 2] >> 10)
                schedule[index] = schedule[index - 16] &+ s0 &+ schedule[index - 7] &+ s1
            }

            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for index in 0..<64 {
                let sum1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25)
                let choose = (e & f) ^ (~e & g)
                let temp1 = h &+ sum1 &+ choose &+ roundConstants[index] &+ schedule[index]
                let sum0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ temp1
                d = c
                c = b
                b = a
                a = temp1 &+ temp2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
        }

        return state.map { String(format: "%08x", $0) }.joined()
    }

    private static func rotateRight(_ value: UInt32, _ amount: UInt32) -> UInt32 {
        (value >> amount) | (value << (32 - amount))
    }

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2,
    ]
}

// MARK: - 磁盘格式

/// 落盘信封：带版本与作用域标记。
///
/// 版本号是给未来迁移留的口子（比如记录结构变化时按版本转换）；
/// `scopeHash` 只是标出「这个文件属于哪个账号作用域」，写的仍是哈希而不是明文。
private struct LocalLibraryFile: Codable {
    var version: Int
    var backend: String
    var scopeHash: String
    var items: [String: LocalLibraryRecord]

    init(version: Int, backend: String, scopeHash: String, items: [String: LocalLibraryRecord]) {
        self.version = version
        self.backend = backend
        self.scopeHash = scopeHash
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 0
        backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? ""
        scopeHash = try container.decodeIfPresent(String.self, forKey: .scopeHash) ?? ""
        items = try container.decodeIfPresent([String: LocalLibraryRecord].self, forKey: .items) ?? [:]
    }
}

// MARK: - 持久化

/// JSON 落盘实现。
///
/// 这里是 `nonisolated` 的文件级函数：`LocalLibraryState`（@MainActor）`await` 它们时
/// 会切到协作线程池执行（SE-0338），主线程完全不参与编码。
///
/// 不做并发保护：唯一调用方是 `LocalLibraryState`，它保证同一时刻只有一个 drain 在写。
private enum LocalLibraryPersistence {
    /// 当前文件格式版本
    /// 2 = 跨后端共享（按内容身份记录）。1 = 旧版（按后端 + 条目 id）。
    static let schemaVersion = 2

    /// `Application Support/JellyfinMac/local-state/`
    ///
    /// 只解析一次：`FileManager.urls(for:in:)` 每次都会走系统目录查询，
    /// 而每个账号作用域都要用它拼路径（与 `PlaylistStore.fileURL` 同样的理由）。
    static let directoryURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("JellyfinMac", isDirectory: true)
            .appendingPathComponent("local-state", isDirectory: true)
    }()

    /// 解码器（只在主线程的懒加载路径里用）
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func fileURL(for scope: LocalLibraryScope) -> URL {
        directoryURL.appendingPathComponent(scope.fileName, isDirectory: false)
    }

    /// 读一个作用域的表。
    ///
    /// 容错策略：文件不存在 → 空表（首次使用，正常）；解码失败 → 空表 + 日志（不崩、不删文件，
    /// 用户下次写入才会覆盖它 —— 保留原文件是为了还有手工捞回的可能）。
    static func read(_ scope: LocalLibraryScope) -> [String: LocalLibraryRecord] {
        let url = fileURL(for: scope)
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let file = try decoder.decode(LocalLibraryFile.self, from: data)
            if file.version > schemaVersion {
                print("[LocalLibraryState] \(url.lastPathComponent) 版本 \(file.version) 高于当前 \(schemaVersion)，按已知字段尽力读取")
            }
            return file.items
        } catch {
            print("[LocalLibraryState] 读取失败，按空表处理 \(url.lastPathComponent): \(error)")
            return [:]
        }
    }

    /// 后台写一个作用域的表（编码 + 原子写都在这里，不占主线程）。
    static func write(_ items: [String: LocalLibraryRecord], for scope: LocalLibraryScope) async {
        performWrite(items, for: scope)
    }

    /// 同步写（只给 `flushNowBlocking` 在 App 退出流程里用；会把主线程占住一次小 JSON 写）
    static func writeSynchronously(_ items: [String: LocalLibraryRecord], for scope: LocalLibraryScope) {
        performWrite(items, for: scope)
    }

    private static func performWrite(_ items: [String: LocalLibraryRecord], for scope: LocalLibraryScope) {
        let url = fileURL(for: scope)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            // 每次写新建 encoder：磁盘写是唯一的热点，encoder 本身的分配可以忽略；
            // 共享一个 JSONEncoder 反而会在「两个 drain 交错」时引入共享可变状态。
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let file = LocalLibraryFile(
                version: schemaVersion,
                // 新格式跨后端共享：这个字段只作诊断标记（旧格式读时用来还原后端）
                backend: "shared",
                scopeHash: scope.accountKeyHash,
                items: items
            )
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[LocalLibraryState] 写入失败 \(url.lastPathComponent): \(error)")
        }
    }

    /// 真删文件（`clear` 用；文件不存在不算错）
    static func removeFile(for scope: LocalLibraryScope) {
        let url = fileURL(for: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[LocalLibraryState] 删除失败 \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - 仓库

/// 「服务端没有 → 本地兜底」的用户数据仓库。
///
/// 背景：飞牛音乐只有收藏；播放次数 / 最近播放时间 / 续播位置都没有。
/// 这些数据写在这里，读取时由调用方（当前是 `MusicDataStore.applyLocalOverrides`）
/// 用 `merge(server:local:)` 合并到 `MediaItem.userData` —— 字段位置不变，UI 不区分来源。
///
/// 线程模型：
/// - **所有内存态都在 @MainActor**（与状态层同一个 actor，读写不需要锁，也不会和 UI 抢）；
/// - 编码 + 写盘在 `LocalLibraryPersistence.write`（nonisolated async → 后台线程池）；
/// - 落盘 debounce 300ms：播放进度每 0.5s 变一次，逐次写盘是持续的磁盘写放大；
/// - 写盘期间的连续变更不会丢：dirty 集合只增不减，drain 循环会再扫一遍（见 `drainDirtyScopes`）。
///
/// 持久化位置：`Application Support/JellyfinMac/local-state/<backend>-<hash16>.json`（每账号一个文件）。
@MainActor
final class LocalLibraryState {
    static let shared = LocalLibraryState()

    private init() {}

    // MARK: - 纯函数：合并规则

    /// 合并服务端与本地兜底用户数据（纯函数，不读单例、不碰磁盘 → 可脱离 App 单测）。
    ///
    /// 规则：
    /// 1. **收藏**：`serverSupportsFavorites == true`（如 Jellyfin 的曲目、飞牛的曲目）→ 一律服务端，
    ///    本地只是镜像；不支持（如飞牛的专辑/艺人）→ 本地。
    /// 2. **播放次数 / 上次播放时间 / 是否播完 / 续播位置**：本地有记录就本地优先 ——
    ///    这些字段服务端根本没有（飞牛），本地的才是用户看到过的那个值。
    ///    本地没有这条记录时保留服务端的值（Jellyfin 场景）。
    ///
    /// 注意：调用方只在「后端缺这项能力」时才应该把本地记录喂进来；
    /// 若对 Jellyfin 也传本地记录（本地也会记播放统计用于离线续播），
    /// 会把服务端更准确的 playCount 覆盖成 1 —— 见 `MusicDataStore.applyLocalOverrides` 的门控。
    nonisolated static func merge(
        server: MediaUserData,
        local: MediaUserData?,
        serverSupportsFavorites: Bool
    ) -> MediaUserData {
        var merged = server
        if serverSupportsFavorites {
            // 服务端支持收藏时以服务端为准（包括「在别的设备上取消了收藏」）
            merged.isFavorite = server.isFavorite
        } else {
            merged.isFavorite = local?.isFavorite ?? server.isFavorite
        }

        if let local {
            merged.playCount = local.playCount
            merged.lastPlayed = local.lastPlayed
            merged.resumePosition = local.resumePosition
            merged.isPlayed = local.isPlayed
        }
        return merged
    }

    /// 不知道后端收藏能力时的保守合并（当前状态层调用点 `merge(server:local:)` 用它）。
    ///
    /// 收藏取**并集**：服务端 `true` 一定保留（支持收藏的后端上服务端是权威），
    /// 本地 `true` 也保留（不支持收藏的后端 —— 飞牛的专辑/艺人 —— 只能靠本地）。
    /// 这样同一个函数对两类条目都成立：曲目收藏来自服务端，专辑收藏来自本地。
    ///
    /// 代价：如果某条「只存在本地」的收藏在服务端开始支持收藏后于别处被取消，
    /// 陈旧的本地 `true` 会继续生效。彻底解决要靠调用方传入能力（用上面那个重载）
    /// 或换账号时 `clear`。见 `docs/research/local-fallback-notes.md`。
    nonisolated static func merge(server: MediaUserData, local: MediaUserData?) -> MediaUserData {
        var merged = merge(server: server, local: local, serverSupportsFavorites: true)
        if let local, local.isFavorite {
            merged.isFavorite = true
        }
        return merged
    }

    // MARK: - 内存状态（全部 @MainActor）

    /// 作用域 → (条目 id → 记录)
    private var tables: [LocalLibraryScope: [String: LocalLibraryRecord]] = [:]
    /// 已从磁盘读过（或 clear 过）的作用域，避免每次读都碰磁盘
    private var loadedScopes: Set<LocalLibraryScope> = []
    /// 待落盘的作用域
    private var dirtyScopes: Set<LocalLibraryScope> = []
    /// 每次 `clear` +1；在途写盘完成后用它判断「写入期间是否被清空」
    private var clearGenerations: [LocalLibraryScope: Int] = [:]
    /// debounce 窗口（nil = 当前没有排队的写盘）
    private var debounceTask: Task<Void, Never>?
    /// 正在跑 drain 的次数（`flushNow` 用它等待在途写盘）
    private var activeDrains = 0

    /// 任何一次本地用户数据变更自增（调用方可用它做 O(1) 的变更检测，
    /// 与 `PlaylistStore.revision` 同一用途）。
    private(set) var revision = 0

    // MARK: - 读

    /// 该作用域下所有本地用户数据（条目 id → 数据）。没记录时返回空字典。
    func overrides(profileKey: String) -> [String: MediaUserData] {
        let scope = LocalLibraryScope(profileKey: profileKey)
        ensureLoaded(scope)
        guard let table = tables[scope], !table.isEmpty else { return [:] }
        var result: [String: MediaUserData] = [:]
        result.reserveCapacity(table.count)
        for (itemID, record) in table {
            result[itemID] = record.userData
        }
        return result
    }

    /// 单条目的本地用户数据；`nil` = 本地从没碰过这条目（与服务端「全空」区分开）。
    func userData(contentKey: String, profileKey: String) -> MediaUserData? {
        let scope = LocalLibraryScope(profileKey: profileKey)
        ensureLoaded(scope)
        return tables[scope]?[contentKey]?.userData
    }

    /// 本地收藏的条目 id 集合
    func favoriteIDs(profileKey: String) -> Set<String> {
        let scope = LocalLibraryScope(profileKey: profileKey)
        ensureLoaded(scope)
        guard let table = tables[scope] else { return [] }
        return Set(table.compactMap { $0.value.isFavorite ? $0.key : nil })
    }

    /// 继续播放：未听完的条目 id（按最近播放时间倒序，最多 `limit` 首）。
    ///
    /// 「未听完」= `resumePosition > 5` 且 `resumePosition < duration - 10`：
    /// - 前 5 秒不算「听过」（用户很可能只是滑过去了）；
    /// - 最后 10 秒不算「续播」（马上播完的条目继续播没有意义，播放器会直接从头）。
    /// `duration <= 0`（时长未知）的记录不参与 —— 没法判断是否听完。
    func resumableIDs(profileKey: String, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let scope = LocalLibraryScope(profileKey: profileKey)
        ensureLoaded(scope)
        guard let table = tables[scope] else { return [] }

        let candidates: [(id: String, lastPlayed: Date)] = table.compactMap { itemID, record in
            guard record.duration > 0 else { return nil }
            guard record.resumePosition > 5 else { return nil }
            guard record.resumePosition < record.duration - 10 else { return nil }
            return (itemID, record.lastPlayed ?? record.updatedAt ?? .distantPast)
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.lastPlayed != rhs.lastPlayed {
                    return lhs.lastPlayed > rhs.lastPlayed
                }
                // 同一时刻按 id 升序，保证结果稳定（不含随机顺序）
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map(\.id)
    }

    // MARK: - 写

    /// 播放进度：position / duration 都是秒。
    ///
    /// - `duration <= 0`（服务端没给时长 / 流还没解析出来）时**忽略本次进度**：
    ///   没有时长就没法判断「未听完」，写进去只会污染「继续播放」列表；
    /// - `playedToEnd == true` 时清空进度并标记已播完（从「继续播放」里移除）。
    func recordProgress(
        contentKey: String,
        profileKey: String,
        position: Double,
        duration: Double,
        playedToEnd: Bool
    ) {
        let scope = LocalLibraryScope(profileKey: profileKey)
        mutate(scope, contentKey: contentKey) { record in
            if playedToEnd {
                record.resumePosition = 0
                record.isPlayed = true
                if duration > 0 { record.duration = duration }
            } else if duration > 0 {
                // 夹到 [0, duration]：播放器偶尔会报出比时长略大的位置（缓冲/浮点误差）
                record.resumePosition = min(max(position, 0), duration)
                record.duration = duration
            }
        }
    }

    /// 播放开始：播放次数 +1、最近播放时间 = now、标记已播放（含播完后再播）。
    func recordPlayStart(contentKey: String, profileKey: String) {
        let scope = LocalLibraryScope(profileKey: profileKey)
        mutate(scope, contentKey: contentKey) { record in
            record.playCount += 1
            record.lastPlayed = Date()
            record.isPlayed = true
        }
    }

    /// 收藏（仅用于服务端不支持收藏的条目 —— 支持时由后端写服务端，这里只是镜像）
    func setFavorite(contentKey: String, profileKey: String, favorite: Bool) {
        let scope = LocalLibraryScope(profileKey: profileKey)
        mutate(scope, contentKey: contentKey) { record in
            record.isFavorite = favorite
        }
    }

    /// 清空一个作用域：内存表清掉 + **真正删除磁盘文件**（退出登录 / 换账号时调）。
    ///
    /// 与 debounce 的关系：删除后 generation +1；正在途中的写盘完成后会发现 generation 变了，
    /// 按最新内存状态收敛（内存又空了就再删一次、内存有新数据就重写），
    /// 不会出现「clear 之后又被旧快照写回来」。
    func clear(profileKey: String) {
        let scope = LocalLibraryScope(profileKey: profileKey)
        tables[scope] = [:]
        loadedScopes.insert(scope)
        dirtyScopes.remove(scope)
        clearGenerations[scope, default: 0] += 1
        revision &+= 1
        LocalLibraryPersistence.removeFile(for: scope)
    }

    // MARK: - 旧格式迁移（按后端 + 条目 id 的 v1 文件）

    /// 旧版（v1）文件里的记录，键为 `"<backend>|<itemID>"`。
    ///
    /// 为什么不直接搬进新表：v1 的键是**条目 id**，而我们没有条目元数据就换不出内容身份。
    /// 所以只在「真的看到这个条目」时按需搬一条（`adoptLegacy`），既保证不丢老进度，
    /// 又不需要在启动时把整库拉一遍。
    private var legacyRecords: [String: LocalLibraryRecord]?
    private var loadedLegacy = false

    /// 查一条旧记录（`nil` = 没有 / 已迁移）
    func legacyUserData(backend: BackendKind, itemID: String) -> MediaUserData? {
        loadLegacyIfNeeded()
        return legacyRecords?["\(backend.rawValue)|\(itemID)"]?.userData
    }

    /// 把旧记录搬到新的内容身份下（幂等；已有新记录时做保守合并）。
    ///
    /// 只在 `MusicDataStore` 应用本地覆盖时调用：那时手里正好有 `MediaItem`，
    /// 可以算出内容身份。
    func adoptLegacy(
        backend: BackendKind,
        itemID: String,
        contentKey: String,
        profileKey: String
    ) {
        loadLegacyIfNeeded()
        let legacyKey = "\(backend.rawValue)|\(itemID)"
        guard let legacy = legacyRecords?[legacyKey] else { return }
        let scope = LocalLibraryScope(profileKey: profileKey)
        ensureLoaded(scope)

        var merged = tables[scope]?[contentKey] ?? LocalLibraryRecord()
        let incoming = legacy
        merged.playCount = max(merged.playCount, incoming.playCount)
        merged.isFavorite = merged.isFavorite || incoming.isFavorite
        merged.isPlayed = merged.isPlayed || incoming.isPlayed
        if let a = merged.lastPlayed, let b = incoming.lastPlayed {
            if b > a { merged.lastPlayed = b; merged.resumePosition = incoming.resumePosition; merged.duration = incoming.duration }
        } else if merged.lastPlayed == nil, let b = incoming.lastPlayed {
            merged.lastPlayed = b
            merged.resumePosition = incoming.resumePosition
            merged.duration = incoming.duration
        }
        if merged.duration == 0 { merged.duration = incoming.duration }
        if merged.resumePosition == 0 { merged.resumePosition = incoming.resumePosition }
        merged.updatedAt = Date()

        tables[scope, default: [:]][contentKey] = merged
        legacyRecords?.removeValue(forKey: legacyKey)
        revision &+= 1
        markDirty(scope)
    }

    private func loadLegacyIfNeeded() {
        guard !loadedLegacy else { return }
        loadedLegacy = true
        var result: [String: LocalLibraryRecord] = [:]
        let directory = LocalLibraryPersistence.directoryURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            legacyRecords = result
            return
        }
        for file in files where file.pathExtension == "json" && !file.lastPathComponent.hasPrefix("profile-") {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? LocalLibraryPersistence.decoder.decode(LocalLibraryFile.self, from: data)
            else { continue }
            // v1 文件名是 `<backend>-<hash>`，backend 字段里也写着后端
            let backend = decoded.backend.isEmpty
                ? file.lastPathComponent.split(separator: "-").first.map(String.init) ?? ""
                : decoded.backend
            for (itemID, record) in decoded.items {
                result["\(backend)|\(itemID)"] = record
            }
        }
        legacyRecords = result
    }

    /// 立刻把待写数据全部落盘（App 退出、切换账号、注销前调用）。
    ///
    /// 为什么需要它：debounce 意味着「最后一次变更后 300ms 内进程退出」会丢数据。
    /// 调用点不在本文件：`applicationWillTerminate` 或「退出登录」流程里 `await` 一次。
    func flushNow() async {
        debounceTask?.cancel()
        debounceTask = nil
        // 等已经开跑的 drain 结束（每次等待 1ms，避免空转占满主线程）
        while activeDrains > 0 {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        await drainDirtyScopes()
    }

    /// 立刻落盘（**同步**版本，只给「进程马上要退出」的场合用）。
    ///
    /// 为什么需要它：`applicationWillTerminate` 不能 `await`，`Task { await flushNow() }` 也不保证
    /// 在进程退出前跑完 —— 而 debounce 意味着「最后一次变更后 300ms 内退出」会丢掉那一笔。
    /// 这里直接在调用线程完成编码与写盘（数据量是单账号的本地兜底记录，几 KB~几百 KB，可接受）。
    ///
    /// 与在途异步写并发时的收敛：每写一个作用域把 generation +1，在途的那次写完成后会发现
    /// generation 变了并按**最新内存态**再写一次（见 `persist(_:)`），最终文件内容一定是最新的。
    func flushNowBlocking() {
        debounceTask?.cancel()
        debounceTask = nil
        let scopes = dirtyScopes
        dirtyScopes.removeAll()
        for scope in scopes {
            guard let items = tables[scope] else { continue }
            clearGenerations[scope, default: 0] += 1
            LocalLibraryPersistence.writeSynchronously(items, for: scope)
        }
    }

    // MARK: - 内部

    /// 读改写单个条目：所有写入口都经由它，保证「空记录清理 + revision + 标脏」三件事一致。
    private func mutate(
        _ scope: LocalLibraryScope,
        contentKey: String,
        _ body: (inout LocalLibraryRecord) -> Void
    ) {
        ensureLoaded(scope)
        var record = tables[scope]?[contentKey] ?? LocalLibraryRecord()
        body(&record)
        record.updatedAt = Date()
        if record.isEmpty {
            tables[scope]?.removeValue(forKey: contentKey)
        } else {
            tables[scope, default: [:]][contentKey] = record
        }
        revision &+= 1
        markDirty(scope)
    }

    /// 懒加载一个作用域的磁盘数据（只读一次；失败按空表，见 `LocalLibraryPersistence.read`）
    private func ensureLoaded(_ scope: LocalLibraryScope) {
        guard !loadedScopes.contains(scope) else { return }
        loadedScopes.insert(scope)
        tables[scope] = LocalLibraryPersistence.read(scope)
    }

    /// 标记脏 + 开启 debounce 窗口
    private func markDirty(_ scope: LocalLibraryScope) {
        dirtyScopes.insert(scope)
        guard debounceTask == nil else { return }
        debounceTask = Task { @MainActor [weak self] in
            // 合并窗口：300ms 内的连续变更只落盘一次
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
            guard let self else { return }
            self.debounceTask = nil
            await self.drainDirtyScopes()
        }
    }

    /// 把当前所有脏作用域写盘。
    ///
    /// `while` 而不是一次 `for`：写盘期间（await 让出主 actor）来的新变更会重新进 `dirtyScopes`，
    /// 循环会再扫一遍 —— 这是「不丢最后一次写入」的关键。
    private func drainDirtyScopes() async {
        activeDrains += 1
        defer { activeDrains -= 1 }
        while !dirtyScopes.isEmpty {
            let scopes = dirtyScopes
            dirtyScopes.removeAll()
            for scope in scopes {
                await persist(scope)
            }
        }
    }

    /// 单个作用域落盘（快照 → 后台写 → 处理 clear 竞态）
    private func persist(_ scope: LocalLibraryScope) async {
        // 已被 clear（内存里没有这个作用域）：不写，否则会把刚删掉的文件又建回来
        guard let items = tables[scope] else { return }
        let generation = clearGenerations[scope, default: 0]
        await LocalLibraryPersistence.write(items, for: scope)
        guard clearGenerations[scope, default: 0] != generation else { return }
        // 写盘期间被 clear：以内存最新状态为准做一次收敛
        if let latest = tables[scope] {
            await LocalLibraryPersistence.write(latest, for: scope)
        } else {
            LocalLibraryPersistence.removeFile(for: scope)
        }
    }
}
