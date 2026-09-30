import SwiftUI

struct MusicArtistView: View {
    let artist: BaseItemDto
    let onOpenAlbum: (BaseItemDto) -> Void
    let onBack: () -> Void

    @StateObject private var vm: MusicArtistViewModel

    init(artist: BaseItemDto, onOpenAlbum: @escaping (BaseItemDto) -> Void, onBack: @escaping () -> Void) {
        self.artist = artist
        self.onOpenAlbum = onOpenAlbum
        self.onBack = onBack
        _vm = StateObject(wrappedValue: MusicArtistViewModel(artistId: artist.id))
    }

    var body: some View {
        VStack(spacing: 0) {
            BackBar(label: "返回", onBack: onBack)
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header

                    if !vm.albums.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            SectionHeader(title: "专辑")
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 24)],
                                alignment: .leading,
                                spacing: 28
                            ) {
                                ForEach(vm.albums) { album in
                                    PosterCard(item: album, width: 320, onTap: { onOpenAlbum(album) })
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await vm.load() }
        .overlay {
            if vm.isLoading && vm.albums.isEmpty {
                ProgressView().controlSize(.large)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 24) {
            RemoteImage(url: APIClient.shared.primaryImageURL(for: artist, width: 320), contentMode: .fill)
                .frame(width: 160, height: 160)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(Theme.border))
                .shadow(color: Theme.cardShadow, radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 12) {
                Text("艺人")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.secondaryText)
                Text(artist.name ?? "")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(Theme.primaryText)
                Text(metaLine)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
                HStack(spacing: 12) {
                    Button {
                        MusicPlayerModel.shared.play(tracks: vm.tracks, startAt: 0)
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
                }
            }
        }
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
}
