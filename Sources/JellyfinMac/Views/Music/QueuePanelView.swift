import SwiftUI

/// 播放队列面板（重做 §7.2）：玻璃厚材质悬浮面板，显示当前队列、点击跳播、拖动排序、移除。
///
/// - 标题 13/600 + 计数 chip，行高 52（§4.5 列表行）；
/// - 当前行 `surfaceSelected` + 3pt 指示条 + 频谱；hover / 键盘 focus 显示移除按钮与拖拽把手；
/// - 排序沿用 `List` 的 `.onMove`（`music.moveQueueItems`），交互逻辑与构造签名不变。
struct QueuePanelView: View {
    @ObservedObject private var music = MusicPlayerModel.shared
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header

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
        // chrome 层（§7.2 规则 1）：抽屉 / 面板走玻璃厚材质
        .glassPanel(.thick, cornerRadius: Theme.Size.panelRadius, elevation: .e3)
    }

    @ViewBuilder
    private var header: some View {
        if Theme.isPaper {
            // paper（§6.6）：规则标签形态 ──── 播放队列 ──── 右侧「清空」跟在细线后
            RuleLabel("播放队列") {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("\(music.queue.count) 首")
                        .textStyle(.monoSM, color: Theme.Paper.ink3)
                    clearButton
                    PlainIconButton(systemName: "xmark", label: "关闭队列", action: onClose)
                }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(height: 52)
            .accessibilityAddTraits(.isHeader)
        } else {
            glassHeader
        }
    }

    /// paper：清空队列。队列为空时不渲染 —— 没有可清的东西，按钮只会是噪声
    @ViewBuilder
    private var clearButton: some View {
        if !music.queue.isEmpty {
            Button("清空") {
                music.clearQueue()
                ToastCenter.shared.show("已清空队列", systemImage: "trash")
            }
            .buttonStyle(GhostButtonStyle(compact: true))
            .help("清空播放队列")
            .accessibilityLabel("清空播放队列")
        }
    }

    /// glass（v3）形态：与改动前逐字一致
    private var glassHeader: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text("播放队列")
                .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Chip(text: "\(music.queue.count) 首")

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
                    showsHandle: true,
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
        // paper 点线行 48（§4.4「行高 48（队列）」）
        .environment(\.defaultMinListRowHeight, Theme.isPaper ? PaperRowMetrics.listRowHeight : 52)
        .padding(.horizontal, Theme.Spacing.xs)
    }
}
