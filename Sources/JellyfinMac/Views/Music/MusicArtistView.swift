import SwiftUI

/// 艺人详情页（重做，§4.4）：复用专辑详情骨架——圆形封面 + 热门曲目 + 专辑网格。
struct MusicArtistView: View {
    let artist: BaseItemDto
    let sizeClass: LayoutSizeClass
    let parentTitle: String
    let onOpenAlbum: (BaseItemDto) -> Void
    let onBack: () -> Void

    @StateObject private var vm: MusicArtistViewModel
    @State private var appeared = false

    init(
        artist: BaseItemDto,
        sizeClass: LayoutSizeClass,
        parentTitle: String,
        onOpenAlbum: @escaping (BaseItemDto) -> Void,
        onBack: @escaping () -> Void
    ) {
        self.artist = artist
        self.sizeClass = sizeClass
        self.parentTitle = parentTitle
        self.onOpenAlbum = onOpenAlbum
        self.onBack = onBack
        _vm = StateObject(wrappedValue: MusicArtistViewModel(artistId: artist.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                sizeClass: sizeClass,
                parentTitle: parentTitle,
                onParent: onBack,
                title: artist.name ?? "艺人"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, sizeClass.pageMargin)
                        .padding(.top, sizeClass.isNarrow ? Theme.Spacing.xxl : Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.xxl)

                    VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                        if vm.isLoading && vm.albums.isEmpty && vm.tracks.isEmpty {
                            SkeletonGrid(count: 6, minWidth: sizeClass.gridMin, spacing: sizeClass.gridSpacing)
                        } else {
                            if !vm.albums.isEmpty { albumsSection }
                            if !vm.tracks.isEmpty { topTracksSection }
                            if vm.albums.isEmpty && vm.tracks.isEmpty { emptyState }
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
        }
        .task {
            await vm.load()
            appeared = true
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        let coverSize = sizeClass.detailCoverSize
        let cover = RemoteImage(
            url: APIClient.shared.primaryImageURL(for: artist, width: 480),
            contentMode: .fill
        )
        .frame(width: coverSize, height: coverSize)
        .clipShape(Circle())
        .elevation(.e2, cornerRadius: coverSize / 2)

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

            Text(artist.name ?? "")
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
                    MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: 0)
                } label: {
                    Label("播放", systemImage: "play.fill")
                        .frame(minWidth: 88)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.tracks.isEmpty)

                Button {
                    MusicPlayerModel.shared.play(tracks: vm.tracks.shuffled(), startAt: 0)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                        .frame(minWidth: 76)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(vm.tracks.isEmpty)
            }
            .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 元信息行：专辑数 · 曲目数
    private var metaLine: String {
        var parts: [String] = []
        if let count = artist.childCount, count > 0 {
            parts.append("\(count) 张专辑")
        } else if !vm.albums.isEmpty {
            parts.append("\(vm.albums.count) 张专辑")
        }
        if !vm.tracks.isEmpty {
            parts.append("\(vm.tracks.count) 首曲目")
        }
        return parts.joined(separator: " · ")
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
                ForEach(Array(vm.albums.enumerated()), id: \.element.id) { index, album in
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
                tracks: Array(vm.tracks.prefix(10)),
                sizeClass: sizeClass,
                showHeader: false,
                onTap: { index in
                    MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: index)
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
