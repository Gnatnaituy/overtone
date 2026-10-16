import Foundation

struct PlaybackReport: Codable {
    let itemId: String
    let mediaSourceId: String?
    let positionTicks: Int64
    let playMethod: String
    let isPaused: Bool
    let canSeek: Bool

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case mediaSourceId = "MediaSourceId"
        case positionTicks = "PositionTicks"
        case playMethod = "PlayMethod"
        case isPaused = "IsPaused"
        case canSeek = "CanSeek"
    }
}

/// 向 Jellyfin 上报播放进度（默认每 10 秒一次 + 暂停/停止时立即上报；
/// 间隔可在设置页「播放 · 进度上报间隔」调整）
final class PlaybackReporter {
    private let itemId: String
    private let mediaSourceId: String?
    private let playMethod: String
    /// 周期上报间隔（秒）
    private let interval: TimeInterval
    private var timer: Timer?
    private var lastPosition: Double = 0
    private var isPaused = false

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []
        return e
    }()

    init(itemId: String, mediaSourceId: String?, playMethod: String, interval: TimeInterval = 10) {
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.interval = max(interval, 1)
    }

    func start(position: Double) {
        lastPosition = position
        isPaused = false
        Task { await report(.playing) }
        startTimer()
    }

    /// 进度 / 暂停状态更新（由播放器的 0.5s 时间观察器驱动）。
    ///
    /// 暂停时：立刻上报一次 `IsPaused = true` 的进度，并**停掉周期定时器**；
    /// 恢复播放时再重新起表。原来定时器贯穿整个曲目生命周期，暂停后仍每
    /// `interval` 秒发一次请求，是一份没有意义的常驻网络负载。
    func update(position: Double, paused: Bool) {
        lastPosition = position
        guard paused != isPaused else { return }
        isPaused = paused
        Task { await report(.progress) }
        if paused {
            stopTimer()
        } else {
            startTimer()
        }
    }

    func stop(position: Double? = nil) {
        stopTimer()
        let pos = position ?? lastPosition
        Task { await report(.stopped, position: pos) }
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.report(.progress) }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private enum Kind {
        case playing
        case progress
        case stopped

        /// Jellyfin 会话上报端点：`Start / Progress / Stopped` **都挂在 `/Sessions/Playing` 下**。
        ///
        /// 原实现按 `rawValue` 拼成 `/Sessions/Progress`、`/Sessions/Stopped` —— 这两个路径
        /// 在服务端不存在，每次上报都 404（实测：`/Sessions/Progress` → 404，
        /// `/Sessions/Playing/Progress` → 400（端点存在））。结果是播放进度从未真正
        /// 同步到服务器，且每 10 秒产生一次必然失败请求。
        var path: String {
            switch self {
            case .playing: return "/Sessions/Playing"
            case .progress: return "/Sessions/Playing/Progress"
            case .stopped: return "/Sessions/Playing/Stopped"
            }
        }
    }

    private func report(_ kind: Kind, position: Double? = nil) async {
        let pos = position ?? lastPosition
        let body = PlaybackReport(
            itemId: itemId,
            mediaSourceId: mediaSourceId,
            positionTicks: Int64(pos * 10_000_000),
            playMethod: playMethod,
            isPaused: isPaused && kind != .stopped,
            canSeek: true
        )
        guard let data = try? Self.encoder.encode(body) else { return }
        try? await APIClient.shared.postEmpty(kind.path, body: data)
    }
}
