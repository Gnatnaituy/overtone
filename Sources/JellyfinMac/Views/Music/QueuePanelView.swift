import SwiftUI

/// 播放队列抽屉（重做）：显示当前队列、点击跳播、拖动排序、移除。
struct QueuePanelView: View {
    @ObservedObject private var music = MusicPlayerModel.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            if music.queue.isEmpty {
                EmptyState(
                    systemImage: "music.note.list",
                    title: "队列为空",
                    message: "去资料库点一首歌吧"
                )
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                queueList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Theme.borderSubtle)
                .frame(width: 1)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("播放队列")
                .textStyle(.body, weight: .semibold, color: Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text("\(music.queue.count) 首")
                .textStyle(.caption, color: Theme.textSecondary)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.surfaceSunken))

            Spacer(minLength: 0)

            PlainIconButton(systemName: "xmark", label: "关闭队列", action: onClose)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .frame(height: 52)
    }

    private var queueList: some View {
        List {
            ForEach(Array(music.queue.enumerated()), id: \.element.id) { index, track in
                QueueRow(
                    track: track,
                    index: index,
                    isCurrent: index == music.currentIndex,
                    isPlaying: music.isPlaying && index == music.currentIndex,
                    showsIndex: true,
                    onRemove: index == music.currentIndex ? nil : { music.removeQueueItem(at: index) },
                    onTap: { music.jump(to: index) }
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }
            .onMove { source, destination in
                music.moveQueueItems(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 56)
    }
}
