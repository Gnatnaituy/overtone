import Foundation

// MARK: - 直连播放能力判定（纯函数）
//
// 证据：协议档 §7.5「macOS / AVPlayer 侧格式能力对照」表、§7.7 坑 #15
//      （「`codec`/`format` 可能缺省 → 缺省时不猜，直接直连试播」）；
//      [dart] `transcode_service.dart:21-28` 的容器黑名单（Android 视角，已换算到 macOS：
//      aiff 在 macOS 是原生支持的，所以这里把它从黑名单挪到白名单）。
//
// 飞牛的 `/track/stream` 是**文件直出**（原始字节流），所以「能不能播」完全取决于
// AVFoundation 认不认这个容器/编码。这里只做「已知结论」，不做探测：
// 未知格式一律当作「先试直连」。
enum FeiniuPlaybackFormat {

    /// AVPlayer(macOS 13+) 原生可播的容器。
    ///
    /// FLAC 从 macOS 11 起原生支持，所以列为直连；但协议档 §7.5 提示
    /// 「tvOS 上有 metadata block type 127 导致整首拒播的已知问题，macOS 侧需实测」
    /// —— 因此播放器仍应保留「直连失败 → `transcodeFallback`」的回退路径。
    static let directPlayable: Set<String> = [
        "mp3", "m4a", "m4b", "mp4", "aac", "alac", "aif", "aiff", "wav", "caf", "flac",
    ]

    /// 确定不能直连、必须走服务端转码的容器。
    ///
    /// APE / WavPack / DSD / DTS / TTA / WMA / Musepack / RealAudio / MKA/MKV 在
    /// AVFoundation 上都不支持（协议档 §7.5），这也是飞牛转码接口存在的意义。
    /// `.ogg`/`opus` 单独列出：Opus-in-CAF 支持、`.ogg` 容器基本不支持 → 走转码更稳。
    static let requiresTranscode: Set<String> = [
        "ape", "wv", "dsf", "dff", "dsd", "wma", "dts", "tta", "mpc", "ra", "au",
        "mka", "mkv", "ogg", "opus",
    ]

    /// 判断某格式能否直连播放。
    ///
    /// - Returns: `true` = 已知可直连；`false` = 已知必须转码；
    ///            `nil` = 未知（缺省 / 不在名单里）→ 调用方按「先直连试播」处理。
    static func canDirectPlay(format: String?) -> Bool? {
        guard let normalized = format?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !normalized.isEmpty
        else { return nil }
        if directPlayable.contains(normalized) { return true }
        if requiresTranscode.contains(normalized) { return false }
        // TODO(C)：名单外的格式（如 wavpack 的别名 "wvc"、AIFF-C 变体）没有实测依据，
        // 按协议档 §7.7#15 的建议「不猜，直接试播」。真机验证后把结论补进上面两个集合。
        return nil
    }
}
