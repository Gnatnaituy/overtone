import Foundation

/// 跨后端的**内容身份**。
///
/// 同一个音乐文件既可能在 Jellyfin 的库里，也在飞牛音乐的库里 —— 两边的条目 id
/// （Jellyfin 的 `BaseItem.Id` / 飞牛的 GUID）完全不同，但它们是同一首歌。
/// 如果本地状态（播放进度、播放次数、收藏）与封面缓存都以「后端 + 条目 id」为键，
/// 同一首歌就会被记两遍、封面也会下两遍。
///
/// 这里用「元数据指纹」算一个与后端无关的键：
///
/// ```
/// 曲目：t|标题|艺人|时长秒     （时长 1 秒一档，查表时 ±2 秒探测，见 candidates）
/// 专辑：a|专辑名|专辑艺人
/// 艺人：r|艺人名
/// ```
///
/// 归一化（`normalize`）要吃掉两个服务端之间的常见差异：
/// 全角/半角（NFKC）、大小写、空格、标点、零宽字符。
///
/// **不做的归一化**（会误合并不同版本，宁可分成两条）：
/// 不剥 `(Live)` / `(Remastered 2011)` 这类后缀 —— 它们是不同录音，进度不能共享。
enum ContentIdentity {

    // MARK: - 归一化

    /// 元数据归一化：NFKC 折叠（全角→半角等）→ 小写 → 只保留字母/数字/汉字。
    ///
    /// 例：`"Ｈｅｌｌｏ， World!"` → `"helloworld"`；`"周杰伦"` → `"周杰伦"`。
    static func normalize(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let folded = raw.precomposedStringWithCompatibilityMapping.lowercased()
        var result = String()
        result.reserveCapacity(folded.count)
        for scalar in folded.unicodeScalars {
            // 字母（含汉字）/ 数字留下；空格、标点、emoji、零宽字符全部丢掉
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// 时长档（秒）。`0`/未知 → nil，调用方退化成「不按时长区分」。
    static func durationBucket(_ duration: Double) -> Int? {
        guard duration.isFinite, duration > 0 else { return nil }
        return Int(duration.rounded())
    }

    // MARK: - 对外键

    /// 条目所属的内容身份键（写入本地记录时用这个当 key）。
    static func key(for item: MediaItem) -> String {
        switch item.kind {
        case .track:
            return trackKey(title: item.title, artist: trackArtist(item), duration: item.duration)
        case .album:
            return albumKey(title: item.title, albumArtist: item.artistName)
        case .artist:
            return artistKey(name: item.title)
        case .playlist:
            // 播放列表是各服务端各自的组织方式，不跨后端合并
            return "p|\(item.backend.rawValue)|\(item.id)"
        case .folder:
            return "f|\(item.backend.rawValue)|\(item.id)"
        }
    }

    /// 曲目在查表时要试的全部键：同内容身份 + 时长 ±2 秒。
    ///
    /// 为什么要探测而不是精确匹配：两台服务器的时长可能差几百毫秒（容器/解码差异），
    /// 而档位是 1 秒 —— 199.9s 与 200.1s 会落到 199 与 200 两档。±2 档足以覆盖，
    /// 又不会把「3 分钟的歌」和「5 分钟的同名曲」误判成同一首。
    static func candidates(for item: MediaItem) -> [String] {
        guard item.kind == .track else { return [key(for: item)] }
        let artist = trackArtist(item)
        guard let bucket = durationBucket(item.duration) else {
            return [trackKey(title: item.title, artist: artist, bucket: 0)]
        }
        return [-2, -1, 0, 1, 2].map {
            trackKey(title: item.title, artist: artist, bucket: bucket + $0)
        }
    }

    /// 视觉身份：**不含时长档**。
    ///
    /// 封面缓存跨后端共用要靠它：两个服务端对同一首歌的时长可能差几百毫秒，
    /// 1 秒档会落到相邻两档（226.4 vs 226.6），而封面其实是同一张。
    /// 曲目这里只取「标题 + 艺人」——同一首歌的 Live/Remaster 封面通常也是同一张；
    /// 若某首歌因此串图，代价只是显示错一张封面（下次换后端会刷新），
    /// 比"同一首歌封面下两遍"更可接受。
    static func visualKey(for item: MediaItem) -> String {
        switch item.kind {
        case .track:
            return "v|t|\(normalize(item.title))|\(normalize(trackArtist(item) ?? ""))"
        case .album:
            return albumKey(title: item.title, albumArtist: item.artistName)
        case .artist:
            return artistKey(name: item.title)
        case .playlist, .folder:
            return key(for: item)
        }
    }

    /// 主键（等于 `candidates` 的正中那一项；写入用）
    static func trackKey(title: String, artist: String?, duration: Double) -> String {
        trackKey(title: title, artist: artist, bucket: durationBucket(duration) ?? 0)
    }

    /// 直接给档位的版本（`candidates` 的 ±2 秒探测用）
    static func trackKey(title: String, artist: String?, bucket: Int) -> String {
        "t|\(normalize(title))|\(normalize(artist ?? ""))|\(bucket)"
    }

    static func albumKey(title: String, albumArtist: String?) -> String {
        "a|\(normalize(title))|\(normalize(albumArtist ?? ""))"
    }

    static func artistKey(name: String) -> String {
        "r|\(normalize(name))"
    }

    /// 曲目的「艺人」取哪个字段：优先专辑艺人，退回曲目艺人。
    ///
    /// 两边服务端对同一首歌的 `albumArtist` 通常一致（来自同一个标签），
    /// 而「曲目艺人」在合作曲上容易出现 `A / B`、`A feat. B` 之类的差异。
    private static func trackArtist(_ item: MediaItem) -> String? {
        let candidates = [item.artistName, item.subtitle]
        for candidate in candidates {
            if let value = candidate, !normalize(value).isEmpty { return value }
        }
        return nil
    }
}
