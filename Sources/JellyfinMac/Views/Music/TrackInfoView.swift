import SwiftUI

/// 曲目信息弹窗：格式、比特率、采样率、位深、声道等（直接来自领域模型 `MediaItem`）。
///
/// 改造前这里会再发一次 `/Items/{id}?Fields=MediaSources` 请求拿 `MediaSources`；
/// 领域模型已经把要展示的字段拍平到 `MediaItem` 上（后端各自映射），所以不再有请求、
/// 加载态与错误态 —— 打开即可显示。
struct TrackInfoView: View {
    let track: MediaItem

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(ref: track.artworkRef(width: 128), contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.title)
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                        // paper：曲名走衬线（信息面板的「印刷」气质，§2.2）
                        .fontDesign(Theme.isPaper ? .serif : .default)
                        .lineLimit(2)
                    Text([track.albumTitle, track.artistName].compactMap { $0 }.joined(separator: " · "))
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                if let format = track.format, !format.isEmpty {
                    infoRow("容器格式", format.uppercased())
                }
                if let bitrate = track.bitrate, bitrate > 0 {
                    infoRow("比特率", "\(bitrate / 1000) kbps")
                }
                if let sampleRate = track.sampleRate, sampleRate > 0 {
                    infoRow("采样率", "\(sampleRate / 1000) kHz")
                }
                if let bitDepth = track.bitDepth, bitDepth > 0 {
                    infoRow("位深", "\(bitDepth) bit")
                }
                if let channels = track.channels, channels > 0 {
                    infoRow("声道", Self.channelsText(channels))
                }
                infoRow("时长", formatPlaybackTime(track.duration))
                if track.userData.playCount > 0 {
                    infoRow("播放次数", "\(track.userData.playCount)")
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 280)
    }

    /// paper（§6.8 思路：设置 / 信息面板像设备说明书）：标签列定宽 + hairline 行线，数值走 mono
    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        if Theme.isPaper {
            HStack(spacing: Theme.Spacing.lg) {
                Text(label)
                    .textStyle(.footnote, color: Theme.Paper.ink2)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .textStyle(.mono, color: Theme.Paper.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 26)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.Paper.hairline).frame(height: 1)
            }
            .accessibilityElement(children: .combine)
        } else {
            glassInfoRow(label, value)
        }
    }

    /// glass（v3）形态：与改动前逐字一致
    private func glassInfoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .textStyle(.footnote, color: Theme.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .textStyle(.footnote, weight: .medium, color: Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func channelsText(_ channels: Int) -> String {
        switch channels {
        case 1: return "单声道"
        case 2: return "双声道"
        case 6: return "5.1 声道"
        case 8: return "7.1 声道"
        default: return "\(channels) 声道"
        }
    }
}
