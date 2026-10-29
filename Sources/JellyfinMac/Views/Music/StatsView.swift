import SwiftUI

// MARK: - 听歌统计页

/// 听歌统计页（新）。
///
/// 结构：面包屑（从首页进来时）/ 顶栏 / 时间范围行 / 滚动内容。
/// 内容分四块：概览数字 → 收听热力图（Canvas 自绘）→ 时段分布 → Top 歌曲·艺人·专辑。
///
/// 双风格：
/// - 玻璃（v3）：白卡 + `e1` + `borderSubtle`，大数字走 `title2`；
/// - 纸墨（v4）：纸块 + 1px 细线、区块标题是印刷规则标签（`SectionHeader` 自动降级），
///   大数字走衬线（`paperSerifTitle`）——「红只属于声音」，热力图用墨的浓度表达密度。
///
/// 断点：概览 2×2（W0/W1）/ 4 列（W2+）；Top 榜纵向（W0/W1）/ 三列（W2+）。
struct StatsView: View {
    let sizeClass: LayoutSizeClass
    /// 从首页进来时的面包屑上级（MainView 传「首页」）
    var parentTitle: String?
    var onBack: (() -> Void)?

    @ObservedObject private var history = PlaybackHistoryStore.shared
    /// 只为「点 Top 歌曲 → 反查 MediaItem 播放」：统计本身不依赖媒体库是否加载
    @ObservedObject private var store = MusicDataStore.shared
    @Environment(\.appReduceMotion) private var reduceMotion

    @State private var range: PlaybackStatsRange = .month
    /// 聚合结果缓存：不在 `body` 里现算（事件上万条时一次排序就是几毫秒，而 body 会被
    /// 搜索框、窗口尺寸、播放状态反复触发）
    @State private var summary = PlaybackStatsSummary.empty(range: .month)
    @State private var showRecap = false
    /// 热力图实测宽度（Canvas 单元格尺寸随窗口自适应）
    @State private var heatmapWidth: CGFloat = 0
    @State private var appeared = false

    private var calendar: Calendar { .current }

    /// 年度报告默认年份：最近有记录的年份，没有数据时用当前年
    private var recapYear: Int {
        PlaybackStats.latestYear(in: history.events) ?? calendar.component(.year, from: Date())
    }

    private var rangeSelection: Binding<String> {
        Binding(
            get: { range.rawValue },
            set: { range = PlaybackStatsRange(rawValue: $0) ?? .month }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            if let parentTitle, let onBack {
                BreadcrumbBar(
                    sizeClass: sizeClass,
                    parentTitle: parentTitle,
                    onParent: onBack,
                    title: "听歌统计"
                )
            }

            PageTopBar(
                sizeClass: sizeClass,
                title: "听歌统计",
                subtitle: summary.isEmpty ? nil : "\(summary.totalPlays) 次播放"
            ) {
                EmptyView()
            }

            rangeBar

            ScrollView {
                PageContent(sizeClass: sizeClass) {
                    content
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
            // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
            .pageBodyWidthClamp()
        }
        .onAppear {
            history.reload()
            refreshSummary()
            withAnimation(reduceMotion ? nil : Theme.Motion.base) { appeared = true }
        }
        .onChange(of: range) { _ in refreshSummary() }
        .onChange(of: history.events) { _ in refreshSummary() }
        .sheet(isPresented: $showRecap) {
            YearlyRecapView(events: history.events, year: recapYear)
        }
    }

    // MARK: - 时间范围行（分段 + 年度报告入口）

    private var rangeBar: some View {
        HStack(spacing: Theme.Spacing.lg) {
            SegmentedControl(
                segments: PlaybackStatsRange.allCases.map { .init($0.rawValue, $0.title) },
                selection: rangeSelection
            )
            .accessibilityLabel("统计时间范围")

            Spacer(minLength: Theme.Spacing.md)

            Button {
                showRecap = true
            } label: {
                Label("年度报告", systemImage: "sparkles")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .disabled(history.events.isEmpty)
            .help("生成年度听歌报告")
            .accessibilityLabel("打开年度听歌报告")
        }
        .padding(.horizontal, sizeClass.pageMargin)
        .frame(height: 56)
    }

    // MARK: - 滚动内容

    @ViewBuilder
    private var content: some View {
        if history.events.isEmpty {
            EmptyState(
                systemImage: "chart.bar.xaxis",
                title: "还没有听歌数据",
                message: "播放几首歌之后，这里会出现收听热力图、时段分布与最常听的曲目"
            )
            .accessibilityLabel("还没有听歌数据")
        } else if summary.isEmpty {
            EmptyState(
                systemImage: "calendar",
                title: "这个时间范围还没有记录",
                message: "换一个时间范围看看，或者继续听歌"
            )
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                overviewSection
                heatmapSection
                hourlySection
                topSection
                footerNote
            }
        }
    }

    // MARK: 概览（4 个数字）

    private var overviewSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "概览")

            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.flexible(), spacing: Theme.Spacing.lg),
                    count: sizeClass.isNarrow ? 2 : 4
                ),
                alignment: .leading,
                spacing: Theme.Spacing.lg
            ) {
                metricCard(title: "播放次数", value: "\(summary.totalPlays)", unit: "次")
                    .staggerAppear(index: 0, visible: appeared)
                metricCard(title: "收听时长", value: formatTotalDuration(summary.totalSeconds), unit: nil)
                    .staggerAppear(index: 1, visible: appeared)
                metricCard(title: "活跃天数", value: "\(summary.activeDays)", unit: "天")
                    .staggerAppear(index: 2, visible: appeared)
                metricCard(title: "不同曲目", value: "\(summary.uniqueTracks)", unit: "首")
                    .staggerAppear(index: 3, visible: appeared)
            }
        }
    }

    private func metricCard(title: String, value: String, unit: String?) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .textStyle(.caption, weight: .semibold, color: Theme.isPaper ? Theme.Paper.ink3 : Theme.textTertiary)
                .textCase(.uppercase)
                .tracking(0.66)

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(value)
                    .paperSerifTitle(.title2, weight: .bold, color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .textStyle(.footnote, color: Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StatsCardChrome())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)：\(value)\(unit ?? "")")
    }

    // MARK: 收听热力图（Canvas 自绘，GitHub 风格）

    private var heatmapSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "收听热力图") {
                Text(heatmapNote)
                    .textStyle(.footnote, color: Theme.textTertiary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                heatmapCanvas

                HStack(spacing: Theme.Spacing.md) {
                    Text("少")
                        .textStyle(.caption, color: Theme.textTertiary)
                    ForEach(Array(Self.heatmapLegendCounts.enumerated()), id: \.offset) { _, count in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatmapColor(for: count))
                            .frame(width: 11, height: 11)
                    }
                    Text("多")
                        .textStyle(.caption, color: Theme.textTertiary)

                    Spacer(minLength: Theme.Spacing.md)

                    if let peakHour = PlaybackStats.peakHour(summary.hourlyCounts) {
                        Text("最常收听 \(hourText(peakHour))")
                            .textStyle(.footnote, color: Theme.textSecondary)
                    }
                }
            }
            .modifier(StatsCardChrome())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "收听热力图，\(range.title)，\(summary.activeDays) 天有播放记录，共 \(summary.totalPlays) 次播放"
            )
        }
    }

    /// 图例的 5 档代表值（真实桶值，保证图例颜色与格子一致）
    private static let heatmapLegendCounts = [0, 1, 3, 6, 11]

    private var heatmapCanvas: some View {
        let columns = heatmapGrid
        return Canvas { context, size in
            let gap: CGFloat = 3
            let columnCount = max(columns.count, 1)
            let rawCell = (size.width - gap * CGFloat(columnCount - 1)) / CGFloat(columnCount)
            let cell = min(max(rawCell, 4), 16)
            let totalWidth = cell * CGFloat(columnCount) + gap * CGFloat(columnCount - 1)
            // 周数很少（近 7 天）时居中，不贴左边缘
            let originX = max((size.width - totalWidth) / 2, 0)

            for (columnIndex, column) in columns.enumerated() {
                for (rowIndex, cellValue) in column.enumerated() {
                    let rect = CGRect(
                        x: originX + CGFloat(columnIndex) * (cell + gap),
                        y: CGFloat(rowIndex) * (cell + gap),
                        width: cell,
                        height: cell
                    )
                    let path = Path(roundedRect: rect, cornerRadius: max(cell * 0.22, 1))
                    context.fill(path, with: .color(heatmapColor(for: cellValue)))
                }
            }
        }
        .frame(height: heatmapHeight(for: heatmapGrid.count))
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: HeatmapWidthKey.self, value: geo.size.width)
            }
        )
        .onPreferenceChange(HeatmapWidthKey.self) { width in
            if abs(width - heatmapWidth) > 0.5 { heatmapWidth = width }
        }
    }

    /// 单元格尺寸（Canvas 与 frame 高度必须用同一套算法，否则格子会被拉扁）
    private func heatmapCellSize(columnCount: Int) -> CGFloat {
        let gap: CGFloat = 3
        let count = CGFloat(max(columnCount, 1))
        let available = heatmapWidth > 0 ? heatmapWidth : 320
        let rawCell = (available - gap * (count - 1)) / count
        return min(max(rawCell, 4), 16)
    }

    private func heatmapHeight(for columnCount: Int) -> CGFloat {
        let gap: CGFloat = 3
        return heatmapCellSize(columnCount: columnCount) * 7 + gap * 6
    }

    /// 当前范围的热力图窗口：列 = 周（7 天从 `firstWeekday` 起），行 = 星期。
    ///
    /// 窗口口径：
    /// - 近 7 天 = 1 周；近 30 天 ≈ 5 周；近一年 = 53 周；
    /// - 全部 = 从最早记录到今天，但**最多回溯约一年**（53 周）——
    ///   否则听五年歌会把格子压成一条线，反而读不出密度。
    private var heatmapGrid: [[Int]] {
        let today = calendar.startOfDay(for: Date())
        let start: Date
        switch range {
        case .week:
            start = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month:
            start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .year:
            start = calendar.date(byAdding: .day, value: -364, to: today) ?? today
        case .all:
            let earliest = summary.firstPlayedAt.map { calendar.startOfDay(for: $0) } ?? today
            let cap = calendar.date(byAdding: .day, value: -370, to: today) ?? today
            start = max(earliest, cap)
        }

        // 对齐到本周第一天：第一列可能含范围外的「空白格」（不画）
        let weekday = calendar.component(.weekday, from: start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let alignedStart = calendar.date(byAdding: .day, value: -leading, to: start) ?? start

        var columns: [[Int]] = []
        var cursor = alignedStart
        while cursor <= today {
            var column: [Int] = []
            column.reserveCapacity(7)
            for offset in 0..<7 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: cursor) else {
                    column.append(0)
                    continue
                }
                if day < start || day > today {
                    // 范围外的对齐格：画成「无数据」的浅底
                    column.append(-1)
                } else {
                    column.append(summary.playCount(on: day, calendar: calendar))
                }
            }
            columns.append(column)
            guard let next = calendar.date(byAdding: .day, value: 7, to: cursor) else { break }
            cursor = next
        }
        return columns
    }

    private var heatmapNote: String {
        let base = "\(summary.activeDays) 天有播放"
        return range == .all ? "展示最近约 12 个月 · \(base)" : "越深代表当天听得越多 · \(base)"
    }

    private func heatmapColor(for count: Int) -> Color {
        guard count >= 0 else {
            return Theme.isPaper ? Theme.Paper.sunken.opacity(0.6) : Theme.surfaceSunken.opacity(0.6)
        }
        if count == 0 {
            return Theme.isPaper ? Theme.Paper.sunken : Theme.surfaceSunken
        }
        let level: CGFloat
        switch count {
        case 1: level = 0.24
        case 2...3: level = 0.42
        case 4...6: level = 0.62
        case 7...10: level = 0.80
        default: level = 1
        }
        if Theme.isPaper {
            // 纸墨：用墨的浓度表达密度（v4 §1.3「红只属于正在发声的事」）
            return Theme.Paper.ink.opacity(0.10 + 0.80 * level)
        }
        return Theme.brand500.opacity(0.14 + 0.86 * level)
    }

    // MARK: 时段分布（24 小时柱状，Canvas 自绘）

    private var hourlySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "时段分布") {
                if let peakHour = PlaybackStats.peakHour(summary.hourlyCounts) {
                    Text("最常收听 \(hourText(peakHour))")
                        .textStyle(.footnote, color: Theme.textSecondary)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                hourlyCanvas
                    .frame(height: 92)

                HStack(spacing: 0) {
                    ForEach(Array(Self.hourAxisLabels.enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .textStyle(.caption, color: Theme.textTertiary)
                        if index < Self.hourAxisLabels.count - 1 {
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .modifier(StatsCardChrome())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(hourlyAccessibilityLabel)
        }
    }

    private static let hourAxisLabels = ["0 时", "6 时", "12 时", "18 时", "23 时"]

    private var hourlyCanvas: some View {
        let counts = summary.hourlyCounts
        let peak = PlaybackStats.peakHour(counts)
        let maxValue = max(counts.max() ?? 0, 1)
        return Canvas { context, size in
            let gap: CGFloat = 3
            let barWidth = max((size.width - gap * 23) / 24, 1)
            for hour in 0..<24 {
                let count = hour < counts.count ? counts[hour] : 0
                let height: CGFloat = count == 0
                    ? 2
                    : max(2, size.height * CGFloat(count) / CGFloat(maxValue))
                let rect = CGRect(
                    x: CGFloat(hour) * (barWidth + gap),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let path = Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 2))
                context.fill(path, with: .color(hourlyBarColor(hour: hour, count: count, peak: peak)))
            }
        }
    }

    private func hourlyBarColor(hour: Int, count: Int, peak: Int?) -> Color {
        if count == 0 {
            return Theme.isPaper ? Theme.Paper.hairline : Theme.borderSubtle
        }
        let isPeak = hour == peak
        if Theme.isPaper {
            return isPeak ? Theme.Paper.signal : Theme.Paper.ink.opacity(0.42)
        }
        return isPeak ? Theme.brand500 : Theme.brand500.opacity(0.42)
    }

    private var hourlyAccessibilityLabel: String {
        guard let peakHour = PlaybackStats.peakHour(summary.hourlyCounts) else {
            return "时段分布，暂无数据"
        }
        return "时段分布，最常收听时段是 \(hourText(peakHour))，共 \(summary.hourlyCounts[peakHour]) 次播放"
    }

    /// 小时 → 「22:00」这类文案
    private func hourText(_ hour: Int) -> String {
        let h = min(max(hour, 0), 23)
        return h < 10 ? "0\(h):00" : "\(h):00"
    }

    // MARK: Top 歌曲 / 艺人 / 专辑

    private var topSection: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: Theme.Spacing.lg, alignment: .top),
                count: sizeClass.isNarrow ? 1 : 3
            ),
            alignment: .leading,
            spacing: Theme.Spacing.xl
        ) {
            topCard(title: "最常听的歌", entries: summary.topSongs, kinds: .songs, index: 0)
            topCard(title: "最常听的艺人", entries: summary.topArtists, kinds: .artists, index: 1)
            topCard(title: "最常听的专辑", entries: summary.topAlbums, kinds: .albums, index: 2)
        }
    }

    private enum TopKind {
        case songs, artists, albums
    }

    private func topCard(title: String, entries: [PlaybackStatEntry], kinds: TopKind, index: Int) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: title)

            if entries.isEmpty {
                Text("暂无记录")
                    .textStyle(.bodySM, color: Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.lg)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.key) { rank, entry in
                        topRow(rank: rank, entry: entry, kinds: kinds)
                        if rank < entries.count - 1 {
                            Rectangle()
                                .fill(Theme.isPaper ? Theme.Paper.hairline : Theme.borderSubtle)
                                .frame(height: 1)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(StatsCardChrome())
        .staggerAppear(index: index + 4, visible: appeared)
    }

    private func topRow(rank: Int, entry: PlaybackStatEntry, kinds: TopKind) -> some View {
        let subtitle: String? = {
            switch kinds {
            case .songs: return entry.subtitle
            case .artists: return entry.uniqueTracks > 0 ? "\(entry.uniqueTracks) 首" : nil
            case .albums: return entry.subtitle
            }
        }()
        // 只有歌曲能点播放；且**不在渲染时**去曲库里反查（那是每帧 5×3×N 次 contentKey 计算），
        // 反查只发生在点击那一刻（见 `play(_:)`）
        let row = HStack(spacing: Theme.Spacing.lg) {
            Text("\(rank + 1)")
                .textStyle(.mono, color: Theme.isPaper ? Theme.Paper.ink3 : Theme.textTertiary)
                .frame(width: 18, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .textStyle(.bodySM, weight: .medium,
                               color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .textStyle(.footnote, color: Theme.isPaper ? Theme.Paper.ink2 : Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.plays) 次")
                .textStyle(.mono, color: Theme.isPaper ? Theme.Paper.ink2 : Theme.textTertiary)
                .lineLimit(1)
        }
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle())

        return Group {
            switch kinds {
            case .songs:
                Button {
                    play(entry)
                } label: {
                    row
                }
                .buttonStyle(.plain)
                .acceptClickThrough()
                .help("播放《\(entry.name)》")
            case .artists, .albums:
                row
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(rank + 1) 名，\(entry.name)，\(entry.plays) 次播放")
    }

    /// 点 Top 歌曲 → 在已加载曲库里反查同一首歌并播放（曲库没加载 / 匹配不到时给 Toast）
    private func play(_ entry: PlaybackStatEntry) {
        guard let track = store.tracks.first(where: { $0.contentKey == entry.key }) else {
            ToastCenter.shared.show("本地曲库里找不到《\(entry.name)》", systemImage: "questionmark.circle")
            return
        }
        MusicPlayerModel.shared.play(tracks: [track], startAt: 0)
    }

    // MARK: 页脚说明

    private var footerNote: some View {
        Text("统计只保存在本机（应用支持目录），不会上传到服务器。")
            .textStyle(.caption, color: Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Spacing.lg)
    }

    // MARK: - 数据

    private func refreshSummary() {
        summary = PlaybackStats.summary(
            events: history.events,
            range: range,
            now: Date(),
            calendar: calendar
        )
    }
}

// MARK: - 热力图宽度上报

private struct HeatmapWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - 统计卡片外观（双风格）

/// 统计块外观：玻璃 = 白卡 + `e1` + 细描边；纸墨 = 纸块 + 1px 细线（v4 零投影）。
///
/// 纸墨下**不挂投影、不叠卡片**：区块标题由 `SectionHeader` 自动降级为印刷规则标签，
/// 这块「纸块」只是一张印了表格的纸，与 `libraryTableChrome` 的取舍一致。
private struct StatsCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
                .padding(Theme.Spacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Paper.sheet)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .strokeBorder(Theme.Paper.hairline)
                )
        } else {
            content
                .padding(Theme.Spacing.xl)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.borderSubtle)
                )
                .elevation(.e1, cornerRadius: Theme.Radius.lg)
        }
    }
}
