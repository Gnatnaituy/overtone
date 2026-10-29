import Foundation

// MARK: - wire → 领域模型 映射（纯函数）
//
// 证据：协议档 §6.1（Track 字段表）、§6.2（Album/Artist）、§6.3（Playlist）、
//      §6.4（User/Library）、§6.5（AudioSpec）、§6.1「duration 单位坑」、
//      §7.7 坑 #4（accessStatus）、§7.1（coverId 不能由 GUID 拼）；
//      [dart] `api_models.dart` 的 `FnTrack`/`FnAlbum`/`FnArtist`/`FnPlaylist`/`FnLibrary`。
//
// 全是静态纯函数：`FeiniuJSON` 进、领域模型出。没有网络、没有状态 →
// 可以用一份录制下来的 JSON 直接单测映射（包括 duration 归一化）。
enum FeiniuMapping {

    // MARK: 曲目

    /// `/track/list`、`/track/album-detail/list`、`/search/track` 等返回的单曲。
    ///
    /// 注意：同一个 `Track` 有两种形状 —— 列表项是**扁平**的曲目对象，而
    /// `/track/metadata` 返回 `{track, audioSpec}` 两层（协议档 §7.3）。这里吃扁平形状；
    /// 需要详情时先用 `FeiniuMapping.trackEnvelope` 拆包。
    static func track(_ json: FeiniuJSON) -> MediaItem? {
        guard let guid = trimmed(json["guid"]?.stringValue), !guid.isEmpty else { return nil }

        // `accessStatus`：0/缺省=可播，非 0=不可播（1/3 文件缺失，2/4 无权限，其余不可用）。
        // 协议档 §7.7#4 要求「灰显 + 禁止入队 + 整单播放时过滤」。
        // TODO(C)：`MediaItem` 没有「不可播」字段（本次边界不允许改 MediaModels.swift），
        // 所以只能在这里**直接丢弃**——宁可少一首，也不要让用户点了没反应。
        // 状态层将来若加 `isPlayable`，把这里改成置标记而不是 `return nil`。
        let accessStatus = json["accessStatus"]?.intValue ?? 0
        guard accessStatus == 0 else { return nil }

        let album = json["album"]
        let artists = json["artists"]?.arrayValue ?? []
        let firstArtist = artists.first
        let spec = json["audioSpec"]

        let title = trimmed(json["title"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "未知标题"

        // duration 秒/毫秒混用 → 一律经 `FeiniuDuration.normalize` 归一成秒。
        // 曲目级 `duration` 优先，缺失时退到 `audioSpec.duration`（两处都可能缺）。
        let duration = FeiniuDuration.normalize(
            json["duration"]?.doubleValue ?? spec?["duration"]?.doubleValue
        )

        // 封面：`coverId` 带 `track_`/`album_` 前缀，**必须从响应里读，不能拿 GUID 拼**。
        // 曲目自身没有封面时用所属专辑的（这是 [dart] 的兜底顺序）。
        let coverId = trimmed(json["coverId"]?.stringValue) ?? trimmed(album?["coverId"]?.stringValue)

        var userData = MediaUserData()
        userData.isFavorite = json["isFavorite"]?.boolValue ?? false

        return MediaItem(
            id: guid,
            backend: .feiniu,
            kind: .track,
            title: title,
            subtitle: trimmed(firstArtist?["name"]?.stringValue),
            albumID: trimmed(album?["guid"]?.stringValue),
            albumTitle: trimmed(album?["name"]?.stringValue),
            artistID: trimmed(firstArtist?["guid"]?.stringValue),
            artistName: trimmed(firstArtist?["name"]?.stringValue),
            duration: duration,
            trackNumber: json["trackNo"]?.intValue,
            discNumber: json["discNo"]?.intValue,
            // 曲目级 `year`（协议档 §6.1 标 S：证据等级弱于 V，缺省即 nil）。
            year: json["year"]?.intValue,
            // 曲目没有 `createdAt` 字段（协议档 §6.1 字段表里没有）→ dateAdded 留空，
            // 由状态层的本地库兜底（与飞牛没有播放统计同理）。
            dateAdded: nil,
            artwork: artwork(coverId: coverId),
            genres: genres(json),
            // `MediaItem.format` 只放容器；`codec` 单独存在 wire 里（协议档 §6.5）——
            // 播放判定用 format，信息页要显示 codec 时得另加字段（TODO(C)）。
            format: trimmed(spec?["format"]?.stringValue) ?? trimmed(spec?["codec"]?.stringValue),
            // `bitrate` 单位 = **bps**，直接用，不要换算：
            // [kotlin] `PlaybackQuality.kt:22` 显示时 `bitrate / 1000.0` → kbps，
            // 且单测样本是 `bitrate = 320000` → "MP3 · 320 kbps"、FLAC 样本 `847806`
            // （`PlaybackQualityTest.kt:11`、`MusicShellTest.kt:3540`）—— 说明服务端给的就是 bps。
            // TODO(C)：这是从第三方客户端的显示逻辑反推的，协议档 §6.5 没写单位；
            // 真机若看到「845 kbps」显示成「846 MB 码率」，说明这里该改成 `* 1000`。
            bitrate: spec?["bitrate"]?.intValue,
            sampleRate: spec?["sampleRate"]?.intValue,
            bitDepth: spec?["bitDepth"]?.intValue,
            channels: spec?["channel"]?.intValue,
            userData: userData
        )
    }

    /// 把 `/track/metadata` 的 `{track, audioSpec}` 拆成扁平曲目（`audioSpec` 合进 track）。
    ///
    /// TODO(C)：本后端目前没有用到这个接口（列表项已带 audioSpec），保留给「曲目信息页」
    /// 需要更权威的 `audioSpec` 时用。协议档 §7.3 明确提到两种形状并存。
    static func trackDetail(_ json: FeiniuJSON) -> MediaItem? {
        guard var trackObject = json["track"]?.objectValue else { return nil }
        if let spec = json["audioSpec"] {
            trackObject["audioSpec"] = spec
        }
        return track(FeiniuJSON.makeObject(trackObject))
    }

    /// 流派：飞牛的 `genres` 可能是 `[{guid,name}]` 也可能是字符串数组（两种形状都见过），
    /// 这里宽容解析；字段缺失返回空数组（不猜、不报错）。
    static func genres(_ json: FeiniuJSON) -> [String] {
        guard let array = json["genres"]?.arrayValue else { return [] }
        return array.compactMap { entry -> String? in
            if let plain = entry.stringValue { return trimmed(plain) }
            return trimmed(entry["name"]?.stringValue)
        }
        .filter { !$0.isEmpty }
    }

    // MARK: 专辑 / 艺人 / 播放列表

    /// `/album/list`、`/album/artist-detail/list`、`/search/album`。
    static func album(_ json: FeiniuJSON) -> MediaItem? {
        guard let guid = trimmed(json["guid"]?.stringValue), !guid.isEmpty else { return nil }
        let artist = json["artists"]?.arrayValue?.first
        let title = trimmed(json["name"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "未知专辑"

        var userData = MediaUserData()
        // 飞牛没有专辑级收藏（只有 track 级，协议档 §5.4）→ 恒 false。
        userData.isFavorite = false

        return MediaItem(
            id: guid,
            backend: .feiniu,
            kind: .album,
            title: title,
            // 领域约定：专辑副标题 = 专辑艺人（见 MediaItem.subtitle 注释）。
            subtitle: trimmed(artist?["name"]?.stringValue),
            albumID: guid,
            albumTitle: title,
            artistID: trimmed(artist?["guid"]?.stringValue),
            artistName: trimmed(artist?["name"]?.stringValue),
            // 列表项有 `year`（Int）；详情接口是 `releaseDate`（字符串）。
            // TODO(C)：协议档 §6.2 警告 [ps5] 把 releaseDate 直接当 int 用可能得 0；
            // 这里只读 `year`，不从 `releaseDate` 猜年份。
            year: json["year"]?.intValue,
            artwork: artwork(coverId: trimmed(json["coverId"]?.stringValue)),
            genres: genres(json),
            // 专辑曲目数：`trackCount`（协议档 §6.2，列表项与详情都有）
            childCount: json["trackCount"]?.intValue,
            userData: userData
        )
    }

    /// `/artist/list`、`/search/artist`。
    static func artist(_ json: FeiniuJSON) -> MediaItem? {
        guard let guid = trimmed(json["guid"]?.stringValue), !guid.isEmpty else { return nil }
        let title = trimmed(json["name"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "未知艺人"

        // 领域约定：艺人副标题 = 「N 张专辑」。`/artist/list` 的列表项通常只有
        // guid/name/coverId（协议档 §6.2），albumCount 只有 detail 才有——
        // 拿不到就不显示，别编一个数字。
        let subtitle: String?
        if let albumCount = json["albumCount"]?.intValue {
            subtitle = "\(albumCount) 张专辑"
        } else if let trackCount = json["trackCount"]?.intValue, trackCount > 0 {
            // TODO(C)：列表项到底有没有 trackCount 未实测（[dart] `FnArtist` 只解 guid/name/coverId）。
            subtitle = "\(trackCount) 首歌曲"
        } else {
            subtitle = nil
        }

        return MediaItem(
            id: guid,
            backend: .feiniu,
            kind: .artist,
            title: title,
            subtitle: subtitle,
            artistID: guid,
            artistName: title,
            artwork: artwork(coverId: trimmed(json["coverId"]?.stringValue)),
            genres: genres(json),
            // 艺人专辑数：`albumCount` 只有 `/artist/detail` 有，列表项通常没有 → nil 由 UI 降级
            childCount: json["albumCount"]?.intValue
        )
    }

    /// `/playlist/list`（远程歌单，`MusicBackend.remotePlaylists()` 用）。
    static func remotePlaylist(_ json: FeiniuJSON) -> RemotePlaylist? {
        guard let guid = trimmed(json["guid"]?.stringValue), !guid.isEmpty else { return nil }
        let name = trimmed(json["name"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 } ?? "播放列表"
        return RemotePlaylist(id: guid, name: name, trackCount: json["trackCount"]?.intValue ?? 0)
    }

    // MARK: 媒体库

    /// `/shared-library/list`（协议档 §6.4 Library 字段）。
    static func library(_ json: FeiniuJSON) -> MusicLibrary? {
        guard let guid = trimmed(json["guid"]?.stringValue), !guid.isEmpty else { return nil }
        // 展示名：`name` 优先；否则取 `path` 末段（[dart] `FnLibrary.displayName` 同逻辑）。
        let name = trimmed(json["name"]?.stringValue).flatMap { $0.isEmpty ? nil : $0 }
            ?? lastPathComponent(of: json["path"]?.stringValue)
            ?? "飞牛音乐"
        return MusicLibrary(id: guid, name: name, backend: .feiniu)
    }

    // MARK: 封面

    /// 构造封面引用。
    ///
    /// ⚠️ 设计说明：**`ArtworkRef.itemID` 在飞牛后端里装的是 `coverId`**，不是曲目 GUID。
    /// 原因是飞牛的封面只能用响应里的 `coverId`（带 `track_`/`album_`/`playlist_` 前缀）
    /// 去 `/static/cover` 取，**不能拿 GUID 拼**（协议档 §3.7、§7.1 头号坑）。
    /// `ArtworkRef` 没有别的槽位能放这个字符串，而 `version` 的语义是「Jellyfin 的
    /// ImageTag / 飞牛没有则为 nil」（见 MediaModels 注释），所以它保持 nil。
    /// 这样 `cacheKey` 也是稳定的：`feiniu|track_xxx|primary|-|400`。
    static func artwork(coverId: String?) -> ArtworkRef? {
        guard let coverId = trimmed(coverId), !coverId.isEmpty else { return nil }
        return ArtworkRef(backend: .feiniu, itemID: coverId, kind: .primary, version: nil, maxWidth: 400)
    }

    // MARK: 工具

    /// 去掉首尾空白；空字符串 → nil（飞牛大量字段「存在但为空」）。
    static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func lastPathComponent(of path: String?) -> String? {
        guard let path = trimmed(path) else { return nil }
        let component = path
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .last
            .map(String.init)
        return trimmed(component)
    }
}
