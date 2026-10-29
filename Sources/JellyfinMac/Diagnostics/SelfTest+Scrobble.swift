import Foundation

/// 听歌记录自检：提交资格 / Last.fm 签名 / 待补报队列编解码 / 时间戳与载荷。
///
/// 由 `SelfTest.run(into:)` 在 Lead 接线后调用 `scrobbleChecks(checker)`；
/// 这里只依赖 `State/Scrobble` 下的纯逻辑，不触网、不读写钥匙串。
extension SelfTest {
    static func scrobbleChecks(_ c: Checker) {
        eligibility(c)
        lastFMSignature(c)
        pendingQueue(c)
        payloads(c)
    }

    // MARK: - 提交资格（≥30s 且（≥50% 或 ≥240s））

    private static func eligibility(_ c: Checker) {
        c.expect(!ScrobbleRule.isEligible(played: 0, duration: 0, completed: false), "0 时长不提交")
        c.expect(
            !ScrobbleRule.isEligible(played: 100, duration: 0, completed: true),
            "0 时长即使播完也不提交"
        )
        c.expect(
            !ScrobbleRule.isEligible(played: .nan, duration: 200, completed: false),
            "非法进度不提交"
        )

        c.expect(
            !ScrobbleRule.isEligible(played: 99, duration: 200, completed: false),
            "不足 50% 不提交"
        )
        c.expect(
            ScrobbleRule.isEligible(played: 100, duration: 200, completed: false),
            "恰好 50% 提交"
        )

        c.expect(
            !ScrobbleRule.isEligible(played: 239, duration: 600, completed: false),
            "不足 240 秒不提交"
        )
        c.expect(
            ScrobbleRule.isEligible(played: 240, duration: 600, completed: false),
            "长曲满 240 秒提交（不看 50%）"
        )

        c.expect(
            !ScrobbleRule.isEligible(played: 29.9, duration: 40, completed: false),
            "不足 30 秒不提交"
        )
        c.expect(
            ScrobbleRule.isEligible(played: 30, duration: 40, completed: false),
            "满 30 秒且超过 50% 提交"
        )

        c.expect(
            ScrobbleRule.isEligible(played: 5, duration: 30, completed: true),
            "自然播完视为听满整首"
        )
        c.expect(
            !ScrobbleRule.isEligible(played: 20, duration: 20, completed: true),
            "20 秒短曲播完也不提交（低于 30 秒）"
        )

        // 有效增量：正常前进才计入；拖动进度条 / 从续播位置起播的大跨度不计
        c.near(ScrobbleRule.creditedDelta(from: 100, to: 105), 5, "正常进度增量计入")
        c.near(ScrobbleRule.creditedDelta(from: 10, to: 120), 0, "大跨度（跳播）不计")
        c.near(ScrobbleRule.creditedDelta(from: 100, to: 90), 0, "进度后退不计")
        c.near(ScrobbleRule.creditedDelta(from: 0, to: 0), 0, "原地不动不计")
    }

    // MARK: - Last.fm 签名

    private static func lastFMSignature(_ c: Checker) {
        c.equal(
            LastFMAPI.md5Hex("abc"),
            "900150983cd24fb0d6963f7d28e17f72",
            "MD5 十六进制小写"
        )

        // api_sig = MD5(按参数名排序的 name+value 拼接 + secret)
        c.equal(
            LastFMAPI.signature(
                params: ["method": "auth.getToken", "api_key": "abc123def456"],
                secret: "s3cr3t"
            ),
            "778d81f58179c187cac6a3c9c318558c",
            "Last.fm 签名固定向量（auth.getToken）"
        )

        // 数组参数（artist[0]）+ 中文：排序按 ASCII，值按 UTF-8 参与 md5
        let scrobbleParams = [
            "api_key": "0123456789abcdef0123456789abcdef",
            "artist[0]": "周杰伦",
            "method": "track.scrobble",
            "sk": "session-key",
            "timestamp[0]": "1700000000",
            "track[0]": "夜曲",
        ]
        c.equal(
            LastFMAPI.signature(params: scrobbleParams, secret: "c0ffee"),
            "9ed6b8b2c892bfbe8b0d519c25327bfd",
            "Last.fm 签名固定向量（数组参数 + 中文）"
        )

        // format 不参与签名：多带 format 会得到另一个值，因此调用方必须先签名后追加 format
        let withFormat = scrobbleParams.merging(["format": "json"]) { _, new in new }
        c.expect(
            LastFMAPI.signature(params: withFormat, secret: "c0ffee")
                != LastFMAPI.signature(params: scrobbleParams, secret: "c0ffee"),
            "format 不参与签名（call 必须先签名后追加）"
        )

        // 签名与参数字典的插入顺序无关
        let reordered: [String: String] = [
            "track[0]": "夜曲",
            "timestamp[0]": "1700000000",
            "sk": "session-key",
            "method": "track.scrobble",
            "artist[0]": "周杰伦",
            "api_key": "0123456789abcdef0123456789abcdef",
        ]
        c.equal(
            LastFMAPI.signature(params: reordered, secret: "c0ffee"),
            "9ed6b8b2c892bfbe8b0d519c25327bfd",
            "签名与参数字典顺序无关"
        )
    }

    // MARK: - 待补报队列

    private static func pendingQueue(_ c: Checker) {
        let entries = [
            ScrobblePendingEntry(
                service: .lastFM,
                listen: ScrobbleListen(
                    title: "夜曲",
                    artist: "周杰伦",
                    album: "十一月的萧邦",
                    duration: 226.4,
                    trackNumber: 1,
                    playedAt: 1_700_000_000
                )
            ),
            ScrobblePendingEntry(
                service: .listenBrainz,
                listen: ScrobbleListen(title: "Ocean", artist: "Someone", playedAt: 1)
            ),
        ]

        let encoded = try? ScrobblePendingStore.encode(entries)
        let decoded = encoded.flatMap { try? ScrobblePendingStore.decode($0) }
        c.expect(
            decoded == entries,
            "待补报队列 JSON 往返（UUID / 枚举 / 中文 / 可选字段）"
        )

        // 上限 200：超限丢最旧的，保留最新
        let many = (0..<250).map { index in
            ScrobblePendingEntry(
                service: .lastFM,
                listen: ScrobbleListen(title: "t\(index)", artist: "a", playedAt: index)
            )
        }
        let trimmed = ScrobblePendingStore.trimmed(many)
        c.equal(trimmed.count, ScrobblePendingStore.capacity, "队列上限 200 条")
        c.expect(trimmed.first?.listen.title == "t50", "超限时丢弃最旧记录")
        c.expect(trimmed.last?.listen.title == "t249", "超限时保留最新记录")
    }

    // MARK: - 时间戳与载荷

    private static func payloads(_ c: Checker) {
        c.equal(
            ScrobbleRule.unixTimestamp(for: Date(timeIntervalSince1970: 1_700_000_000.987)),
            1_700_000_000,
            "时间戳向下取整"
        )
        c.equal(
            ScrobbleRule.unixTimestamp(for: Date(timeIntervalSince1970: 0.4)),
            0,
            "小于 1 秒取整为 0"
        )

        let listen = ScrobbleListen(
            title: "夜曲",
            artist: "周杰伦",
            album: "十一月的萧邦",
            duration: 226.4,
            trackNumber: 1,
            playedAt: 1_700_000_000
        )

        let nowPlaying = ListenBrainzAPI.listenPayload(listen, includeTimestamp: false)
        c.expect(nowPlaying["listened_at"] == nil, "playing_now 不带 listened_at")
        let single = ListenBrainzAPI.listenPayload(listen, includeTimestamp: true)
        c.equal(single["listened_at"] as? Int, 1_700_000_000, "single 带整数 listened_at")

        guard let metadata = single["track_metadata"] as? [String: Any] else {
            c.expect(false, "track_metadata 必须存在")
            return
        }
        c.equal(metadata["artist_name"] as? String, "周杰伦", "ListenBrainz artist_name")
        c.equal(metadata["track_name"] as? String, "夜曲", "ListenBrainz track_name")
        c.equal(metadata["release_name"] as? String, "十一月的萧邦", "ListenBrainz release_name")
        guard let additional = metadata["additional_info"] as? [String: Any] else {
            c.expect(false, "additional_info 必须存在")
            return
        }
        c.equal(additional["duration_ms"] as? Int, 226_400, "ListenBrainz duration_ms")
        c.equal(additional["tracknumber"] as? Int, 1, "ListenBrainz tracknumber")

        // 从领域曲目构造：空艺人 / 空歌名服务端会拒收，构造阶段就应失败
        let playable = MediaItem(
            id: "jf-1",
            backend: .jellyfin,
            kind: .track,
            title: "夜曲",
            subtitle: "周杰伦",
            artistName: "周杰伦",
            duration: 226.4
        )
        if let derived = ScrobbleListen(item: playable, playedAt: 1_700_000_000) {
            c.equal(derived.artist, "周杰伦", "从 MediaItem 取艺人")
            c.equal(derived.title, "夜曲", "从 MediaItem 取歌名")
            c.near(derived.duration, 226.4, "从 MediaItem 取时长")
        } else {
            c.expect(false, "正常曲目应能构造听歌记录")
        }

        let artistless = MediaItem(
            id: "jf-2",
            backend: .jellyfin,
            kind: .track,
            title: "无艺人",
            subtitle: "",
            artistName: "",
            duration: 100
        )
        c.expect(
            ScrobbleListen(item: artistless, playedAt: 0) == nil,
            "缺艺人时不构造听歌记录"
        )
    }
}
