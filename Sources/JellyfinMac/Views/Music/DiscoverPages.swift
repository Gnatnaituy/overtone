import SwiftUI

// MARK: - 通用曲目列表页（收藏/最近/最常共用）

struct TrackListPage: View {
    let title: String
    let tracks: [BaseItemDto]
    var emptyIcon = "music.note"
    var emptyText = "这里还什么都没有"
    /// 推入的二级页面显示返回栏（如流派曲目）
    var onBack: (() -> Void)?

    @ObservedObject private var music = MusicPlayerModel.shared

    var body: some View {
        VStack(spacing: 0) {
            if let onBack {
                BackBar(label: "返回", onBack: onBack)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    PageHeader(title: title, meta: tracks.isEmpty ? nil : "\(tracks.count) 首") {
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
                    }

                    if tracks.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: emptyIcon)
                                .font(.system(size: 36))
                                .foregroundStyle(Theme.tertiaryText)
                            Text(emptyText)
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.secondaryText)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                    } else {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                MusicRow(
                                    track: track,
                                    isCurrent: music.currentTrack?.id == track.id,
                                    isPlaying: music.isPlaying && music.currentTrack?.id == track.id,
                                    onTap: { MusicPlayerModel.shared.play(tracks: tracks, startAt: index) }
                                )
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
    }
}

// MARK: - 收藏

struct FavoritesView: View {
    @ObservedObject private var store = MusicDataStore.shared

    var body: some View {
        TrackListPage(
            title: "收藏",
            tracks: store.favoriteTracks,
            emptyIcon: "heart",
            emptyText: "还没有收藏的曲目\n在曲目行悬停点击 ♥ 即可收藏"
        )
    }
}

// MARK: - 最近播放

struct RecentlyPlayedView: View {
    @ObservedObject private var store = MusicDataStore.shared

    var body: some View {
        TrackListPage(
            title: "最近播放",
            tracks: store.recentlyPlayedTracks,
            emptyIcon: "clock.arrow.circlepath",
            emptyText: "还没有播放记录"
        )
    }
}

// MARK: - 最常播放

struct MostPlayedView: View {
    @ObservedObject private var store = MusicDataStore.shared

    var body: some View {
        TrackListPage(
            title: "最常播放",
            tracks: store.mostPlayedTracks,
            emptyIcon: "flame",
            emptyText: "还没有播放数据，多听几次就会出现在这里"
        )
    }
}
