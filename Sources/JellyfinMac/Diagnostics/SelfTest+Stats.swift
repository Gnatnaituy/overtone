import Foundation

// MARK: - 听歌统计 / 年度报告自检
//
// 断言对象是 `PlaybackHistory.swift` 里的**纯逻辑**：不碰磁盘、不碰 `@MainActor` 存储、
// 不依赖当前时区（固定 UTC 日历 + 固定时间戳），所以结果与运行环境无关。
//
// 由 `SelfTest.run(into:)` 调用（Lead 接线）：`playbackStats(checker)`。

extension SelfTest {
    /// 听歌统计 + 年度报告（范围过滤 / 播放次数 / 去重 / 活跃天数 / 小时分桶 / 人格 / prune）
    static func playbackStats(_ c: Checker) {
        // 固定日历：UTC + 周一为首日 —— 结果不随机器时区 / 地区设置变化
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2

        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
            ) ?? Date(timeIntervalSince1970: 0)
        }

        // 固定事件：跨 2024 / 2025 / 2026 三个自然年
        let oldTrack = ListeningEvent(
            startedAt: date(2024, 6, 1, 20, 0),
            contentKey: "t|d", title: "旧曲", artistName: "艺人丁", albumTitle: "专辑四",
            duration: 200, listenedSeconds: 200, completed: true
        )
        let lastYearTrack = ListeningEvent(
            startedAt: date(2025, 12, 31, 20, 0),
            contentKey: "t|d", title: "旧曲", artistName: "艺人丁", albumTitle: "专辑四",
            duration: 200, listenedSeconds: 120
        )
        let first = ListeningEvent(
            startedAt: date(2026, 1, 5, 9, 10),
            contentKey: "t|a", title: "曲目甲", artistName: "艺人甲", albumTitle: "专辑一",
            duration: 210, listenedSeconds: 200
        )
        let second = ListeningEvent(
            startedAt: date(2026, 1, 5, 23, 30),
            contentKey: "t|b", title: "曲目乙", artistName: "艺人乙", albumTitle: "专辑二",
            duration: 180, listenedSeconds: 180, completed: true
        )
        let third = ListeningEvent(
            startedAt: date(2026, 1, 6, 23, 40),
            contentKey: "t|a", title: "曲目甲", artistName: "艺人甲", albumTitle: "专辑一",
            duration: 210, listenedSeconds: 210, completed: true
        )
        let spring = ListeningEvent(
            startedAt: date(2026, 3, 10, 12, 0),
            contentKey: "t|c", title: "曲目丙", artistName: "艺人丙", albumTitle: "专辑三",
            duration: 240, listenedSeconds: 150
        )
        // 故意乱序传入：聚合内部必须先排序（首曲 / 连续天数 / 展示名都依赖顺序）
        let events = [spring, second, first, oldTrack, third, lastYearTrack]
        let now = date(2026, 1, 7, 12, 0)

        // MARK: 时间范围下界

        c.equal(
            PlaybackStatsRange.week.startDate(now: now, calendar: calendar),
            date(2026, 1, 1),
            "近 7 天从今天往前数 7 天（含当天）"
        )
        c.equal(
            PlaybackStatsRange.month.startDate(now: now, calendar: calendar),
            date(2025, 12, 9),
            "近 30 天从今天往前数 30 天（含当天）"
        )
        c.equal(
            PlaybackStatsRange.year.startDate(now: now, calendar: calendar),
            date(2025, 1, 7),
            "近一年是滚动 12 个月"
        )
        c.expect(PlaybackStatsRange.all.startDate(now: now, calendar: calendar) == nil, "全部没有下界")

        // MARK: 近 7 天：范围过滤 / 播放次数 / 去重 / 活跃天数 / 小时分桶

        let week = PlaybackStats.summary(events: events, range: .week, now: now, calendar: calendar)
        c.equal(week.totalPlays, 3, "近 7 天只统计窗口内的事件")
        c.near(week.totalSeconds, 590, "近 7 天累计收听时长（200 + 180 + 210）")
        c.equal(week.activeDays, 2, "活跃天数按自然日去重")
        c.equal(week.uniqueTracks, 2, "同一首歌播两次只算一首（去重）")
        c.equal(week.dailyCounts[date(2026, 1, 5)], 2, "1 月 5 日两次")
        c.equal(week.dailyCounts[date(2026, 1, 6)], 1, "1 月 6 日一次")
        c.equal(week.dailyCounts[date(2026, 3, 10)], nil, "范围外的那一天不出现")
        c.equal(week.hourlyCounts.count, 24, "小时桶固定 24 个")
        c.equal(week.hourlyCounts[9], 1, "9 点一次")
        c.equal(week.hourlyCounts[23], 2, "23 点两次")
        c.equal(week.monthlyCounts.count, 12, "月桶固定 12 个")
        c.equal(week.monthlyCounts[0], 3, "1 月三次")

        // Top 榜：歌曲 / 艺人 / 专辑各取前 5，含名称与次数
        c.equal(week.topSongs.count, 2, "近 7 天只有两首歌")
        c.equal(week.topSongs.first?.key, "t|a", "Top 歌曲按次数降序")
        c.equal(week.topSongs.first?.plays, 2, "Top 歌曲次数")
        c.equal(week.topSongs.first?.name, "曲目甲", "Top 歌曲展示名")
        c.equal(week.topArtists.first?.name, "艺人甲", "Top 艺人")
        c.equal(week.topArtists.first?.plays, 2, "Top 艺人次数")
        c.equal(week.topAlbums.first?.name, "专辑一", "Top 专辑")

        // 逐级放大范围：近 30 天 / 近一年 / 全部
        let month = PlaybackStats.summary(events: events, range: .month, now: now, calendar: calendar)
        c.equal(month.totalPlays, 4, "近 30 天含去年 12 月 31 日")
        c.equal(month.uniqueTracks, 3, "近 30 天三首不同的歌")

        let year = PlaybackStats.summary(events: events, range: .year, now: now, calendar: calendar)
        c.equal(year.totalPlays, 4, "近一年含 2025 年的事件")
        let all = PlaybackStats.summary(events: events, range: .all, now: now, calendar: calendar)
        c.equal(all.totalPlays, 6, "全部含 2024 年的事件")
        c.equal(all.uniqueTracks, 4, "全部四首不同的歌（t|a 重复两次）")
        c.equal(all.uniqueArtists, 4, "全部四位艺人")
        c.equal(all.activeDays, 5, "全部五个活跃日")
        c.equal(all.topSongs.count, 4, "全部 <= 5 条时全给")

        // 空数据不能崩，结构必须完整
        let empty = PlaybackStats.summary(events: [], range: .all, now: now, calendar: calendar)
        c.expect(empty.isEmpty, "空事件 → 空汇总")
        c.equal(empty.hourlyCounts.count, 24, "空汇总仍给满 24 个小时桶")
        c.equal(empty.monthlyCounts.count, 12, "空汇总仍给满 12 个月桶")
        c.equal(empty.topSongs, [], "空汇总没有 Top 榜")

        // MARK: 年度报告 2026

        let recap2026 = PlaybackStats.yearlyRecap(events: events, year: 2026, calendar: calendar)
        c.equal(recap2026.year, 2026, "报告年份")
        c.equal(recap2026.totalPlays, 4, "2026 年播放次数")
        c.equal(recap2026.activeDays, 3, "2026 年活跃天数")
        c.equal(recap2026.uniqueTracks, 3, "2026 年不同曲目")
        c.equal(recap2026.uniqueArtists, 3, "2026 年不同艺人")
        c.equal(recap2026.firstTrack?.contentKey, "t|a", "首曲按开始时间取最早的一条（乱序输入也要对）")
        c.equal(recap2026.firstTrack?.title, "曲目甲", "首曲标题")
        c.equal(recap2026.monthlyCounts[0], 3, "1 月三次")
        c.equal(recap2026.monthlyCounts[2], 1, "3 月一次")
        c.equal(recap2026.peakHour, 23, "最常时段 23 点（两次）")
        c.equal(recap2026.longestStreak, 2, "最长连续 2 天（1/5、1/6）")
        c.equal(recap2026.topArtists.first?.name, "艺人甲", "Top 艺人")
        c.equal(recap2026.topSongs.first?.plays, 2, "Top 歌曲次数")
        c.equal(recap2026.topSongs.count, 3, "年度报告 Top 榜取 3 条")

        // 四维人格的确定性（固定数据 → 固定结果）
        c.equal(recap2026.persona.dayNight, .night, "23 点 → 深夜型")
        c.equal(recap2026.persona.exploration, .explorer, "3 首 / 4 次 ≥ 50% → 探索者")
        c.equal(recap2026.persona.trend, .newSeeker, "2026 年首次听到的歌 → 追新族")
        c.equal(recap2026.persona.taste, .omnivore, "3 位艺人 / 4 次 ≥ 25% → 杂食型")
        c.equal(recap2026.persona.title, "夜色漫游者", "人格标题固定映射")

        // MARK: 年度报告 2025（老歌判定）

        let recap2025 = PlaybackStats.yearlyRecap(events: events, year: 2025, calendar: calendar)
        c.equal(recap2025.totalPlays, 1, "2025 年一次")
        c.equal(recap2025.uniqueTracks, 1, "2025 年一首")
        c.equal(recap2025.firstTrack?.contentKey, "t|d", "2025 年首曲")
        c.equal(recap2025.persona.trend, .nostalgic, "2024 年就听过的歌 → 怀旧派")
        c.equal(recap2025.persona.dayNight, .dusk, "20 点 → 黄昏型")
        c.equal(recap2025.persona.title, "黄昏拾音人", "黄昏 + 探索 → 人格标题")

        // 没有数据的年份：报告是空的，但字段齐全
        let recapEmpty = PlaybackStats.yearlyRecap(events: events, year: 2020, calendar: calendar)
        c.expect(recapEmpty.isEmpty, "没有数据的年份 → 空报告")
        c.equal(recapEmpty.persona.title, "午后漫游者", "空报告的人格回落到中性默认值")
        c.equal(PlaybackStats.latestYear(in: events, calendar: calendar), 2026, "最近有记录的年份")

        // MARK: 断点：连续天数 / 最常时段 / 人格阈值

        c.equal(
            PlaybackStats.longestStreak(
                days: [date(2026, 1, 5), date(2026, 1, 6), date(2026, 3, 10)],
                calendar: calendar
            ),
            2,
            "跨月断开只算 2 天"
        )
        c.equal(
            PlaybackStats.longestStreak(days: [], calendar: calendar),
            0,
            "没有活跃日 → 0"
        )
        c.equal(PlaybackStats.peakHour(Array(repeating: 0, count: 24)), nil, "全零没有峰值")
        var tieHours = Array(repeating: 0, count: 24)
        tieHours[2] = 5
        tieHours[18] = 5
        c.equal(PlaybackStats.peakHour(tieHours), 2, "峰值并列取更早的小时")

        let morning = RecapPersona.make(
            totalPlays: 10,
            uniqueTracks: 4,
            uniqueArtists: 1,
            peakHour: 8,
            newTrackRatio: 0.9
        )
        c.equal(morning.dayNight, .morning, "8 点 → 晨间型")
        c.equal(morning.exploration, .specialist, "4 首 / 10 次 < 50% → 专精者")
        c.equal(morning.trend, .newSeeker, "新歌占比 90% → 追新族")
        c.equal(morning.taste, .focused, "1 位艺人 / 10 次 < 25% → 专注型")
        c.equal(morning.title, "晨间守候者", "晨间 + 专精 → 人格标题")

        // MARK: 保留策略（prune）

        c.equal(PlaybackStats.retentionMonths, 24, "保留 24 个月")
        c.equal(PlaybackStats.maxEvents, 20_000, "事件上限 2 万条")

        let prunedByAge = PlaybackStats.pruned(
            events: events,
            now: date(2026, 7, 1),
            months: 24,
            calendar: calendar
        )
        c.equal(prunedByAge.count, 5, "超过 24 个月的 2024 年事件被裁掉")
        c.equal(prunedByAge.first?.startedAt, date(2025, 12, 31, 20, 0), "裁剪后仍按时间升序")
        c.expect(
            !prunedByAge.contains { $0.startedAt == date(2024, 6, 1, 20, 0) },
            "过期事件真的没了"
        )

        let prunedByLimit = PlaybackStats.pruned(
            events: events,
            now: date(2026, 1, 7),
            months: 24,
            limit: 3,
            calendar: calendar
        )
        c.equal(prunedByLimit.count, 3, "超上限只保留最新 3 条")
        c.equal(prunedByLimit.first?.contentKey, "t|b", "保留的是最新的三条（旧数据先走）")
        c.equal(prunedByLimit.last?.contentKey, "t|c", "最新一条是最后一次播放")

        // MARK: 进度夹取

        c.near(PlaybackStats.clamped(300, duration: 200), 200, "进度夹到时长上限")
        c.near(PlaybackStats.clamped(-5, duration: 200), 0, "负数进度 → 0")
        c.near(PlaybackStats.clamped(100, duration: 0), 100, "时长未知时只夹下界")
        c.near(PlaybackStats.clamped(.nan, duration: 200), 0, "NaN 进度 → 0（否则累计时长会变成 NaN）")
    }
}
