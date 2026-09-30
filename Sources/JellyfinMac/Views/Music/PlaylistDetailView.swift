import SwiftUI

struct PlaylistDetailView: View {
    let playlist: Playlist

    @ObservedObject private var store = MusicDataStore.shared
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var syncService = PlaylistSyncService.shared
    @ObservedObject private var music = MusicPlayerModel.shared
    @State private var showRename = false
    @State private var showDeleteConfirm = false
    @State private var renameText = ""
    /// 曲目计算结果缓存：数据/规则变化时重算，避免每次渲染重复过滤
    @State private var computedTracks: [BaseItemDto] = []
    /// 图标用封面（随机取 4 首，2x2 拼图）
    @State private var coverTracks: [BaseItemDto] = []

    private var livePlaylist: Playlist? {
        playlistStore.allPlaylists.first { $0.id == playlist.id }
    }

    private var tracks: [BaseItemDto] { computedTracks }

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
        // 随机取 4 首封面构成播放列表图标
        coverTracks = Array(computedTracks.shuffled().prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            // 播放列表从侧栏直接进入，顶部「返回」没有意义（2026-09-30 去掉）。
            // 只留一条细拖拽区，窗口仍可从内容区顶部拖动。
            WindowDragArea()
                .frame(height: 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if !tracks.isEmpty {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                MusicRow(
                                    track: track,
                                    isCurrent: music.currentTrack?.id == track.id,
                                    isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                                    onRemove: livePlaylist?.isSmart == true ? nil : {
                                        if let live = livePlaylist {
                                            playlistStore.remove(trackId: track.id, from: live)
                                        }
                                    },
                                    onTap: { MusicPlayerModel.shared.play(tracks: tracks, startAt: index) }
                                )
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: tracks)
                    } else if store.isLoading {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 60)
                    } else {
                        emptyHint
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            await store.loadIfNeeded()
            recomputeTracks()
        }
        .onChange(of: store.tracks) { _ in
            recomputeTracks()
        }
        .onChange(of: playlistStore.allPlaylists) { _ in
            recomputeTracks()
        }
        .alert("重命名播放列表", isPresented: $showRename) {
            TextField("名称", text: $renameText)
            Button("确定") {
                if let live = livePlaylist {
                    playlistStore.rename(live, to: renameText)
                }
            }
            Button("取消", role: .cancel) {}
        }
        .alert("删除播放列表", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) {
                if let live = livePlaylist {
                    playlistStore.delete(live)
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("确定要删除「\(livePlaylist?.name ?? "")」吗？")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            playlistIcon

            VStack(alignment: .leading, spacing: 8) {
                Text(livePlaylist?.name ?? "")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                    .lineLimit(1)
                if let keyword = livePlaylist?.smartRule?.artistKeyword {
                    Text("艺术家包含「\(keyword)」· 每次打开自动更新")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                }
                if livePlaylist?.isSmart == true, livePlaylist?.serverId != nil {
                    Text("已镜像为服务器播放列表，匹配结果自动同步")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentText)
                }
                Text("\(tracks.count) 首曲目")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                if let error = syncService.lastError {
                    Text("同步失败：\(error)")
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            Spacer()

            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        MusicPlayerModel.shared.play(tracks: tracks.shuffled(), startAt: 0)
                    } label: {
                        Label("随机播放", systemImage: "shuffle")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(tracks.isEmpty)

                    Button {
                        MusicPlayerModel.shared.play(tracks: tracks, startAt: 0)
                    } label: {
                        Label("播放全部", systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(tracks.isEmpty)
                }

                HStack(spacing: 8) {
                    Button {
                        Task { await syncService.syncAll() }
                    } label: {
                        if syncService.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 30, height: 30)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondaryText)
                                .frame(width: 30, height: 30)
                                .background(Circle().fill(Theme.hoverFill))
                        }
                    }
                    .buttonStyle(.plain)
                    .help("与服务器同步播放列表")
                    .accessibilityLabel("与服务器同步播放列表")

                    Button {
                        renameText = livePlaylist?.name ?? ""
                        showRename = true
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.hoverFill))
                    }
                    .buttonStyle(.plain)
                    .help("重命名")
                    .accessibilityLabel("重命名")

                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Theme.hoverFill))
                    }
                    .buttonStyle(.plain)
                    .help("删除播放列表")
                    .accessibilityLabel("删除播放列表")
                }
            }
        }
    }

    /// 播放列表图标：随机取 4 首曲目封面拼成 2x2；无曲目时回退渐变音符
    private var playlistIcon: some View {
        Group {
            if coverTracks.count >= 2 {
                VStack(spacing: 2) {
                    HStack(spacing: 2) {
                        coverThumb(cover(at: 0))
                        coverThumb(cover(at: 1))
                    }
                    HStack(spacing: 2) {
                        coverThumb(cover(at: 2))
                        coverThumb(cover(at: 3))
                    }
                }
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
                .shadow(color: Theme.cardShadow, radius: 8, y: 4)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Theme.accentGradient)
                        .frame(width: 96, height: 96)
                    Image(systemName: livePlaylist?.isSmart == true ? "sparkles" : "music.note.list")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                }
                .shadow(color: Theme.accentStart.opacity(0.35), radius: 12, y: 6)
            }
        }
    }

    private func cover(at index: Int) -> BaseItemDto? {
        coverTracks.indices.contains(index) ? coverTracks[index] : nil
    }

    private func coverThumb(_ track: BaseItemDto?) -> some View {
        RemoteImage(url: track?.artworkURL(width: 128), contentMode: .fill)
            .frame(width: 47, height: 47)
            .clipped()
    }

    private var emptyHint: some View {
        VStack(spacing: 10) {
            Image(systemName: livePlaylist?.isSmart == true ? "sparkles" : "music.note")
                .font(.system(size: 36))
                .foregroundStyle(Theme.tertiaryText)
            Text(livePlaylist?.isSmart == true ? "没有匹配到曲目，换一个关键字试试" : "播放列表是空的，在曲目上悬停点击 + 添加")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
    }
}
