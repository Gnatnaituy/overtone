import SwiftUI

// MARK: - 通用曲目列表页（收藏 / 最近播放 / 最常播放共用）

/// 统一样式：面包屑 + 顶栏（标题 / 搜索 / 播放全部）+ 曲目列表（行高 48）。
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
                    if tracks.isEmpty {
                        EmptyState(
                            systemImage: emptyIcon,
                            title: emptyText,
                            message: emptyHint
                        )
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
        }
        .background(Theme.canvas.ignoresSafeArea())
        .onAppear { appeared = true }
    }
}
