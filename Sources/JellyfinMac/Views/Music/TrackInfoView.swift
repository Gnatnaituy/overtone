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
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                RemoteImage(url: track.artworkURL(width: 128), contentMode: .fill)
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.name ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .lineLimit(2)
                    Text([track.album, track.albumArtist].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }

            Rectangle().fill(Theme.divider).frame(height: 1)

            if let source = vm.mediaSource {
                VStack(alignment: .leading, spacing: 8) {
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
                    .padding(.vertical, 10)
            } else if let error = vm.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(width: 280)
        .task { await vm.load() }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.primaryText)
        }
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
