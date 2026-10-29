import Foundation

/// 内置自检：后端协议解析 / 地址规范化 / 歌词 / 本地合并这类**纯逻辑**的断言集合。
///
/// 为什么不用 XCTest：本仓库的构建约定是「只装 Command Line Tools 也能构建」
/// （见 docs/build-notes.md），而 CLT 里没有 `XCTest` 模块，`swift test` 会直接
/// 在依赖扫描阶段失败。所以把断言做进可执行文件本身：
///
/// ```bash
/// ./scripts/dev-test.sh          # 内部执行 `swift run … --selftest`
/// ```
///
/// 这些断言覆盖的正是「写错了只表现为服务端 401 / 收藏不生效 / 时长差 1000 倍」
/// 的那批代码 —— 它们没有 UI 反馈，靠手测极难发现。
enum SelfTest {
    static var isRequested: Bool {
        CommandLine.arguments.contains("--selftest")
    }

    /// 由 `JellyfinApp.init()` 调用；命中 `--selftest` 时跑完即退出（不启动界面）。
    static func runIfRequested() {
        guard isRequested else { return }
        let checker = Checker()
        run(into: checker)
        checker.report()
        exit(checker.failures.isEmpty ? 0 : 1)
    }

    static func run(into checker: Checker) {
        authx(checker)
        address(checker)
        duration(checker)
        lyrics(checker)
        genres(checker)
        sharedLogic(checker)
        fnConnect(checker)
        contentIdentity(checker)
        // 2026-10 新增功能：听歌统计 / 歌词偏移 / 听歌记录 / 播放衔接
        playbackStats(checker)
        lyricsChecks(checker)
        scrobbleChecks(checker)
        playbackChecks(checker)
    }

    // MARK: - authx

    private static func authx(_ c: Checker) {
        let url = URL(string: "http://192.168.1.10:5666/music/api/v1/track/list")!

        c.equal(
            FeiniuAuthxSigner.canonicalQuery([
                URLQueryItem(name: "size", value: "50"),
                URLQueryItem(name: "page", value: "1"),
            ]),
            "page=1&size=50",
            "GET 参数按名排序后参与签名"
        )

        c.equal(
            FeiniuAuthxSigner.canonicalQuery([
                URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "sort", value: nil),
                URLQueryItem(name: "q", value: "null"),
            ]),
            "page=1",
            "nil / \"null\" 参数不参与签名"
        )

        let proxied = URL(string: "https://example.com/nas/music/api/v1/track/list")!
        c.equal(
            FeiniuAuthxSigner.signingPath(for: proxied),
            "/music/api/v1/track/list",
            "反代前缀必须截掉"
        )
        c.equal(
            FeiniuAuthxSigner.signingPath(for: url),
            "/music/api/v1/track/list",
            "标准基址的签名路径"
        )

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "size", value: "50"),
            URLQueryItem(name: "page", value: "1"),
        ]
        let payload = FeiniuAuthxSigner.dataPayload(method: "GET", url: components.url!, body: nil)
        c.equal(String(decoding: payload, as: UTF8.self), "page=1&size=50", "GET dataHash 输入")
        c.equal(FeiniuHash.md5Hex(payload), "6da002d7fdcb7a848138cca7cb81d927", "GET dataHash")

        c.equal(
            FeiniuAuthxSigner.authxHeader(
                method: "GET",
                url: components.url!,
                body: nil,
                nonce: "123456",
                timestampMs: 1_700_000_000_000
            ),
            "nonce=123456&timestamp=1700000000000&sign=c867d24fc551948cf8cf2a3696715a46",
            "authx 固定向量（改动签名实现必须能解释这个值的变化）"
        )

        let body = Data(#"{"trackGUID":"abc"}"#.utf8)
        c.equal(
            FeiniuAuthxSigner.dataPayload(
                method: "POST",
                url: URL(string: "http://h:5666/music/api/v1/favorite-track/create")!,
                body: body
            ),
            body,
            "POST 签的是实际发出的 body 字节"
        )
    }

    // MARK: - 地址规范化

    private static func address(_ c: Checker) {
        let bareHost = try? FeiniuAddress.normalize("192.168.1.10:5666")
        c.equal(
            bareHost?.absoluteString,
            "http://192.168.1.10:5666/music",
            "裸 host:port 补 scheme 与 /music"
        )
        for raw in [
            "http://192.168.1.10:5666/music/",
            "http://192.168.1.10:5666/music/api/v1",
            "http://192.168.1.10:5666/",
        ] {
            c.equal(
                (try? FeiniuAddress.normalize(raw))?.absoluteString,
                "http://192.168.1.10:5666/music",
                "基址收敛：\(raw)"
            )
        }
        let proxiedAddress = try? FeiniuAddress.normalize(
            "https://example.com/nas/music/api/v1/track/list"
        )
        c.equal(
            proxiedAddress?.absoluteString,
            "https://example.com/nas/music",
            "反代前缀保留"
        )
        c.expect(
            (try? FeiniuAddress.normalize("https://fnos.net/abc123/music")) == nil,
            "FN Connect 引导地址必须拒绝"
        )
        c.expect(
            (try? FeiniuAddress.normalize("   ")) == nil,
            "空地址必须拒绝"
        )
    }

    // MARK: - 时长

    private static func duration(_ c: Checker) {
        c.near(FeiniuDuration.normalize(245.5), 245.5, "秒单位原样")
        c.near(FeiniuDuration.normalize(245_500), 245.5, "毫秒单位换算")
        c.near(FeiniuDuration.normalize(20_000), 20_000, "阈值边界（20000 仍按秒）")
        c.near(FeiniuDuration.normalize(20_001), 20.001, "阈值边界（20001 起按毫秒）")
        c.near(FeiniuDuration.normalize(nil as Double?), 0, "nil → 0")
        c.near(FeiniuDuration.normalize(-5), 0, "负数 → 0")
    }

    // MARK: - 歌词

    private static func lyrics(_ c: Checker) {
        let lrc = """
        [ti:测试]
        [00:12.34]第一行
        [00:15.00]第二行
        """
        let lines = FeiniuLyrics.parse(lrc)
        let timed = lines.filter { $0.start != nil }
        c.equal(timed.count, 2, "时间轴行数")
        if timed.count == 2 {
            c.near(timed[0].start ?? -1, 12.34, "第一条时间戳（秒）")
            c.equal(timed[0].text, "第一行", "第一条歌词文本")
            c.near(timed[1].start ?? -1, 15.0, "第二条时间戳（秒）")
        }

        let plain = FeiniuLyrics.parse("只有一行文本", isLRC: false)
        c.equal(plain.count, 1, "纯文本歌词行数")
        c.equal(plain.first?.text, "只有一行文本", "纯文本歌词内容")
        c.expect(plain.first?.start == nil, "纯文本歌词无时间轴")
    }

    // MARK: - 流派（宽容解析）

    private static func genres(_ c: Checker) {
        let objectShape = FeiniuJSON.makeObject([
            "genres": FeiniuJSON(value: .array([
                FeiniuJSON.makeObject([
                    "guid": FeiniuJSON(value: .string("g1")),
                    "name": FeiniuJSON(value: .string("民谣")),
                ]),
            ])),
        ])
        c.equal(FeiniuMapping.genres(objectShape), ["民谣"], "genres 为对象数组")

        let stringShape = FeiniuJSON.makeObject([
            "genres": FeiniuJSON(value: .array([FeiniuJSON(value: .string("摇滚"))])),
        ])
        c.equal(FeiniuMapping.genres(stringShape), ["摇滚"], "genres 为字符串数组")

        c.equal(FeiniuMapping.genres(FeiniuJSON.makeObject([:])), [], "缺失 genres → 空数组")
    }

    // MARK: - 跨后端纯逻辑

    private static func sharedLogic(_ c: Checker) {
        c.equal(HTTPClient.camelize("Items"), "items", "camelize Items")
        c.equal(HTTPClient.camelize("ParentId"), "parentId", "camelize ParentId")
        c.equal(
            HTTPClient.camelize("PlaybackPositionTicks"),
            "playbackPositionTicks",
            "camelize PlaybackPositionTicks"
        )
        c.equal(HTTPClient.camelize("Is_Favorite_Item"), "isFavoriteItem", "camelize snake_case")

        let base = ArtworkRef(
            backend: .feiniu,
            itemID: "track_abc",
            kind: .primary,
            version: nil,
            maxWidth: 400
        )
        c.equal(base.cacheKey, "feiniu|track_abc|primary|-|400", "封面缓存键格式")
        let same = ArtworkRef(
            backend: .feiniu,
            itemID: "track_abc",
            kind: .primary,
            version: nil,
            maxWidth: 400
        )
        c.equal(base.cacheKey, same.cacheKey, "同图同键（签名 URL 不影响缓存）")
        var newVersion = base
        newVersion.version = "tag2"
        c.expect(base.cacheKey != newVersion.cacheKey, "换图必须换缓存键")
        var otherWidth = base
        otherWidth.maxWidth = 800
        c.expect(base.cacheKey != otherWidth.cacheKey, "不同尺寸分开缓存")

        var progress = MediaUserData()
        c.near(progress.progressRatio(duration: 0), 0, "无时长时进度为 0")
        progress.resumePosition = 30
        c.near(progress.progressRatio(duration: 120), 0.25, "进度比例")
        progress.resumePosition = 999
        c.near(progress.progressRatio(duration: 120), 1, "进度比例上限截断")

        // 本地兜底合并：统计字段一律本地优先，收藏 2 参版本取并集
        var server = MediaUserData()
        server.isFavorite = false
        var local = MediaUserData()
        local.isFavorite = true
        local.playCount = 7
        local.resumePosition = 42
        local.lastPlayed = Date(timeIntervalSince1970: 1_700_000_000)
        let merged = LocalLibraryState.merge(server: server, local: local)
        c.equal(merged.playCount, 7, "播放次数以本地为准")
        c.near(merged.resumePosition, 42, "续播位置以本地为准")
        c.expect(merged.isFavorite, "本地记住的收藏不能被服务端 false 吃掉")
        c.equal(merged.lastPlayed, local.lastPlayed, "最近播放时间以本地为准")

        // 精确版：服务端支持收藏时以服务端为准（别的设备取消收藏要能同步回来）
        let precise = LocalLibraryState.merge(
            server: server,
            local: local,
            serverSupportsFavorites: true
        )
        c.expect(!precise.isFavorite, "服务端支持收藏时以服务端为准")
        c.equal(precise.playCount, 7, "精确合并下统计字段仍本地优先")

        let noLocal = LocalLibraryState.merge(server: server, local: nil)
        c.equal(noLocal.playCount, 0, "无本地数据时保留服务端数据")

        let page = Paged(items: [1, 2, 3], total: 10, offset: 0, limit: 3)
        c.expect(page.hasMore, "分页：还有下一页")
        let last = Paged(items: [8, 9, 10], total: 10, offset: 7, limit: 3)
        c.expect(!last.hasMore, "分页：最后一页")
    }

    // MARK: - 内容身份（跨后端「同一首歌只存一份」的基础）

    private static func media(
        backend: BackendKind,
        id: String,
        title: String,
        artist: String?,
        duration: Double,
        kind: MediaKind = .track
    ) -> MediaItem {
        MediaItem(
            id: id,
            backend: backend,
            kind: kind,
            title: title,
            subtitle: artist,
            artistName: artist,
            duration: duration,
            artwork: ArtworkRef(
                backend: backend,
                itemID: "\(backend.rawValue)-\(id)",
                kind: .primary,
                version: nil,
                maxWidth: 400
            )
        )
    }

    private static func contentIdentity(_ c: Checker) {
        // 归一化：全角/半角、大小写、空格、标点都要吃掉
        c.equal(ContentIdentity.normalize("Ｈｅｌｌｏ， World!"), "helloworld", "归一化：全角+标点+大小写")
        c.equal(ContentIdentity.normalize("  周杰伦  "), "周杰伦", "归一化：汉字保留、空格去掉")
        c.equal(ContentIdentity.normalize(""), "", "归一化：空串")
        c.equal(ContentIdentity.normalize("Sia – 1000 Forms of Fear"), "sia1000formsoffear", "归一化：破折号/空格")

        // 同一首歌在两个后端 → 同一个内容身份（条目 id 完全不同也不影响）
        let jf = media(backend: .jellyfin, id: "jf-123", title: "夜曲", artist: "周杰伦", duration: 226.4)
        let fn = media(backend: .feiniu, id: "fn-guid-abc", title: "夜曲", artist: "周杰伦", duration: 226.6)
        // 时长档可能落在相邻两档（226 vs 227），所以判据是「互相能探测到」而不是「键字符串相等」
        let mutual = Set(ContentIdentity.candidates(for: jf))
            .isDisjoint(with: Set(ContentIdentity.candidates(for: fn))) == false
        c.expect(mutual, "同一首歌跨后端 → 互相能探测到（时长档相邻也算同一首）")
        // 视觉身份（封面共享）不含时长，必须完全相等
        c.equal(ContentIdentity.visualKey(for: jf), ContentIdentity.visualKey(for: fn), "同一首歌跨后端 → 视觉身份一致")

        // 时长差几百毫秒（档位可能落在相邻两档）→ ±2 秒探测要能命中
        let slow = media(backend: .feiniu, id: "fn-2", title: "夜曲", artist: "周杰伦", duration: 228.2)
        let overlap = !Set(ContentIdentity.candidates(for: slow))
            .isDisjoint(with: Set(ContentIdentity.candidates(for: jf)))
        c.expect(overlap, "时长差 1.8s 的两端仍应命中（±2 秒探测）")

        // 不同录音（同名不同艺人 / 时长差很大）不能合并
        let cover = media(backend: .feiniu, id: "fn-3", title: "夜曲", artist: "某翻唱歌手", duration: 226.5)
        c.expect(cover.contentKey != jf.contentKey, "同名不同艺人不能合并")
        let live = media(backend: .feiniu, id: "fn-4", title: "夜曲 (Live)", artist: "周杰伦", duration: 300)
        c.expect(live.contentKey != jf.contentKey, "Live 版与原版不能合并")
        let disjoint = Set(ContentIdentity.candidates(for: live))
            .isDisjoint(with: Set(ContentIdentity.candidates(for: jf)))
        c.expect(disjoint, "差 74 秒的两个版本，探测区间不应重叠")

        // 专辑 / 艺人同样跨后端共享（封面缓存靠它）
        let albumJF = media(backend: .jellyfin, id: "a1", title: "十一月的萧邦", artist: "周杰伦", duration: 0, kind: .album)
        let albumFN = media(backend: .feiniu, id: "a2", title: "十一月的萧邦", artist: "周杰伦", duration: 0, kind: .album)
        c.equal(albumJF.contentKey, albumFN.contentKey, "同一张专辑跨后端 → 同一内容身份")
        let artistJF = media(backend: .jellyfin, id: "r1", title: "周杰伦", artist: nil, duration: 0, kind: .artist)
        let artistFN = media(backend: .feiniu, id: "r2", title: "周杰伦", artist: nil, duration: 0, kind: .artist)
        c.equal(artistJF.contentKey, artistFN.contentKey, "同一艺人跨后端 → 同一内容身份")

        // 播放列表不跨后端合并（各服务端自己的组织方式）
        let playlist1 = media(backend: .jellyfin, id: "p1", title: "通勤", artist: nil, duration: 0, kind: .playlist)
        let playlist2 = media(backend: .feiniu, id: "p1", title: "通勤", artist: nil, duration: 0, kind: .playlist)
        c.expect(playlist1.contentKey != playlist2.contentKey, "播放列表不跨后端合并")

        // 封面别名缓存键：同一首歌两个后端 → 同一个别名键（只存一份图），宽度分档
        let ref1 = jf.artworkRef(width: 400)
        let ref2 = fn.artworkRef(width: 400)
        c.equal(ref1?.contentCacheKey, ref2?.contentCacheKey, "封面跨后端别名一致")
        c.expect(ref1?.cacheKey != ref2?.cacheKey, "各自的原键仍按后端区分（换后端可各自失效）")
        c.expect(ref1?.contentCacheKey != jf.artworkRef(width: 800)?.contentCacheKey, "别名按宽度分档")
    }

    // MARK: - FN Connect（定位签名 / 候选顺序 / 安全过滤）

    private static func fnConnect(_ c: Checker) {
        // FN ID 识别：无 scheme / 点 / 斜杠才算 FN ID（有点的当主机名）
        c.expect(FeiniuFNConnect.isFNID("ravooo"), "普通 FN ID")
        c.expect(FeiniuFNConnect.isFNID("rak_1-x"), "含下划线连字符的 FN ID")
        c.expect(!FeiniuFNConnect.isFNID("ravooo.fnos.net"), "带域名后缀的不是 FN ID")
        c.expect(!FeiniuFNConnect.isFNID("192.168.1.10"), "IP 不是 FN ID")
        c.expect(!FeiniuFNConnect.isFNID("http://x"), "URL 不是 FN ID")
        c.expect(!FeiniuFNConnect.isFNID("   "), "空串不是 FN ID")

        // 从引导地址里取 FN ID
        c.equal(FeiniuFNConnect.fnID(fromRelayURL: "https://fnos.net/ravooo/music"), "ravooo", "引导地址取 FN ID")
        c.equal(FeiniuFNConnect.fnID(fromRelayURL: "fnos.net/ravooo/music"), "ravooo", "无 scheme 的引导地址")
        c.expect(FeiniuFNConnect.fnID(fromRelayURL: "https://example.com/ravooo/music") == nil, "非 FN 域名不取")

        // 定位签名固定向量（nonce / timestamp 外部注入 → 纯函数可断言）
        c.equal(
            FeiniuFNConnect.authxHeader(fnId: "ravooo", nonce: "123456", timestampMs: 1_700_000_000_000),
            "nonce=123456&timestamp=1700000000000&sign=73135840a9272ece544f0f7572c1175d",
            "FN Connect 定位 authx"
        )
        c.equal(
            FeiniuFNConnect.fnSign(fnId: "ravooo", timestampMs: 1_700_000_000_000),
            "f4d4d2712f18233c3a7a6dd9fa8db35498a73ac3150a48e61546653611d8492e",
            "fn-sign"
        )
        c.equal(
            String(decoding: FeiniuFNConnect.lookupBody(fnId: "ravooo"), as: UTF8.self),
            #"{"fnId":"ravooo"}"#,
            "定位请求体是紧凑 JSON"
        )

        // 候选顺序：内网 http → 内网 https → 公网 → DDNS → relay
        var endpoints = FnConnectEndpoints(fnId: "ravooo")
        endpoints.lanIPv4 = ["192.168.31.249"]
        endpoints.publicIPv4 = ["175.152.188.213"]
        endpoints.publicIPv6 = ["2408:8266:e34:c040::249"]
        endpoints.relay = ["ravooo.fnos.net:443", "evil.example.com:443"]
        let candidates = FeiniuFNConnect.candidates(from: endpoints)
        c.equal(candidates.first?.baseURL.absoluteString, "http://192.168.31.249:5666/music", "内网 http 优先")
        c.equal(candidates.first?.timeout, 3, "内网探测超时 3s（放宽以免冷连接误判不可达）")
        c.expect(candidates.last?.usesRelay == true, "relay 兜底")
        c.equal(candidates.last?.baseURL.absoluteString, "https://ravooo.fnos.net/music", "relay 基址（恒 443）")
        c.expect(
            !candidates.contains { $0.baseURL.host == "evil.example.com" },
            "非白名单后缀的 relay 候选必须丢弃"
        )

        // 定位响应的错误码映射
        let notFound = Data(#"{"code":1001,"msg":"not found"}"#.utf8)
        var threwNotFound = false
        do { _ = try FeiniuFNConnect.decodeLookup(notFound, fnId: "ravooo") } catch { threwNotFound = true }
        c.expect(threwNotFound, "code=1001 → FN ID 不存在")

        let ok = Data(#"""
        {"code":0,"msg":"","data":{"ipv4":["192.168.31.249"],"fn":["ravooo.fnos.net:443"],
         "port":{"httpPort":5666,"httpsPort":5667},"ver":"3.0.0","forbbidPublicIpv6":false}}
        """#.utf8)
        if let decoded = try? FeiniuFNConnect.decodeLookup(ok, fnId: "ravooo") {
            c.equal(decoded.lanIPv4, ["192.168.31.249"], "解析内网候选")
            c.equal(decoded.relay, ["ravooo.fnos.net:443"], "解析 relay 候选")
            c.equal(decoded.httpPort, 5666, "解析端口")
            c.equal(decoded.serverVersion, "3.0.0", "解析定位服务版本")
        } else {
            c.expect(false, "正常响应应能解析")
        }

        // 私网判定（自签证书只对私网放行）
        c.expect(SelfSignedHostDelegate.isPrivateHost("192.168.31.249"), "192.168/16 是私网")
        c.expect(SelfSignedHostDelegate.isPrivateHost("10.0.0.2"), "10/8 是私网")
        c.expect(SelfSignedHostDelegate.isPrivateHost("nas.local"), ".local 是私网")
        c.expect(!SelfSignedHostDelegate.isPrivateHost("ravooo.fnos.net"), "relay 域名不是私网（必须走系统校验）")
        c.expect(!SelfSignedHostDelegate.isPrivateHost("175.152.188.213"), "公网 IP 不是私网")
    }
}

// MARK: - 命令行诊断（`--fn-resolve <FN ID>`）

enum FeiniuSessionDiagnostics {
    static let appDomain = "com.jellyfin.mac-client"

    static var isRequested: Bool { CommandLine.arguments.contains("--feiniu-validate") }

    /// 用 app 的真实代码路径校验「已存的飞牛会话」：读盘 → validateSession → 打印结果。
    static func runIfRequested() {
        guard isRequested else { return }
        Task { @MainActor in
            // 注意：命令行跑的是裸二进制，`UserDefaults.standard` 的域是二进制名而不是
            // app 的 bundle id，所以要显式打开 app 的 suite 才能读到界面里登录的会话。
            let appDefaults = UserDefaults(suiteName: Self.appDomain)
            guard let data = appDefaults?.data(forKey: "backend.feiniu.session"),
                  var stored = try? JSONDecoder().decode(BackendSession.self, from: data) else {
                print("[feiniu-validate] 没有已存的飞牛会话（app 域：\(Self.appDomain)）")
                exit(2)
            }
            // 可选第二参数：临时覆盖基址（用于对比「内网 vs 中继」）
            let args = CommandLine.arguments
            if let index = args.firstIndex(of: "--feiniu-validate"), args.indices.contains(index + 1),
               let base = URL(string: args[index + 1]) {
                stored = BackendSession(
                    backend: stored.backend,
                    serverURL: base,
                    username: stored.username,
                    token: stored.token,
                    userID: stored.userID,
                    userDisplayName: stored.userDisplayName,
                    extraCookie: base.host?.contains("fnos.net") == true ? "mode=relay" : nil,
                    fnID: stored.fnID
                )
                print("[feiniu-validate] 使用覆盖基址：\(base.absoluteString)")
            }
            print("[feiniu-validate] 已存会话 base=\(stored.serverURL.absoluteString)")
            print("[feiniu-validate] fnID=\(stored.fnID ?? "无") relayCookie=\(stored.extraCookie ?? "无") userID=\(stored.userID)")
            do {
                let user = try await FeiniuBackend().validateSession(stored)
                print("[feiniu-validate] ✓ 校验通过：\(user.name)（\(user.id)）")
                exit(0)
            } catch {
                print("[feiniu-validate] ✗ 校验失败：\(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
    }
}

enum FnConnectDiagnostics {
    static var requestedFNID: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--fn-resolve"), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    /// 解析并打印候选/中继结果（用于在没有界面的环境里验证 FN Connect）
    static func runIfRequested() {
        guard let fnID = requestedFNID else { return }
        print("[fn-resolve] 定位 FN ID：\(fnID)")
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let session = FeiniuFNConnect.makeSession()
                let endpoints = try await FeiniuFNConnect.lookup(fnId: fnID, session: session)
                print("[fn-resolve] 定位成功：ver=\(endpoints.serverVersion) http=\(endpoints.httpPort) https=\(endpoints.httpsPort)")
                print("[fn-resolve] 内网 \(endpoints.lanIPv4) 公网 v4 \(endpoints.publicIPv4) 公网 v6 \(endpoints.publicIPv6)")
                print("[fn-resolve] relay \(endpoints.relay)")
                for candidate in FeiniuFNConnect.candidates(from: endpoints) {
                    let ok = await FeiniuFNConnect.probe(candidate, session: session)
                    print("[fn-resolve] 探测 \(candidate.label) \(candidate.baseURL.absoluteString) → \(ok ? "通" : "不通")")
                }
                let resolution = try await FeiniuFNConnect.resolve(fnId: fnID, session: session)
                print("[fn-resolve] 最终基址：\(resolution.baseURL.absoluteString)（\(resolution.via)）"
                    + " relayCookie=\(resolution.relayCookie ?? "无")")
                semaphore.signal()
            } catch {
                print("[fn-resolve] ✗ \(error.localizedDescription)")
                semaphore.signal()
                exit(1)
            }
            exit(0)
        }
        semaphore.wait()
    }
}

// MARK: - 最小断言器

/// 轻量断言器：收集所有失败再统一退出（一次跑完看全部问题，而不是首个失败就停）。
final class Checker {
    private(set) var failures: [String] = []
    private(set) var passed = 0

    func expect(_ condition: Bool, _ label: String) {
        if condition {
            passed += 1
        } else {
            failures.append(label)
        }
    }

    func equal<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
        if lhs == rhs {
            passed += 1
        } else {
            failures.append("\(label)：期望 \(rhs)，实际 \(lhs)")
        }
    }

    func equal<T: Equatable>(_ lhs: [T], _ rhs: [T], _ label: String) {
        if lhs == rhs {
            passed += 1
        } else {
            failures.append("\(label)：期望 \(rhs)，实际 \(lhs)")
        }
    }

    func near(_ lhs: Double, _ rhs: Double, _ label: String, accuracy: Double = 0.001) {
        if abs(lhs - rhs) <= accuracy {
            passed += 1
        } else {
            failures.append("\(label)：期望 \(rhs)，实际 \(lhs)")
        }
    }

    func report() {
        if failures.isEmpty {
            print("[selftest] ✓ \(passed) 项断言全部通过")
            return
        }
        print("[selftest] ✗ \(failures.count) 项失败（\(passed) 项通过）：")
        for (index, failure) in failures.enumerated() {
            print("  \(index + 1). \(failure)")
        }
    }
}
