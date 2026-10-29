import AppKit
import Combine
import Foundation

// MARK: - 结算规则

/// 提交资格（Last.fm 与 ListenBrainz 共用的宽口径）：
///
/// - 曲目时长必须已知（0 时长不提交 —— 两个服务都会拒收无时长数据）；
/// - 至少听了 30 秒；
/// - 听够 **50%** 或满 **240 秒**；
/// - 自然播完按「听满整首」处理（进度回调可能落后于真实位置）。
///
/// 纯函数，`SelfTest+Scrobble` 直接断言。
enum ScrobbleRule {
    static let minimumPlayed: Double = 30
    static let longListenSeconds: Double = 240
    static let playRatio: Double = 0.5
    /// 单次进度回调最多计入的「有效收听」秒数。
    ///
    /// 进度回调间隔是 5–60 秒（见 `AppSettings.reportInterval`），超过这个跨度基本是
    /// 拖动进度条 / 从续播位置起播 —— 不计入收听时长，避免「跳到 90% 就算听过」。
    static let maxCreditedDelta: Double = 30

    /// Unix 秒（向下取整）：Last.fm `timestamp` / ListenBrainz `listened_at` 都只收整数秒。
    static func unixTimestamp(for date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded(.down))
    }

    /// 两次进度之间的有效收听秒数：只有正常前进且跨度合理才计入。
    static func creditedDelta(from previous: Double, to position: Double) -> Double {
        guard previous.isFinite, position.isFinite else { return 0 }
        let delta = position - previous
        guard delta > 0, delta <= maxCreditedDelta else { return 0 }
        return delta
    }

    static func isEligible(played: Double, duration: Double, completed: Bool) -> Bool {
        guard duration.isFinite, duration > 0, played.isFinite else { return false }
        let clamped = min(max(played, 0), duration)
        let effective = completed ? duration : clamped
        guard effective >= minimumPlayed else { return false }
        return effective >= duration * playRatio || effective >= longListenSeconds
    }
}

// MARK: - 会话

/// 当前播放会话：从 `noteStarted` 到切歌 / 播完 / 退出之间的累计状态。
///
/// 每次进度变化都同步落 `UserDefaults`（体量只有几百字节），这样强退 / 崩溃后
/// 下次启动仍能拿到「上次听了一半的那首歌」并正常结算。
struct ScrobbleSession: Codable, Equatable {
    var service: ScrobbleServiceKind
    /// 与后端无关的内容身份（曲目切换判定）
    var contentKey: String
    var listen: ScrobbleListen
    /// 累计「有效收听」秒数（只由合理的前进增量累加，跳播不计）
    var played: Double = 0
    /// 上一次进度回调的位置（用来算有效增量）
    var lastPosition: Double = 0
    var completed: Bool = false
    /// Now Playing 每首只发一次
    var nowPlayingSent: Bool = false
}

enum ScrobbleSessionStore {
    private static let key = "scrobble.session.v1"
    private static let lock = NSLock()

    static func load() -> ScrobbleSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ScrobbleSession.self, from: data)
    }

    static func save(_ session: ScrobbleSession) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - 待补报队列

/// 失败重试队列：`UserDefaults` JSON，上限 200 条（超出丢最旧的）。
///
/// 为什么先进队列再发网络：`willTerminate` 里网络请求来不及完成，
/// 先把记录落盘才能保证「退出前听够的那首不丢」，发送成功后再从队列移除。
enum ScrobblePendingStore {
    static let capacity = 200
    private static let key = "scrobble.pending.v1"
    private static let lock = NSLock()

    // MARK: 纯编解码（自检用）

    static func encode(_ entries: [ScrobblePendingEntry]) throws -> Data {
        try JSONEncoder().encode(entries)
    }

    static func decode(_ data: Data) throws -> [ScrobblePendingEntry] {
        try JSONDecoder().decode([ScrobblePendingEntry].self, from: data)
    }

    /// 只保留最新的 `capacity` 条（新记录优先）。
    static func trimmed(_ entries: [ScrobblePendingEntry]) -> [ScrobblePendingEntry] {
        guard entries.count > capacity else { return entries }
        return Array(entries.suffix(capacity))
    }

    // MARK: 读写

    static func load() -> [ScrobblePendingEntry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? decode(data)) ?? []
    }

    static func append(_ entry: ScrobblePendingEntry) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.append(entry)
        entries = trimmed(entries)
        saveLocked(entries)
    }

    static func remove(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.removeAll { $0.id == id }
        saveLocked(entries)
    }

    private static func loadLocked() -> [ScrobblePendingEntry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? decode(data)) ?? []
    }

    private static func saveLocked(_ entries: [ScrobblePendingEntry]) {
        guard let data = try? encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - 退出结算

/// `NSApplication.willTerminate` 的同步结算。
///
/// 为什么不用 `ScrobbleService.finalizePending()`：退出路径上再往主 actor 排任务不保证
/// 还能执行；而会话在每次进度变化时都已落盘，所以这里直接从 `UserDefaults` 读值结算，
/// 只做纯值运算 + 队列写入（与主 actor 的写入用同一把锁串行化）。
enum ScrobbleTermination {
    static func settleStoredSession() {
        guard let stored = ScrobbleSessionStore.load() else { return }
        ScrobbleSessionStore.clear()
        guard ScrobbleRule.isEligible(
            played: stored.played,
            duration: stored.listen.duration,
            completed: stored.completed
        ) else { return }
        ScrobblePendingStore.append(
            ScrobblePendingEntry(service: stored.service, listen: stored.listen)
        )
        // 退出路径上尽快落盘（正常退出 CFPreferences 也会同步，这里显式一次更稳）
        UserDefaults.standard.synchronize()
    }
}

// MARK: - 听歌记录服务

/// Last.fm / ListenBrainz 听歌记录。
///
/// 设计要点：
/// - **仅当 `ScrobbleSettings.enabled` 时工作**；所有失败静默（只更新设置页状态 / 待补报数）；
/// - 网络请求全部异步且不阻塞播放（`flushPending` 的节流见 `lastFlushAt`）；
/// - 结算规则见 `ScrobbleRule`：≥50% 或 ≥240s 且 ≥30s；
/// - 先进持久化待补报队列、发送成功才移除，保证退出 / 离线不丢记录；
/// - 监听 `NSApplication.willTerminate` 自行结算（`ScrobbleTermination`）。
///
/// 接线（Lead 负责）：在 `MusicDataStore.notePlaybackStarted / noteProgress /
/// notePlaybackFinished` 里转发到同名方法；启动时最好再调一次 `bootstrap()`。
@MainActor
final class ScrobbleService: ObservableObject {
    static let shared = ScrobbleService()

    /// 待补报条数（设置页可见；失败不会打断播放）
    @Published private(set) var pendingCount: Int = 0

    private var session: ScrobbleSession?
    private var didBootstrap = false
    private var isFlushing = false
    private var lastFlushAt: Date = .distantPast
    private var terminateObserver: NSObjectProtocol?

    private init() {
        session = ScrobbleSessionStore.load()
        pendingCount = ScrobblePendingStore.load().count
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ScrobbleTermination.settleStoredSession()
        }
    }

    // MARK: - 生命周期

    /// 幂等启动：结算上次运行遗留的会话，再补报离线队列。
    ///
    /// 建议在 app 启动时调用一次；未调用时首次播放 / 打开设置页也会懒加载。
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        finalizePending()
        guard ScrobbleSettings.shared.enabled else { return }
        flushPending(force: true)
    }

    // MARK: - 播放事件（Lead 在 MusicDataStore.note* 里转发）

    /// 开始播放：先结算上一条 → 开新会话 → 发 Now Playing（每首一次）。
    func noteStarted(_ item: MediaItem) {
        bootstrap()
        guard ScrobbleSettings.shared.enabled else { return }
        finalizePending()
        startSession(for: item, at: 0)
    }

    /// 进度变化：按「合理前进的增量」累计有效收听时长。
    func noteProgress(_ item: MediaItem, position: Double) {
        guard ScrobbleSettings.shared.enabled, position.isFinite else { return }
        if session == nil {
            // 兜底：没有收到 noteStarted（例如启动续播）时补一条会话。
            // 起点按当前位置算 —— 不能把续播位置本身当成「听过」。
            startSession(for: item, at: position)
        }
        guard var active = session, active.contentKey == item.contentKey else { return }
        let capped: Double
        if active.listen.duration > 0 {
            capped = min(max(position, 0), active.listen.duration)
        } else {
            capped = max(position, 0)
        }
        let delta = ScrobbleRule.creditedDelta(from: active.lastPosition, to: capped)
        if delta > 0 {
            if active.listen.duration > 0 {
                active.played = min(active.played + delta, active.listen.duration)
            } else {
                active.played += delta
            }
        }
        active.lastPosition = capped
        session = active
        ScrobbleSessionStore.save(active)
    }

    /// 新建会话并发送 Now Playing。`position` 是起播位置（续播时不为 0）。
    private func startSession(for item: MediaItem, at position: Double) {
        guard let listen = ScrobbleListen(
            item: item,
            playedAt: ScrobbleRule.unixTimestamp(for: Date())
        ) else {
            // 缺艺人 / 歌名：两个服务都收不了，直接不开会话
            return
        }
        let started = ScrobbleSession(
            service: ScrobbleSettings.shared.service,
            contentKey: item.contentKey,
            listen: listen,
            played: 0,
            lastPosition: max(position, 0),
            completed: false,
            nowPlayingSent: true
        )
        session = started
        ScrobbleSessionStore.save(started)
        sendNowPlaying(listen, service: started.service)
    }

    /// 自然播完：按「听满整首」结算。
    func noteFinished(_ item: MediaItem) {
        bootstrap()
        guard ScrobbleSettings.shared.enabled else { return }
        guard var active = session, active.contentKey == item.contentKey else {
            finalizePending()
            return
        }
        active.completed = true
        if active.listen.duration > 0 {
            active.played = max(active.played, active.listen.duration)
        }
        // 播完即会话结束：先清掉会话再结算，避免下一次 noteStarted 的 finalize 重复提交
        session = nil
        ScrobbleSessionStore.clear()
        settle(active)
    }

    /// 结算当前会话（切歌 / 退出前 / 启动恢复）：达标才进入待补报队列。
    func finalizePending() {
        bootstrap()
        guard let active = session else { return }
        session = nil
        ScrobbleSessionStore.clear()
        guard ScrobbleSettings.shared.enabled else { return }
        settle(active)
    }

    /// 放弃当前会话（关闭总开关时调用，不提交）。
    func discardSession() {
        session = nil
        ScrobbleSessionStore.clear()
    }

    // MARK: - 结算

    private func settle(_ active: ScrobbleSession) {
        guard ScrobbleRule.isEligible(
            played: active.played,
            duration: active.listen.duration,
            completed: active.completed
        ) else { return }
        ScrobblePendingStore.append(
            ScrobblePendingEntry(service: active.service, listen: active.listen)
        )
        pendingCount = ScrobblePendingStore.load().count
        flushPending()
    }

    // MARK: - 待补报队列

    /// 提交待补报队列。失败静默：条目保留，下次启动 / 成功上报 / 重新连接时再试。
    ///
    /// - Parameter force: 启动、重新连接等场景绕过 15 秒节流。
    func flushPending(force: Bool = false) {
        guard ScrobbleSettings.shared.enabled, !isFlushing else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastFlushAt) < 15 { return }
        let entries = ScrobblePendingStore.load()
        pendingCount = entries.count
        guard !entries.isEmpty else { return }

        lastFlushAt = now
        isFlushing = true
        Task { [weak self] in
            guard let self else { return }
            for entry in entries {
                switch await Self.submit(entry) {
                case .success:
                    ScrobblePendingStore.remove(id: entry.id)
                case .skipped:
                    // 该服务的凭据不完整：保留条目，继续后面的（可能是另一个服务）
                    continue
                case .failure:
                    // 网络 / 服务暂不可用：停止本轮，剩余条目留待下次
                    self.finishFlushing()
                    return
                }
                if entries.count > 1 {
                    // 温和节流：ListenBrainz 建议提交间隔 ≥1s，这里 0.3s 起步足够低频
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
            self.finishFlushing()
        }
    }

    private func finishFlushing() {
        isFlushing = false
        pendingCount = ScrobblePendingStore.load().count
    }

    private enum SubmitOutcome {
        /// 提交成功，可从队列移除
        case success
        /// 该服务凭据不完整：不消费、不阻断其它条目
        case skipped
        /// 网络 / 服务错误：停止本轮
        case failure
    }

    private static func submit(_ entry: ScrobblePendingEntry) async -> SubmitOutcome {
        switch entry.service {
        case .lastFM:
            guard let apiKey = ScrobbleSettings.shared.lastFMAPIKey.trimmedForScrobble,
                  let secret = await ScrobbleKeychain.read(.lastFMSecret),
                  let sessionKey = await ScrobbleKeychain.read(.lastFMSession) else {
                return .skipped
            }
            do {
                try await LastFMAPI.scrobble(
                    entry.listen,
                    apiKey: apiKey,
                    secret: secret,
                    sessionKey: sessionKey
                )
                return .success
            } catch {
                return .failure
            }
        case .listenBrainz:
            guard let token = await ScrobbleKeychain.read(.listenBrainzToken) else {
                return .skipped
            }
            do {
                try await ListenBrainzAPI.submitSingle(entry.listen, token: token)
                return .success
            } catch {
                return .failure
            }
        }
    }

    // MARK: - Now Playing

    private func sendNowPlaying(_ listen: ScrobbleListen, service: ScrobbleServiceKind) {
        Task { [weak self] in
            let sent = await Self.submitNowPlaying(listen, service: service)
            guard let self, sent else { return }
            // 「成功时 flush」：网络通了，顺手把离线期间的待补报补上
            self.flushPending()
        }
    }

    private static func submitNowPlaying(
        _ listen: ScrobbleListen,
        service: ScrobbleServiceKind
    ) async -> Bool {
        switch service {
        case .lastFM:
            guard let apiKey = ScrobbleSettings.shared.lastFMAPIKey.trimmedForScrobble,
                  let secret = await ScrobbleKeychain.read(.lastFMSecret),
                  let sessionKey = await ScrobbleKeychain.read(.lastFMSession) else {
                return false
            }
            do {
                try await LastFMAPI.updateNowPlaying(
                    listen,
                    apiKey: apiKey,
                    secret: secret,
                    sessionKey: sessionKey
                )
                return true
            } catch {
                return false
            }
        case .listenBrainz:
            guard let token = await ScrobbleKeychain.read(.listenBrainzToken) else {
                return false
            }
            do {
                try await ListenBrainzAPI.submitNowPlaying(listen, token: token)
                return true
            } catch {
                return false
            }
        }
    }
}
