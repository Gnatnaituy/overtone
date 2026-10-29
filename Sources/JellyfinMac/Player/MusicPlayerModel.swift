import AppKit
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

/// 音量：独立可观察对象（与 `PlaybackProgress` 同样的理由）。
///
/// 拖动音量滑块时 `level` 以拖动事件频率发布（60–120Hz）。它若挂在 `MusicPlayerModel`
/// 上，所有观察播放器的视图都会跟着每帧重建，而它们只关心「在播哪首 / 是否在播」。
@MainActor
final class PlaybackVolume: ObservableObject {
    @Published var level: Double = 1.0 {
        didSet { onLevelChange?(level) }
    }

    /// 回写通道（由 `MusicPlayerModel` 装配）
    var onLevelChange: ((Double) -> Void)?
}

/// 全局音乐播放器：浏览页面间持续播放，支持专辑队列顺序播放。
///
/// 改造要点（对应评估里 R1/R2）：
/// 1. 播放源不再是一个裸 URL —— 由活动后端给出 `PlayableSource`（可能带逐请求签名），
///    再交给 `MediaResourceLoader` 装配成 `AVURLAsset`；
/// 2. 进度上报走 `MusicBackend.report(_:)`（Jellyfin 报 `/Sessions/Playing*`，
///    飞牛只报 `track_play`），同时本地始终记一份续播位置（飞牛没有进度，靠它续播）；
/// 3. 队列元素是领域模型 `MediaItem`，与后端无关。
@MainActor
final class MusicPlayerModel: ObservableObject {
    static let shared = MusicPlayerModel()

    let progress = PlaybackProgress()
    let volume = PlaybackVolume()

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

    // MARK: - 双播放器（交叉淡化）

    /// 主播放器 A（改造前就存在的那只手；旧代码与外部只读访问一直认它）
    private let primaryPlayer = AVPlayer()
    /// 备用播放器 B：交叉淡化时提前起播下一首，淡入完成后接管为主播放器
    private let secondaryPlayer = AVPlayer()
    /// 当前主播放器是否是 B（每次交叉淡化完成后翻转）
    private var activeIsSecondary = false

    /// 对外保留的播放器引用：**始终指向当前主播放器**（换角色后自动跟随）。
    ///
    /// 兼容性说明：改造前是 `let player = AVPlayer()`，外部只读使用；
    /// 现在改为「指向当前主播放器」的只读计算属性，调用点语义不变。
    var player: AVPlayer { activeIsSecondary ? secondaryPlayer : primaryPlayer }

    /// 另一只手（交叉淡化期间放下一首；平时空闲）
    private var standbyPlayer: AVPlayer { activeIsSecondary ? primaryPlayer : secondaryPlayer }

    @Published var queue: [MediaItem] = [] {
        didSet { queueStateDidChange() }
    }
    @Published var currentIndex = -1 {
        didSet { queueStateDidChange() }
    }
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var playMode: PlayMode = .sequential {
        didSet { queueStateDidChange() }
    }
    @Published var sleepTimerEnd: Date?

    /// InstantMix 自动续播段的起始下标（-1 = 队列里没有自动续播段）。
    ///
    /// 队列面板据此画「以下为自动续播」分隔（见 `QueuePanelView`），
    /// 队列持久化时一并保存，重启后分隔位置不丢。
    @Published var autoContinueStart = -1

    /// 当前使用中的资源加载器（动态签名场景下必须持强引用，AVAsset 只弱持有 delegate）
    private var resourceLoader: MediaResourceLoader?
    private var timeObserver: Any?
    private var secondaryTimeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var isSeeking = false
    private var sleepTimer: Timer?
    private var fadeTimer: Timer?
    private var nowPlayingTick = 0

    // 进度上报节流
    private var lastReportedPosition: Double = 0
    private var lastReportAt: Date = .distantPast
    private var playStartedAt: Date?
    private var currentPlayMethod: PlayMethod = .directPlay

    // MARK: 播放失败 / 缓冲监听

    /// 当前曲目的播放源（失败时靠它的 `transcodeFallback` 决定能否降级重试）
    private var currentSource: PlayableSource?
    /// 当前曲目是否已因直连失败降级重试过一次（**每首最多一次**，防止死循环）
    private var didRetryWithFallback = false
    /// 当前曲目是否已报出终态错误（`status.failed` 与 `failedToPlayToEndTime` 可能先后到达）
    private var didReportTerminalFailure = false
    /// `AVPlayerItem.status` 的 KVO（起播失败）
    private var itemStatusObservation: NSKeyValueObservation?
    /// `AVPlayer.timeControlStatus` 的 KVO（缓冲/等待中）
    private var timeControlObservation: NSKeyValueObservation?
    /// `failedToPlayToEndTime`（播到一半网络断了）
    private var failedToPlayObserver: NSObjectProtocol?

    // MARK: 播放衔接（交叉淡化 / 淡出直切）

    /// 正在进行中的衔接。同一时刻最多一个：用户手动操作会先取消它。
    private struct Transition {
        enum Kind {
            /// 双播放器交叉淡化
            case crossfade
            /// 淡出 → 直切 → 淡入（未预取 / 转码 / HLS 的降级路径，也用于手动切歌）
            case fadeThrough
            /// 睡眠定时临近：淡出后暂停
            case fadeOutAndPause
        }

        let kind: Kind
        let seconds: Double
        let startedAt: Date
        /// 淡出方是不是 B 播放器（完成交叉后要翻 `activeIsSecondary`）
        let fromIsSecondary: Bool
        /// 目标曲目在队列里的下标（`fadeOutAndPause` 为 nil）
        let toIndex: Int?
    }

    private var transition: Transition?
    private var transitionTimer: Timer?

    /// 备用播放器在交叉淡化期间的状态（下一首的 loader 必须强引用住）
    private var standbyLoader: MediaResourceLoader?
    private var standbySource: PlayableSource?
    private var standbyPlayMethod: PlayMethod = .directPlay
    private var standbyTrackID: String?
    private var standbyItemStatusObservation: NSKeyValueObservation?
    private var standbyFailedToPlayObserver: NSObjectProtocol?

    /// `startPlayback` 消费一次：用指定时长做淡入（淡出直切路径用），nil = 按设置
    private var pendingStartFadeIn: Double?

    // MARK: 下一首预取

    /// 预取到的下一首：`item` 已构建好，`loader` 是动态签名场景下必须被强引用的资源加载器。
    ///
    /// 为什么预取的是 **AVPlayerItem** 而不是只有 `PlayableSource`：
    /// 起播耗时的大头在「解析播放源 + AVFoundation 首次探测媒体」，这两步都可以提前做；
    /// 真正换曲时只要 `replaceCurrentItem` 即可，交叉淡化才来得及。
    private struct PrefetchedTrack {
        let trackID: String
        let source: PlayableSource
        let item: AVPlayerItem
        let loader: MediaResourceLoader?
        let playMethod: PlayMethod
    }

    private var prefetched: PrefetchedTrack?
    private var prefetchTask: Task<Void, Never>?
    /// 预取代次：队列 / 索引 / 模式一变就 +1，过期结果直接丢弃
    private var prefetchGeneration = 0
    /// 随机模式下预取的目标下标（保证「预取的那首」就是 next 实际会播的那首）
    private var prefetchedShuffleIndex: Int?

    // MARK: InstantMix 自动续播

    private var instantMixTask: Task<Void, Never>?
    private var instantMixInFlight = false
    /// 最近一次请求续播用的种子 id（同一首不重复请求）
    private var instantMixSeedID: String?

    /// 队列尾部已自动追加的曲目数
    var autoContinuedTrackCount: Int {
        guard autoContinueStart >= 0, autoContinueStart <= queue.count else { return 0 }
        return queue.count - autoContinueStart
    }

    // MARK: 队列持久化状态

    /// 正在从磁盘恢复队列：恢复期间的 `@Published` didSet 不该把「刚读出来的队列」再排一次保存
    private var isRestoringQueue = false
    /// debounce 中的队列保存任务
    private var queueStateSaveTask: Task<Void, Never>?
    /// 进度 tick 触发落盘的节流时间
    private var lastQueueStateSavedAt: Date = .distantPast
    /// 退出通知的观察者
    private var terminationObserver: NSObjectProtocol?

    var currentTrack: MediaItem? {
        queue.indices.contains(currentIndex) ? queue[currentIndex] : nil
    }

    var hasQueue: Bool { !queue.isEmpty }

    private var backend: MusicBackend { BackendRegistry.shared.active }

    // MARK: - 初始化

    init() {
        primaryPlayer.volume = Float(volume.level)
        secondaryPlayer.volume = 0
        volume.onLevelChange = { [weak self] level in
            guard let self else { return }
            // 过渡进行中由过渡定时器控制两只播放器的音量，避免拖动音量条打断交叉淡化
            guard self.transition == nil else { return }
            self.player.volume = Float(level)
            self.standbyPlayer.volume = 0
        }
        timeObserver = primaryPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handleTime(time.seconds, isSecondary: false) }
        }
        secondaryTimeObserver = secondaryPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in self?.handleTime(time.seconds, isSecondary: true) }
        }
        setupRemoteCommands()
        restorePersistedQueue()
        // ⚠️ 这里刻意用非隔离的 block 观察者 + 线程安全镜像，而不是
        // `Task { @MainActor in … }`：`applicationWillTerminate` 之后进程马上退出，
        // 那个 Task 不保证被调度到；镜像在播放期间持续更新，退出回调直接同步写盘。
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            MusicPlayerModel.flushQueueStateOnTerminate()
        }
    }

    // MARK: - 队列持久化（恢复 / 保存）

    /// 启动时恢复上次的队列，但**不自动播放**。
    ///
    /// 产品语义：恢复出来的只是「待播清单」，用户按播放键时从保存的位置续播
    /// （见 `togglePlay` 里 `player.currentItem == nil` 的分支）。这样既兑现了
    /// 「重启后队列还在」，又不会一启动就出声。
    private func restorePersistedQueue() {
        guard let snapshot = QueuePersistence.load(backend: BackendRegistry.shared.activeKind) else {
            return
        }
        isRestoringQueue = true
        defer { isRestoringQueue = false }

        queue = snapshot.tracks
        currentIndex = snapshot.currentIndex
        playMode = PlayMode(rawValue: snapshot.playMode) ?? .sequential
        autoContinueStart = snapshot.autoContinueStart
        if let track = currentTrack {
            progress.duration = track.duration
            progress.position = snapshot.position
            pendingResumePosition = snapshot.position > 5 ? snapshot.position : nil
        }
        isPlaying = false
        isLoading = false
        updateNowPlayingInfo()
        refreshTerminationMirror()
    }

    /// 队列 / 索引 / 模式变化：刷新退出镜像并排一次 debounce 保存
    private func queueStateDidChange() {
        guard !isRestoringQueue else { return }
        refreshTerminationMirror()
        scheduleQueueStateSave()
        // 队列被编辑 / 换模式后，预取目标可能已经变了（随机模式尤其）
        schedulePrefetch()
    }

    private func scheduleQueueStateSave() {
        queueStateSaveTask?.cancel()
        queueStateSaveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch {
                return
            }
            guard let self else { return }
            self.queueStateSaveTask = nil
            self.saveQueueStateNow()
        }
    }

    /// 立即落盘（暂停 / 播完 / seek 之后、以及退出前需要确定性落盘的时机）
    func saveQueueStateNow() {
        queueStateSaveTask?.cancel()
        queueStateSaveTask = nil
        let snapshot = makeQueueSnapshot()
        Self.terminationMirror.store(snapshot)
        if let snapshot {
            QueuePersistence.save(snapshot)
        } else {
            QueuePersistence.clear()
        }
        lastQueueStateSavedAt = Date()
    }

    /// 由当前内存状态构造快照；空队列 / 非法索引 → nil（没有值得恢复的队列）
    private func makeQueueSnapshot() -> QueueSnapshot? {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return nil }
        return QueueSnapshot(
            backendKind: BackendRegistry.shared.activeKind,
            savedAt: Date(),
            currentIndex: currentIndex,
            playMode: playMode.rawValue,
            position: max(progress.position, 0),
            tracks: queue,
            autoContinueStart: autoContinueStart
        )
    }

    /// 进度 tick 的节流落盘：小队列 10 秒、大队列 30 秒一次（整队列 JSON 的写放大要控制）
    private func persistQueueStateIfNeeded() {
        let interval: TimeInterval = queue.count > 300 ? 30 : 10
        guard Date().timeIntervalSince(lastQueueStateSavedAt) >= interval else { return }
        scheduleQueueStateSave()
    }

    /// 刷新「退出兜底」镜像。每个进度 tick 都刷（拷贝的是 COW 数组引用，开销可忽略），
    /// 这样 `applicationWillTerminate` 拿到的是最新位置，而不是最近一次 10 秒快照。
    private func refreshTerminationMirror() {
        Self.terminationMirror.store(makeQueueSnapshot())
    }

    /// 进程退出兜底：不跨 actor，直接读镜像同步写盘
    private nonisolated static func flushQueueStateOnTerminate() {
        guard let snapshot = terminationMirror.read() else {
            QueuePersistence.clear()
            return
        }
        QueuePersistence.save(snapshot)
    }

    /// 退出兜底镜像：主 actor 写、退出回调（任意线程）读，用锁保护。
    ///
    /// 为什么不用 `Task { @MainActor in … }`：`applicationWillTerminate` 返回后进程立即退出，
    /// 等不到下一次 actor 调度；镜像只存一份 `QueueSnapshot`（值类型），锁竞争可忽略。
    private final class QueueSnapshotMirror: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: QueueSnapshot?

        func store(_ snapshot: QueueSnapshot?) {
            lock.lock()
            self.snapshot = snapshot
            lock.unlock()
        }

        func read() -> QueueSnapshot? {
            lock.lock()
            defer { lock.unlock() }
            return snapshot
        }
    }

    /// 镜像本身是线程安全的，因此可以在非隔离的退出回调里直接访问
    private nonisolated static let terminationMirror = QueueSnapshotMirror()

    // MARK: - 播放控制

    /// 从头播放（默认行为：点曲目 = 从头开始，与改造前一致）
    func play(tracks: [MediaItem], startAt index: Int) {
        pendingResumePosition = nil
        playInternal(tracks: tracks, startAt: index)
    }

    /// 续播：从该曲目记录的位置继续（「继续播放」卡片用；飞牛没有服务端进度，靠本地兜底）
    func resume(tracks: [MediaItem], startAt index: Int, position: Double) {
        pendingResumePosition = position > 5 ? position : nil
        playInternal(tracks: tracks, startAt: index)
    }

    private func playInternal(tracks: [MediaItem], startAt index: Int) {
        guard !tracks.isEmpty else { return }
        queue = tracks
        currentIndex = max(0, min(index, tracks.count - 1))
        loadCurrent()
    }

    func togglePlay() {
        guard currentTrack != nil else { return }
        // 过渡中按暂停/播放：先取消过渡（恢复旧曲音量、停掉备用播放器），再做用户操作，
        // 否则会在「旧曲淡出、下一首淡入」的中间态上暂停，状态对不上。
        cancelTransitionForUserAction()
        if isPlaying {
            player.pause()
            isPlaying = false
            reportProgress(force: true)
            // 暂停是「确定用户要停在这里」的时机，进度必须是新的（退出兜底镜像也一并刷新）
            saveQueueStateNow()
        } else if player.currentItem == nil {
            // 队列是从磁盘恢复的、或上次停在暂停而播放器没有条目：先重新解析播放源再播
            loadCurrent()
        } else {
            player.play()
            isPlaying = true
            reportProgress(force: true)
        }
        updateNowPlayingInfo()
    }

    func next() {
        cancelTransitionForUserAction()
        let target: Int?
        switch playMode {
        case .shuffle:
            target = queue.count > 1 ? upcomingTrack()?.index : nil
        case .sequential:
            target = currentIndex < queue.count - 1 ? currentIndex + 1 : nil
        case .listRepeat:
            target = queue.isEmpty ? nil : (currentIndex + 1) % queue.count
        case .singleRepeat:
            target = currentIndex < queue.count - 1 ? currentIndex + 1 : 0
        }
        guard let target, queue.indices.contains(target) else {
            // 顺序播到队尾：与改造前一致，走停止（自动续播若已追加会在目标里体现）
            if playMode == .sequential { stopAtEnd() }
            return
        }
        startUserTransition(to: target)
    }

    func toggleShuffle() {
        playMode = playMode == .shuffle ? .sequential : .shuffle
    }

    func cycleRepeat() {
        switch playMode {
        case .sequential: playMode = .listRepeat
        case .listRepeat: playMode = .singleRepeat
        case .singleRepeat: playMode = .sequential
        case .shuffle: playMode = .listRepeat
        }
    }

    func previous() {
        cancelTransitionForUserAction()
        if progress.position > 5 || currentIndex <= 0 {
            Task { await seek(to: 0) }
        } else {
            startUserTransition(to: currentIndex - 1)
        }
    }

    func seek(to seconds: Double) async {
        cancelTransitionForUserAction()
        isSeeking = true
        await player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        progress.position = seconds
        isSeeking = false
        reportProgress(force: true)
        updateNowPlayingInfo()
        saveQueueStateNow()
    }

    func sliderEditingChanged(_ editing: Bool) {
        isSeeking = editing
        if !editing {
            Task { await seek(to: progress.position) }
        }
    }

    func seekTo(position seconds: Double) {
        let clamped = min(max(seconds, 0), max(progress.duration, 0))
        progress.position = clamped
        Task { await seek(to: clamped) }
    }

    func scrub(ratio: Double) {
        cancelTransitionForUserAction()
        isSeeking = true
        progress.position = progress.duration * min(max(ratio, 0), 1)
    }

    func endScrub() {
        guard isSeeking else { return }
        isSeeking = false
        Task { await seek(to: progress.position) }
    }

    // MARK: - 队列管理

    func jump(to index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        cancelTransitionForUserAction()
        currentIndex = index
        loadCurrent()
    }

    func removeQueueItem(at index: Int) {
        guard queue.indices.contains(index), index != currentIndex else { return }
        // 删除会移动下标，过渡里记录的 toIndex 会指向别的曲目
        cancelTransitionForUserAction()
        queue.remove(at: index)
        if index < currentIndex { currentIndex -= 1 }
    }

    func moveQueueItems(from source: IndexSet, to destination: Int) {
        cancelTransitionForUserAction()
        let currentId = currentTrack?.id
        queue.move(fromOffsets: source, toOffset: destination)
        if let currentId, let i = queue.firstIndex(where: { $0.id == currentId }) {
            currentIndex = i
        }
    }

    func clearQueue() {
        guard !queue.isEmpty else { return }
        cancelTransitionForUserAction()
        finishCurrentTrack(finished: false)
        player.pause()
        player.replaceCurrentItem(with: nil)
        clearPlaybackObservers()
        currentSource = nil
        didRetryWithFallback = false
        didReportTerminalFailure = false
        resourceLoader = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        isPlaying = false
        isLoading = false
        sleepTimer?.invalidate()
        sleepTimer = nil
        fadeTimer?.invalidate()
        fadeTimer = nil
        progress.position = 0
        progress.duration = 0
        autoContinueStart = -1
        invalidatePrefetch()
        instantMixTask?.cancel()
        instantMixTask = nil
        instantMixInFlight = false
        instantMixSeedID = nil
        queue = []
        currentIndex = -1
        // 用户主动清空：磁盘上的旧队列也要立刻删掉，否则重启后又「复活」
        queueStateSaveTask?.cancel()
        queueStateSaveTask = nil
        Self.terminationMirror.store(nil)
        QueuePersistence.clear()
        updateNowPlayingInfo()
    }

    func playNext(_ track: MediaItem) {
        // 插到当前曲之后会把过渡目标往后挤，先收掉过渡
        cancelTransitionForUserAction()
        if currentIndex < 0 || queue.isEmpty {
            play(tracks: [track], startAt: 0)
        } else {
            queue.insert(track, at: currentIndex + 1)
        }
    }

    func enqueue(_ tracks: [MediaItem]) {
        guard !tracks.isEmpty else { return }
        if currentIndex < 0 || queue.isEmpty {
            play(tracks: tracks, startAt: 0)
        } else {
            queue.append(contentsOf: tracks)
        }
    }

    // MARK: - 睡眠定时器

    func setSleepTimer(minutes: Double?) {
        sleepTimer?.invalidate()
        sleepTimer = nil
        guard let minutes else {
            sleepTimerEnd = nil
            player.volume = Float(volume.level)
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
        } else if remaining < 5, isPlaying, transition == nil {
            // 过渡期间音量由过渡定时器控制；否则会和交叉淡化抢同一只播放器的音量
            player.volume = Float(volume.level) * Float(max(remaining / 5, 0))
        }
    }

    private func fadeOutAndPause() {
        if transition != nil {
            cancelTransition(restoreVolume: false)
        }
        player.volume = 0
        player.pause()
        isPlaying = false
        reportProgress(force: true)
        player.volume = Float(volume.level)
        updateNowPlayingInfo()
    }

    // MARK: - 内部：换曲

    /// 装载当前曲目。
    ///
    /// - Parameter prefetchedOverride: 调用方在改 `currentIndex` **之前**摘下来的预取。
    ///   为什么要显式传：`currentIndex` 的 didSet 会触发 `schedulePrefetch()` 重建预取，
    ///   它同步清空 `self.prefetched` —— 不先摘下来，切曲时刚预取好的 item 会被丢掉。
    private func loadCurrent(prefetchedOverride: PrefetchedTrack? = nil) {
        guard let track = currentTrack else { return }
        finishCurrentTrack(finished: false)
        isSeeking = false
        errorMessage = nil
        isLoading = true

        // 预取到的正是当前这首：直接起播（省掉解析 + 首次媒体探测，换曲才够快）
        if let prefetch = prefetchedOverride ?? prefetched, prefetch.trackID == track.id {
            self.prefetched = nil
            startPlayback(source: prefetch.source, track: track, prefetched: prefetch)
            return
        }
        // 目标变了：作废旧预取（别把一个用不上的 loader 与连接池压在内存里）
        invalidatePrefetch()

        let backend = self.backend
        let item = track

        Task { @MainActor in
            do {
                let source = try await backend.playableSource(for: item)
                // 解析期间可能已换曲 / 清空队列：只认「当前仍是这一首」的结果
                guard self.currentTrack?.id == item.id else { return }
                if let reason = source.unplayableReason {
                    errorMessage = reason
                    isLoading = false
                    isPlaying = false
                    pendingStartFadeIn = nil
                    return
                }
                startPlayback(source: source, track: item)
            } catch {
                guard self.currentTrack?.id == item.id else { return }
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                isLoading = false
                isPlaying = false
                pendingStartFadeIn = nil
            }
        }
    }

    /// 装载并起播一首歌。
    ///
    /// - Parameters:
    ///   - isRetry: 「直连失败 → 转码回退」的重试（重试不重复累计本地播放次数）
    ///   - resumePosition: 指定起播位置（回退重试时保留当前位置）；`nil` = 用 `pendingResumePosition`
    ///   - prefetched: 已预取好的 item（有就复用，避免重复构建和二次探测）
    private func startPlayback(
        source: PlayableSource,
        track: MediaItem,
        isRetry: Bool = false,
        resumePosition: Double? = nil,
        prefetched: PrefetchedTrack? = nil
    ) {
        let playerItem: AVPlayerItem
        if let prefetched, prefetched.trackID == track.id {
            playerItem = prefetched.item
            // 动态签名场景需要同时持有 loader（AVAsset 只弱持有 delegate）
            resourceLoader = prefetched.loader
        } else {
            // 动态签名场景需要同时持有 loader（AVAsset 只弱持有 delegate）
            let (asset, loader) = MediaResourceLoader.makeAssetAndLoader(for: source)
            resourceLoader = loader
            playerItem = AVPlayerItem(asset: asset)
        }
        self.prefetched = nil
        currentSource = source
        if !isRetry {
            didRetryWithFallback = false
        }
        didReportTerminalFailure = false

        player.replaceCurrentItem(with: playerItem)
        progress.duration = track.duration
        let startPosition = resumePosition ?? pendingResumePosition ?? 0
        progress.position = min(max(startPosition, 0), max(track.duration - 1, 0))
        pendingResumePosition = nil
        currentPlayMethod = source.playMethod
        isPlaying = true
        isLoading = true
        errorMessage = nil

        // 有本地续播位置时跳过去
        if progress.position > 5 {
            Task { await seek(to: progress.position) }
        }

        observeEnd(of: playerItem)
        observePlayback(of: playerItem)
        player.volume = 0
        player.play()
        let fadeInOverride = pendingStartFadeIn
        pendingStartFadeIn = nil
        startFadeIn(duration: fadeInOverride)
        updateNowPlayingInfo()

        if !isRetry {
            // 播放统计 + 服务端「开始播放」事件（回退重试不重复计数）
            MusicDataStore.shared.notePlaybackStarted(track)
        }
        playStartedAt = Date()
        lastReportedPosition = progress.position
        lastReportAt = Date()
        Task { await backend.report(PlaybackEvent(
            kind: .started,
            itemID: track.id,
            position: progress.position,
            duration: progress.duration,
            isPaused: false,
            playMethod: source.playMethod
        )) }

        if !isRetry {
            // 起播成功后再安排下一首：此刻队列/索引已经稳定
            schedulePrefetch()
            maybeRequestInstantMix()
        }
    }

    // MARK: - 播放衔接（真交叉淡化 / 降级直切）

    /// 每个进度 tick 检查一次：到点了吗？走真交叉还是降级路径？
    ///
    /// 判定本身在 `CrossfadeMath.evaluate`（纯函数、可自检），这里只负责把它翻译成动作。
    private func maybeStartTransition() {
        guard transition == nil, isPlaying, !isSeeking else { return }
        guard currentTrack != nil, let upcoming = upcomingTrack(), upcoming.index != currentIndex else {
            return
        }

        let prefetchedMatches = prefetched?.trackID == upcoming.item.id
        let prefetchedIsTranscode = prefetched?.playMethod == .transcode
        let prefetchedIsHLS = prefetched?.source.isHLS == true
        let action = CrossfadeMath.evaluate(
            trackDuration: progress.duration,
            position: progress.position,
            requestedSeconds: AppSettings.shared.crossfadeSeconds,
            nextPrepared: prefetchedMatches,
            nextRequiresFadeThrough: prefetchedMatches && (prefetchedIsTranscode || prefetchedIsHLS),
            isSingleRepeat: playMode == .singleRepeat,
            sleepRemaining: sleepTimerEnd.map { $0.timeIntervalSinceNow }
        )

        switch action {
        case .none:
            return
        case .crossfade(let seconds):
            beginCrossfade(toIndex: upcoming.index, seconds: seconds)
        case .fadeThrough(let seconds):
            beginFadeThrough(toIndex: upcoming.index, seconds: seconds)
        case .fadeOutAndPause(let seconds):
            beginSleepFadeOut(seconds: seconds)
        }
    }

    /// 真交叉淡化：备用播放器提前起播下一首，两只播放器在 `seconds` 内交换音量。
    private func beginCrossfade(toIndex: Int, seconds: Double) {
        guard queue.indices.contains(toIndex) else { return }
        guard let prefetch = prefetched,
              prefetch.trackID == queue[toIndex].id,
              prefetch.source.unplayableReason == nil else {
            // 预取在 tick 之间失效：退回降级直切
            beginFadeThrough(toIndex: toIndex, seconds: seconds)
            return
        }
        prefetched = nil

        let base = Float(volume.level)
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: prefetch.item)
        standbyPlayer.volume = 0
        // 动态签名：备用流的 loader 也必须强引用住（AVAsset 只弱持有 delegate）
        standbyLoader = prefetch.loader
        standbySource = prefetch.source
        standbyPlayMethod = prefetch.playMethod
        standbyTrackID = prefetch.trackID
        installStandbyObservers(item: prefetch.item)
        standbyPlayer.play()

        transition = Transition(
            kind: .crossfade,
            seconds: max(seconds, 0.1),
            startedAt: Date(),
            fromIsSecondary: activeIsSecondary,
            toIndex: toIndex
        )
        player.volume = base
        startTransitionTimer()
    }

    /// 交叉完成：备用播放器接管为主播放器，旧播放器摘下并清理。
    private func completeCrossfade(_ current: Transition) {
        stopTransitionTimer()
        transition = nil
        guard let toIndex = current.toIndex, queue.indices.contains(toIndex) else {
            stopStandby()
            return
        }
        let newTrack = queue[toIndex]

        // 旧曲收尾：位置用旧播放器的实时时间（progress 可能还差一个 tick）
        let oldSeconds = player.currentTime().seconds
        if oldSeconds.isFinite, oldSeconds >= 0 {
            progress.position = oldSeconds
        }
        finishCurrentTrack(finished: false)

        // 旧播放器彻底摘下（item / loader / 观察者都属于旧曲）
        player.pause()
        player.replaceCurrentItem(with: nil)
        player.volume = 0
        clearPlaybackObservers()
        clearEndObserver()
        resourceLoader = nil
        currentSource = nil
        didRetryWithFallback = false
        didReportTerminalFailure = false

        // 备用播放器的状态提升为主状态
        resourceLoader = standbyLoader
        currentSource = standbySource
        currentPlayMethod = standbyPlayMethod
        standbyLoader = nil
        standbySource = nil
        standbyPlayMethod = .directPlay
        standbyTrackID = nil
        clearStandbyObservers()

        activeIsSecondary.toggle()
        currentIndex = toIndex
        let newSeconds = player.currentTime().seconds
        progress.duration = newTrack.duration
        progress.position = newSeconds.isFinite && newSeconds >= 0
            ? min(newSeconds, max(newTrack.duration, 0))
            : 0
        isPlaying = true
        isLoading = false
        errorMessage = nil
        player.volume = Float(volume.level)

        if let item = player.currentItem {
            observeEnd(of: item)
            observePlayback(of: item)
        }
        MusicDataStore.shared.notePlaybackStarted(newTrack)
        playStartedAt = Date()
        lastReportedPosition = progress.position
        lastReportAt = Date()
        Task { await backend.report(PlaybackEvent(
            kind: .started,
            itemID: newTrack.id,
            position: progress.position,
            duration: progress.duration,
            isPaused: false,
            playMethod: currentPlayMethod
        )) }
        updateNowPlayingInfo()
        saveQueueStateNow()
        schedulePrefetch()
        maybeRequestInstantMix()
    }

    /// 降级 / 手动切歌：淡出 → 直切 → 淡入（单播放器）。
    private func beginFadeThrough(toIndex: Int, seconds: Double) {
        guard queue.indices.contains(toIndex), toIndex != currentIndex else { return }
        let duration = max(seconds, 0)
        guard duration > 0 else {
            switchTrackNow(toIndex: toIndex)
            return
        }
        transition = Transition(
            kind: .fadeThrough,
            seconds: duration,
            startedAt: Date(),
            fromIsSecondary: activeIsSecondary,
            toIndex: toIndex
        )
        startTransitionTimer()
    }

    /// 手动切歌（next / previous）：≤1 秒短过渡；交叉淡化关闭时直切（与改造前一致）。
    private func startUserTransition(to index: Int) {
        guard queue.indices.contains(index) else { return }
        if index == currentIndex {
            // 目标就是当前曲（单曲循环 / 队列只有一首）：按改造前语义重播
            if !isPlaying {
                player.play()
                isPlaying = true
            }
            Task { await seek(to: 0) }
            return
        }
        let seconds = CrossfadeMath.manualTransitionDuration(
            requestedSeconds: AppSettings.shared.crossfadeSeconds
        )
        if seconds > 0, isPlaying, player.currentItem != nil {
            beginFadeThrough(toIndex: index, seconds: seconds)
        } else {
            switchTrackNow(toIndex: index)
        }
    }

    /// 不淡出、直接切到某首
    private func switchTrackNow(toIndex index: Int) {
        guard queue.indices.contains(index) else { return }
        let prefetchedForTarget = prefetched?.trackID == queue[index].id ? prefetched : nil
        self.prefetched = nil
        currentIndex = index
        loadCurrent(prefetchedOverride: prefetchedForTarget)
    }

    /// 淡出完成：切歌并淡入。预取可用则同步切（几乎无缝），否则异步解析。
    private func performFadeThroughSwitch() {
        guard let current = transition,
              let toIndex = current.toIndex,
              queue.indices.contains(toIndex) else {
            cancelTransition(restoreVolume: true)
            return
        }
        stopTransitionTimer()
        transition = nil

        let oldSeconds = player.currentTime().seconds
        if oldSeconds.isFinite, oldSeconds >= 0 {
            progress.position = oldSeconds
        }
        finishCurrentTrack(finished: false)

        let newTrack = queue[toIndex]
        // 先摘预取：改 currentIndex 的 didSet 会 schedulePrefetch() 把它清掉
        let prefetchedForNext = prefetched?.trackID == newTrack.id ? prefetched : nil
        self.prefetched = nil
        pendingStartFadeIn = current.seconds
        currentIndex = toIndex
        if let prefetch = prefetchedForNext {
            startPlayback(
                source: prefetch.source,
                track: newTrack,
                prefetched: prefetch
            )
        } else {
            // 没预取到：先把已淡出的旧 item 摘掉，解析完再起播并淡入
            player.pause()
            player.replaceCurrentItem(with: nil)
            clearPlaybackObservers()
            clearEndObserver()
            resourceLoader = nil
            currentSource = nil
            loadCurrent()
        }
    }

    /// 自然播完但没赶上触发点（seek 到末尾 / tick 漏了）：按原逻辑直接切下一首
    private func transitionToNextTrack() {
        guard let next = upcomingTrack() else {
            stopAtEnd()
            return
        }
        let prefetchedForNext = prefetched?.trackID == next.item.id ? prefetched : nil
        self.prefetched = nil
        currentIndex = next.index
        loadCurrent(prefetchedOverride: prefetchedForNext)
    }

    /// 睡眠定时临近：淡出后暂停，不接下一首。
    private func beginSleepFadeOut(seconds: Double) {
        guard transition == nil, isPlaying else { return }
        transition = Transition(
            kind: .fadeOutAndPause,
            seconds: max(seconds, 0.2),
            startedAt: Date(),
            fromIsSecondary: activeIsSecondary,
            toIndex: nil
        )
        startTransitionTimer()
    }

    private func pauseAfterFadeOut() {
        player.pause()
        isPlaying = false
        player.volume = 0
        reportProgress(force: true)
        updateNowPlayingInfo()
        player.volume = Float(volume.level)
        saveQueueStateNow()
    }

    // MARK: 过渡定时器

    private func startTransitionTimer() {
        stopTransitionTimer()
        transitionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.transitionTick() }
        }
    }

    private func stopTransitionTimer() {
        transitionTimer?.invalidate()
        transitionTimer = nil
    }

    private func transitionTick() {
        guard let current = transition else {
            stopTransitionTimer()
            return
        }
        let elapsed = max(Date().timeIntervalSince(current.startedAt), 0)
        let ratio = min(elapsed / current.seconds, 1)
        let base = Float(volume.level)

        switch current.kind {
        case .crossfade:
            player.volume = base * CrossfadeMath.fadeOutGain(progress: ratio)
            standbyPlayer.volume = base * CrossfadeMath.fadeInGain(progress: ratio)
            if ratio >= 1 {
                completeCrossfade(current)
            }
        case .fadeThrough:
            player.volume = base * CrossfadeMath.fadeOutGain(progress: ratio)
            if ratio >= 1 {
                performFadeThroughSwitch()
            }
        case .fadeOutAndPause:
            player.volume = base * CrossfadeMath.fadeOutGain(progress: ratio)
            if ratio >= 1 {
                transition = nil
                stopTransitionTimer()
                pauseAfterFadeOut()
            }
        }
    }

    // MARK: 过渡取消

    private func cancelTransition(restoreVolume: Bool) {
        guard transition != nil else { return }
        let kind = transition?.kind
        transition = nil
        stopTransitionTimer()
        if restoreVolume {
            player.volume = Float(volume.level)
        }
        if kind == .crossfade {
            stopStandby()
        }
    }

    /// 用户手动操作（暂停 / seek / 切歌 / 清空）前调用：把过渡收干净
    private func cancelTransitionForUserAction() {
        guard transition != nil else { return }
        cancelTransition(restoreVolume: true)
    }

    private func stopStandby() {
        standbyPlayer.pause()
        standbyPlayer.replaceCurrentItem(with: nil)
        standbyPlayer.volume = 0
        clearStandbyObservers()
        standbyLoader = nil
        standbySource = nil
        standbyPlayMethod = .directPlay
        standbyTrackID = nil
    }

    // MARK: 备用流观察者

    private func installStandbyObservers(item: AVPlayerItem) {
        clearStandbyObservers()
        standbyItemStatusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            guard status == .failed else { return }
            Task { @MainActor in self?.handleStandbyFailure() }
        }
        standbyFailedToPlayObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleStandbyFailure() }
        }
    }

    private func clearStandbyObservers() {
        standbyItemStatusObservation?.invalidate()
        standbyItemStatusObservation = nil
        if let standbyFailedToPlayObserver {
            NotificationCenter.default.removeObserver(standbyFailedToPlayObserver)
            self.standbyFailedToPlayObserver = nil
        }
    }

    /// 备用流（交叉淡化的下一首）起播失败：放弃交叉、恢复旧曲音量，等自然结束走降级直切。
    private func handleStandbyFailure() {
        guard let current = transition, current.kind == .crossfade else { return }
        print("[MusicPlayerModel] 交叉淡化备用流起播失败，降级为淡出直切")
        stopStandby()
        transition = nil
        stopTransitionTimer()
        player.volume = Float(volume.level)
        prefetched = nil
    }

    // MARK: - 下一首预取

    /// 按当前播放模式算「下一首」；`nil` = 没有下一首（单曲循环 / 顺序或随机只剩一首）。
    ///
    /// 随机模式会**记住**抽到的下标：预取与真正换曲必须指向同一首，
    /// 否则预取白做、交叉淡化永远走「未预取」降级路径。
    private func upcomingTrack() -> (index: Int, item: MediaItem)? {
        guard queue.indices.contains(currentIndex) else { return nil }
        switch playMode {
        case .singleRepeat:
            return nil
        case .sequential:
            let next = currentIndex + 1
            guard queue.indices.contains(next) else { return nil }
            return (next, queue[next])
        case .listRepeat:
            guard queue.count > 1 else { return nil }
            let next = (currentIndex + 1) % queue.count
            return (next, queue[next])
        case .shuffle:
            guard queue.count > 1 else { return nil }
            if let index = prefetchedShuffleIndex,
               queue.indices.contains(index),
               index != currentIndex {
                return (index, queue[index])
            }
            var index = Int.random(in: 0..<queue.count)
            while index == currentIndex {
                index = Int.random(in: 0..<queue.count)
            }
            prefetchedShuffleIndex = index
            return (index, queue[index])
        }
    }

    /// 作废预取并取消在途解析
    private func invalidatePrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchGeneration &+= 1
        prefetched = nil
    }

    /// 起播后 / 队列变化后调用：异步准备好下一首的播放源与 `AVPlayerItem`。
    ///
    /// 预取失败**不影响当前播放** —— 真正换曲时会再解析一次，只是没有「秒切」。
    private func schedulePrefetch() {
        prefetchTask?.cancel()
        prefetchGeneration &+= 1
        prefetched = nil
        guard playMode != .singleRepeat,
              let next = upcomingTrack(),
              next.index != currentIndex else {
            return
        }
        let generation = prefetchGeneration
        let nextIndex = next.index
        let nextTrack = next.item
        let backend = self.backend
        prefetchTask = Task { @MainActor [weak self] in
            do {
                let source = try await backend.playableSource(for: nextTrack)
                guard let self, !Task.isCancelled, generation == self.prefetchGeneration else { return }
                // 期间可能换曲 / 队列被编辑：只接受「仍指向同一首」的结果
                guard let upcoming = self.upcomingTrack(),
                      upcoming.index == nextIndex,
                      upcoming.item.id == nextTrack.id,
                      source.unplayableReason == nil else { return }
                let (asset, loader) = MediaResourceLoader.makeAssetAndLoader(for: source)
                self.prefetched = PrefetchedTrack(
                    trackID: nextTrack.id,
                    source: source,
                    item: AVPlayerItem(asset: asset),
                    loader: loader,
                    playMethod: source.playMethod
                )
            } catch {
                guard !Task.isCancelled else { return }
                print("[MusicPlayerModel] 预取下一首失败（换曲时再解析）：\(error.localizedDescription)")
            }
        }
    }

    // MARK: - InstantMix 自动续播

    /// 队列剩最后一首且开启自动续播时，向服务端要一批相似曲目接到队尾。
    ///
    /// 失败 / 能力不支持时**静默保持原行为**（播完停止）—— 自动续播是锦上添花，
    /// 不该因为推荐接口抖动而打断正在播放的歌。
    private func maybeRequestInstantMix() {
        guard let seed = currentTrack else { return }
        guard QueueContinuation.shouldRequestContinuation(
            queueCount: queue.count,
            currentIndex: currentIndex,
            autoContinueEnabled: AppSettings.shared.autoContinue,
            backendSupportsInstantMix: backend.capabilities.instantMix,
            autoContinuedTrackCount: autoContinuedTrackCount
        ) else { return }
        guard !instantMixInFlight, instantMixSeedID != seed.id else { return }

        let backend = self.backend
        let backendKind = BackendRegistry.shared.activeKind
        let seedID = seed.id
        instantMixInFlight = true
        instantMixSeedID = seedID
        instantMixTask = Task { @MainActor [weak self] in
            defer { self?.instantMixInFlight = false }
            do {
                let candidates = try await backend.instantMix(
                    seedID: seedID,
                    limit: QueueContinuation.requestLimit
                )
                guard let self, !Task.isCancelled else { return }
                // 期间换了后端 / 队列被清空 / 换曲：结果一律丢弃
                guard BackendRegistry.shared.activeKind == backendKind,
                      self.currentTrack?.id == seedID else { return }
                let appended = QueueContinuation.appendable(
                    from: candidates,
                    existing: self.queue,
                    limit: QueueContinuation.requestLimit
                )
                guard !appended.isEmpty else { return }
                if self.autoContinueStart < 0 {
                    self.autoContinueStart = self.queue.count
                }
                self.queue.append(contentsOf: appended)
                print("[MusicPlayerModel] InstantMix 自动续播追加 \(appended.count) 首")
                self.saveQueueStateNow()
                self.schedulePrefetch()
            } catch {
                self?.instantMixSeedID = nil
                print("[MusicPlayerModel] InstantMix 续播失败（保持播完停止）：\(error.localizedDescription)")
            }
        }
    }

    private func clearEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    private func observeEnd(of playerItem: AVPlayerItem) {
        clearEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnded() }
        }
    }

    // MARK: - 播放失败 / 缓冲监听

    /// 给新装的 item 挂上三类观察（换曲时先摘旧的，避免旧 item 的失败回调打到新曲目上）
    private func observePlayback(of playerItem: AVPlayerItem) {
        clearPlaybackObservers()
        // ① 起播失败（格式不支持 / 404 / 鉴权失败）
        itemStatusObservation = playerItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
            let status = item.status
            Task { @MainActor in self?.handleItemStatus(status) }
        }
        // ② 缓冲 / 等待中 → isLoading
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new, .initial]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.handleTimeControlStatus(status) }
        }
        // ③ 播到一半断流（网络中断 / 服务端断开）
        failedToPlayObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: playerItem,
            queue: .main
        ) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor in self?.handlePlaybackFailure(error) }
        }
    }

    private func clearPlaybackObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        if let failedToPlayObserver {
            NotificationCenter.default.removeObserver(failedToPlayObserver)
            self.failedToPlayObserver = nil
        }
    }

    private func handleItemStatus(_ status: AVPlayerItem.Status) {
        switch status {
        case .readyToPlay:
            // 就绪不等于已出声：loading 收尾交给 timeControlStatus
            break
        case .failed:
            handlePlaybackFailure(player.currentItem?.error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func handleTimeControlStatus(_ status: AVPlayer.TimeControlStatus) {
        guard isPlaying else {
            isLoading = false
            return
        }
        switch status {
        case .waitingToPlayAtSpecifiedRate:
            isLoading = true
        case .playing:
            isLoading = false
        case .paused:
            break
        @unknown default:
            break
        }
    }

    /// 播放失败：**先尝试一次「直连 → 转码」回退**，回退也失败才报错停播。
    ///
    /// 权限/格式问题里有一大类是「原始文件直连拿不到（Range 被拒 / 容器不支持），
    /// 但服务端转码能出」—— 这类失败不该让用户手动去设置页切音质。
    /// 回退只做一次（`didRetryWithFallback`），并且保留当前播放位置。
    private func handlePlaybackFailure(_ error: Error?) {
        guard !didReportTerminalFailure else { return }

        if !didRetryWithFallback,
           let fallback = currentSource?.transcodeFallback,
           fallback != currentSource?.url {
            didRetryWithFallback = true
            print("[MusicPlayerModel] 直连失败，尝试转码回退：\(error?.localizedDescription ?? "未知错误")")
            let seconds = player.currentTime().seconds
            let resume = seconds.isFinite && seconds > 0 ? seconds : nil
            let fallbackSource = PlayableSource(
                url: fallback,
                authorization: currentSource?.authorization,
                isHLS: isHLSURL(fallback),
                playMethod: .transcode,
                unplayableReason: nil,
                transcodeFallback: nil
            )
            if let track = currentTrack {
                startPlayback(
                    source: fallbackSource,
                    track: track,
                    isRetry: true,
                    resumePosition: resume
                )
                return
            }
        }

        didReportTerminalFailure = true
        player.pause()
        isPlaying = false
        isLoading = false
        errorMessage = describePlaybackFailure(error)
        if let track = currentTrack {
            print("[MusicPlayerModel] 播放失败 item=\(track.id)：\(error?.localizedDescription ?? "未知错误")")
        }
        reportProgress(force: true)
        updateNowPlayingInfo()
        saveQueueStateNow()
    }

    private func describePlaybackFailure(_ error: Error?) -> String {
        guard let error else { return "无法播放这首歌" }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return "播放失败：\(error.localizedDescription)"
        }
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet: return "网络未连接，无法播放"
        case NSURLErrorTimedOut: return "连接服务器超时，请稍后重试"
        case NSURLErrorCannotConnectToHost: return "无法连接服务器"
        case NSURLErrorNetworkConnectionLost: return "网络中断，播放失败"
        case NSURLErrorUserAuthenticationRequired: return "登录已失效，请重新登录"
        default: return "网络错误：\(error.localizedDescription)"
        }
    }

    private func isHLSURL(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8"
    }

    /// 换曲 / 停止时收尾：上报 stopped + 落地续播位置
    ///
    /// 只在**本次会话真正起播过**时上报：从磁盘恢复队列后用户直接点播放，
    /// 或者恢复后马上换曲，都不该给服务器发一个「没开始过的 stopped」。
    private func finishCurrentTrack(finished: Bool) {
        guard let track = currentTrack else { return }
        guard playStartedAt != nil else { return }
        let position = progress.position
        let backend = self.backend
        let playMethod = currentPlayMethod
        Task { await backend.report(PlaybackEvent(
            kind: .stopped,
            itemID: track.id,
            position: position,
            duration: progress.duration,
            isPaused: true,
            playMethod: playMethod
        )) }
        MusicDataStore.shared.noteProgress(track, position: position)
        playStartedAt = nil
    }

    /// 淡入主播放器。`overrideDuration` 非 nil 时用它（淡出直切路径），否则用设置里的淡入时长。
    private func startFadeIn(duration overrideDuration: Double? = nil) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        let target = Float(volume.level)
        let duration = overrideDuration ?? AppSettings.shared.fadeDuration
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
        // 过渡进行中：先看是不是「淡出方播完了」
        if let current = transition {
            switch current.kind {
            case .crossfade:
                // 旧曲提前播完（时长估算略长）：立刻完成角色交换，别等定时器
                completeCrossfade(current)
                return
            case .fadeThrough:
                performFadeThroughSwitch()
                return
            case .fadeOutAndPause:
                transition = nil
                stopTransitionTimer()
                pauseAfterFadeOut()
                return
            }
        }

        switch playMode {
        case .singleRepeat:
            Task { await seek(to: 0) }
            player.play()
            isPlaying = true
            startFadeIn()
        case .sequential:
            if currentIndex < queue.count - 1 {
                transitionToNextTrack()
            } else {
                stopAtEnd()
            }
        case .listRepeat:
            guard queue.count > 1 else {
                Task { await seek(to: 0) }
                player.play()
                isPlaying = true
                return
            }
            transitionToNextTrack()
        case .shuffle:
            if upcomingTrack() != nil {
                transitionToNextTrack()
            } else {
                stopAtEnd()
            }
        }
    }

    private func stopAtEnd() {
        isPlaying = false
        progress.position = progress.duration
        if let track = currentTrack {
            MusicDataStore.shared.notePlaybackFinished(track)
        }
        finishCurrentTrack(finished: true)
        updateNowPlayingInfo()
        saveQueueStateNow()
    }

    private func handleTime(_ seconds: Double, isSecondary: Bool) {
        // 重叠期间进度以主播放器为准：备用播放器此时在放下一首，它的 tick 一律忽略
        guard isSecondary == activeIsSecondary else { return }
        guard !isSeeking else { return }
        progress.position = seconds
        reportProgress()
        // 退出兜底镜像每个 tick 都刷（COW 数组拷贝，成本可忽略）；写盘按 10/30 秒节流
        refreshTerminationMirror()
        persistQueueStateIfNeeded()
        nowPlayingTick += 1
        if nowPlayingTick % 10 == 0 {
            refreshNowPlayingElapsed()
        }
        // 到达「剩余时长 ≤ 交叉时长」时开始衔接（真交叉或降级直切）
        maybeStartTransition()
    }

    /// 进度上报：服务端能收就报服务端，本地始终记（飞牛没有进度，续播全靠本地）。
    private func reportProgress(force: Bool = false) {
        guard let track = currentTrack else { return }
        let interval = max(AppSettings.shared.reportInterval, 3)
        let now = Date()
        guard force || now.timeIntervalSince(lastReportAt) >= interval else { return }
        lastReportAt = now
        let position = progress.position
        lastReportedPosition = position

        let backend = self.backend
        let playMethod = currentPlayMethod
        let paused = !isPlaying
        Task {
            await backend.report(PlaybackEvent(
                kind: .progress,
                itemID: track.id,
                position: position,
                duration: progress.duration,
                isPaused: paused,
                playMethod: playMethod
            ))
        }
        // 本地兜底：每 5 秒落一次盘，别把写盘频率拉到 0.5s
        if force || now.timeIntervalSince(lastLocalPersistAt) >= 5 {
            lastLocalPersistAt = now
            MusicDataStore.shared.noteProgress(track, position: position)
        }
    }

    private var lastLocalPersistAt: Date = .distantPast
    /// 换曲时要从该位置起播（仅 `resume(tracks:startAt:position:)` 设置，消费一次即清）
    private var pendingResumePosition: Double?

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
            MPMediaItemPropertyTitle: currentTrack?.title ?? "未在播放",
            MPMediaItemPropertyArtist: currentTrack?.artistName ?? currentTrack?.albumTitle ?? "",
            MPMediaItemPropertyAlbumTitle: currentTrack?.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: max(progress.duration, 0),
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: progress.position,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let ref = currentTrack?.artworkRef(width: 512),
           let url = backend.artworkURL(ref) {
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
