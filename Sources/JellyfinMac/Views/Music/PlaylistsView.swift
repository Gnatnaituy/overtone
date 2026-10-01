import SwiftUI

/// 播放列表页（重做）：统一顶栏 + 网格/列表视图切换 + 新建 / 智能列表。
struct PlaylistsView: View {
    let sizeClass: LayoutSizeClass
    let onOpenPlaylist: (Playlist) -> Void
    @Binding var searchQuery: String
    let searchFocusRequest: Int
    let onSearchSubmit: () -> Void

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @ObservedObject private var store = MusicDataStore.shared
    @State private var viewMode: LibraryViewMode = .grid
    @State private var showCreatePlaylist = false
    @State private var showCreateSmart = false
    @State private var newPlaylistName = ""
    @State private var newSmartName = ""
    @State private var newSmartKeyword = ""

    var body: some View {
        VStack(spacing: 0) {
            PageTopBar(
                sizeClass: sizeClass,
                title: "播放列表",
                subtitle: playlistStore.allPlaylists.isEmpty ? nil : "\(playlistStore.allPlaylists.count) 个",
                searchText: $searchQuery,
                searchFocusRequest: searchFocusRequest,
                onSearchSubmit: onSearchSubmit
            ) {
                HStack(spacing: Theme.Spacing.md) {
                    ViewModeToggle(mode: $viewMode)

                    Button {
                        newPlaylistName = ""
                        showCreatePlaylist = true
                    } label: {
                        Label("新建", systemImage: "plus")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("新建播放列表")

                    Button {
                        newSmartName = ""
                        newSmartKeyword = ""
                        showCreateSmart = true
                    } label: {
                        Label("智能", systemImage: "sparkles")
                    }
                    .buttonStyle(SecondaryButtonStyle(compact: true))
                    .help("新建智能播放列表")
                }
            }

            ScrollView {
                PageContent(sizeClass: sizeClass) {
                    PlaylistGrid(
                        sizeClass: sizeClass,
                        onOpenPlaylist: onOpenPlaylist,
                        viewMode: viewMode
                    )
                }
            }
            .scrollIndicators(.hidden)
            .background(ScrollBarHider())
        }
        .background(Theme.canvas.ignoresSafeArea())
        .task { await store.loadIfNeeded() }
        .alert("新建播放列表", isPresented: $showCreatePlaylist) {
            TextField("播放列表名称", text: $newPlaylistName)
            Button("创建") {
                let created = playlistStore.create(name: newPlaylistName)
                newPlaylistName = ""
                onOpenPlaylist(created)
            }
            Button("取消", role: .cancel) {}
        }
        .alert("新建智能播放列表", isPresented: $showCreateSmart) {
            TextField("播放列表名称", text: $newSmartName)
            TextField("艺术家关键字（如：坂本龍一）", text: $newSmartKeyword)
            Button("创建") {
                let created = playlistStore.createSmart(name: newSmartName, artistKeyword: newSmartKeyword)
                newSmartName = ""
                newSmartKeyword = ""
                onOpenPlaylist(created)
            }
            Button("取消", role: .cancel) {}
        }
    }
}

/// 播放列表网格 / 列表（资料库「播放列表」分段与本页共用）
struct PlaylistGrid: View {
    let sizeClass: LayoutSizeClass
    let onOpenPlaylist: (Playlist) -> Void
    var viewMode: LibraryViewMode = .grid

    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var appeared = false

    private var metrics: TrackRowMetrics { TrackRowMetrics(sizeClass: sizeClass) }

    var body: some View {
        Group {
            if playlistStore.allPlaylists.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "还没有播放列表",
                    message: "用顶栏的「新建」创建一个，或让「智能」按艺人关键字自动收集"
                )
            } else if viewMode == .grid {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: sizeClass.gridMin, maximum: sizeClass.gridMax),
                                       spacing: sizeClass.gridSpacing.h)],
                    alignment: .leading,
                    spacing: sizeClass.gridSpacing.v
                ) {
                    ForEach(Array(playlistStore.allPlaylists.enumerated()), id: \.element.id) { index, playlist in
                        PlaylistCard(playlist: playlist, width: 320) { onOpenPlaylist(playlist) }
                            .staggerAppear(index: index, visible: appeared)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(playlistStore.allPlaylists.enumerated()), id: \.element.id) { index, playlist in
                        LibraryListRow(
                            title: playlist.name,
                            subtitle: playlist.isSmart ? "智能播放列表" : "\(playlist.trackIds.count) 首曲目",
                            artworkURL: nil,
                            isCurrent: false,
                            isPlaying: false,
                            metrics: metrics,
                            onTap: { onOpenPlaylist(playlist) }
                        )
                        if index < playlistStore.allPlaylists.count - 1 {
                            RowDivider()
                        }
                    }
                }
                .libraryTableChrome()
            }
        }
        .onAppear { appeared = true }
    }
}
