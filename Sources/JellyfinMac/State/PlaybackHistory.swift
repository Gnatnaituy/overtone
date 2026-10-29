import Foundation
import CryptoKit
import AppKit

// MARK: - 播放事件

/// 一次播放事件 —— 听歌统计与年度报告的**最小事实单元**。
///
/// 为什么记「事件流」而不是记计数器：
/// - 热力图按**天**、时段分布按**小时**、年度报告按**自然月 + 人格四维**都要时间轴；
/// - 聚合成本放在读取侧（`PlaybackStats`），写入侧只追加一条，
///   新增一个统计维度不需要改存储格式。
///
/// `contentKey` 用 `MediaItem.contentKey`（与后端无关的内容身份，见 `ContentIdentity`）：
/// 同一首歌在 Jellyfin 与飞牛各播一次，统计里算同一首歌。
struct ListeningEvent: Codable, Hashable, Sendable {
    /// 开始播放的时刻
    var startedAt: Date
    /// 与后端无关的内容身份（`MediaItem.contentKey`）
    var contentKey: String
    var title: String
    var artistName: String?
    var albumTitle: String?
    var albumID: String?
    var artistID: String?
    /// 曲目总时长（秒；0 = 后端没给，未知）
    var duration: Double
    /// 本次实际听的秒数（进度最大值，夹到 `duration`）
    var listenedSeconds: Double
    /// 是否听完（自然播放到结尾）
    var completed: Bool

    init(
        startedAt: Date,
        contentKey: String,
        title: String,
        artistName: String? = nil,
        albumTitle: String? = nil,
        albumID: String? = nil,
        artistID: String? = nil,
        duration: Double = 0,
        listenedSeconds: Double = 0,
        completed: Bool = false
    ) {
        self.startedAt = startedAt
        self.contentKey = contentKey
        self.title = title
        self.artistName = artistName
        self.albumTitle = albumTitle
        self.albumID = albumID
        self.artistID = artistID
        self.duration = duration
        self.listenedSeconds = listenedSeconds
        self.completed = completed
    }

    /// 展示用艺人名（空 → 未知艺人）
    var artistDisplay: String { Self.display(artistName, fallback: "未知艺人") }
    /// 展示用专辑名（空 → 未知专辑）
    var albumDisplay: String { Self.display(albumTitle, fallback: "未知专辑") }

    fileprivate static func display(_ raw: String?, fallback: String) -> String {
        let trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

// MARK: - 落盘文件（版本化信封）

/// 播放历史文件信封。
///
/// 带 `version` 是为了以后加维度（例如把「跳过」也记一条）时能识别旧文件；
/// 读取侧对**更高版本**只告警、尽力按已知字段读（与 `LocalLibraryState` 同一策略）。
struct PlaybackHistoryFile: Codable, Sendable {
    var version: Int
    /// 账号指纹（sha256 前 16 位），只作诊断校验
    var profileHash: String
    var events: [ListeningEvent]

    init(profileHash: String, events: [ListeningEvent]) {
        self.version = PlaybackHistoryPersistence.schemaVersion
        self.profileHash = profileHash
        self.events = events
    }
}

// MARK: - 纯逻辑：时间范围

/// 统计时间范围（分段控件四档）。
enum PlaybackStatsRange: String, CaseIterable, Identifiable, Sendable {
    case week
    case month
    case year
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .week: return "近 7 天"
        case .month: return "近 30 天"
        case .year: return "近一年"
        case .all: return "全部"
        }
    }

    /// 范围下界（含）；`nil` 表示不限（全部）。
    ///
    /// 口径是「**今天往前数**的滚动窗口」，而不是「本周 / 本月 / 本年」：
    /// 周一的「本周」只剩一天，会让人误以为统计坏了；滚动窗口永远有 7 / 30 / 365 天。
    func startDate(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .week:
            return calendar.date(byAdding: .day, value: -6, to: today)
        case .month:
            return calendar.date(byAdding: .day, value: -29, to: today)
        case .year:
            return calendar.date(byAdding: .year, value: -1, to: today)
        case .all:
            return nil
        }
    }
}

// MARK: - 纯逻辑：聚合结果

/// Top 榜的一条（歌曲 / 艺人 / 专辑共用）。
///
/// `key` 是分组键（歌曲 = contentKey；艺人 / 专辑 = 归一化名称），`name` 是展示名。
struct PlaybackStatEntry: Identifiable, Hashable, Sendable {
    let key: String
    var name: String
    var subtitle: String?
    /// 播放次数
    var plays: Int
    /// 累计收听秒数
    var seconds: Double
    /// 该分组下出现过的不同曲目数（艺人和专辑用它显示「N 首」）
    var uniqueTracks: Int

    var id: String { key }
}

/// 一个时间范围的统计汇总（`PlaybackStats.summary` 的返回值）。
struct PlaybackStatsSummary: Equatable, Sendable {
    var range: PlaybackStatsRange
    var totalPlays: Int = 0
    var totalSeconds: Double = 0
    /// 有播放记录的天数
    var activeDays: Int = 0
    var uniqueTracks: Int = 0
    var uniqueArtists: Int = 0
    var uniqueAlbums: Int = 0
    /// Top 榜（按播放次数降序，同次数按累计时长，再按 key 字典序 —— 结果确定）
    var topSongs: [PlaybackStatEntry] = []
    var topArtists: [PlaybackStatEntry] = []
    var topAlbums: [PlaybackStatEntry] = []
    /// 每天播放次数（键 = `calendar.startOfDay`；没有播放的天不出现）
    var dailyCounts: [Date: Int] = [:]
    /// 24 个小时桶
    var hourlyCounts: [Int] = Array(repeating: 0, count: 24)
    /// 12 个自然月桶（下标 = 月份 - 1）
    var monthlyCounts: [Int] = Array(repeating: 0, count: 12)
    var firstPlayedAt: Date?
    var lastPlayedAt: Date?

    var isEmpty: Bool { totalPlays == 0 }

    static func empty(range: PlaybackStatsRange) -> PlaybackStatsSummary {
        PlaybackStatsSummary(range: range)
    }

    /// 某一天的播放次数（没有记录 = 0），热力图按它取色。
    func playCount(on day: Date, calendar: Calendar = .current) -> Int {
        dailyCounts[calendar.startOfDay(for: day)] ?? 0
    }
}

// MARK: - 纯逻辑：年度人格

/// 年度报告的四维人格。
///
/// 四个维度全部由**事件本身**决定（不掺随机数、不掺当前时间），
/// 因此同一年的数据永远得到同一份报告 —— 自检可以直接断言。
struct RecapPersona: Equatable, Sendable {
    /// 昼夜：按最常收听时段分四档
    enum DayNight: String, Sendable {
        case morning = "晨间型"
        case afternoon = "午后型"
        case dusk = "黄昏型"
        case night = "深夜型"
    }

    /// 探索 vs 专精：不同曲目 / 播放次数
    enum Exploration: String, Sendable {
        case explorer = "探索者"
        case specialist = "专精者"
    }

    /// 新歌 vs 老歌：本年之前从未听过的曲目占比
    enum Trend: String, Sendable {
        case newSeeker = "追新族"
        case nostalgic = "怀旧派"
    }

    /// 杂食 vs 专注：不同艺人 / 播放次数
    enum Taste: String, Sendable {
        case omnivore = "杂食型"
        case focused = "专注型"
    }

    var dayNight: DayNight
    var exploration: Exploration
    var trend: Trend
    var taste: Taste

    /// 人格标题（昼夜 × 探索 两维决定，共 8 种，固定映射）
    var title: String {
        switch (dayNight, exploration) {
        case (.morning, .explorer): return "清晨探索家"
        case (.morning, .specialist): return "晨间守候者"
        case (.afternoon, .explorer): return "午后漫游者"
        case (.afternoon, .specialist): return "午后专注者"
        case (.dusk, .explorer): return "黄昏拾音人"
        case (.dusk, .specialist): return "黄昏收藏家"
        case (.night, .explorer): return "夜色漫游者"
        case (.night, .specialist): return "深夜单曲循环者"
        }
    }

    /// UI 用：四维的（标题，取值）列表，顺序固定
    var dimensions: [(title: String, value: String)] {
        [
            ("昼夜节律", dayNight.rawValue),
            ("探索偏好", exploration.rawValue),
            ("追新程度", trend.rawValue),
            ("口味广度", taste.rawValue),
        ]
    }

    /// 由聚合指标推导四维人格（纯函数）。
    ///
    /// 阈值全部写在函数里并配注释：自检断言的是这些阈值的行为，改阈值必须同步改断言。
    static func make(
        totalPlays: Int,
        uniqueTracks: Int,
        uniqueArtists: Int,
        peakHour: Int?,
        newTrackRatio: Double
    ) -> RecapPersona {
        // 昼夜：6–10 晨间 / 11–16 午后 / 17–21 黄昏 / 其余（22–5）深夜
        let dayNight: DayNight
        switch peakHour ?? 12 {
        case 6..<11: dayNight = .morning
        case 11..<17: dayNight = .afternoon
        case 17..<22: dayNight = .dusk
        default: dayNight = .night
        }

        // 探索–专精：播放里有多少是「不同的歌」；≥ 50% 视为探索者
        let exploreRatio = totalPlays > 0 ? Double(uniqueTracks) / Double(totalPlays) : 1
        let exploration: Exploration = exploreRatio >= 0.5 ? .explorer : .specialist

        // 新歌–老歌：本年首次听到的曲目占比；≥ 50% 视为追新族
        let trend: Trend = newTrackRatio >= 0.5 ? .newSeeker : .nostalgic

        // 杂食–专注：播放里有多少是「不同的艺人」；≥ 25% 视为杂食型
        let tasteRatio = totalPlays > 0 ? Double(uniqueArtists) / Double(totalPlays) : 1
        let taste: Taste = tasteRatio >= 0.25 ? .omnivore : .focused

        return RecapPersona(dayNight: dayNight, exploration: exploration, trend: trend, taste: taste)
    }
}

/// 年度报告（`PlaybackStats.yearlyRecap` 的返回值）。
struct YearlyRecap: Equatable, Sendable {
    var year: Int
    var totalPlays: Int = 0
    var totalSeconds: Double = 0
    var activeDays: Int = 0
    var uniqueTracks: Int = 0
    var uniqueArtists: Int = 0
    var uniqueAlbums: Int = 0
    /// 该年第一首歌（按开始时间）
    var firstTrack: ListeningEvent?
    /// Top 3
    var topSongs: [PlaybackStatEntry] = []
    var topArtists: [PlaybackStatEntry] = []
    var topAlbums: [PlaybackStatEntry] = []
    /// 月份分布（12 桶）
    var monthlyCounts: [Int] = Array(repeating: 0, count: 12)
    /// 小时分布（24 桶）
    var hourlyCounts: [Int] = Array(repeating: 0, count: 24)
    /// 最常收听的小时（并列取更早的小时；没有数据为 nil）
    var peakHour: Int?
    /// 最长连续收听天数
    var longestStreak: Int = 0
    var persona: RecapPersona

    var isEmpty: Bool { totalPlays == 0 }

    static func empty(year: Int) -> YearlyRecap {
        YearlyRecap(year: year, persona: .make(
            totalPlays: 0,
            uniqueTracks: 0,
            uniqueArtists: 0,
            peakHour: nil,
            newTrackRatio: 1
        ))
    }
}

// MARK: - 纯逻辑：聚合入口

/// 听歌统计的**纯函数**聚合层。
///
/// 与存储完全解耦：输入 `[ListeningEvent]` + 时间 + 日历，输出值类型结果。
/// 自检（`SelfTest+Stats.swift`）直接断言这一层，不碰磁盘、不碰 `@MainActor`。
enum PlaybackStats {
    /// 概览页 Top 榜的条数
    static let summaryTopLimit = 5
    /// 年度报告的 Top 榜条数
    static let recapTopLimit = 3
    /// 保留月数（与 `PlaybackHistoryStore.retentionMonths` 同源）
    static let retentionMonths = 24
    /// 事件条数上限
    static let maxEvents = 20_000

    // MARK: 范围过滤

    /// 按范围取出事件，并**按开始时间升序**排列。
    ///
    /// 升序是后面所有聚合的确定性前提：分组取「最近一次的展示名」、
    /// 首曲取 `first`、连续天数扫描都依赖顺序。
    static func scopedEvents(
        _ events: [ListeningEvent],
        range: PlaybackStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ListeningEvent] {
        let start = range.startDate(now: now, calendar: calendar)
        // 有下界（周 / 月 / 年）时上界也要卡：系统时钟回拨或测试夹具写进来的「未来事件」
        // 只按 lowerBound 过滤会混进「近 7 天」，把热力图和 Top 榜整体带偏。
        // 「全部」保持字面语义 —— 展示历史里的所有记录，不被 now 截断。
        let filtered: [ListeningEvent]
        if let start {
            filtered = events.filter { $0.startedAt >= start && $0.startedAt <= now }
        } else {
            filtered = events
        }
        return filtered.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.contentKey < rhs.contentKey
        }
    }

    // MARK: 汇总

    static func summary(
        events: [ListeningEvent],
        range: PlaybackStatsRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PlaybackStatsSummary {
        let scoped = scopedEvents(events, range: range, now: now, calendar: calendar)
        var summary = PlaybackStatsSummary.empty(range: range)
        guard !scoped.isEmpty else { return summary }

        summary.totalPlays = scoped.count
        summary.totalSeconds = scoped.reduce(0) { $0 + max($1.listenedSeconds, 0) }
        summary.firstPlayedAt = scoped.first?.startedAt
        summary.lastPlayedAt = scoped.last?.startedAt

        var days: Set<Date> = []
        var songs: Set<String> = []
        var artists: Set<String> = []
        var albums: Set<String> = []
        days.reserveCapacity(scoped.count)
        songs.reserveCapacity(scoped.count)

        for event in scoped {
            let day = calendar.startOfDay(for: event.startedAt)
            days.insert(day)
            summary.dailyCounts[day, default: 0] += 1

            let hour = calendar.component(.hour, from: event.startedAt)
            if summary.hourlyCounts.indices.contains(hour) {
                summary.hourlyCounts[hour] += 1
            }
            let month = calendar.component(.month, from: event.startedAt) - 1
            if summary.monthlyCounts.indices.contains(month) {
                summary.monthlyCounts[month] += 1
            }

            songs.insert(songKey(event))
            artists.insert(artistKey(event))
            albums.insert(albumKey(event))
        }

        summary.activeDays = days.count
        summary.uniqueTracks = songs.count
        summary.uniqueArtists = artists.count
        summary.uniqueAlbums = albums.count
        summary.topSongs = topSongs(scoped, limit: summaryTopLimit)
        summary.topArtists = topArtists(scoped, limit: summaryTopLimit)
        summary.topAlbums = topAlbums(scoped, limit: summaryTopLimit)
        return summary
    }

    // MARK: 年度报告

    /// 某一天的播放次数（范围外为 0）
    static func playCount(
        events: [ListeningEvent],
        day: Date,
        calendar: Calendar = .current
    ) -> Int {
        let target = calendar.startOfDay(for: day)
        return events.reduce(0) { partial, event in
            calendar.isDate(event.startedAt, inSameDayAs: target) ? partial + 1 : partial
        }
    }

    /// 最近有播放记录的年份（没有数据时为 nil）。
    ///
    /// 年度报告用它决定默认年份：年末年初时「今年」可能还没几首歌，
    /// 而去年那份报告更有意义；只有完全没数据时才回落到当前年。
    static func latestYear(in events: [ListeningEvent], calendar: Calendar = .current) -> Int? {
        events.map { calendar.component(.year, from: $0.startedAt) }.max()
    }

    static func yearlyRecap(
        events: [ListeningEvent],
        year: Int,
        calendar: Calendar = .current
    ) -> YearlyRecap {
        let sorted = events.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.contentKey < rhs.contentKey
        }

        // 用自然年的边界过滤，而不是 `component(.year)` 逐个比较（后者每次都要建 components）
        let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1))
        let end = calendar.date(from: DateComponents(year: year + 1, month: 1, day: 1))
        let scoped = sorted.filter { event in
            if let start, event.startedAt < start { return false }
            if let end, event.startedAt >= end { return false }
            return true
        }

        var recap = YearlyRecap.empty(year: year)
        guard !scoped.isEmpty else { return recap }

        recap.totalPlays = scoped.count
        recap.totalSeconds = scoped.reduce(0) { $0 + max($1.listenedSeconds, 0) }
        recap.firstTrack = scoped.first

        var days: Set<Date> = []
        var songs: Set<String> = []
        var artists: Set<String> = []
        var albums: Set<String> = []

        for event in scoped {
            let day = calendar.startOfDay(for: event.startedAt)
            days.insert(day)
            let hour = calendar.component(.hour, from: event.startedAt)
            if recap.hourlyCounts.indices.contains(hour) {
                recap.hourlyCounts[hour] += 1
            }
            let month = calendar.component(.month, from: event.startedAt) - 1
            if recap.monthlyCounts.indices.contains(month) {
                recap.monthlyCounts[month] += 1
            }
            songs.insert(songKey(event))
            artists.insert(artistKey(event))
            albums.insert(albumKey(event))
        }

        recap.activeDays = days.count
        recap.uniqueTracks = songs.count
        recap.uniqueArtists = artists.count
        recap.uniqueAlbums = albums.count
        recap.topSongs = topSongs(scoped, limit: recapTopLimit)
        recap.topArtists = topArtists(scoped, limit: recapTopLimit)
        recap.topAlbums = topAlbums(scoped, limit: recapTopLimit)
        recap.peakHour = peakHour(recap.hourlyCounts)
        recap.longestStreak = longestStreak(days: days, calendar: calendar)

        // 新歌 vs 老歌：需要**全部历史**才能判断「本年之前是否听过」
        var firstSeen: [String: Date] = [:]
        for event in sorted where firstSeen[event.contentKey] == nil {
            firstSeen[event.contentKey] = event.startedAt
        }
        var newTracks = 0
        for key in songs {
            guard let first = firstSeen[key] else { continue }
            if calendar.component(.year, from: first) == year { newTracks += 1 }
        }
        let newTrackRatio = songs.isEmpty ? 1 : Double(newTracks) / Double(songs.count)

        recap.persona = .make(
            totalPlays: recap.totalPlays,
            uniqueTracks: recap.uniqueTracks,
            uniqueArtists: recap.uniqueArtists,
            peakHour: recap.peakHour,
            newTrackRatio: newTrackRatio
        )
        return recap
    }

    // MARK: 保留策略

    /// 保留最近 `months` 个月、最多 `limit` 条（**返回升序**）。
    ///
    /// 两条规则同时生效：先按时间下界裁掉过期事件，再在超限时保留**最新**的
    /// `limit` 条（`removeFirst` 而不是 `removeLast`：旧数据先走）。
    static func pruned(
        events: [ListeningEvent],
        now: Date = Date(),
        months: Int = retentionMonths,
        limit: Int = maxEvents,
        calendar: Calendar = .current
    ) -> [ListeningEvent] {
        let cutoff = calendar.date(byAdding: .month, value: -max(months, 0), to: now)
        var kept = cutoff.map { lowerBound in
            events.filter { $0.startedAt >= lowerBound }
        } ?? events

        kept.sort { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.contentKey < rhs.contentKey
        }
        if kept.count > max(limit, 0) {
            kept.removeFirst(kept.count - max(limit, 0))
        }
        return kept
    }

    // MARK: 内部：分组键

    /// 歌曲分组键：内容身份（同一首歌跨后端只算一首）
    fileprivate static func songKey(_ event: ListeningEvent) -> String {
        let key = event.contentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? "track|\(ContentIdentity.normalize(event.title))" : key
    }

    /// 艺人分组键：归一化艺名（"周杰伦"/"周杰倫 " 这类差异合并）
    fileprivate static func artistKey(_ event: ListeningEvent) -> String {
        let normalized = ContentIdentity.normalize(event.artistDisplay)
        return normalized.isEmpty ? "artist|unknown" : "artist|\(normalized)"
    }

    fileprivate static func albumKey(_ event: ListeningEvent) -> String {
        let normalized = ContentIdentity.normalize(event.albumDisplay)
        return normalized.isEmpty ? "album|unknown" : "album|\(normalized)"
    }

    // MARK: 内部：Top 榜

    fileprivate static func topSongs(_ scoped: [ListeningEvent], limit: Int) -> [PlaybackStatEntry] {
        entries(
            scoped,
            limit: limit,
            key: songKey,
            name: { $0.title },
            subtitle: { $0.artistDisplay }
        )
    }

    fileprivate static func topArtists(_ scoped: [ListeningEvent], limit: Int) -> [PlaybackStatEntry] {
        entries(
            scoped,
            limit: limit,
            key: artistKey,
            name: { $0.artistDisplay },
            subtitle: { _ in nil }
        )
    }

    fileprivate static func topAlbums(_ scoped: [ListeningEvent], limit: Int) -> [PlaybackStatEntry] {
        entries(
            scoped,
            limit: limit,
            key: albumKey,
            name: { $0.albumDisplay },
            subtitle: { $0.artistDisplay }
        )
    }

    /// 通用分组聚合 + 排序 + 截断。
    ///
    /// 排序是**完全确定**的：次数降序 → 秒数降序 → 键字典序。
    private static func entries(
        _ scoped: [ListeningEvent],
        limit: Int,
        key: (ListeningEvent) -> String,
        name: (ListeningEvent) -> String?,
        subtitle: (ListeningEvent) -> String?
    ) -> [PlaybackStatEntry] {
        guard limit > 0, !scoped.isEmpty else { return [] }

        var order: [String] = []
        var buckets: [String: PlaybackStatEntry] = [:]
        var trackSets: [String: Set<String>] = [:]

        for event in scoped {
            let bucketKey = key(event)
            guard !bucketKey.isEmpty else { continue }

            var entry = buckets[bucketKey] ?? PlaybackStatEntry(
                key: bucketKey,
                name: name(event) ?? bucketKey,
                subtitle: subtitle(event),
                plays: 0,
                seconds: 0,
                uniqueTracks: 0
            )
            if buckets[bucketKey] == nil {
                order.append(bucketKey)
            }
            entry.plays += 1
            entry.seconds += max(event.listenedSeconds, 0)
            // 展示名 / 副标题取**最近一次**出现的写法（scoped 已按时间升序）
            if let freshName = name(event), !freshName.isEmpty {
                entry.name = freshName
            }
            if let freshSubtitle = subtitle(event), !freshSubtitle.isEmpty {
                entry.subtitle = freshSubtitle
            }
            buckets[bucketKey] = entry
            trackSets[bucketKey, default: []].insert(event.contentKey)
        }

        var result: [PlaybackStatEntry] = []
        result.reserveCapacity(min(limit, order.count))
        for bucketKey in order {
            guard var entry = buckets[bucketKey] else { continue }
            entry.uniqueTracks = trackSets[bucketKey]?.count ?? 0
            result.append(entry)
        }
        result.sort { lhs, rhs in
            if lhs.plays != rhs.plays { return lhs.plays > rhs.plays }
            if lhs.seconds != rhs.seconds { return lhs.seconds > rhs.seconds }
            return lhs.key < rhs.key
        }
        return Array(result.prefix(limit))
    }

    // MARK: 内部：时段 / 连续天数

    /// 最常收听的小时（并列取更早的小时；全零返回 nil）
    static func peakHour(_ hourlyCounts: [Int]) -> Int? {
        var best: Int?
        var bestCount = 0
        for (hour, count) in hourlyCounts.enumerated() where count > bestCount {
            best = hour
            bestCount = count
        }
        return best
    }

    /// 最长连续天数（输入是天集合，允许乱序）
    static func longestStreak(days: Set<Date>, calendar: Calendar = .current) -> Int {
        guard !days.isEmpty else { return 0 }
        var best = 1
        var current = 1
        var previous: Date?
        for day in days.sorted() {
            if let previous,
               let next = calendar.date(byAdding: .day, value: 1, to: previous),
               calendar.isDate(next, inSameDayAs: day) {
                current += 1
            } else {
                current = 1
            }
            best = max(best, current)
            previous = day
        }
        return best
    }

    /// 进度夹到 `[0, duration]`；`duration` 未知（0）时只夹下界。
    ///
    /// 非有限值 / 负数一律当 0：AVPlayer 在换曲瞬间偶尔会给出 NaN，
    /// 一个 NaN 混进事件会让「累计收听时长」永久变成 NaN。
    static func clamped(_ position: Double, duration: Double) -> Double {
        guard position.isFinite, position > 0 else { return 0 }
        guard duration > 0 else { return position }
        return min(position, duration)
    }
}

// MARK: - 落盘

/// 播放历史的磁盘层：`Application Support/JellyfinMac/playback-history/profile-<sha256 前 16 位>.json`
///
/// 为什么按账号分文件：统计是「个人」数据，同机多账号（家庭共享）不能互相污染。
/// 文件名只用账号 key 的 sha256 前 16 位 —— 与 `LocalLibraryState` 同一约定：
/// 文件名会出现在崩溃日志 / 截图 / 备份工具里，没必要暴露用户名。
///
/// 本枚举全部是 `nonisolated static`：编码 + 写盘发生在后台线程池，不占主线程。
enum PlaybackHistoryPersistence {
    /// 当前文件格式版本
    static let schemaVersion = 1

    /// `Application Support/JellyfinMac/playback-history/`
    ///
    /// 只解析一次：`FileManager.urls(for:in:)` 每次都会走系统目录查询。
    static let directoryURL: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("JellyfinMac", isDirectory: true)
            .appendingPathComponent("playback-history", isDirectory: true)
    }()

    /// 解码器（只在读取路径用；`Date` 与写入侧同为 ISO8601）
    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// 账号 key → 文件名指纹（sha256 前 16 个 hex 字符）
    static func profileHash(_ profileKey: String) -> String {
        let digest = SHA256.hash(data: Data(profileKey.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func fileURL(profileHash: String) -> URL {
        directoryURL.appendingPathComponent("profile-\(profileHash).json", isDirectory: false)
    }

    /// 读一个账号的历史（文件不存在 / 解码失败 → 空数组，不崩、不删文件）。
    ///
    /// 读取时顺带套一次保留策略：超过 24 个月或 2 万条的旧文件在下次写盘时被收敛，
    /// 不必等用户再听一首歌。
    static func read(profileKey: String) -> [ListeningEvent] {
        let url = fileURL(profileHash: profileHash(profileKey))
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            let file = try decoder.decode(PlaybackHistoryFile.self, from: data)
            if file.version > schemaVersion {
                print("[PlaybackHistory] \(url.lastPathComponent) 版本 \(file.version) 高于当前 \(schemaVersion)，按已知字段尽力读取")
            }
            return PlaybackStats.pruned(events: file.events)
        } catch {
            print("[PlaybackHistory] 读取失败，按空历史处理 \(url.lastPathComponent): \(error)")
            return []
        }
    }

    /// 同步写（调用方保证不在主线程，或只在退出流程里作为最后一笔写盘）。
    static func performWrite(_ events: [ListeningEvent], profileHash: String) {
        let url = fileURL(profileHash: profileHash)
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let file = PlaybackHistoryFile(profileHash: profileHash, events: events)
            let data = try encoder.encode(file)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[PlaybackHistory] 写入失败 \(url.lastPathComponent): \(error)")
        }
    }

    /// 删文件（`clear` 用；文件不存在不算错）
    static func removeFile(profileHash: String) {
        let url = fileURL(profileHash: profileHash)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            print("[PlaybackHistory] 删除失败 \(url.lastPathComponent): \(error)")
        }
    }
}

// MARK: - 播放历史仓库

/// 播放历史仓库：把播放器的「开始 / 进度 / 结束」变成事件流，并负责落盘。
///
/// 接线方式（`MusicDataStore.note*` 里调用，本文件不反向依赖播放器）：
/// ```
/// noteStarted(item)              // 开始播放：收尾上一条 + 开一条新的
/// noteProgress(item, position:)  // 进度：取 max(position)，夹到 duration
/// noteFinished(item)             // 播完：completed + listened = duration
/// finalizePending()              // 暂停 / 停止 / 换曲：收尾当前这条
/// ```
///
/// 线程模型：
/// - 内存态全在 `@MainActor`（与状态层同一个 actor，读写不加锁）；
/// - 编码 + 写盘在 `PlaybackHistoryPersistence.performWrite`（后台线程池）；
/// - 写盘有 600ms 合并窗口：进度回调不写盘，只有「事件收尾」才写；
/// - `NSApplication.willTerminateNotification` 里同步收尾 + 同步写盘，退出不丢最后一笔。
@MainActor
final class PlaybackHistoryStore: NSObject, ObservableObject {
    static let shared = PlaybackHistoryStore()

    /// 已结束的播放事件（按 `startedAt` 升序；热力图 / 汇总的输入）
    @Published private(set) var events: [ListeningEvent] = []

    /// 当前已加载的账号（`AppState.profileKey`）；nil = 还没加载过
    private(set) var loadedProfileKey: String?

    /// 正在累积的这一条（`noteStarted` 建立，进度只改内存，收尾时才进 `events`）
    private var pending: ListeningEvent?
    private var debounceTask: Task<Void, Never>?
    /// 有尚未写盘的变化
    private var needsFlush = false
    private var lastPruneAt = Date.distantPast

    /// 保留 24 个月
    static let retentionMonths = PlaybackStats.retentionMonths
    /// 上限 2 万条
    static let maxEvents = PlaybackStats.maxEvents
    /// 写盘合并窗口（秒）
    private static let debounceNanoseconds: UInt64 = 600_000_000
    /// 少于这个秒数且没听完的「划过」不进历史，避免快速切歌把热力图刷满
    static let minimumListenedSeconds: Double = 1

    private override init() {
        super.init()
        // 退出前必须自己收尾 + 写盘：`applicationWillTerminate` 里别人不一定记得调我们
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillTerminate(_:)),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    // MARK: - 对外 API（播放器接线用）

    /// 开始播放一首歌：先把上一条收尾（切歌很快时也不丢），再开一条新的。
    func noteStarted(_ item: MediaItem) {
        loadProfileIfNeeded()
        finalizePending()
        pending = ListeningEvent(
            startedAt: Date(),
            contentKey: item.contentKey,
            title: item.title,
            artistName: item.artistName,
            albumTitle: item.albumTitle,
            albumID: item.albumID,
            artistID: item.artistID,
            duration: max(item.duration, 0),
            listenedSeconds: 0,
            completed: false
        )
    }

    /// 进度回调：只把 `listenedSeconds` 抬到**当前最大值**（夹到 duration）。
    ///
    /// 为什么不在这里发布 / 写盘：进度每几秒来一次，逐次发布会让统计页每 5 秒重算一次
    /// 全量聚合；写盘更是磁盘写放大。收尾时一次性发布 + 合并写盘。
    func noteProgress(_ item: MediaItem, position: Double) {
        loadProfileIfNeeded()
        guard var current = pending, current.contentKey == item.contentKey else { return }
        let clamped = PlaybackStats.clamped(position, duration: current.duration)
        guard clamped > current.listenedSeconds else { return }
        current.listenedSeconds = clamped
        pending = current
    }

    /// 播完：`completed = true`，收听秒数补到整首时长。
    func noteFinished(_ item: MediaItem) {
        loadProfileIfNeeded()
        if var current = pending, current.contentKey == item.contentKey {
            current.completed = true
            let duration = max(current.duration, 0)
            if duration > 0 {
                current.listenedSeconds = max(current.listenedSeconds, duration)
            }
            pending = current
            finalizePending()
        } else {
            // 没有对应的开始事件（例如从队列外直接播完 / 上一次事件被账号切换清掉）：
            // 仍然记一条完整播放，宁可多记也不要丢
            let duration = max(item.duration, 0)
            let event = ListeningEvent(
                startedAt: Date(),
                contentKey: item.contentKey,
                title: item.title,
                artistName: item.artistName,
                albumTitle: item.albumTitle,
                albumID: item.albumID,
                artistID: item.artistID,
                duration: duration,
                listenedSeconds: duration,
                completed: true
            )
            finalize(event)
        }
    }

    /// 收尾当前事件（暂停 / 停止 / 换曲时调用；退出登录、退出 App 也会走到这里）。
    func finalizePending() {
        guard let event = pending else { return }
        pending = nil
        finalize(event)
    }

    /// 清空当前账号的播放历史（并删文件）。
    func clear() {
        loadProfileIfNeeded()
        pending = nil
        debounceTask?.cancel()
        debounceTask = nil
        needsFlush = false
        events = []
        if let key = loadedProfileKey {
            PlaybackHistoryPersistence.removeFile(
                profileHash: PlaybackHistoryPersistence.profileHash(key)
            )
        }
    }

    /// 确保已按当前账号加载（统计页 `onAppear` 调用；重复调用无副作用）。
    func reload() {
        guard loadedProfileKey != AppState.shared.profileKey else { return }
        loadedProfileKey = nil
        loadProfileIfNeeded()
    }

    /// 立即把排队的变化写盘（不等 debounce）。
    func flushNow() {
        debounceTask?.cancel()
        debounceTask = nil
        guard needsFlush, let key = loadedProfileKey else { return }
        needsFlush = false
        let snapshot = events
        let hash = PlaybackHistoryPersistence.profileHash(key)
        Task.detached(priority: .utility) {
            PlaybackHistoryPersistence.performWrite(snapshot, profileHash: hash)
        }
    }

    // MARK: - 内部

    /// 按当前账号懒加载：首次使用 / 切换账号 / 切换后端时加载对应文件。
    ///
    /// 切账号时先把上一个账号排队中的数据按**它自己的**指纹写盘，避免写到新账号名下。
    private func loadProfileIfNeeded() {
        let key = AppState.shared.profileKey
        guard key != loadedProfileKey else { return }

        if let previous = loadedProfileKey, needsFlush {
            debounceTask?.cancel()
            debounceTask = nil
            needsFlush = false
            let snapshot = events
            let hash = PlaybackHistoryPersistence.profileHash(previous)
            Task.detached(priority: .utility) {
                PlaybackHistoryPersistence.performWrite(snapshot, profileHash: hash)
            }
        }

        pending = nil
        loadedProfileKey = key
        events = PlaybackHistoryPersistence.read(profileKey: key)
        lastPruneAt = .distantPast
    }

    /// 把一条事件收尾进历史（带「划过不记」与保留策略）。
    private func finalize(_ event: ListeningEvent) {
        var event = event
        if event.completed, event.duration > 0 {
            event.listenedSeconds = event.duration
        }
        // 只记「真的听了」的事件：快速划过（< 1 秒且没听完）不写历史
        guard event.completed || event.listenedSeconds >= Self.minimumListenedSeconds else { return }

        events.append(event)
        pruneIfNeeded()
        scheduleFlush()
    }

    /// 保留策略：每小时最多跑一次（或超上限时立即跑），避免每首歌都全量排序
    private func pruneIfNeeded() {
        let now = Date()
        guard events.count > Self.maxEvents || now.timeIntervalSince(lastPruneAt) > 3600 else { return }
        lastPruneAt = now
        events = PlaybackStats.pruned(
            events: events,
            now: now,
            months: Self.retentionMonths,
            limit: Self.maxEvents
        )
    }

    /// 合并写盘：600ms 内多次收尾只写一次
    private func scheduleFlush() {
        needsFlush = true
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushNow()
        }
    }

    /// 退出流程：同步收尾 + 同步写盘（`willTerminate` 不会等异步任务）
    private func flushSynchronously() {
        debounceTask?.cancel()
        debounceTask = nil
        guard needsFlush, let key = loadedProfileKey else { return }
        needsFlush = false
        PlaybackHistoryPersistence.performWrite(
            events,
            profileHash: PlaybackHistoryPersistence.profileHash(key)
        )
    }

    @objc private func handleWillTerminate(_ notification: Notification) {
        finalizePending()
        flushSynchronously()
    }
}
