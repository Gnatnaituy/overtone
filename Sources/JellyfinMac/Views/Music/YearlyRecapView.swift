import SwiftUI
import AppKit

// MARK: - 年度听歌报告（sheet）

/// 年度报告：6 张卡片翻页（首曲 / Top 艺人 / Top 歌曲 / 时段 / 人格 / 收尾）。
///
/// 为什么不用 `TabView`：`.page` 翻页样式在 macOS 上不可用（`PageTabViewStyle` 只在
/// iOS / tvOS / watchOS 存在），macOS 的原生 tab 条又会把报告拆成「设置页」的观感。
/// 这里用自定义分页：一张卡 + 底部圆点 + ← → 按钮（方向键同样可用）。
///
/// 分享：`ImageRenderer` 把同一份报告渲染成一张长图（PNG，写到临时目录），
/// 再用 AppKit 的 `NSSharingServicePicker` 弹出系统分享面板。
///
/// Reduce Motion：翻页动画降为仅透明度（`Theme.Motion.reduced`），不做位移。
struct YearlyRecapView: View {
    let events: [ListeningEvent]
    let year: Int

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appReduceMotion) private var reduceMotion
    /// 订阅风格：本 sheet 挂在主窗口子树里，换风格会重建；读环境值保证卡片外观跟着变
    @Environment(\.appVisualStyle) private var appStyle

    /// 报告数据只在 sheet 构造时算一次（`yearlyRecap` 要对全量事件排序，不能每帧重算）。
    ///
    /// 为什么不用 `@State` + `State(initialValue:)`：本仓库在只有 Command Line Tools 的机器上用
    /// `tools/SwiftUIMacrosShim` 替身宏展开 `@State`，那里不接受「在 init 里给 `_xxx` 赋值」的写法
    /// （实测报 "expansion of macro 'State()' did not produce a non-observing accessor"）。
    private let recap: YearlyRecap

    @State private var page = 0
    /// 分享失败的兜底提示（成功时不打扰）
    @State private var shareError: String?

    private static let pageCount = 6

    init(events: [ListeningEvent], year: Int) {
        self.events = events
        self.year = year
        self.recap = PlaybackStats.yearlyRecap(events: events, year: year)
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.xl) {
            header

            ZStack {
                pageCard(page)
                    .id(page)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .opacity.combined(with: .offset(x: 24)),
                        removal: .opacity.combined(with: .offset(x: -24))
                    ))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(reduceMotion ? Theme.Motion.reduced : Theme.Motion.base, value: page)
            .clipped()

            footer
        }
        .padding(Theme.Spacing.xxl)
        .frame(minWidth: 620, idealWidth: 760, maxWidth: 880,
               minHeight: 560, idealHeight: 640, maxHeight: 720)
        .background(Theme.canvas)
    }

    // MARK: - 头部 / 底部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text("年度听歌报告")
                    .paperSerifTitle(.title2, weight: .bold,
                                     color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                Text("\(year) 年 · 共 \(recap.totalPlays) 次播放")
                    .textStyle(.footnote, color: Theme.textSecondary)
            }

            Spacer(minLength: Theme.Spacing.md)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(
                Circle().fill(Theme.isPaper ? Theme.Paper.hover : Theme.surfaceHover)
            )
            .keyboardShortcut(.cancelAction)
            .help("关闭年度报告")
            .accessibilityLabel("关闭年度报告")
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button(action: previousPage) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.isPaper ? Theme.Paper.hover : Theme.surfaceHover))
            .disabled(page == 0)
            .keyboardShortcut(.leftArrow, modifiers: [])
            .help("上一页")
            .accessibilityLabel("上一页")

            pageDots

            Button(action: nextPage) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .frame(width: 28, height: 28)
            .background(Circle().fill(Theme.isPaper ? Theme.Paper.hover : Theme.surfaceHover))
            .disabled(page >= Self.pageCount - 1)
            .keyboardShortcut(.rightArrow, modifiers: [])
            .help("下一页")
            .accessibilityLabel("下一页")

            Text("\(page + 1) / \(Self.pageCount)")
                .textStyle(.mono, color: Theme.textTertiary)
                .padding(.leading, Theme.Spacing.xs)

            Spacer(minLength: Theme.Spacing.md)

            if let shareError {
                Text(shareError)
                    .textStyle(.footnote, color: Theme.danger)
                    .lineLimit(1)
            }

            Button {
                sharePoster()
            } label: {
                Label("分享长图", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(SecondaryButtonStyle(compact: true))
            .disabled(recap.isEmpty)
            .help("把这份报告导出为 PNG 并分享")
            .accessibilityLabel("分享报告长图")

            Button {
                dismiss()
            } label: {
                Text("关闭")
            }
            .buttonStyle(PrimaryButtonStyle(compact: true))
            .accessibilityLabel("关闭年度报告")
        }
    }

    private var pageDots: some View {
        HStack(spacing: Theme.Spacing.sm) {
            ForEach(0..<Self.pageCount, id: \.self) { index in
                Circle()
                    .fill(dotColor(for: index))
                    .frame(width: index == page ? 7 : 5, height: index == page ? 7 : 5)
                    .animation(Theme.Motion.micro, value: page)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(page + 1) 页，共 \(Self.pageCount) 页")
    }

    private func dotColor(for index: Int) -> Color {
        if index == page {
            return Theme.isPaper ? Theme.Paper.ink : Theme.brand500
        }
        return Theme.isPaper ? Theme.Paper.ink3.opacity(0.4) : Theme.textTertiary.opacity(0.4)
    }

    private func previousPage() {
        guard page > 0 else { return }
        page -= 1
    }

    private func nextPage() {
        guard page < Self.pageCount - 1 else { return }
        page += 1
    }

    // MARK: - 六张卡片

    @ViewBuilder
    private func pageCard(_ index: Int) -> some View {
        switch index {
        case 0: openingCard
        case 1: artistCard
        case 2: songsCard
        case 3: hoursCard
        case 4: personaCard
        default: closingCard
        }
    }

    private var openingCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "OVERTONE · 年度报告")

                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                    Text("\(recap.year)")
                        .paperSerifTitle(.display, weight: .bold,
                                         color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                    Text("你听了")
                        .textStyle(.title4, color: Theme.textSecondary)
                }

                Text("\(recap.totalPlays) 次播放 · \(formatTotalDuration(recap.totalSeconds)) · \(recap.activeDays) 天有音乐")
                    .textStyle(.bodyLG, color: Theme.textSecondary)
                    .lineLimit(2)

                RecapHairline()
                    .padding(.vertical, Theme.Spacing.sm)

                RecapEyebrow(text: "今年的第一首歌")

                if let first = recap.firstTrack {
                    Text(first.title)
                        .paperSerifTitle(.title1, weight: .bold,
                                         color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text(metadataLine(title: first.artistDisplay, album: first.albumTitle))
                        .textStyle(.bodySM, color: Theme.textSecondary)
                        .lineLimit(1)
                    Text("\(Self.dayFormatter.string(from: first.startedAt)) 开始播放")
                        .textStyle(.footnote, color: Theme.textTertiary)
                } else {
                    Text("这一年还没有听歌记录。")
                        .textStyle(.title4, color: Theme.textSecondary)
                }

                Spacer(minLength: 0)
            }
        }
    }

    private var artistCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "陪伴你最久的艺人")

                if let top = recap.topArtists.first {
                    Text(top.name)
                        .paperSerifTitle(.title1, weight: .bold,
                                         color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text("\(top.plays) 次播放 · \(max(top.uniqueTracks, 1)) 首不同的歌")
                        .textStyle(.body, color: Theme.textSecondary)
                } else {
                    Text("还没有足够的数据。")
                        .textStyle(.title4, color: Theme.textSecondary)
                }

                RecapHairline()
                    .padding(.vertical, Theme.Spacing.xs)

                RecapRankList(entries: recap.topArtists, subtitleForEntry: { entry in
                    entry.uniqueTracks > 0 ? "\(entry.uniqueTracks) 首" : nil
                })

                Spacer(minLength: 0)
            }
        }
    }

    private var songsCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "你的年度单曲")

                if let top = recap.topSongs.first {
                    Text(top.name)
                        .paperSerifTitle(.title1, weight: .bold,
                                         color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    Text("\(top.subtitle ?? "未知艺人") · 播放 \(top.plays) 次")
                        .textStyle(.body, color: Theme.textSecondary)
                } else {
                    Text("还没有足够的数据。")
                        .textStyle(.title4, color: Theme.textSecondary)
                }

                RecapHairline()
                    .padding(.vertical, Theme.Spacing.xs)

                RecapRankList(entries: recap.topSongs, subtitleForEntry: { $0.subtitle })

                Spacer(minLength: 0)
            }
        }
    }

    private var hoursCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "你最常收听的时段")

                if let peakHour = recap.peakHour {
                    Text(Self.hourRangeText(peakHour))
                        .paperSerifTitle(.title1, weight: .bold,
                                         color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                    Text("\(recap.persona.dayNight.rawValue) · 最长连续 \(recap.longestStreak) 天有音乐")
                        .textStyle(.body, color: Theme.textSecondary)
                } else {
                    Text("还没有足够的数据。")
                        .textStyle(.title4, color: Theme.textSecondary)
                }

                monthChart
                    .frame(height: 110)
                    .padding(.top, Theme.Spacing.sm)

                HStack(spacing: 0) {
                    ForEach(Array(Self.monthLabels.enumerated()), id: \.offset) { index, label in
                        Text(label)
                            .textStyle(.caption, color: Theme.textTertiary)
                            .frame(maxWidth: .infinity)
                        if index < Self.monthLabels.count - 1 { Spacer(minLength: 0) }
                    }
                }

                Spacer(minLength: 0)
            }
        }
    }

    private static let monthLabels = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12"]

    private var monthChart: some View {
        let counts = recap.monthlyCounts
        let peak = counts.max() ?? 0
        return Canvas { context, size in
            let gap: CGFloat = 4
            let barWidth = max((size.width - gap * 11) / 12, 1)
            for month in 0..<12 {
                let count = month < counts.count ? counts[month] : 0
                let ratio: CGFloat = peak > 0 ? CGFloat(count) / CGFloat(peak) : 0
                let height = count == 0 ? 2 : max(2, size.height * ratio)
                let rect = CGRect(
                    x: CGFloat(month) * (barWidth + gap),
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                let path = Path(roundedRect: rect, cornerRadius: min(barWidth / 2, 2))
                let isPeak = count > 0 && count == peak
                let color: Color = {
                    guard count > 0 else {
                        return Theme.isPaper ? Theme.Paper.hairline : Theme.borderSubtle
                    }
                    if Theme.isPaper {
                        return isPeak ? Theme.Paper.signal : Theme.Paper.ink.opacity(0.42)
                    }
                    return isPeak ? Theme.brand500 : Theme.brand500.opacity(0.42)
                }()
                context.fill(path, with: .color(color))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("月份分布，\(Self.peakMonthText(counts))")
    }

    private var personaCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "你的年度人格")

                Text(recap.persona.title)
                    .paperSerifTitle(.title1, weight: .bold,
                                     color: Theme.isPaper ? Theme.Paper.signalInk : Theme.brandText)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)

                Text("由这一年的收听习惯推导：听得最多的时间、重复度、追新程度与口味广度。")
                    .textStyle(.footnote, color: Theme.textTertiary)
                    .lineLimit(2)

                VStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(recap.persona.dimensions.enumerated()), id: \.offset) { _, dimension in
                        HStack(spacing: Theme.Spacing.lg) {
                            Text(dimension.title)
                                .textStyle(.bodySM, color: Theme.textSecondary)
                                .frame(width: 88, alignment: .leading)
                            Text(dimension.value)
                                .paperSerifTitle(.title4, weight: .semibold,
                                                 color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.top, Theme.Spacing.xs)

                Spacer(minLength: 0)
            }
        }
    }

    private var closingCard: some View {
        RecapCardShell {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                RecapEyebrow(text: "这一年，谢谢你听歌")

                Text("\(recap.year) 年")
                    .paperSerifTitle(.display, weight: .bold,
                                     color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                Text(recap.persona.title)
                    .textStyle(.title4, color: Theme.isPaper ? Theme.Paper.signalInk : Theme.brandText)

                RecapHairline()
                    .padding(.vertical, Theme.Spacing.xs)

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Theme.Spacing.lg, alignment: .leading), count: 3),
                    alignment: .leading,
                    spacing: Theme.Spacing.md
                ) {
                    closingMetric(title: "播放次数", value: "\(recap.totalPlays) 次")
                    closingMetric(title: "收听时长", value: formatTotalDuration(recap.totalSeconds))
                    closingMetric(title: "活跃天数", value: "\(recap.activeDays) 天")
                    closingMetric(title: "不同曲目", value: "\(recap.uniqueTracks) 首")
                    closingMetric(title: "不同艺人", value: "\(recap.uniqueArtists) 位")
                    closingMetric(title: "最长连续", value: "\(recap.longestStreak) 天")
                }

                Text("报告只保存在本机，不会上传到服务器。")
                    .textStyle(.caption, color: Theme.textTertiary)

                Spacer(minLength: 0)

                HStack(spacing: Theme.Spacing.lg) {
                    Button {
                        sharePoster()
                    } label: {
                        Label("导出分享长图", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(recap.isEmpty)
                    .accessibilityLabel("导出分享长图")

                    Button {
                        dismiss()
                    } label: {
                        Text("关闭")
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .accessibilityLabel("关闭年度报告")
                }
            }
        }
    }

    private func closingMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .textStyle(.caption, color: Theme.textTertiary)
            Text(value)
                .textStyle(.body, weight: .semibold,
                           color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                .lineLimit(1)
        }
    }

    // MARK: - 文案辅助

    private func metadataLine(title: String, album: String?) -> String {
        let trimmed = (album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : "\(title) · \(trimmed)"
    }

    /// 小时 → 「22:00 – 23:00」
    static func hourRangeText(_ hour: Int) -> String {
        let start = min(max(hour, 0), 23)
        let end = (start + 1) % 24
        func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }
        return "\(pad(start)):00 – \(pad(end)):00"
    }

    private static func peakMonthText(_ counts: [Int]) -> String {
        guard let peak = counts.max(), peak > 0, let index = counts.firstIndex(of: peak) else {
            return "暂无数据"
        }
        return "\(index + 1) 月听得最多，共 \(peak) 次"
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        return formatter
    }()

    // MARK: - 分享（ImageRenderer + NSSharingServicePicker）

    /// 把报告渲染成一张 900×1200 的长图（2x → 1800×2400 PNG），写临时文件后弹系统分享面板。
    @MainActor
    private func sharePoster() {
        shareError = nil
        let renderer = ImageRenderer(content: RecapPoster(recap: recap))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            shareError = "导出图片失败"
            return
        }

        let fileName = "Overtone-年度报告-\(recap.year).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            shareError = "导出图片失败"
            return
        }

        guard let window = NSApp.keyWindow, let view = window.contentView else {
            shareError = "找不到可分享的窗口"
            return
        }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

// MARK: - 卡片外壳

/// 报告卡片外壳：玻璃 = 白卡 + e2；纸墨 = 纸块 + 1px 细线（零投影）。
private struct RecapCardShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.Spacing.section)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                if Theme.isPaper {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Paper.sheet)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.xl)
                        .fill(Theme.surface)
                }
            }
            .overlay {
                if Theme.isPaper {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .strokeBorder(Theme.Paper.hairline)
                } else {
                    RoundedRectangle(cornerRadius: Theme.Radius.xl)
                        .strokeBorder(Theme.borderSubtle)
                }
            }
            .elevation(Theme.isPaper ? .e1 : .e2, cornerRadius: Theme.Radius.md)
    }
}

/// 小型大写标签（报告内的分组标签）
private struct RecapEyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .textStyle(.caption, weight: .semibold,
                       color: Theme.isPaper ? Theme.Paper.ink3 : Theme.textTertiary)
            .textCase(.uppercase)
            .tracking(0.88)
            .accessibilityAddTraits(.isHeader)
    }
}

/// 1px 细线（纸墨 hairline / 玻璃 borderSubtle）
private struct RecapHairline: View {
    var body: some View {
        Rectangle()
            .fill(Theme.isPaper ? Theme.Paper.hairline : Theme.borderSubtle)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

/// 报告内的 Top 榜（序号 + 名称 + 次数）
private struct RecapRankList: View {
    let entries: [PlaybackStatEntry]
    var subtitleForEntry: (PlaybackStatEntry) -> String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.key) { rank, entry in
                HStack(spacing: Theme.Spacing.lg) {
                    Text("\(rank + 1)")
                        .textStyle(.mono, color: Theme.isPaper ? Theme.Paper.ink3 : Theme.textTertiary)
                        .frame(width: 18, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .textStyle(.body, weight: .medium,
                                       color: Theme.isPaper ? Theme.Paper.ink : Theme.textPrimary)
                            .lineLimit(1)
                        if let subtitle = subtitleForEntry(entry) {
                            Text(subtitle)
                                .textStyle(.footnote, color: Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Theme.Spacing.md)

                    Text("\(entry.plays) 次")
                        .textStyle(.mono, color: Theme.Paper.ink2)
                }
                .padding(.vertical, Theme.Spacing.sm)

                if rank < entries.count - 1 {
                    RecapHairline()
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 分享长图

/// 分享用的长图（与 sheet 内的卡片共用同一份 `YearlyRecap`，不额外读盘）。
///
/// 固定 900×1200：`ImageRenderer` 以 2x 渲染 → 1800×2400 PNG，适合发社交平台。
private struct RecapPoster: View {
    let recap: YearlyRecap

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("OVERTONE")
                    .font(.system(size: 15, weight: .bold, design: .serif))
                    .tracking(3)
                    .foregroundStyle(Theme.Paper.ink)
                Spacer(minLength: 0)
                Text("年度听歌报告")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.Paper.ink3)
            }

            Text("\(recap.year)")
                .font(.system(size: 88, weight: .bold, design: .serif))
                .foregroundStyle(Theme.Paper.ink)
                .padding(.top, 6)

            Text(recap.persona.title)
                .font(.system(size: 26, weight: .semibold, design: .serif))
                .foregroundStyle(Theme.Paper.signalInk)

            Rectangle()
                .fill(Theme.Paper.hairlineStrong)
                .frame(height: 1)
                .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 28) {
                posterMetric("播放次数", "\(recap.totalPlays) 次")
                posterMetric("收听时长", formatTotalDuration(recap.totalSeconds))
                posterMetric("活跃天数", "\(recap.activeDays) 天")
                posterMetric("不同曲目", "\(recap.uniqueTracks) 首")
            }

            Rectangle()
                .fill(Theme.Paper.hairline)
                .frame(height: 1)
                .padding(.vertical, 8)

            posterSection(title: "最常听的歌", entries: recap.topSongs, subtitle: { $0.subtitle })
            posterSection(title: "最常听的艺人", entries: recap.topArtists, subtitle: { _ in nil })
            posterSection(title: "最常听的专辑", entries: recap.topAlbums, subtitle: { $0.subtitle })

            Rectangle()
                .fill(Theme.Paper.hairline)
                .frame(height: 1)
                .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 28) {
                posterMetric("最常时段", recap.peakHour.map { YearlyRecapView.hourRangeText($0) } ?? "—")
                posterMetric("最长连续", "\(recap.longestStreak) 天")
                posterMetric("昼夜节律", recap.persona.dayNight.rawValue)
                posterMetric("探索偏好", recap.persona.exploration.rawValue)
            }

            Spacer(minLength: 0)

            HStack {
                Text("泛音 · Overtone")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Paper.ink3)
                Spacer(minLength: 0)
                Text("统计只保存在本机")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Paper.ink3)
            }
        }
        .padding(56)
        .frame(width: 900, height: 1200, alignment: .topLeading)
        .background(Theme.Paper.sheet)
    }

    private func posterMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Paper.ink3)
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(Theme.Paper.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func posterSection(
        title: String,
        entries: [PlaybackStatEntry],
        subtitle: @escaping (PlaybackStatEntry) -> String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Theme.Paper.ink3)
            if entries.isEmpty {
                Text("暂无记录")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.Paper.ink3)
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.key) { rank, entry in
                    HStack(spacing: 10) {
                        Text("\(rank + 1)")
                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.Paper.ink3)
                            .frame(width: 18, alignment: .trailing)
                        Text(entry.name)
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(Theme.Paper.ink)
                            .lineLimit(1)
                        if let text = subtitle(entry) {
                            Text(text)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Paper.ink2)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Text("\(entry.plays) 次")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(Theme.Paper.ink2)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}
