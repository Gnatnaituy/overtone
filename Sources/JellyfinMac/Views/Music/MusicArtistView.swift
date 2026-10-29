import SwiftUI

/// 艺人详情页（重做，§4.4）：复用专辑详情骨架——圆形封面 + 热门曲目 + 专辑网格。
struct MusicArtistView: View {
    let artist: MediaItem
    let sizeClass: LayoutSizeClass
    let parentTitle: String
    let onOpenAlbum: (MediaItem) -> Void
    let onBack: () -> Void

    /// 艺人名下的专辑与曲目（由 `MusicDataStore` 取，后端不支持艺人浏览时用已加载曲库兜底）
    @State private var albums: [MediaItem] = []
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = false
    @State private var appeared = false

    init(
        artist: MediaItem,
        sizeClass: LayoutSizeClass,
        parentTitle: String,
        onOpenAlbum: @escaping (MediaItem) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.artist = artist
        self.sizeClass = sizeClass
        self.parentTitle = parentTitle
        self.onOpenAlbum = onOpenAlbum
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                sizeClass: sizeClass,
                parentTitle: parentTitle,
                onParent: onBack,
                title: artist.title
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, sizeClass.pageMargin)
                        .padding(.top, sizeClass.isNarrow ? Theme.Spacing.xxl : Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.xxl)

                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        if isLoading && albums.isEmpty && tracks.isEmpty {
                            SkeletonGrid(count: 6, minWidth: sizeClass.gridMin, spacing: sizeClass.gridSpacing)
                        } else {
                            if !albums.isEmpty { albumsSection }
                            if !tracks.isEmpty { topTracksSection }
                            if albums.isEmpty && tracks.isEmpty { emptyState }
                        }
                    }
                    .padding(.horizontal, sizeClass.pageMargin)
                    .padding(.top, Theme.Spacing.section)
                    .padding(.bottom, Theme.Spacing.section)
                }
                .frame(maxWidth: sizeClass.contentMaxWidth ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
            // 滚动体不参与内容列宽度协商：内容再宽也不把顶栏顶出窗口右缘（§7.2 规则 3）
            .pageBodyWidthClamp()
        }
        .task {
            await load()
            appeared = true
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        let coverSize = sizeClass.detailCoverSize
        let cover = RemoteImage(ref: artist.artworkRef(width: 480), contentMode: .fill)
        .frame(width: coverSize, height: coverSize)
        .clipShape(Circle())
        .modifier(ArtistCoverChrome(coverSize: coverSize))

        if sizeClass.detailStacksVertically {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                cover
                headerInfo
            }
        } else {
            HStack(alignment: .bottom, spacing: 28) {
                cover
                headerInfo
            }
        }
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Eyebrow(text: "艺人")

            Text(artist.title)
                .textStyle(.title1, color: Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !metaLine.isEmpty {
                Text(metaLine)
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .lineLimit(1)
            }

            HStack(spacing: Theme.Spacing.lg) {
                Button {
                    MusicPlayerModel.shared.play(tracks: tracks, startAt: 0)
                } label: {
                    Label("播放", systemImage: "play.fill")
                        .frame(minWidth: 88)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(tracks.isEmpty)

                Button {
                    MusicPlayerModel.shared.play(tracks: tracks.shuffled(), startAt: 0)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .frame(minWidth: 76)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(tracks.isEmpty)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 元信息行：专辑数 · 曲目数
    ///
    /// 领域模型没有「艺人名下专辑总数」字段（原来的 `childCount` 是 Jellyfin 的 ChildCount），
    /// 这里用**已取到的专辑数**代替：数据来自 `artistAlbums(artistID:)`，语义上等价。
    private var metaLine: String {
        var parts: [String] = []
        if !albums.isEmpty {
            parts.append("\(albums.count) 张专辑")
        }
        if !tracks.isEmpty {
            parts.append("\(tracks.count) 首曲目")
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // 两个请求互不依赖（都以 artistID 为条件，谁也不等谁的结果）：
        // 并发发出后页面等待从 RTT1+RTT2 降到 max(RTT1,RTT2)。
        async let albumList: [MediaItem] = MusicDataStore.shared.artistAlbums(artistID: artist.id)
        async let trackList: [MediaItem] = MusicDataStore.shared.artistTracks(artistID: artist.id)
        albums = await albumList
        tracks = await trackList
    }

    // MARK: - 专辑网格

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "专辑")
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                   spacing: sizeClass.gridSpacing.h)],
                alignment: .leading,
                spacing: sizeClass.gridSpacing.v
            ) {
                ForEach(Array(albums.enumerated()), id: \.element.id) { index, album in
                    PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                        .staggerAppear(index: index, visible: appeared)
                }
            }
        }
    }

    // MARK: - 热门曲目

    private var topTracksSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader(title: "热门曲目")
            TrackTable(
                tracks: Array(tracks.prefix(10)),
                sizeClass: sizeClass,
                showHeader: false,
                onTap: { index in
                    MusicPlayerModel.shared.play(tracks: tracks, startAt: index)
                }
            )
        }
    }

    private var emptyState: some View {
        EmptyState(
            systemImage: "person.crop.circle",
            title: "这位艺人还没有可播放的内容",
            message: "服务器上的曲目可能缺少专辑关联"
        )
    }
}

/// 艺人头像外观：glass = `e2` 投影；paper = 1px 强 hairline 圆描边。
///
/// 圆形头像没有「套封框」可加（§4.6 的压框只给方封面），而纸墨下 `elevation` 不出投影、
/// 只在深色主题补一圈 `borderSubtle` —— 浅色纸面上头像会完全没有边。
/// 这里与 T3 的 `ArtistCard` 保持同一手法（`Paper.hairlineStrong`，§2.3 描边是主要分隔手段）。
private struct ArtistCoverChrome: ViewModifier {
    let coverSize: CGFloat

    func body(content: Content) -> some View {
        if Theme.isPaper {
            content.overlay(
                Circle().strokeBorder(Theme.Paper.hairlineStrong, lineWidth: 1)
            )
        } else {
            content.elevation(.e2, cornerRadius: coverSize / 2)
        }
    }
}
