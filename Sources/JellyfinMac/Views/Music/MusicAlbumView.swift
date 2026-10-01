import SwiftUI

/// 专辑详情页（重做，§4.4）：面包屑返回栏 + 统一头部骨架（封面 / 标签 / 标题 / 元信息 / 流派 / 操作）+ 曲目表。
struct MusicAlbumView: View {
    let item: BaseItemDto
    let sizeClass: LayoutSizeClass
    let parentTitle: String
    let onBack: () -> Void

    @StateObject private var vm: MusicAlbumViewModel
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var store = MusicDataStore.shared

    init(item: BaseItemDto, sizeClass: LayoutSizeClass, parentTitle: String, onBack: @escaping () -> Void) {
        self.item = item
        self.sizeClass = sizeClass
        self.parentTitle = parentTitle
        self.onBack = onBack
        _vm = StateObject(wrappedValue: MusicAlbumViewModel(albumId: item.id))
    }

    private var current: BaseItemDto { vm.album ?? item }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                sizeClass: sizeClass,
                parentTitle: parentTitle,
                onParent: onBack,
                title: current.name ?? "专辑"
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, sizeClass.pageMargin)
                        .padding(.top, sizeClass.isNarrow ? Theme.Spacing.xxl : Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.xxl)
                        .background(Theme.surface)

                    Group {
                        if vm.isLoading && vm.tracks.isEmpty {
                            SkeletonList(count: 8)
                        } else if vm.tracks.isEmpty {
                            EmptyState(
                                systemImage: "music.note.list",
                                title: "这张专辑还没有曲目",
                                message: "检查服务器上的专辑内容"
                            )
                        } else {
                            TrackTable(
                                tracks: vm.tracks,
                                sizeClass: sizeClass,
                                onTap: { index in
                                    MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: index)
                                }
                            )
                        }
                    }
                    .padding(.horizontal, sizeClass.pageMargin)
                    .padding(.top, Theme.Spacing.xxl)
                    .padding(.bottom, Theme.Spacing.section)
                }
                .frame(maxWidth: sizeClass.contentMaxWidth ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task { await vm.load() }
    }

    // MARK: - 头部（窄窗纵向堆叠 / 常规横向底部对齐）

    @ViewBuilder
    private var header: some View {
        let coverSize = sizeClass.detailCoverSize
        let cover = RemoteImage(url: current.artworkURL(width: 480), contentMode: .fill)
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .elevation(.e2)

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
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Eyebrow(text: "专辑")

            Text(current.name ?? "")
                .textStyle(.title1, color: Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !metaParts.isEmpty {
                Text(metaParts.joined(separator: " · "))
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .lineLimit(1)
            }

            if let genres = current.genres, !genres.isEmpty {
                HStack(spacing: Theme.Spacing.md) {
                    ForEach(Array(genres.prefix(3).enumerated()), id: \.offset) { _, genre in
                        Chip(text: genre)
                    }
                }
            }

            actionRow
                .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionRow: some View {
        HStack(spacing: Theme.Spacing.lg) {
            Button {
                playAll()
            } label: {
                Label("播放", systemImage: "play.fill")
                    .frame(minWidth: 76)
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

            IconButton(
                systemName: current.userData?.isFavorite == true ? "heart.fill" : "heart",
                label: current.userData?.isFavorite == true ? "取消收藏" : "收藏专辑",
                size: Theme.Size.iconButtonLg,
                isOn: current.userData?.isFavorite == true,
                tint: current.userData?.isFavorite == true ? Theme.favorite : nil
            ) {
                Task { await store.toggleFavorite(current) }
            }

            albumMenu
        }
    }

    private var albumMenu: some View {
        TokenMenu(accessibilityLabel: "更多操作", help: "更多操作") {
            Button {
                if let first = vm.tracks.first { MusicPlayerModel.shared.playNext(first) }
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            .disabled(vm.tracks.isEmpty)

            Button {
                MusicPlayerModel.shared.enqueue(vm.tracks)
                ToastCenter.shared.show("已添加 \(vm.tracks.count) 首到播放队列", systemImage: "text.badge.plus")
            } label: {
                Label("整张专辑加入队列", systemImage: "text.badge.plus")
            }
            .disabled(vm.tracks.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Size.iconButtonLg, height: Theme.Size.iconButtonLg)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.borderDefault))
                .contentShape(Circle())
        }
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let artist = current.albumArtist { parts.append(artist) }
        if let year = current.productionYear { parts.append(String(year)) }
        if !vm.tracks.isEmpty {
            parts.append("\(vm.tracks.count) 首曲目")
            let total = vm.tracks.reduce(0.0) { $0 + $1.runtimeSeconds }
            if total > 0 { parts.append(formatTotalDuration(total)) }
        }
        return parts
    }

    private func playAll() {
        guard !vm.tracks.isEmpty else { return }
        MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: 0)
    }
}
