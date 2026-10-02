import SwiftUI

/// 播放列表详情页（重做，§4.4）：面包屑 + 统一头部骨架（2×2 封面拼图）+ 曲目表。
/// 本地播放列表支持「上移 / 下移」调整顺序（拖拽排序的键盘等价物）。
struct PlaylistDetailView: View {
    let playlist: Playlist
    let sizeClass: LayoutSizeClass
    let parentTitle: String
    let onBack: () -> Void

    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var syncService = PlaylistSyncService.shared
    @ObservedObject private var music = MusicPlayerModel.shared

    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    /// 曲目计算结果缓存：数据/规则变化时重算，避免每次渲染重复过滤
    @State private var computedTracks: [BaseItemDto] = []
    @State private var coverTracks: [BaseItemDto] = []
    @State private var appeared = false

    private var livePlaylist: Playlist? {
        playlistStore.allPlaylists.first { $0.id == playlist.id }
    }

    private var isSmart: Bool { livePlaylist?.isSmart == true }

    private func recomputeTracks() {
        guard let live = livePlaylist else {
            computedTracks = []
            coverTracks = []
            return
        }
        if live.isSmart, let keyword = live.smartRule?.artistKeyword {
            computedTracks = store.smartTracks(keyword: keyword)
        } else {
            computedTracks = live.trackIds.compactMap { store.track(id: $0) }
        }
        coverTracks = Array(computedTracks.prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(
                sizeClass: sizeClass,
                parentTitle: parentTitle,
                onParent: onBack,
                title: livePlaylist?.name ?? playlist.name
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, sizeClass.pageMargin)
                        .padding(.top, sizeClass.isNarrow ? Theme.Spacing.xxl : Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.xxl)

                    trackSection
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
        .task {
            await store.loadIfNeeded()
            recomputeTracks()
            appeared = true
        }
        .onChange(of: store.tracks) { _ in recomputeTracks() }
        .onChange(of: playlistStore.allPlaylists) { _ in recomputeTracks() }
        .alert("重命名播放列表", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let live = livePlaylist { playlistStore.rename(live, to: renameText) }
            }
            Button("取消", role: .cancel) {}
        }
        // 破坏性操作走统一二次确认弹窗（§4.5）
        .onChange(of: showDeleteConfirm) { wantsDelete in
            guard wantsDelete else { return }
            showDeleteConfirm = false
            DialogCenter.shared.confirm(
                title: "删除播放列表",
                message: "确定要删除「\(livePlaylist?.name ?? "")」吗？此操作不可撤销。",
                confirmTitle: "删除"
            ) {
                if let live = livePlaylist { playlistStore.delete(live) }
                onBack()
            }
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var header: some View {
        let coverSize = sizeClass.detailCoverSize
        let cover = PlaylistCoverMosaic(
            tracks: coverTracks,
            size: coverSize,
            fallbackIcon: isSmart ? "sparkles" : "music.note.list"
        )

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
            Eyebrow(text: isSmart ? "智能播放列表" : "播放列表")

            Text(livePlaylist?.name ?? playlist.name)
                .textStyle(.title1, color: Theme.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                if let keyword = livePlaylist?.smartRule?.artistKeyword {
                    Text("艺术家包含「\(keyword)」· 每次打开自动更新")
                        .textStyle(.footnote, color: Theme.textSecondary)
                }
                Text("\(computedTracks.count) 首曲目")
                    .textStyle(.bodySM, color: Theme.textSecondary)
                if isSmart, livePlaylist?.serverId != nil {
                    Text("已镜像为服务器播放列表，匹配结果自动同步")
                        .textStyle(.caption, color: Theme.tealText)
                }
                if let error = syncService.lastError {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                        Text("同步失败：\(error)")
                            .textStyle(.caption)
                    }
                    .foregroundStyle(Theme.danger)
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
                MusicPlayerModel.shared.play(tracks: computedTracks, startAt: 0)
            } label: {
                Label("播放", systemImage: "play.fill")
                    .frame(minWidth: 76)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(computedTracks.isEmpty)

            Button {
                MusicPlayerModel.shared.play(tracks: computedTracks.shuffled(), startAt: 0)
            } label: {
                Label("随机播放", systemImage: "shuffle")
                    .frame(minWidth: 76)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(computedTracks.isEmpty)

            IconButton(
                systemName: "arrow.triangle.2.circlepath",
                label: "与服务器同步播放列表",
                size: Theme.Size.iconButtonLg
            ) {
                Task { await syncService.syncAll() }
            }

            IconButton(
                systemName: "pencil",
                label: "重命名",
                size: Theme.Size.iconButtonLg
            ) {
                renameText = livePlaylist?.name ?? ""
                showRename = true
            }

            IconButton(
                systemName: "trash",
                label: "删除播放列表",
                size: Theme.Size.iconButtonLg,
                tint: Theme.danger
            ) {
                showDeleteConfirm = true
            }
        }
    }

    // MARK: - 曲目

    @ViewBuilder
    private var trackSection: some View {
        if store.isLoading && computedTracks.isEmpty {
            SkeletonList(count: 8)
        } else if computedTracks.isEmpty {
            EmptyState(
                systemImage: isSmart ? "sparkles" : "music.note",
                title: isSmart ? "没有匹配到曲目" : "播放列表是空的",
                message: isSmart ? "换一个艺术家关键字试试" : "在曲目行的「更多」菜单里添加到这个播放列表"
            )
        } else {
            let metrics = TrackRowMetrics(sizeClass: sizeClass)
            LazyVStack(spacing: 0) {
                ForEach(Array(computedTracks.enumerated()), id: \.element.id) { index, track in
                    MusicRow(
                        track: track,
                        index: index,
                        metrics: metrics,
                        isCurrent: music.currentTrack?.id == track.id,
                        isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                        onRemove: isSmart ? nil : {
                            if let live = livePlaylist {
                                playlistStore.remove(trackId: track.id, from: live)
                            }
                        },
                        onTap: { MusicPlayerModel.shared.play(tracks: computedTracks, startAt: index) }
                    )
                    .contextMenu {
                        if !isSmart {
                            Button {
                                if let live = livePlaylist {
                                    playlistStore.shiftTrack(in: live, trackId: track.id, offset: -1)
                                }
                            } label: {
                                Label("上移", systemImage: "arrow.up")
                            }
                            .disabled(index == 0)

                            Button {
                                if let live = livePlaylist {
                                    playlistStore.shiftTrack(in: live, trackId: track.id, offset: 1)
                                }
                            } label: {
                                Label("下移", systemImage: "arrow.down")
                            }
                            .disabled(index == computedTracks.count - 1)
                        }
                    }
                    .staggerAppear(index: index, visible: appeared)
                }
            }
        }
    }
}
