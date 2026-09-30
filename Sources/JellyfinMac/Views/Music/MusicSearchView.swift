import SwiftUI

/// 搜索页（设计稿）：大搜索框 + 过滤分段（全部/歌曲/专辑/艺人/播放列表）+ 混合结果列表
struct MusicSearchView: View {
    /// ⌘F 一次性聚焦请求（消费后自动复位）
    @Binding var focusRequest: Bool
    let onOpenAlbum: (BaseItemDto) -> Void
    let onOpenArtist: (BaseItemDto) -> Void
    let onOpenPlaylist: (Playlist) -> Void

    @StateObject private var vm = MusicSearchViewModel()
    @ObservedObject private var playlistStore = PlaylistStore.shared
    @State private var searchText = ""
    @State private var filter = "all"
    @FocusState private var searchFocused: Bool

    private enum ResultKind {
        case track(BaseItemDto)
        case album(BaseItemDto)
        case artist(BaseItemDto)
        case playlist(Playlist)

        var id: String {
            switch self {
            case .track(let t): return "t-\(t.id)"
            case .album(let a): return "a-\(a.id)"
            case .artist(let a): return "r-\(a.id)"
            case .playlist(let p): return "p-\(p.id.uuidString)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        emptyPrompt
                    } else if vm.isSearching && vm.isEmpty && matchedPlaylists.isEmpty {
                        ProgressView()
                            .controlSize(.large)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, 80)
                    } else if results.isEmpty {
                        noResults
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(results, id: \.id) { kind in
                                resultRow(kind)
                            }
                        }
                        .padding(.vertical, 6)
                        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: results.map(\.id))
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task(id: searchText) { vm.search(searchText) }
        .onChange(of: focusRequest) { requested in
            if requested {
                searchFocused = true
                focusRequest = false
            }
        }
        .onAppear {
            if focusRequest {
                searchFocused = true
                focusRequest = false
            }
        }
    }

    // MARK: - 顶栏（搜索框 + 过滤分段，兼作窗口拖拽区）

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.secondaryText)
                TextField("搜索歌曲、专辑、艺人...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { vm.search(searchText) }
                if !searchText.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { searchText = "" }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .help("清空搜索")
                    .accessibilityLabel("清空搜索")
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(Theme.background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .strokeBorder(searchFocused ? Theme.primaryBlue : Theme.border, lineWidth: searchFocused ? 1.5 : 1)
            )
            .shadow(color: searchFocused ? Theme.primaryBlue.opacity(0.12) : .clear, radius: 8, y: 2)
            .animation(.easeOut(duration: 0.15), value: searchFocused)
            .frame(maxWidth: 560)

            SegmentedControl(
                segments: [
                    .init("all", "全部"),
                    .init("tracks", "歌曲"),
                    .init("albums", "专辑"),
                    .init("artists", "艺人"),
                    .init("playlists", "播放列表")
                ],
                selection: $filter
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 14)
        .background(WindowDragArea().background(Theme.background))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: - 结果集合

    /// 过滤后的结果序列
    private var results: [ResultKind] {
        switch filter {
        case "tracks": return vm.tracks.map { .track($0) }
        case "albums": return vm.albums.map { .album($0) }
        case "artists": return vm.artists.map { .artist($0) }
        case "playlists": return matchedPlaylists.map { .playlist($0) }
        default:
            // 全部：按类型轮转交错（歌曲/专辑/艺人/播放列表），贴合设计稿混排
            var mixed: [ResultKind] = []
            let groups: [[ResultKind]] = [
                vm.tracks.map { .track($0) },
                vm.albums.map { .album($0) },
                vm.artists.map { .artist($0) },
                matchedPlaylists.map { .playlist($0) }
            ]
            var indexes = [Int](repeating: 0, count: groups.count)
            var exhausted = false
            while !exhausted {
                exhausted = true
                for (g, group) in groups.enumerated() where indexes[g] < group.count {
                    mixed.append(group[indexes[g]])
                    indexes[g] += 1
                    exhausted = false
                }
            }
            return mixed
        }
    }

    /// 本地播放列表按名称匹配（服务端搜索不含播放列表）
    private var matchedPlaylists: [Playlist] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !term.isEmpty else { return [] }
        return playlistStore.allPlaylists.filter { $0.name.lowercased().contains(term) }
    }

    // MARK: - 结果行（设计稿：图标方块 + 标题 + 类型副标题 + 时长）

    @ViewBuilder
    private func resultRow(_ kind: ResultKind) -> some View {
        switch kind {
        case .track(let track):
            SearchResultRow(
                icon: "music.note",
                iconShape: .rect,
                title: track.name ?? "",
                subtitle: [track.albumArtist ?? track.album, "歌曲"].compactMap { $0 }.joined(separator: " · "),
                trailing: formatPlaybackTime(track.runtimeSeconds)
            ) {
                if let index = vm.tracks.firstIndex(where: { $0.id == track.id }) {
                    MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: index)
                }
            }
        case .album(let album):
            SearchResultRow(
                icon: "opticaldisc",
                iconShape: .rect,
                title: album.name ?? "",
                subtitle: "\(album.albumArtist ?? "") · 专辑",
                trailing: nil
            ) {
                onOpenAlbum(album)
            }
        case .artist(let artist):
            SearchResultRow(
                icon: "person.crop.circle",
                iconShape: .circle,
                title: artist.name ?? "",
                subtitle: "艺人",
                trailing: nil
            ) {
                onOpenArtist(artist)
            }
        case .playlist(let playlist):
            SearchResultRow(
                icon: "music.note.list",
                iconShape: .rect,
                title: playlist.name,
                subtitle: "\(playlist.trackIds.count) 首 · 播放列表",
                trailing: nil
            ) {
                onOpenPlaylist(playlist)
            }
        }
    }

    // MARK: - 空状态

    private var emptyPrompt: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiaryText)
            Text("搜索歌曲、专辑、艺术家、播放列表")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 100)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "music.note")
                .font(.system(size: 40))
                .foregroundStyle(Theme.tertiaryText)
            Text("未找到相关内容")
                .font(.system(size: 14))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 100)
    }
}

/// 搜索结果行（设计稿）：图标方块 + 标题/类型副标题 + 时长，悬停浅底、行间细分隔线
private struct SearchResultRow: View {
    enum IconShape {
        case rect, circle
    }

    let icon: String
    let iconShape: IconShape
    let title: String
    let subtitle: String
    let trailing: String?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    switch iconShape {
                    case .rect:
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .fill(Theme.surface2)
                    case .circle:
                        Circle()
                            .fill(Theme.surface2)
                    }
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.secondaryText)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }

                Spacer()

                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 44, alignment: .trailing)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSm)
                    .fill(hovered ? Theme.hoverFill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.border.opacity(0.6))
                .frame(height: 1)
                .padding(.leading, 64)
                .opacity(hovered ? 0 : 1)
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovered = $0 }
    }
}
