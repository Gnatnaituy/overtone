import Foundation

/// 歌词时间轴：高亮行与偏移量的**唯一算法**（`LyricsPane` 与 `ImmersiveLyricsView` 共用）。
///
/// 为什么单独成文件：两个界面都要回答「现在唱到哪一行」。各写一套的代价不在于多写十几行，
/// 而在于**偏移的符号约定**会在其中一处写反 —— 那样两边只在偏移 ≠ 0 时慢慢分叉，
/// 正常播放（偏移 0）完全看不出来，只有蓝牙延迟补偿或拖进度时才暴露。
///
/// 符号约定（与 `AppSettings.lyricsOffsetSeconds` 的注释一致）：
/// **正值 = 歌词推迟显示**。实现上等价于「用 `position − offset` 去查时间戳」：
/// 偏移 +0.5s 时，播放到 5.5s 才命中 `start == 5.0` 的行。
enum LyricsTimeline {
    /// 偏移允许范围（秒）：覆盖蓝牙耳机 / 外接声卡的常见延迟；再大就不是延迟，而是词不同步
    static let offsetLimit: Double = 2

    /// 高亮容差（秒）：播放进度每 0.5s 上报一次，容差要盖住一次采样间隔
    static let defaultTolerance: Double = 0.2

    /// 当前应高亮的行下标；`nil` = 还没有可高亮的行（纯文本歌词 / 还没到第一行）。
    ///
    /// - Parameters:
    ///   - lyrics: 歌词行（`start == nil` 的是纯文本 / 空行，不参与时间轴）
    ///   - position: 播放进度（秒）
    ///   - offset: 歌词偏移（**正值 = 推迟**）
    ///   - tolerance: 命中容差（秒）
    static func activeIndex(
        lyrics: [LyricLine],
        position: Double,
        offset: Double = 0,
        tolerance: Double = defaultTolerance
    ) -> Int? {
        guard !lyrics.isEmpty, position.isFinite else { return nil }
        // 正值 = 推迟：要等播放得更久才命中，所以查询用 position − offset
        let shifted = position - (offset.isFinite ? offset : 0)
        let slack = tolerance.isFinite ? max(tolerance, 0) : 0

        var active: Int?
        for (index, line) in lyrics.enumerated() {
            guard let start = line.start else { continue }  // 纯文本行跳过，不打断扫描
            if start <= shifted + slack {
                active = index
            } else {
                // 时间戳升序（解析侧保证）：越过当前进度的第一行即可停
                break
            }
        }
        return active
    }

    /// 是否有可跟随时轴的行 —— 决定「歌词偏移 / 沉浸式」入口是否出现
    static func hasSyncedLyrics(_ lyrics: [LyricLine]) -> Bool {
        lyrics.contains { $0.start != nil }
    }

    /// 把偏移夹到 ±`offsetLimit`；非有限值（NaN / ∞）视为 0
    static func clampedOffset(_ raw: Double) -> Double {
        guard raw.isFinite else { return 0 }
        return min(max(raw, -offsetLimit), offsetLimit)
    }

    /// 偏移的展示文本：`+0.3s` / `-0.1s` / `0.0s`
    ///
    /// 固定一位小数：菜单标签在 −0.1 / +0.1 之间切换时不会跳宽。
    static func offsetText(_ offset: Double) -> String {
        let value = clampedOffset(offset)
        // `%+.1f` 对 ±0.0 会输出 "+0.0s" / "-0.0s"：零值（含四舍五入后为零）统一成 `0.0s`
        if abs(value) < 0.05 { return "0.0s" }
        return String(format: "%+.1fs", value)
    }
}
