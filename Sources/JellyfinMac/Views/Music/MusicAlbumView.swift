import SwiftUI

/// 专辑详情页（设计稿）：返回栏 + 大封面头部（标签/标题/元信息/流派/操作按钮）+ 表格曲目列表
struct MusicAlbumView: View {
    let item: BaseItemDto
    let onBack: () -> Void
    @StateObject private var vm: MusicAlbumViewModel
    @ObservedObject private var music = MusicPlayerModel.shared
    @ObservedObject private var store = MusicDataStore.shared

    init(item: BaseItemDto, onBack: @escaping () -> Void) {
        self.item = item
        self.onBack = onBack
        _vm = StateObject(wrappedValue: MusicAlbumViewModel(albumId: item.id))
    }

    private var current: BaseItemDto { vm.album ?? item }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 640
            VStack(spacing: 0) {
                BackBar(label: "返回", onBack: onBack)
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        header(compact: compact)

                        if !vm.tracks.isEmpty {
                            TrackTable(
                                tracks: vm.tracks,
                                onTap: { index in
                                    MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: index)
                                }
                            )
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .padding(.horizontal, compact ? 20 : 32)
                    .padding(.top, 28)
                    .padding(.bottom, 32)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await vm.load() }
        .overlay {
            if vm.isLoading && vm.album == nil {
                ProgressView().controlSize(.large)
            }
        }
    }

    // MARK: - 头部（设计稿：封面 + 标签 + 标题 + 元信息 + 流派标签 + 操作按钮；窄窗口纵向堆叠）

    private func header(compact: Bool) -> some View {
        let coverSize: CGFloat = compact ? 160 : 220
        let cover = RemoteImage(url: current.artworkURL(width: 480), contentMode: .fill)
            .frame(width: coverSize, height: coverSize)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg))
            .shadow(color: Theme.cardShadow, radius: 10, y: 5)

        return Group {
            if compact {
                VStack(alignment: .leading, spacing: 20) {
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
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("专辑")
                .font(.system(size: 11, weight: .semibold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Theme.secondaryText)

            Text(current.name ?? "")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Theme.primaryText)
                .lineLimit(2)

            // 元信息行：艺人 · 年份 · 曲目数 · 总时长
            Text(metaParts.joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)

            if let genres = current.genres, !genres.isEmpty {
                HStack(spacing: 8) {
                    ForEach(Array(genres.prefix(3).enumerated()), id: \.offset) { _, genre in
                        Chip(text: genre)
                    }
                }
            }

            HStack(spacing: 12) {
                Button {
                    playAll()
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(vm.tracks.isEmpty)

                Button {
                    MusicPlayerModel.shared.play(tracks: vm.tracks.shuffled(), startAt: 0)
                } label: {
                    Label("随机播放", systemImage: "shuffle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(vm.tracks.isEmpty)

                Button {
                    Task { await store.toggleFavorite(current) }
                } label: {
                    Image(systemName: current.userData?.isFavorite == true ? "heart.fill" : "heart")
                        .font(.system(size: 14))
                        .foregroundStyle(current.userData?.isFavorite == true ? Color(hex: 0xFF5C8A) : Theme.secondaryText)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.surface))
                        .overlay(Circle().strokeBorder(Theme.border))
                        .scaleEffect(current.userData?.isFavorite == true ? 1.05 : 1)
                }
                .buttonStyle(.plain)
                .animation(.spring(response: 0.3, dampingFraction: 0.6), value: current.userData?.isFavorite == true)
                .help(current.userData?.isFavorite == true ? "取消收藏" : "收藏专辑")
            }
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
