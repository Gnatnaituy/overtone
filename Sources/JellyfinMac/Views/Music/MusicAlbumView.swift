import SwiftUI

/// 专辑详情页（重做，§4.4）：面包屑返回栏 + 统一头部骨架（封面 / 标签 / 标题 / 元信息 / 流派 / 操作）+ 曲目表。
struct MusicAlbumView: View {
    let item: MediaItem
    let sizeClass: LayoutSizeClass
    let parentTitle: String
    let onBack: () -> Void

    /// 曲库里的专辑对象（带专辑艺人 / 年份等元数据）；nil 时回落到传入的 item
    @State private var detail: MediaItem?
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = false
    // 这里**不**观察 MusicPlayerModel / MusicDataStore：
    // - `music` 在 body 里从未被读取，但观察它会让播放/暂停、切歌、**音量拖动**
    //   （`volume` 也是 @Published，拖一次滑块几十次发布）都重建整个专辑页；
    // - `store` 只在收藏按钮的动作闭包里用到，观察它等于让每次曲库变更都白重绘一页。
    // 曲目表的「当前曲」高亮由 TrackTableRows 自己观察播放器，范围收在表内。

    init(item: MediaItem, sizeClass: LayoutSizeClass, parentTitle: String, onBack: @escaping () -> Void) {
        self.item = item
        self.sizeClass = sizeClass
        self.parentTitle = parentTitle
        self.onBack = onBack
    }

    /// 头部展示用的专辑对象：曲库里那份（元数据更全）优先，取不到就用传入的 item
    private var current: MediaItem { detail ?? item }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                sizeClass: sizeClass,
                parentTitle: parentTitle,
                onParent: onBack,
                title: current.title
            )

            ScrollView {
                // 表头吸顶（§2.3）：曲目表放进 pinned Section
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    header
                        .padding(.horizontal, sizeClass.pageMargin)
                        .padding(.top, sizeClass.isNarrow ? Theme.Spacing.xxl : Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.xxl)

                    if isLoading && tracks.isEmpty {
                        SkeletonList(count: 8)
                            .padding(.horizontal, sizeClass.pageMargin)
                            .padding(.bottom, Theme.Spacing.section)
                    } else if tracks.isEmpty {
                        EmptyState(
                            systemImage: "music.note.list",
                            title: "这张专辑还没有曲目",
                            message: "检查服务器上的专辑内容"
                        )
                        .padding(.bottom, Theme.Spacing.section)
                    } else {
                        Section {
                            TrackTableRows(
                                tracks: tracks,
                                sizeClass: sizeClass,
                                onTap: { index in
                                    MusicPlayerModel.shared.play(tracks: tracks, startAt: index)
                                }
                            )
                            .padding(.horizontal, sizeClass.pageMargin)
                            .padding(.bottom, Theme.Spacing.section)
                        } header: {
                            TrackTableHeader(sizeClass: sizeClass)
                                .padding(.horizontal, sizeClass.pageMargin)
                        }
                    }
                }
                .frame(maxWidth: sizeClass.contentMaxWidth ?? .infinity, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
            // 滚动体不参与内容列宽度协商：头部再宽也不把面包屑顶出窗口右缘
            .pageBodyWidthClamp()
        }
        .task { await load() }
    }

    // MARK: - 头部（窄窗纵向堆叠 / 常规横向底部对齐）

    @ViewBuilder
    private var header: some View {
        let coverSize = sizeClass.detailCoverSize
        // 全部封面统一圆角（§7.2 规则 2）；paper 下换成印刷套封的 2px 圆角（§4.6）
        let coverRadius: CGFloat = Theme.isPaper ? Theme.Radius.cover : Theme.Radius.md
        let cover = RemoteImage(ref: current.artworkRef(width: 480), contentMode: .fill)
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: coverRadius))
            .pagesCoverChrome(radius: coverRadius, level: .e2)

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
        // 只算一次：`metaParts` 含一次 O(曲目数) 的时长求和，
        // 写成 `if !metaParts.isEmpty { Text(metaParts…) }` 会算两遍
        let meta = metaParts
        return VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Eyebrow(text: "专辑")

            Text(current.title)
                .textStyle(.title1, color: Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if !meta.isEmpty {
                Text(meta.joined(separator: " · "))
                    .textStyle(.bodySM, color: Theme.textSecondary)
                    .lineLimit(1)
            }

            // 流派（领域模型统一字段；Jellyfin 有，飞牛可能给空数组）
            if !current.genres.isEmpty {
                FlowLayout(spacing: Theme.Spacing.sm, lineSpacing: Theme.Spacing.sm) {
                    ForEach(current.genres.prefix(4), id: \.self) { genre in
                        Text(genre)
                            .textStyle(.caption, color: Theme.textSecondary)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(Theme.surfaceSunken)
                            )
                            .overlay(
                                Capsule().strokeBorder(Theme.borderSubtle)
                            )
                    }
                }
                .padding(.top, Theme.Spacing.sm)
            }

            actionRow
                .padding(.top, Theme.Spacing.xs)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 操作行：可用宽度不够时换行（§4.4「操作行换行」），而不是把页面顶宽
    private var actionRow: some View {
        FlowLayout(spacing: Theme.Spacing.lg, lineSpacing: Theme.Spacing.md) {
            Button {
                playAll()
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

            // 能力门控：服务器不支持专辑收藏时（飞牛）按钮置灰，收藏只落在本地存储
            IconButton(
                systemName: current.isFavorite ? "heart.fill" : "heart",
                label: current.isFavorite ? "取消收藏" : "收藏专辑",
                size: Theme.Size.iconButtonLg,
                isOn: current.isFavorite,
                tint: current.isFavorite ? Theme.favorite : nil,
                help: albumFavoriteHelp
            ) {
                Task { await MusicDataStore.shared.toggleFavorite(current) }
            }
            .opacity(albumFavoriteSupported ? 1 : 0.55)

            albumMenu
        }
    }

    private var albumMenu: some View {
        TokenMenu(accessibilityLabel: "更多操作", help: "更多操作") {
            Button {
                if let first = tracks.first { MusicPlayerModel.shared.playNext(first) }
            } label: {
                Label("下一首播放", systemImage: "arrow.up.circle")
            }
            .disabled(tracks.isEmpty)

            Button {
                MusicPlayerModel.shared.enqueue(tracks)
                ToastCenter.shared.show("已添加 \(tracks.count) 首到播放队列", systemImage: "text.badge.plus")
            } label: {
                Label("整张专辑加入队列", systemImage: "text.badge.plus")
            }
            .disabled(tracks.isEmpty)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: Theme.Size.iconButtonLg, height: Theme.Size.iconButtonLg)
                .modifier(AlbumMenuChrome())
                .contentShape(Circle())
        }
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if let artist = current.artistName { parts.append(artist) }
        if let year = current.year { parts.append(String(year)) }
        if let count = current.childCount, count > 0 {
            parts.append("\(count) 首曲目")
        } else if !tracks.isEmpty {
            parts.append("\(tracks.count) 首曲目")
            let total = tracks.reduce(0.0) { $0 + $1.duration }
            if total > 0 { parts.append(formatTotalDuration(total)) }
        }
        return parts
    }

    /// 专辑收藏是否由服务器支持（飞牛只支持曲目收藏）
    private var albumFavoriteSupported: Bool {
        AppState.shared.capabilities.albumArtistFavorites
    }

    /// 不支持时按钮置灰，并用 tooltip 说明「已在本机记住」
    private var albumFavoriteHelp: String? {
        albumFavoriteSupported ? nil : "当前服务器不支持专辑收藏（本地已记住）"
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        // 专辑对象：曲库里已加载的那份（元数据更全）；取不到就用传入的 item
        detail = MusicDataStore.shared.albums.first { $0.id == item.id }
        // 曲目表：后端支持就走单独接口（按唱片顺位排序），否则 MusicDataStore 用已加载曲库兜底
        tracks = await MusicDataStore.shared.albumTracks(albumID: item.id)
    }

    private func playAll() {
        guard !tracks.isEmpty else { return }
        MusicPlayerModel.shared.play(tracks: tracks, startAt: 0)
    }
}

/// 「更多操作」按钮外观：glass = 圆形玻璃控件；paper = 幽灵按钮（无底无框，§4.1）
private struct AlbumMenuChrome: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.isPaper {
            content
        } else {
            content.glassControl(cornerRadius: Theme.Size.iconButtonLg / 2)
        }
    }
}
