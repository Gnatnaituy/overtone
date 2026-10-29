import Foundation

// MARK: - 判定结果

/// 一次「该不该开始衔接」的判定结果（纯逻辑，播放器按它选执行路径）。
///
/// 为什么把降级路径也放进返回值：真正「播完该干什么」取决于**当前播放器的能力**
/// （下一首是否已预取、是否转码/HLS、睡眠定时是否临近），这些条件放在播放器里判断会散成
/// 五六个 if；集中到 `CrossfadeMath.evaluate` 后，降级策略变成一张可断言的真值表。
enum CrossfadeAction: Equatable {
    /// 还没到衔接点（或本次根本不做衔接）
    case none
    /// 双播放器真交叉淡化（active 淡出 + standby 淡入，重叠 `seconds` 秒）
    case crossfade(seconds: Double)
    /// 降级：淡出 → 直切 → 淡入（下一首未预取 / 转码 / HLS）
    case fadeThrough(seconds: Double)
    /// 睡眠定时临近：淡出后暂停，不接下一首
    case fadeOutAndPause(seconds: Double)

    /// 本次衔接需要占用的时长（`none` 为 0）
    var seconds: Double {
        switch self {
        case .none: return 0
        case .crossfade(let seconds), .fadeThrough(let seconds), .fadeOutAndPause(let seconds):
            return seconds
        }
    }
}

// MARK: - 纯数学

/// 交叉淡化 / 淡入淡出的纯逻辑：时长夹取、等功率增益曲线、触发点判定。
///
/// 刻意不 import AVFoundation —— 这里全是数学，可以在 `--selftest` 里脱离播放器断言。
enum CrossfadeMath {
    /// 设置里允许的最大交叉淡化时长（与 `AppSettings.crossfadeSeconds` 的上限一致）
    static let maximumSeconds: Double = 12

    /// 低于这个时长听感上就是「直切」，按 0 处理（避免 0.03 秒这种无意义的定时器）
    static let minimumSeconds: Double = 0.2

    /// 手动切歌（next/previous）的过渡上限：约 1 秒，再长就变成拖沓
    static let manualTransitionSeconds: Double = 1.0

    /// 睡眠定时的保护窗：剩余时间进入「交叉时长 + 5 秒」内就不再做衔接
    static let sleepGuardSeconds: Double = 5

    // MARK: 时长

    /// 夹取为 `0...maximumSeconds`；非有限值与低于 `minimumSeconds` 的值都归 0。
    static func clamped(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0 }
        let value = min(max(seconds, 0), maximumSeconds)
        return value < minimumSeconds ? 0 : value
    }

    /// 本次交叉实际可用的时长。
    ///
    /// 不超过半首歌：否则「时长 10 秒的短曲 + 8 秒交叉」会在刚开始播放时就触发交叉，
    /// 表现为「每首歌都从中间开始」。半首歌的下限是 `minimumSeconds`。
    static func effectiveDuration(trackDuration: Double, requestedSeconds: Double) -> Double {
        guard trackDuration.isFinite, trackDuration > 0 else { return 0 }
        let requested = clamped(requestedSeconds)
        guard requested > 0 else { return 0 }
        let ceiling = trackDuration / 2
        guard ceiling >= minimumSeconds else { return 0 }
        return min(requested, ceiling)
    }

    /// 手动切歌的过渡时长：用户设置的交叉时长与 1 秒取小；关闭交叉淡化则直切。
    static func manualTransitionDuration(requestedSeconds: Double) -> Double {
        let requested = clamped(requestedSeconds)
        guard requested > 0 else { return 0 }
        return min(requested, manualTransitionSeconds)
    }

    /// 交叉开始的时间点（秒）；`nil` = 这首歌不值得/不能交叉。
    static func crossfadeStartTime(trackDuration: Double, requestedSeconds: Double) -> Double? {
        let seconds = effectiveDuration(trackDuration: trackDuration, requestedSeconds: requestedSeconds)
        guard seconds > 0 else { return nil }
        return max(trackDuration - seconds, 0)
    }

    /// 距离自然播完还剩多少秒（负数按 0）
    static func remainingTime(trackDuration: Double, position: Double) -> Double {
        guard trackDuration.isFinite, trackDuration > 0, position.isFinite else { return 0 }
        return max(trackDuration - position, 0)
    }

    // MARK: 增益曲线

    /// 淡出增益：进度 0 → 1，1 → 0（等功率余弦曲线）。
    ///
    /// 为什么用等功率（cos/sin）而不是线性：两条线性曲线叠加时中点会掉约 3dB，
    /// 听感是「交叉处突然变小声」；cos² + sin² ≡ 1 让重叠期间总功率守恒。
    static func fadeOutGain(progress: Double) -> Float {
        let t = clampProgress(progress)
        if t <= 0 { return 1 }
        if t >= 1 { return 0 }
        return Float(cos(t * .pi / 2))
    }

    /// 淡入增益：进度 0 → 0，1 → 1（与 `fadeOutGain` 等功率互补）。
    static func fadeInGain(progress: Double) -> Float {
        let t = clampProgress(progress)
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return Float(sin(t * .pi / 2))
    }

    // MARK: 触发判定

    /// 判断此刻是否该开始衔接，以及走哪条路径。
    ///
    /// 参数都是**已解耦的布尔事实**（播放器负责查）：
    /// - `nextPrepared`：下一首的 `AVPlayerItem` 是否已在 standby 上就绪；
    /// - `nextRequiresFadeThrough`：下一首是转码/HLS（起播慢，不适合双流并行）；
    /// - `isSingleRepeat`：单曲循环不做衔接（它只是 seek 回 0）；
    /// - `sleepRemaining`：睡眠定时剩余秒数（`nil` = 没设）。
    ///
    /// 优先级：睡眠定时 > 单曲循环 > 真交叉 > 降级直切。睡眠定时最优先是因为
    /// 「用户要睡了」比「下一首别断」重要，此时把下一首接上来反而会破坏淡出暂停的语义。
    static func evaluate(
        trackDuration: Double,
        position: Double,
        requestedSeconds: Double,
        nextPrepared: Bool,
        nextRequiresFadeThrough: Bool,
        isSingleRepeat: Bool,
        sleepRemaining: Double?
    ) -> CrossfadeAction {
        let seconds = effectiveDuration(trackDuration: trackDuration, requestedSeconds: requestedSeconds)
        guard seconds > 0, position.isFinite, position >= 0 else { return .none }
        guard position >= trackDuration - seconds else { return .none }
        if isSingleRepeat { return .none }

        if let sleepRemaining, sleepRemaining.isFinite, sleepRemaining <= seconds + sleepGuardSeconds {
            return .fadeOutAndPause(seconds: seconds)
        }
        guard nextPrepared, !nextRequiresFadeThrough else {
            return .fadeThrough(seconds: seconds)
        }
        return .crossfade(seconds: seconds)
    }

    // MARK: 内部

    private static func clampProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }
}
