import Foundation

/// 歌词偏移 / 高亮时间轴的自检（由 `SelfTest.run(into:)` 调用 `lyricsChecks`）。
///
/// 守的是「写错了不报错、只表现为高亮差半句」的那类逻辑：偏移符号（正值 = 推迟）、
/// 容差边界、纯文本歌词、夹到 ±2s 与展示格式。这些用眼睛验不出来 ——
/// 偏移 +0.5 与 −0.5 在正常播放时都「看起来在动」。
extension SelfTest {
    static func lyricsChecks(_ c: Checker) {
        // 固定样本：0 / 5 / 10 / 20 秒，中间夹一行无时间戳的纯文本行（空行）
        let synced = [
            LyricLine(text: "第一行", start: 0),
            LyricLine(text: "第二行", start: 5),
            LyricLine(text: "", start: nil),
            LyricLine(text: "第三行", start: 10),
            LyricLine(text: "第四行", start: 20),
        ]

        /// 断言高亮行；`tolerance` 省略时走默认容差
        func line(
            _ position: Double,
            offset: Double = 0,
            tolerance: Double? = nil,
            _ expected: Int?,
            _ label: String
        ) {
            let actual: Int?
            if let tolerance {
                actual = LyricsTimeline.activeIndex(
                    lyrics: synced, position: position, offset: offset, tolerance: tolerance
                )
            } else {
                actual = LyricsTimeline.activeIndex(
                    lyrics: synced, position: position, offset: offset
                )
            }
            c.equal(actual, expected, label)
        }

        // MARK: 基础命中

        line(0, 0, "歌词：0s 命中首行")
        line(6, 1, "歌词：两行之间取前一行")
        line(12, 3, "歌词：跳过无时间戳行后继续扫描")
        line(60, 4, "歌词：播过末行后停在末行")
        line(4.7, 0, "歌词：容差外仍是前一行")
        line(4.85, 1, "歌词：容差内切到下一行")
        line(4.7, offset: 0, tolerance: 0.5, 1, "歌词：容差可调（0.5s 内算命中）")

        // MARK: 偏移（正值 = 推迟）

        line(5.0, offset: 0.5, 0, "歌词：+0.5s 偏移让第二行推迟到 5.5s")
        line(5.6, offset: 0.5, 1, "歌词：推迟后到点仍会切行")
        line(4.6, offset: -0.5, 1, "歌词：−0.5s 偏移让歌词提前命中")
        line(0, offset: 0.3, tolerance: nil, nil, "歌词：正值偏移连首行一起推迟（0s 时还没有行）")
        line(0.4, offset: 0.3, 0, "歌词：偏移把首行推到 0.3s 后命中")
        line(6, offset: 1.5, 0, "歌词：正偏移改变整条时间轴")

        // MARK: 边界：纯文本 / 空表 / 首行之前

        let plainLyrics = [
            LyricLine(text: "只有文字", start: nil),
            LyricLine(text: "没有时间戳", start: nil),
        ]
        c.equal(
            LyricsTimeline.activeIndex(lyrics: plainLyrics, position: 30),
            nil,
            "歌词：纯文本歌词没有高亮行"
        )
        c.equal(
            LyricsTimeline.activeIndex(lyrics: [], position: 30),
            nil,
            "歌词：空歌词表没有高亮行"
        )

        let lateStart = [
            LyricLine(text: "晚一点", start: 5),
            LyricLine(text: "再晚", start: 9),
        ]
        c.equal(
            LyricsTimeline.activeIndex(lyrics: lateStart, position: 2),
            nil,
            "歌词：未到首行之前不猜一行"
        )

        // MARK: 同步歌词判定（决定入口显隐）

        c.expect(LyricsTimeline.hasSyncedLyrics(synced), "歌词：有时间戳 → 有同步歌词")
        c.expect(!LyricsTimeline.hasSyncedLyrics(plainLyrics), "歌词：纯文本 → 不算同步歌词")
        c.expect(!LyricsTimeline.hasSyncedLyrics([]), "歌词：空表 → 不算同步歌词")

        // MARK: 偏移夹取与展示

        c.near(LyricsTimeline.offsetLimit, 2, "歌词：偏移上限是 2 秒")
        c.near(LyricsTimeline.defaultTolerance, 0.2, "歌词：默认容差是 0.2 秒")
        c.near(LyricsTimeline.clampedOffset(5), 2, "歌词：偏移上限夹到 +2s")
        c.near(LyricsTimeline.clampedOffset(-5), -2, "歌词：偏移下限夹到 −2s")
        c.near(LyricsTimeline.clampedOffset(1.25), 1.25, "歌词：范围内偏移原样保留")
        c.near(LyricsTimeline.clampedOffset(0), 0, "歌词：0 偏移原样保留")
        c.near(LyricsTimeline.clampedOffset(.nan), 0, "歌词：NaN 偏移视为 0")
        c.near(LyricsTimeline.clampedOffset(.infinity), 0, "歌词：无穷偏移视为 0")

        c.equal(LyricsTimeline.offsetText(0.3), "+0.3s", "歌词：正偏移文本带走 +")
        c.equal(LyricsTimeline.offsetText(-0.1), "-0.1s", "歌词：负偏移文本带走 −")
        c.equal(LyricsTimeline.offsetText(0), "0.0s", "歌词：零偏移不带符号")
        c.equal(LyricsTimeline.offsetText(-0.0), "0.0s", "歌词：负零也显示 0.0s")
        c.equal(LyricsTimeline.offsetText(0.04), "0.0s", "歌词：四舍五入后为零也显示 0.0s")
        c.equal(LyricsTimeline.offsetText(2), "+2.0s", "歌词：上限偏移文本带一位小数")
        c.equal(LyricsTimeline.offsetText(-9), "-2.0s", "歌词：越界偏移先夹后展示")
    }
}
