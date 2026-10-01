import AVFoundation
import MediaPlayer
import SwiftUI

/// 播放进度：独立可观察对象。position 每 0.5s 更新一次，
/// 单独发布避免只关心队列/播放状态的列表视图被进度 tick 拖着重渲染。
@MainActor
final class PlaybackProgress: ObservableObject {
    @Published var position: Double = 0
    @Published var duration: Double = 0
}

/// 全局音乐播放器：浏览页面间持续播放，支持专辑队列顺序播放
/// 含：队列管理（跳播/排序/插播）、系统媒体键（MPRemoteCommandCenter）、
///     Now Playing 信息、睡眠定时器、切歌淡入
@MainActor
final class MusicPlayerModel: ObservableObject {
    static let shared = MusicPlayerModel()

    /// 播放进度（独立发布，见 PlaybackProgress）
    let progress = PlaybackProgress()

    enum PlayMode: String, CaseIterable {
        case sequential
        case listRepeat
        case singleRepeat
        case shuffle

        var icon: String {
            switch self {
            case .sequential: return "repeat"
            case .listRepeat: return "repeat"
            case .singleRepeat: return "repeat.1"
            case .shuffle: return "shuffle"
            }
        }

        var title: String {
            switch self {
            case .sequential: return "顺序播放"
            case .listRepeat: return "列表循环"
            case .singleRepeat: return "单曲循环"
            case .shuffle: return "随机播放"
            }
        }
    }

    let player = AVPlayer()

    @Published var queue: [BaseItemDto] = []
    @Published var currentIndex = -1
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var volume: Double = 1.0 {
        didSet { player.volume = Float(volume) }
    }
    @Published var playMode: PlayMode = .sequential
    /// 睡眠定时截止时刻（nil = 未设置）
    @Published var sleepTimerEnd: Date?

    private var reporter: PlaybackReporter?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var sleepTimer: Timer?
    private var fadeTimer: Timer?
    private var nowPlayingTick = 0

    var currentTrack: BaseItemDto? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var hasQueue: Bool { !queue.isEmpty }

    init() {
        player.volume = Float(volume)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handleTime(time.seconds) }
        }
        setupRemoteCommands()
    }

    // MARK: - 播放控制

    func play(tracks: [BaseItemDto], startAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        loadCurrent()
    }

    func togglePlay() {
        guard currentTrack != nil else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            reporter?.update(position: progress.position, paused: true)
        } else {
            player.play()
            isPlaying = true
            reporter?.update(position: progress.position, paused: false)
        }
        updateNowPlayingInfo()
    }

    func next() {
        switch playMode {
        case .shuffle:
            guard queue.count > 1 else { return }
            var idx = Int.random(in: 0..<queue.count)
            while idx == currentIndex { idx = Int.random(in: 0..<queue.count) }
            currentIndex = idx
            loadCurrent()
        case .sequential:
            if currentIndex < queue.count - 1 {
                currentIndex += 1
                loadCurrent()
            } else {
                stopAtEnd()
            }
        case .listRepeat:
            currentIndex = (currentIndex + 1) % queue.count
            loadCurrent()
        case .singleRepeat:
            currentIndex = currentIndex < queue.count - 1 ? currentIndex + 1 : 0
            loadCurrent()
        }
    }

    /// 随机播放开关（设计稿独立随机按钮）
    func toggleShuffle() {
        playMode = playMode == .shuffle ? .sequential : .shuffle
    }

    /// 循环模式切换：顺序 → 列表循环 → 单曲循环（设计稿独立循环按钮）
    func cycleRepeat() {
        switch playMode {
        case .sequential: playMode = .listRepeat
        case .listRepeat: playMode = .singleRepeat
        case .singleRepeat: playMode = .sequential
        case .shuffle: playMode = .listRepeat
        }
    }

    func previous() {
        if progress.position > 5 || currentIndex <= 0 {
            Task { await seek(to: 0) }
        } else {
            currentIndex -= 1
            loadCurrent()
        }
    }

    func seek(to seconds: Double) async {
        isSeeking = true
        await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        progress.position = seconds
        isSeeking = false
        updateNowPlayingInfo()
    }
    func sliderEditingChanged(_ editing: Bool) {
        isSeeking = editing
        if !editing {
            Task { await seek(to: progress.position) }
        }
    }

    /// 键盘 / VoiceOver 微调：直接定位到指定秒数（可访问性 ±5s）
    func seekTo(position seconds: Double) {
        let clamped = min(max(seconds, 0), max(progress.duration, 0))
        progress.position = clamped
        Task { await seek(to: clamped) }
    }

    /// 迷你条拖动进度：实时更新显示位置，松手后真正跳转
    func scrub(ratio: Double) {
        isSeeking = true
        progress.position = progress.duration * min(max(ratio, 0), 1)
    }

    func endScrub() {
        guard isSeeking else { return }
        isSeeking = false
        Task { await seek(to: progress.position) }
    }

    // MARK: - 队列管理

    /// 跳到队列中指定曲目
    func jump(to index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        currentIndex = index
        loadCurrent()
    }

    /// 移除队列条目（当前播放的曲目不可移除）
    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
    }

    /// 拖动排序后修正当前索引
    func moveQueueItems(from source: IndexSet, to destination: Int) {
        let currentId = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentId, let i = queue.firstIndex(where: { $0.id == currentId }) {
            currentIndex = i
        }
    }

    /// 插播到当前曲目之后
    func playNext(_ track: BaseItemDto) {
        if currentIndex < 0 || queue.isEmpty {
            play(tracks: [track], startAt: 0)
        } else {
            queue.insert(track, at: currentIndex + 1)
        }
    }

    /// 追加到队列末尾（空闲时直接开始播放）
    func enqueue(_ tracks: [BaseItemDto]) {
        guard !tracks.isEmpty else { return }
        if currentIndex < 0 || queue.isEmpty {
            play(tracks: tracks, startAt: 0)
        } else {
            queue.append(contentsOf: tracks)
        }
    }

    // MARK: - 睡眠定时器

    /// 设置睡眠定时（minutes = nil 关闭）；临近结束自动渐弱音量后暂停
    func setSleepTimer(minutes: Double?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes else {
            sleepTimerEnd = nil
            player.volume = Float(volume)
            return
        }
        sleepTimerEnd = Date().addingTimeInterval(minutes * 60)
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkSleepTimer() }
        }
    }

    private func checkSleepTimer() {
        guard let end = sleepTimerEnd else { return }
        let remaining = end.timeIntervalSinceNow
        if remaining <= 0 {
            setSleepTimer(minutes: nil)
            fadeOutAndPause()
        } else if remaining < 5, isPlaying {
            // 最后 5 秒线性渐弱
            player.volume = Float(volume) * Float(max(remaining / 5, 0))
        }
    }

    private func fadeOutAndPause() {
        player.volume = 0
        player.pause()
        isPlaying = false
        reporter?.update(position: progress.position, paused: true)
        player.volume = Float(volume)
        updateNowPlayingInfo()
    }

    // MARK: - 内部

    private func loadCurrent() {
        guard let track = currentTrack else { return }
        stopReporting()
        guard let url = streamURL(for: track) else {
            errorMessage = "无法获取播放地址"
            return
        }
        errorMessage = nil
        isLoading = true

        let playerItem = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: playerItem)
        progress.duration = track.runtimeSeconds
        progress.position = 0
        isPlaying = false

        reporter = PlaybackReporter(
            itemId: track.id,
            mediaSourceId: nil,
            playMethod: AppSettings.shared.requiresTranscode ? "Transcode" : "DirectPlay",
            interval: AppSettings.shared.reportInterval
        )
        reporter?.start(position: 0)

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }

        player.volume = 0
        player.play()
        isPlaying = true
        isLoading = false
        startFadeIn()
        updateNowPlayingInfo()
    }

    /// 换曲淡入（时长来自设置页「交叉淡入」，0 表示不淡入），消除换曲"咔哒"感
    private func startFadeIn() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let target = Float(volume)
        let duration = AppSettings.shared.fadeDuration
        guard duration > 0 else {
            player.volume = target
            return
        }
        let tick = 0.05
        let totalSteps = max(Int(duration / tick), 1)
        var steps = 0
        fadeTimer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                steps += 1
                self.player.volume = min(target, target * Float(steps) / Float(totalSteps))
                if steps >= totalSteps {
                    self.fadeTimer?.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
    }

    private func handleEnded() {
        switch playMode {
        case .singleRepeat:
            // 单曲循环：从头重播
            Task { await seek(to: 0) }
            player.play()
            isPlaying = true
            reporter?.update(position: 0, paused: false)
        case .sequential:
            if currentIndex < queue.count - 1 {
                currentIndex += 1
                loadCurrent()
            } else {
                stopAtEnd()
            }
        case .listRepeat:
            currentIndex = (currentIndex + 1) % queue.count
            loadCurrent()
        case .shuffle:
            if queue.count > 1 {
                var idx = Int.random(in: 0..<queue.count)
                while idx == currentIndex { idx = Int.random(in: 0..<queue.count) }
                currentIndex = idx
                loadCurrent()
            } else {
                stopAtEnd()
            }
        }
    }

    private func stopAtEnd() {
        isPlaying = false
        progress.position = progress.duration
        stopReporting()
        updateNowPlayingInfo()
    }

    private func handleTime(_ seconds: Double) {
        guard !isSeeking else { return }
        progress.position = seconds
        reporter?.update(position: seconds, paused: !isPlaying)
        // 每 5 秒同步一次系统进度的已播位置
        nowPlayingTick += 1
        if nowPlayingTick % 10 == 0 {
            refreshNowPlayingElapsed()
        }
    }

    private func stopReporting() {
        reporter?.stop(position: progress.position)
        reporter = nil
    }

    private func streamURL(for track: BaseItemDto) -> URL? {
        guard let base = APIClient.shared.baseURL else { return nil }
        guard var comps = URLComponents(
            url: base.appendingPathComponent("/Audio/\(track.id)/stream"),
            resolvingAgainstBaseURL: false
        ) else { return nil }

        let settings = AppSettings.shared
        var query: [URLQueryItem] = []

        if settings.requiresTranscode {
            // 关闭「直连优先」或选了非原始音质：交给服务器转码到目标码率
            query.append(URLQueryItem(name: "static", value: "false"))
            query.append(URLQueryItem(name: "audioCodec", value: "mp3"))
            query.append(URLQueryItem(name: "transcodeContainer", value: "mp3"))
            if let bitrate = settings.quality.bitrate {
                query.append(URLQueryItem(name: "maxAudioBitrate", value: String(bitrate * 1000)))
            }
            if settings.volumeNormalization {
                query.append(URLQueryItem(name: "enableAudioNormalization", value: "true"))
            }
        } else {
            query.append(URLQueryItem(name: "static", value: "true"))
        }

        if let token = APIClient.shared.token {
            query.append(URLQueryItem(name: "api_key", value: token))
        }
        comps.queryItems = query
        return comps.url
    }

    // MARK: - 系统媒体键与 Now Playing 信息

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == false { self?.togglePlay() }
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                if self?.isPlaying == true { self?.togglePlay() }
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlay() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in await self?.seek(to: positionEvent.positionTime) }
            return .success
        }
    }

    /// 更新系统「正在播放」信息（媒体键浮层/控制中心/坞栏）
    private func updateNowPlayingInfo() {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTrack?.name ?? "未在播放",
            MPMediaItemPropertyArtist: currentTrack?.albumArtist ?? currentTrack?.album ?? "",
            MPMediaItemPropertyAlbumTitle: currentTrack?.album ?? "",
            MPMediaItemPropertyPlaybackDuration: max(progress.duration, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress.position,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        // 封面异步加载后补进信息字典
        if let url = currentTrack?.artworkURL(width: 512) {
            Task {
                guard let image = await ImageCache.shared.image(for: url) else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
    }

    private func refreshNowPlayingElapsed() {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = progress.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
