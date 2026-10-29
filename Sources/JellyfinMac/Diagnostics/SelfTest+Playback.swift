import Foundation

// MARK: - 播放衔接自检

/// 播放衔接（队列持久化 / 交叉淡化数学 / InstantMix 续播规则）的纯逻辑断言。
///
/// 由 `SelfTest.run(into:)` 调用（接入点在 `Diagnostics/SelfTest.swift`）。
/// 这些断言覆盖的是「写错了只表现为『重启队列没了 / 交叉处掉音量 / 续播狂塞重复曲目』」
/// 的那批代码 —— 播放链路本身要真机听，能脱离音频硬件验证的部分尽量钉死在这里。
extension SelfTest {
    static func playbackChecks(_ c: Checker) {
        queueSnapshotChecks(c)
        queueValidationChecks(c)
        crossfadeGainChecks(c)
        crossfadeTriggerChecks(c)
        continuationChecks(c)
    }

    // MARK: 测试夹具

    /// 一条测试曲目（只填断言用得到的字段）
    private static func playbackTrack(
        _ id: String,
        backend: BackendKind = .jellyfin,
        title: String = "曲目",
        duration: Double = 200,
        kind: MediaKind = .track
    ) -> MediaItem {
        MediaItem(
            id: id,
            backend: backend,
            kind: kind,
            title: title,
            subtitle: nil,
            albumID: nil,
            albumTitle: nil,
            artistID: nil,
            artistName: nil,
            duration: duration,
            trackNumber: nil,
            discNumber: nil,
            year: nil,
            dateAdded: nil,
            artwork: nil,
            genres: [],
            childCount: nil,
            format: nil,
            bitrate: nil,
            sampleRate: nil,
            bitDepth: nil,
            channels: nil,
            userData: .empty
        )
    }

    private static func playbackSnapshot(
        backend: BackendKind = .jellyfin,
        savedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        currentIndex: Int = 1,
        playMode: String = "listRepeat",
        position: Double = 42.5,
        tracks: [MediaItem]? = nil,
        autoContinueStart: Int = -1
    ) -> QueueSnapshot {
        QueueSnapshot(
            backendKind: backend,
            savedAt: savedAt,
            currentIndex: currentIndex,
            playMode: playMode,
            position: position,
            tracks: tracks ?? [
                playbackTrack("a"),
                playbackTrack("b"),
                playbackTrack("c"),
            ],
            autoContinueStart: autoContinueStart
        )
    }

    // MARK: 快照 Codable 往返

    private static func queueSnapshotChecks(_ c: Checker) {
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = playbackSnapshot(
            savedAt: savedAt,
            currentIndex: 2,
            playMode: "shuffle",
            position: 88.25,
            autoContinueStart: 1
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let data = try? encoder.encode(snapshot),
           let decoded = try? decoder.decode(QueueSnapshot.self, from: data) {
            c.equal(decoded, snapshot, "队列快照 Codable 往返一致")
            c.equal(decoded.tracks.count, 3, "队列快照保留曲目数量")
            c.equal(decoded.playMode, "shuffle", "队列快照保留播放模式")
        } else {
            c.expect(false, "队列快照应能编码/解码")
        }

        // 手写解码：快照顶层字段缺失时退化默认值，而不是整份丢弃
        // （曲目本身的字段仍由 MediaItem 合成解码器要求完整 —— 这里只针对快照信封）
        if let itemData = try? encoder.encode([playbackTrack("x")]),
           let itemJSON = String(data: itemData, encoding: .utf8) {
            let partial = Data("{\"tracks\":\(itemJSON)}".utf8)
            if let decoded = try? decoder.decode(QueueSnapshot.self, from: partial) {
                c.equal(decoded.tracks.count, 1, "缺顶层字段的快照仍能解码")
                c.equal(decoded.currentIndex, 0, "缺 currentIndex 时默认 0")
                c.equal(decoded.autoContinueStart, -1, "缺 autoContinueStart 时默认 -1")
                c.equal(decoded.version, QueuePersistence.supportedVersion, "缺 version 时按当前版本")
            } else {
                c.expect(false, "缺顶层字段的快照不应解码失败")
            }
        } else {
            c.expect(false, "测试曲目应能编码")
        }
    }

    // MARK: 快照校验（后端 / 7 天 / 索引 / 位置）

    private static func queueValidationChecks(_ c: Checker) {
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = playbackSnapshot(savedAt: savedAt)

        let fresh = snapshot.validated(for: .jellyfin, now: savedAt.addingTimeInterval(60))
        c.expect(fresh != nil, "同后端且 1 分钟前的快照可恢复")

        c.expect(
            snapshot.validated(for: .feiniu, now: savedAt.addingTimeInterval(60)) == nil,
            "后端不匹配的快照不可恢复"
        )
        c.expect(
            snapshot.validated(
                for: .jellyfin,
                now: savedAt.addingTimeInterval(QueuePersistence.maximumAge + 1)
            ) == nil,
            "超过 7 天的快照不可恢复"
        )
        c.expect(
            snapshot.validated(for: .jellyfin, now: savedAt.addingTimeInterval(-7_200)) == nil,
            "保存时间在未来（时钟被改）的快照不可恢复"
        )

        var tooNew = snapshot
        tooNew.version = QueuePersistence.supportedVersion + 1
        c.expect(
            tooNew.validated(for: .jellyfin, now: savedAt.addingTimeInterval(60)) == nil,
            "高于当前版本的快照不可恢复"
        )

        c.expect(
            playbackSnapshot(savedAt: savedAt, tracks: [])
                .validated(for: .jellyfin, now: savedAt.addingTimeInterval(60)) == nil,
            "空队列快照不可恢复"
        )
        c.expect(
            playbackSnapshot(savedAt: savedAt, tracks: [playbackTrack("a", backend: .feiniu)])
                .validated(for: .jellyfin, now: savedAt.addingTimeInterval(60)) == nil,
            "混入其他后端曲目的快照不可恢复"
        )
        c.expect(
            playbackSnapshot(savedAt: savedAt, tracks: [playbackTrack("a", kind: .album)])
                .validated(for: .jellyfin, now: savedAt.addingTimeInterval(60)) == nil,
            "混入非曲目条目的快照不可恢复"
        )

        var dirty = snapshot
        dirty.currentIndex = 99
        dirty.position = 999
        dirty.autoContinueStart = 7
        if let sanitized = dirty.validated(for: .jellyfin, now: savedAt.addingTimeInterval(60)) {
            c.equal(sanitized.currentIndex, 2, "越界索引夹到队尾")
            c.near(sanitized.position, 199, "位置夹到「时长 - 1」以内")
            c.equal(sanitized.autoContinueStart, -1, "越界自动续播起点归 -1")
        } else {
            c.expect(false, "越界字段应被夹取而不是整份丢弃")
        }

        var negative = snapshot
        negative.position = -10
        c.near(
            negative.validated(for: .jellyfin, now: savedAt.addingTimeInterval(60))?.position ?? -1,
            0,
            "负位置归 0"
        )
    }

    // MARK: 增益曲线

    private static func crossfadeGainChecks(_ c: Checker) {
        c.near(Double(CrossfadeMath.fadeOutGain(progress: 0)), 1, "淡出起点增益 1")
        c.near(Double(CrossfadeMath.fadeOutGain(progress: 1)), 0, "淡出终点增益 0")
        c.near(Double(CrossfadeMath.fadeInGain(progress: 0)), 0, "淡入起点增益 0")
        c.near(Double(CrossfadeMath.fadeInGain(progress: 1)), 1, "淡入终点增益 1")

        // 等功率：中点约 0.707，且任意点 cos² + sin² ≈ 1（重叠期间总功率守恒）
        c.near(Double(CrossfadeMath.fadeOutGain(progress: 0.5)), 0.707_106, "淡出中点约 0.707", accuracy: 0.001)
        c.near(Double(CrossfadeMath.fadeInGain(progress: 0.5)), 0.707_106, "淡入中点约 0.707", accuracy: 0.001)
        for step in 0...10 {
            let t = Double(step) / 10
            let out = Double(CrossfadeMath.fadeOutGain(progress: t))
            let into = Double(CrossfadeMath.fadeInGain(progress: t))
            c.near(out * out + into * into, 1, "等功率曲线在 t=\(step)/10 处守恒", accuracy: 0.002)
        }

        // 越界进度按端点处理（时间观察器偶尔会报出 >1 的位置）
        c.near(Double(CrossfadeMath.fadeOutGain(progress: 1.4)), 0, "越界进度按终点处理")
        c.near(Double(CrossfadeMath.fadeInGain(progress: -0.2)), 0, "负进度按起点处理")

        // 时长夹取与短曲边界
        c.near(CrossfadeMath.clamped(-3), 0, "负时长归 0")
        c.near(CrossfadeMath.clamped(0.05), 0, "过短时长按直切处理")
        c.near(CrossfadeMath.clamped(20), 12, "超长时长夹到 12 秒")
        c.near(CrossfadeMath.clamped(.nan), 0, "NaN 归 0")

        c.near(CrossfadeMath.effectiveDuration(trackDuration: 200, requestedSeconds: 8), 8, "常规交叉时长")
        c.near(CrossfadeMath.effectiveDuration(trackDuration: 10, requestedSeconds: 8), 5, "短曲不超过半首")
        c.near(CrossfadeMath.effectiveDuration(trackDuration: 0.3, requestedSeconds: 8), 0, "极短曲不做交叉")
        c.near(CrossfadeMath.effectiveDuration(trackDuration: 200, requestedSeconds: 0), 0, "关闭交叉时不做交叉")

        c.near(CrossfadeMath.manualTransitionDuration(requestedSeconds: 8), 1, "手动切歌用约 1 秒")
        c.near(CrossfadeMath.manualTransitionDuration(requestedSeconds: 0.5), 0.5, "手动切歌不放大用户设置")
        c.near(CrossfadeMath.manualTransitionDuration(requestedSeconds: 0), 0, "关闭交叉时手动切歌直切")
    }

    // MARK: 触发判定与降级路径

    private static func crossfadeTriggerChecks(_ c: Checker) {
        func action(
            duration: Double = 200,
            position: Double = 195,
            requested: Double = 8,
            prepared: Bool = true,
            needsFadeThrough: Bool = false,
            singleRepeat: Bool = false,
            sleepRemaining: Double? = nil
        ) -> CrossfadeAction {
            CrossfadeMath.evaluate(
                trackDuration: duration,
                position: position,
                requestedSeconds: requested,
                nextPrepared: prepared,
                nextRequiresFadeThrough: needsFadeThrough,
                isSingleRepeat: singleRepeat,
                sleepRemaining: sleepRemaining
            )
        }

        c.equal(action(), .crossfade(seconds: 8), "剩余 5 秒（交叉 8 秒）应开始真交叉")
        c.equal(action(position: 100), .none, "远离结尾时不触发")
        c.equal(action(position: 191.9), .none, "触发点之前不触发")
        c.equal(action(position: 192), .crossfade(seconds: 8), "恰好到达触发点即触发")
        c.equal(action(duration: 10, position: 6), .crossfade(seconds: 5), "短曲按半首触发")
        c.equal(action(singleRepeat: true), .none, "单曲循环不交叉")
        c.equal(action(requested: 0), .none, "关闭交叉淡化时不触发")
        c.equal(action(duration: 0, position: 0), .none, "时长未知时不触发")
        c.equal(action(position: -1), .none, "非法位置不触发")

        c.equal(action(prepared: false), .fadeThrough(seconds: 8), "下一首未预取 → 淡出直切淡入")
        c.equal(action(needsFadeThrough: true), .fadeThrough(seconds: 8), "转码/HLS → 淡出直切淡入")

        if case .fadeOutAndPause(let seconds) = action(sleepRemaining: 3) {
            c.near(seconds, 8, "睡眠定时临近时保留淡出时长")
        } else {
            c.expect(false, "睡眠定时临近时应优先淡出暂停")
        }
        c.equal(action(sleepRemaining: 100), .crossfade(seconds: 8), "睡眠定时还远时正常交叉")
    }

    // MARK: InstantMix 续播规则

    private static func continuationChecks(_ c: Checker) {
        let a = playbackTrack("a")
        let b = playbackTrack("b")
        let cTrack = playbackTrack("c")
        let d = playbackTrack("d")
        let album = playbackTrack("album", kind: .album)

        let appended = QueueContinuation.appendable(
            from: [a, cTrack, cTrack, album, d],
            existing: [a, b]
        )
        c.equal(appended.map(\.id), ["c", "d"], "自动续播去重：排除队列已有、候选重复与非曲目")
        c.equal(
            QueueContinuation.appendable(from: [a, cTrack, d], existing: [a, b], limit: 1).map(\.id),
            ["c"],
            "自动续播遵守条数上限"
        )
        c.equal(
            QueueContinuation.appendable(from: [a], existing: [], limit: 0).map(\.id),
            [],
            "上限为 0 时不追加"
        )
        c.equal(
            QueueContinuation.appendable(from: [], existing: [a]).map(\.id),
            [],
            "空候选不追加"
        )

        let base = (
            autoContinueEnabled: true,
            backendSupportsInstantMix: true,
            autoContinuedTrackCount: 0
        )
        c.expect(
            QueueContinuation.shouldRequestContinuation(
                queueCount: 3,
                currentIndex: 2,
                autoContinueEnabled: base.autoContinueEnabled,
                backendSupportsInstantMix: base.backendSupportsInstantMix,
                autoContinuedTrackCount: base.autoContinuedTrackCount
            ),
            "播到队尾且开启自动续播时请求 InstantMix"
        )
        c.expect(
            !QueueContinuation.shouldRequestContinuation(
                queueCount: 3,
                currentIndex: 1,
                autoContinueEnabled: base.autoContinueEnabled,
                backendSupportsInstantMix: base.backendSupportsInstantMix,
                autoContinuedTrackCount: base.autoContinuedTrackCount
            ),
            "队列还剩多首时不该提前续播"
        )
        c.expect(
            !QueueContinuation.shouldRequestContinuation(
                queueCount: 3,
                currentIndex: 2,
                autoContinueEnabled: false,
                backendSupportsInstantMix: true,
                autoContinuedTrackCount: 0
            ),
            "关闭自动续播时不请求"
        )
        c.expect(
            !QueueContinuation.shouldRequestContinuation(
                queueCount: 3,
                currentIndex: 2,
                autoContinueEnabled: true,
                backendSupportsInstantMix: false,
                autoContinuedTrackCount: 0
            ),
            "后端不支持 InstantMix 时不请求"
        )
        c.expect(
            !QueueContinuation.shouldRequestContinuation(
                queueCount: 3,
                currentIndex: 2,
                autoContinueEnabled: true,
                backendSupportsInstantMix: true,
                autoContinuedTrackCount: QueueContinuation.maximumAutoContinuedTracks
            ),
            "自动续播已达上限时回到 stopAtEnd"
        )
        c.expect(
            !QueueContinuation.shouldRequestContinuation(
                queueCount: 0,
                currentIndex: 0,
                autoContinueEnabled: true,
                backendSupportsInstantMix: true,
                autoContinuedTrackCount: 0
            ),
            "空队列不请求续播"
        )
    }
}
