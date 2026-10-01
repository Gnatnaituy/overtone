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
        Task { await report(.playing) }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.report(.progress) }
        }
    }

    func update(position: Double, paused: Bool) {
        lastPosition = position
        if paused != isPaused {
            isPaused = paused
            Task { await report(.progress) }
        }
    }

    func stop(position: Double? = nil) {
        timer?.invalidate()
        timer = nil
        let pos = position ?? lastPosition
        Task { await report(.stopped, position: pos) }
    }

    private enum Kind: String {
        case playing = "Playing"
        case progress = "Progress"
        case stopped = "Stopped"
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
        try? await APIClient.shared.postEmpty("/Sessions/\(kind.rawValue)", body: data)
    }
}
