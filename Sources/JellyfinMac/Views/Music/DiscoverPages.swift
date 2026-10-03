import SwiftUI

// MARK: - 通用曲目列表页（收藏 / 最近播放 / 最常播放共用）

/// 统一样式（§2.2 列表页骨架）：面包屑（可选）+ 顶栏（标题 / 搜索 / 随机 / 播放全部）+ 曲目列表。
///
/// - 行式列表走 `MusicRow`（高 48，hover / 键盘聚焦显示收藏与更多）；
/// - 加载中 `SkeletonList`，空态 `EmptyState`（媒体库尚未加载时附「刷新媒体库」主操作）；
/// - 构造签名保持不变（`MainView` 直接调用）。
struct TrackListPage: View {
    let sizeClass: LayoutSizeClass
    let title: String
    let tracks: [BaseItemDto]
    var emptyIcon = "music.note"
    var emptyText = "这里还什么都没有"
    var emptyHint: String?
    var parentTitle: String?
    var onBack: (() -> Void)?
    @Binding var searchQuery: String
    var searchFocusRequest: Int = 0
    var onSearchSubmit: (() -> Void)?

    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var store = MusicDataStore.shared
    @State private var appeared = false

    private var metrics: TrackRowMetrics { TrackRowMetrics(sizeClass: sizeClass) }

    var body: some View {
        VStack(spacing: 0) {
            if let parentTitle, let onBack {
                BreadcrumbBar(
                    sizeClass: sizeClass,
                    parentTitle: parentTitle,
                    onParent: onBack,
                    title: title
                )
            }

            PageTopBar(
                sizeClass: sizeClass,
                title: title,
                subtitle: tracks.isEmpty ? nil : "\(tracks.count) 首",
                searchText: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: { onSearchSubmit?() }
            ) {
                HStack(spacing: Theme.Spacing.md) {
                    Button {
                        MusicPlayerModel.shared.play(tracks: tracks.shuffled(), startAt: 0)
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .disabled(tracks.isEmpty)

                    Button {
                        MusicPlayerModel.shared.play(tracks: tracks, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .disabled(tracks.isEmpty)
                }
            }

            ScrollView {
                PageContent(sizeClass: sizeClass) {
                    if tracks.isEmpty && store.isLoading {
                        SkeletonList(count: 10)
                    } else if tracks.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                MusicRow(
                                    track: track,
                                    index: index,
                                    metrics: metrics,
                                    isCurrent: music.currentTrack?.id == track.id,
                                    isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                                    onTap: { MusicPlayerModel.shared.play(tracks: tracks, startAt: index) }
                                )
                                .staggerAppear(index: index, visible: appeared)
                            }
                        }
                        .libraryTableChrome()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
            // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
            .pageBodyWidthClamp()
        }
        .onAppear { appeared = true }
    }

    /// 空态：媒体库本身还没加载出来时给一个「刷新媒体库」主操作，避免误判为「没有内容」
    private var emptyState: some View {
        EmptyState(
            systemImage: emptyIcon,
            title: emptyText,
            message: emptyHint
        ) {
            if store.tracks.isEmpty {
                Button {
                    Task { await store.reload() }
                } label: {
                    Label("刷新媒体库", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle(compact: true))
            }
        }
    }
}
