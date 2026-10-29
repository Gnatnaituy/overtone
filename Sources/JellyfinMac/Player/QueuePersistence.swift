import Foundation

// MARK: - 队列快照

/// 播放队列的持久化快照（`Application Support/JellyfinMac/queue-state.json`）。
///
/// 为什么快照要带 `backendKind` 与 `savedAt`：
/// - 队列里的 `MediaItem` 属于**某个后端实例**（id / 封面引用 / 播放源都是后端作用域的），
///   换了后端还恢复旧队列，点播放会用新后端的 playableSource 去解析旧 id —— 必然 404；
/// - 一周前的队列对用户已经没有「我刚才在听」的意义，恢复它反而像 bug。
///
/// 为什么 `playMode` 存字符串而不是 `MusicPlayerModel.PlayMode`：
/// 持久化层与播放器解耦，播放器改枚举（加新模式）时这份文件不需要一起改；
/// 读到不认识的字符串时播放器退化成顺序播放即可（见 `QueueSnapshot.validated` 的调用方）。
struct QueueSnapshot: Codable, Equatable {
    /// 文件格式版本（未来字段语义变化时迁移用）
    var version: Int
    /// 保存时的活动后端
    var backendKind: BackendKind
    var savedAt: Date
    var currentIndex: Int
    /// `MusicPlayerModel.PlayMode.rawValue`；未知值由播放器降级为顺序播放
    var playMode: String
    /// 当前曲目的播放位置（秒）。恢复后不自动播放，用户点播放时从这里续
    var position: Double
    /// 队列曲目（顺序即播放顺序）
    var tracks: [MediaItem]
    /// InstantMix 自动续播段的起始下标（-1 = 队列里没有自动续播段）
    var autoContinueStart: Int

    enum CodingKeys: String, CodingKey {
        case version
        case backendKind
        case savedAt
        case currentIndex
        case playMode
        case position
        case tracks
        case autoContinueStart
    }

    init(
        version: Int = QueuePersistence.supportedVersion,
        backendKind: BackendKind,
        savedAt: Date = Date(),
        currentIndex: Int,
        playMode: String,
        position: Double,
        tracks: [MediaItem],
        autoContinueStart: Int = -1
    ) {
        self.version = version
        self.backendKind = backendKind
        self.savedAt = savedAt
        self.currentIndex = currentIndex
        self.playMode = playMode
        self.position = position
        self.tracks = tracks
        self.autoContinueStart = autoContinueStart
    }
}

// MARK: - 容错解码

extension QueueSnapshot {
    /// 手写解码：**单字段损坏不该让整份队列丢掉**（与 `LocalLibraryRecord` 同一策略）。
    ///
    /// 特别是 `tracks` 里某一条 `MediaItem` 结构变化（旧 app 版本写的）时，
    /// 整份失败会让用户「队列还在、重启就没了」；这里让缺失字段退化成默认值，
    /// 真正的合法性由 `validated(for:now:)` 统一裁决。
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version)
            ?? QueuePersistence.supportedVersion
        backendKind = try container.decodeIfPresent(BackendKind.self, forKey: .backendKind)
            ?? .jellyfin
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt) ?? .distantPast
        currentIndex = try container.decodeIfPresent(Int.self, forKey: .currentIndex) ?? 0
        playMode = try container.decodeIfPresent(String.self, forKey: .playMode) ?? ""
        position = try container.decodeIfPresent(Double.self, forKey: .position) ?? 0
        tracks = try container.decodeIfPresent([MediaItem].self, forKey: .tracks) ?? []
        autoContinueStart = try container.decodeIfPresent(Int.self, forKey: .autoContinueStart) ?? -1
    }
}

// MARK: - 校验（纯函数）

extension QueueSnapshot {
    /// 单个快照最多容纳的曲目数：防「人工编辑 / 异常写入」把一份几十 MB 的 JSON 读进内存。
    static let maximumTrackCount = 5_000

    /// 判断快照能否在当前后端使用，并返回**夹取/清洗过**的副本；`nil` = 不可用。
    ///
    /// 规则（与任务契约一致）：
    /// 1. 文件格式版本不能高于当前 app 认识的版本（未来格式读不懂就放弃）；
    /// 2. 后端必须一致 —— 播放源/id 都是后端作用域的；
    /// 3. 保存时间在 7 天内（且不能是「未来一小时以上」，那通常是系统时钟被改过）；
    /// 4. 队列非空、条目全是曲目且都属于同一后端；
    /// 5. 索引/位置/自动续播起点一律夹到合法区间 —— 坏索引不该让恢复流程崩掉。
    func validated(for kind: BackendKind, now: Date = Date()) -> QueueSnapshot? {
        guard version >= 1, version <= QueuePersistence.supportedVersion else { return nil }
        guard backendKind == kind else { return nil }

        let age = now.timeIntervalSince(savedAt)
        guard age <= QueuePersistence.maximumAge, age > -3_600 else { return nil }

        guard !tracks.isEmpty, tracks.count <= Self.maximumTrackCount else { return nil }
        for track in tracks {
            guard track.kind == .track, track.backend == kind else { return nil }
        }

        var snapshot = self
        snapshot.currentIndex = min(max(currentIndex, 0), tracks.count - 1)
        if !position.isFinite || position < 0 {
            snapshot.position = 0
        }
        let duration = tracks[snapshot.currentIndex].duration
        if duration > 0 {
            // 末尾 1 秒内不让「续播」：否则一按播放就立刻触发下一首
            snapshot.position = min(snapshot.position, max(duration - 1, 0))
        }
        if autoContinueStart < 0 || autoContinueStart >= tracks.count {
            snapshot.autoContinueStart = -1
        }
        return snapshot
    }
}

// MARK: - 磁盘读写

/// 队列快照的落盘实现。
///
/// 线程模型：所有公开方法内部走一条**串行**队列 —— 播放器的 debounce 保存、退出前的同步保存、
/// 换后端时的 clear 可能来自不同上下文（Task / 主线程 / 退出回调），不串行化会互相踩文件
/// （最坏情况：clear 之后被一个迟到的 save 把旧队列写回来）。
enum QueuePersistence {
    /// 文件格式版本（字段语义变化时 +1）
    static let supportedVersion = 1

    /// 超过一周的队列不再恢复
    static let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    /// `Application Support/JellyfinMac/`
    ///
    /// 与 `LocalLibraryState` 的 `local-state/` 平级：队列是「播放会话」而非用户数据，
    /// 单独一个文件，损坏时可整份丢弃，不牵连播放进度/收藏。
    static let directoryURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("JellyfinMac", isDirectory: true)
    }()

    static var fileURL: URL {
        directoryURL.appendingPathComponent("queue-state.json", isDirectory: false)
    }

    /// 串行 IO 队列（读写都排它，保证 clear 与 save 的先后语义）
    private static let ioQueue = DispatchQueue(label: "com.overtone.queue-persistence")

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    // MARK: 读

    /// 读取当前后端的队列快照。
    ///
    /// - 文件不存在：`nil`（第一次启动，正常）；
    /// - 解码失败：`nil` + 日志（**不删文件**，保留人工捞回的可能）；
    /// - 后端不匹配 / 过期：`nil` 并删文件（旧队列没有恢复价值，留着只会在切回旧后端时
    ///   「复活」一段陈年队列，反而像 bug）。
    static func load(backend kind: BackendKind, now: Date = Date()) -> QueueSnapshot? {
        ioQueue.sync {
            let url = fileURL
            guard let data = try? Data(contentsOf: url) else { return nil }
            do {
                let snapshot = try decoder.decode(QueueSnapshot.self, from: data)
                guard let valid = snapshot.validated(for: kind, now: now) else {
                    print("[QueuePersistence] 队列快照不适用于 \(kind.rawValue) 或已过期，丢弃")
                    removeFileIfExists()
                    return nil
                }
                return valid
            } catch {
                print("[QueuePersistence] 读取失败，保留原文件待下次覆盖：\(error)")
                return nil
            }
        }
    }

    // MARK: 写

    /// 同步保存（原子写）。
    ///
    /// 空队列等价于 `clear()`：不写一份「空队列文件」，否则下次启动会读到空快照再删一遍。
    static func save(_ snapshot: QueueSnapshot) {
        guard !snapshot.tracks.isEmpty else {
            clear()
            return
        }
        ioQueue.sync {
            let url = fileURL
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL,
                    withIntermediateDirectories: true
                )
                let data = try encoder.encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                print("[QueuePersistence] 写入失败 \(url.lastPathComponent): \(error)")
            }
        }
    }

    /// 清空持久化的队列（用户清空队列 / 切后端 / 退出登录时调）
    static func clear() {
        ioQueue.sync {
            removeFileIfExists()
        }
    }

    // MARK: 内部

    /// 只在 `ioQueue` 内部调用（不做二次 sync，避免死锁）
    private static func removeFileIfExists() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[QueuePersistence] 删除失败 \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - InstantMix 自动续播（纯规则）

/// 队列尾部自动续播的判定与合并规则（不碰网络/播放器，可被自检直接断言）。
enum QueueContinuation {
    /// 单次 InstantMix 请求的条数
    static let requestLimit = 10

    /// 一次播放会话里最多自动追加多少首：防止「无限续播」把队列撑到几千首
    /// （用户看到的队列面板也会失控）。达到上限后回到正常 stopAtEnd 行为。
    static let maximumAutoContinuedTracks = 30

    /// 是否应该向服务端要 InstantMix。
    ///
    /// 「队列剩 <= 1 首」即当前曲目已经是队尾（`currentIndex >= count - 1`）；
    /// 能力不支持 / 用户关闭自动续播 / 自动段已达上限时都返回 false → 保持原来的 stopAtEnd。
    static func shouldRequestContinuation(
        queueCount: Int,
        currentIndex: Int,
        autoContinueEnabled: Bool,
        backendSupportsInstantMix: Bool,
        autoContinuedTrackCount: Int
    ) -> Bool {
        guard autoContinueEnabled, backendSupportsInstantMix else { return false }
        guard queueCount > 0, currentIndex >= 0 else { return false }
        guard currentIndex >= queueCount - 1 else { return false }
        return autoContinuedTrackCount < maximumAutoContinuedTracks
    }

    /// 把 InstantMix 候选并入队列尾部前的去重规则。
    ///
    /// - 只收 `kind == .track`（服务的推荐偶发会混进专辑/艺人条目）；
    /// - 按 `id` 去重：既排除队列里已有的（含当前曲目 —— InstantMix 经常把种子曲目自己带回来），
    ///   也排除候选内部的重复；
    /// - 保持服务端返回顺序，最多 `limit` 首。
    static func appendable(
        from candidates: [MediaItem],
        existing: [MediaItem],
        limit: Int = requestLimit
    ) -> [MediaItem] {
        guard limit > 0 else { return [] }
        var seen = Set(existing.map(\.id))
        var result: [MediaItem] = []
        result.reserveCapacity(min(limit, candidates.count))
        for candidate in candidates {
            guard candidate.kind == .track else { continue }
            guard seen.insert(candidate.id).inserted else { continue }
            result.append(candidate)
            if result.count >= limit { break }
        }
        return result
    }
}
