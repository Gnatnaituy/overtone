import SwiftUI

/// 曲目信息弹窗：容器、文件大小、编码、比特率、采样率、声道等（来自服务器 MediaSources）
struct TrackInfoView: View {
    let track: BaseItemDto
    @StateObject private var vm: TrackInfoViewModel

    init(track: BaseItemDto) {
        self.track = track
        _vm = StateObject(wrappedValue: TrackInfoViewModel(itemId: track.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.lg) {
                RemoteImage(url: track.artworkURL(width: 128), contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name ?? "")
                        .textStyle(.bodySM, weight: .semibold, color: Theme.textPrimary)
                        .lineLimit(2)
                    Text([track.album, track.albumArtist].compactMap { $0 }.joined(separator: " · "))
                        .textStyle(.caption, color: Theme.textSecondary)
                        .lineLimit(1)
                }
            }

            Rectangle().fill(Theme.borderSubtle).frame(height: 1)

            if let source = vm.mediaSource {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let container = source.container, !container.isEmpty {
                        infoRow("容器格式", container.uppercased())
                    }
                    if let size = source.size {
                        infoRow("文件大小", Self.formatBytes(size))
                    }
                    if let audio = vm.audioStream {
                        if let codec = audio.codec, !codec.isEmpty {
                            infoRow("音频编码", codec.uppercased())
                        }
                        if let bitRate = audio.bitRate, bitRate > 0 {
                            infoRow("比特率", "\(bitRate / 1000) kbps")
                        }
                        if let sampleRate = audio.sampleRate, sampleRate > 0 {
                            infoRow("采样率", "\(sampleRate / 1000) kHz")
                        }
                        if let channels = audio.channels, channels > 0 {
                            infoRow("声道", Self.channelsText(channels))
                        }
                    }
                    infoRow("时长", formatPlaybackTime(track.runtimeSeconds))
                    if let count = track.userData?.playCount, count > 0 {
                        infoRow("播放次数", "\(count)")
                    }
                }
            } else if vm.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Theme.Spacing.lg)
            } else if let error = vm.errorMessage {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                    Text(error)
                        .textStyle(.caption)
                }
                .foregroundStyle(Theme.danger)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: 280)
        .task { await vm.load() }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .textStyle(.footnote, color: Theme.textSecondary)
            Spacer(minLength: 0)
            Text(value)
                .textStyle(.footnote, weight: .medium, color: Theme.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let b = Double(bytes)
        if b >= 1_073_741_824 { return String(format: "%.2f GB", b / 1_073_741_824) }
        if b >= 1_048_576 { return String(format: "%.1f MB", b / 1_048_576) }
        if b >= 1024 { return String(format: "%.1f KB", b / 1024) }
        return "\(bytes) B"
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

@MainActor
final class TrackInfoViewModel: ObservableObject {
    @Published var mediaSource: MediaSourceInfo?
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let itemId: String

    init(itemId: String) {
        self.itemId = itemId
    }

    var audioStream: MediaStream? {
        mediaSource?.mediaStreams?.first { $0.type == "Audio" }
    }

    func load() async {
        guard !isLoading, mediaSource == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let userId = APIClient.shared.user?.id ?? ""
            let detail: BaseItemDto = try await APIClient.shared.get(
                "/Users/\(userId)/Items/\(itemId)",
                query: [URLQueryItem(name: "Fields", value: "MediaSources")]
            )
            mediaSource = detail.mediaSources?.first
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
