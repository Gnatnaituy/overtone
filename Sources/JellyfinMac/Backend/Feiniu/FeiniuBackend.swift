import Foundation

// MARK: - 飞牛音乐后端适配器
//
// 证据来源（顶层）：
// - `docs/research/fnos-music-api.md`（协议档）：§1 入口/基址、§2 认证、§3 只读端点、
//   §4 播放、§5 写接口、§6 字段表、§7 与 Jellyfin 的差异
// - `/tmp/fnresearch/XDORG-N1_FnMusic/lib/app/services/feiniu/*.dart`（[dart] 完整业务实现）
// - `/tmp/fnresearch/seasonyuu_FnMusic/api.md`（api.md：41 项实测通过的协议清单）
// - `Sources/JellyfinMac/Backend/Jellyfin/JellyfinBackend.swift`（结构与错误处理风格的对齐对象）
//
// 设计要点（与 Jellyfin 后端的最大不同）：
// 1. **凭据在 Cookie 里**，而且可能是**逐请求签名**（`authx`）→ 传输层注入放在
//    `HTTPClient.prepare`，播放器则拿 `RequestAuthorization`（见 `playableSource`）。
// 2. **没有播放进度/播放统计**（协议档 §7.4）→ 进度只能本地存，`report` 只发 `track_play`。
// 3. **分页是 `page`/`size`（从 1 开始）**，且服务端可能静默 cap `size` → 一律防御式翻页。
// 4. 参数名大小写混乱（`guid` / `trackGUID` / `albumGUID` / `playlistGUID`）→
//    **逐端点硬编码，不做任何自动大小写转换**（协议档 §7.1 头号坑）。
@MainActor
final class FeiniuBackend: MusicBackend {
    let kind: BackendKind = .feiniu

    /// 能力声明：用自建副本而不是 `BackendCapabilities.feiniu`（见文件末尾 extension 的说明）。
    let capabilities = BackendCapabilities.feiniuBackend

    var playbackPreferences = PlaybackPreferences()

    /// `authx` 签名开关（默认开）。
    ///
    /// 协议档 §2.1 的判读：**当前固件不强制签名**（[dart]、[ps5] 两个真机实现只发 Cookie
    /// 也能读写），但官方 Web 与另外两个客户端都在签。签名常量来自官方 Web 包、升级可能变，
    /// 所以留一个运行时可关的开关：万一升级后常量失效（表现是 401/403），关掉即可恢复。
    var authxEnabled = true

    private(set) var session: BackendSession?

    private var client: HTTPClient?

    /// NAS 安全码（设置页写入；所有请求都要带 `x-access-code`，协议档 §2.4）
    private var accessCode: String?

    // MARK: - 设备号
    //
    // 协议档 §2.5：32 位 hex、**一台设备一个且持久化**；而且「同一个设备号只认最后一次
    // 登录」—— 所以全 App 必须共用这一份（不能给播放器另开一次登录）。
    private static let deviceIdKey = "feiniu.deviceId"

    private static let deviceId: String = {
        if let existing = UserDefaults.standard.string(forKey: deviceIdKey),
           existing.count == 32 {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: deviceIdKey)
        return generated
    }()

    /// 封面 `size` 档位（协议档 §8#12：合法取值未知，这里按 200/400/800 三档试）。
    static let coverSizeTiers = [200, 400, 800]

    /// 分页每页条数：协议档 §7.2 建议 50～100（服务端可能静默 cap，靠翻页补齐）。
    ///
    /// `nonisolated`：它要作为默认参数值使用（默认参数在调用方上下文求值，
    /// 拿不到 MainActor 隔离）。值是不可变的 `Int`，没有隔离问题。
    nonisolated private static let pageSize = 100

    // MARK: - 会话

    /// 登录：`POST /api/v1/user/password-login`（协议档 §2.2；api.md §6.1）。
    ///
    /// 三个要点，缺一个都会登录不上：
    /// 1. `password` 必须是 **`SHA256(明文)` 的小写 hex**，不是明文；
    /// 2. `deviceId` 必须是持久化的 32 位 hex；
    /// 3. 服务端**不会 `Set-Cookie`**，必须自己从 `data.userToken` 取 token 写 Cookie。
    func signIn(_ request: SignInRequest) async throws -> BackendSession {
        // 统一解析：FN ID / FN Connect 引导地址 / 直连地址都能吃。
        // FN Connect 场景会顺带拿到中继 Cookie，后面所有请求（含封面与播放）都要带上。
        let target = try await FeiniuAddress.resolve(request.server)
        let baseURL = target.baseURL
        let username = request.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            throw MusicBackendError.unauthorized("请填写用户名")
        }
        guard !request.password.isEmpty else {
            throw MusicBackendError.unauthorized("请填写密码")
        }

        // 安全码：优先用本次输入，其次回落到已存的安全码（设置页/上次登录）。
        let resolvedAccessCode = Self.nonEmpty(request.accessCode)
            ?? SessionPersistence.shared.accessCode(.feiniu)

        // 登录请求本身也要签 authx（协议档 §2.2 标 V）。
        let loginClient = makeClient(
            baseURL: baseURL,
            token: nil,
            accessCode: resolvedAccessCode,
            extraCookie: target.relayCookie
        )
        let payload = try Self.encodeJSON([
            "username": username,
            "password": FeiniuHash.sha256Hex(request.password),
            "deviceId": Self.deviceId,
        ])
        let response = try await loginClient.send(
            path: "/api/v1/user/password-login",
            method: "POST",
            body: payload
        )
        let data = try FeiniuEnvelope.data(from: response.data)

        guard let token = Self.nonEmpty(data?["userToken"]?.stringValue) else {
            // 响应形状不符（code==0 但没有 userToken）。协议档 §2.2 只记录了这一个字段名。
            throw MusicBackendError.decoding
        }
        let user = data?["user"]
        let userID = Self.nonEmpty(user?["guid"]?.stringValue) ?? ""
        let displayName = Self.nonEmpty(user?["name"]?.stringValue) ?? username

        let session = BackendSession(
            backend: .feiniu,
            serverURL: baseURL,
            username: username,
            token: token,
            userID: userID,
            userDisplayName: displayName,
            // FN Connect 中继需要的 `mode=relay`；直连地址为 nil
            extraCookie: target.relayCookie,
            fnID: target.fnID
        )
        self.accessCode = resolvedAccessCode
        self.session = session
        self.client = makeClient(
            baseURL: baseURL,
            token: token,
            accessCode: resolvedAccessCode,
            extraCookie: target.relayCookie
        )
        return session
    }

    /// 会话校验：`GET /api/v1/user/me`（协议档 §2.6）。
    ///
    /// **不能用 `/sys/config` 判会话**——它在失效会话下也会成功返回（协议档 §2.6 标 V）。
    ///
    /// FN Connect 场景的特殊处理：中继地址会变（换网络、服务端重排候选），旧基址可能
    /// 直接不可达。这时用会话里存的 `fnID` **重新定位一次**再校验；定位后基址或
    /// `mode=relay` Cookie 变了就写回新会话，避免下次启动又走一遍。
    func validateSession(_ session: BackendSession) async throws -> BackendUser {
        let storedAccessCode = SessionPersistence.shared.accessCode(.feiniu)
        do {
            return try await validate(session, accessCode: storedAccessCode)
        } catch {
            guard let fnID = session.fnID else { throw error }
            NSLog("[Feiniu] 会话校验失败（base=%@）：%@ — 用 FN ID 重新定位", session.serverURL.absoluteString, "\(error)")
            let target = try await FeiniuAddress.resolve(fnID)
            NSLog("[Feiniu] 重新定位结果：%@（%@）relayCookie=%@", target.baseURL.absoluteString, target.via, target.relayCookie ?? "无")
            var refreshed = session
            refreshed = BackendSession(
                backend: .feiniu,
                serverURL: target.baseURL,
                username: session.username,
                token: session.token,
                userID: session.userID,
                userDisplayName: session.userDisplayName,
                extraCookie: target.relayCookie,
                fnID: target.fnID
            )
            return try await validate(refreshed, accessCode: storedAccessCode)
        }
    }

    private func validate(_ session: BackendSession, accessCode: String?) async throws -> BackendUser {
        let validatingClient = makeClient(
            baseURL: session.serverURL,
            token: session.token,
            accessCode: accessCode,
            extraCookie: session.extraCookie
        )
        let response = try await validatingClient.send(path: "/api/v1/user/me")
        let data = try FeiniuEnvelope.data(from: response.data)

        let userID = Self.nonEmpty(data?["guid"]?.stringValue) ?? session.userID
        let name = Self.nonEmpty(data?["name"]?.stringValue) ?? session.userDisplayName

        self.accessCode = accessCode
        self.session = BackendSession(
            backend: .feiniu,
            serverURL: session.serverURL,
            username: session.username,
            token: session.token,
            userID: userID,
            userDisplayName: name,
            extraCookie: session.extraCookie,
            fnID: session.fnID
        )
        self.client = validatingClient
        return BackendUser(id: userID, name: name, backend: .feiniu)
    }

    /// 登出。
    ///
    /// 飞牛**没有已验证的注销/登出端点**（协议档 §8#4 把「主动注销」列为未解问题），
    /// 所以这里只清本地状态：服务端会话会自然过期。
    /// TODO(C)：若将来发现注销端点，在这里补一次调用（失败也应无妨）。
    func signOut() async {
        session = nil
        client = nil
        accessCode = nil
    }

    // MARK: - 媒体库

    /// `GET /api/v1/shared-library/list`（协议档 §3.1 / §6.4）。
    ///
    /// 飞牛通常只有一个音乐库，但接口本身返回列表，这里照实返回全部；
    /// 列表为空（例如库列表藏在授权目录配置里）时兜一个默认库，避免选择器空白。
    func libraries() async throws -> [MusicLibrary] {
        let data = try await getData("/api/v1/shared-library/list")
        let libraries = (data?.listElements ?? []).compactMap { FeiniuMapping.library($0) }
        if !libraries.isEmpty { return libraries }
        return [MusicLibrary(id: "feiniu", name: "飞牛音乐", backend: .feiniu)]
    }

    // MARK: - 浏览

    /// 统一列表：曲目 / 专辑 / 艺人（协议档 §3.2、§3.3）。
    ///
    /// - 曲目 → `/api/v1/track/list`（`page` `size` `sort`）
    /// - 专辑 → `/api/v1/album/list`
    /// - 艺人 → `/api/v1/artist/list`（**没有 `sort` 参数**，协议档 §3.3 的参数列只有 page/size）
    ///
    /// `libraryID` 在这里被忽略：飞牛的 `track/list` 等接口没有「按库过滤」的参数
    /// （协议档 §3.2 参数列只有 page/size/sort；多库时曲目是混在一起的）。
    func items(
        in libraryID: String?,
        kind: MediaKind,
        sort: MediaSort,
        offset: Int,
        limit: Int
    ) async throws -> Paged<MediaItem> {
        let path: String
        switch kind {
        case .track:
            path = "/api/v1/track/list"
        case .album:
            path = "/api/v1/album/list"
        case .artist:
            path = "/api/v1/artist/list"
        default:
            // 歌单走 `remotePlaylists()`；文件夹概念在飞牛音乐里不存在。
            throw MusicBackendError.unsupported("\(kind.displayName)列表")
        }

        let size = limit > 0 ? limit : Self.pageSize
        // 飞牛只有 page/size（从 1 开始），没有 offset 概念。
        // 调用方按页取（offset 是 size 的整数倍）时换算精确；不整除时会有偏差，
        // 这是协议限制，不是 bug（协议档 §7.2）。
        let pageNumber = offset > 0 ? (offset / size) + 1 : 1

        var query: [URLQueryItem] = [URLQueryItem(name: "page", value: String(pageNumber))]
        query.append(URLQueryItem(name: "size", value: String(size)))
        // 排序：`sort=字段,方向`（协议档 §7.2、§10.3）。艺人列表没有 sort 参数。
        if kind != .artist, let sortValue = Self.sortValue(kind: kind, sort: sort) {
            query.append(URLQueryItem(name: "sort", value: sortValue))
        }

        let result = try await fetchPage(path: path, query: query)
        let items = result.items.compactMap { Self.mapItem($0, kind: kind) }
        return Paged(
            items: items,
            // total 用服务端值（可能含被 accessStatus 过滤掉的曲目）→ `hasMore` 才会在
            // 过滤后仍然往前翻。服务端返回 0 / 缺失时回退成「已取到的条数 + offset」——
            // 有部署会一直回 `total:0`，直接信它会让列表看起来是空的（协议档 §9.2 同顾虑）。
            total: max(result.total ?? 0, offset + items.count),
            offset: offset,
            limit: size
        )
    }

    /// 专辑内曲目：`GET /api/v1/track/album-detail/list?albumGUID=&page=&size=`（协议档 §3.2）。
    ///
    /// 注意参数名是 **`albumGUID`（大写 GUID）**，不是 `guid`；空值会得到 100002。
    /// 返回顺序由服务端保证（`{list,sort,total}`），默认按碟/轨顺位——不做客户端重排，
    /// 但 CUE 整轨的偏移计算需要 `discNo/trackNo`（见 `playableSource` 的 TODO）。
    func albumTracks(albumID: String) async throws -> [MediaItem] {
        let albumID = try Self.requireID(albumID, name: "专辑")
        let raw = try await allPages(
            path: "/api/v1/track/album-detail/list",
            query: [URLQueryItem(name: "albumGUID", value: albumID)]
        )
        return raw.compactMap { FeiniuMapping.track($0) }
    }

    /// 艺人名下专辑：`GET /api/v1/album/artist-detail/list?artistGUID=&page=&size=`（协议档 §3.3）。
    func artistAlbums(artistID: String) async throws -> [MediaItem] {
        let artistID = try Self.requireID(artistID, name: "艺人")
        let raw = try await allPages(
            path: "/api/v1/album/artist-detail/list",
            query: [URLQueryItem(name: "artistGUID", value: artistID)]
        )
        return raw.compactMap { FeiniuMapping.album($0) }
    }

    /// 艺人名下曲目：`GET /api/v1/track/artist-detail/list?artistGUID=&page=&size=`（协议档 §3.2）。
    func artistTracks(artistID: String) async throws -> [MediaItem] {
        let artistID = try Self.requireID(artistID, name: "艺人")
        let raw = try await allPages(
            path: "/api/v1/track/artist-detail/list",
            query: [URLQueryItem(name: "artistGUID", value: artistID)]
        )
        return raw.compactMap { FeiniuMapping.track($0) }
    }

    /// 搜索：`/api/v1/search/{track,album,artist}?q=&page=&size=`（协议档 §3.5）。
    ///
    /// 三个端点没有聚合接口（`/search/suggest` 只给分组建议、不是结果），
    /// 所以并发发三个请求再合并；任一失败就整体失败（宁可报错也不要半截结果，
    /// 否则用户会以为「搜不到专辑」）。
    ///
    /// 参数名是 **`q`**，不是 `keyword`（协议档 §3.5；[ext] 专门为这个错误写过兼容分支）。
    /// 响应是分页结构 `{list,total}`，不是裸数组（[dart] 记过这个 TypeError 坑）。
    func search(term: String, limit: Int) async throws -> SearchResults {
        let keyword = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return .empty }
        let size = limit > 0 ? limit : 24
        let query: [URLQueryItem] = [
            URLQueryItem(name: "q", value: keyword),
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "size", value: String(size)),
        ]

        // `async let` 的子任务继承 MainActor 隔离，网络 I/O 仍然并发。
        async let tracksTask = getData("/api/v1/search/track", query: query)
        async let albumsTask = getData("/api/v1/search/album", query: query)
        async let artistsTask = getData("/api/v1/search/artist", query: query)
        let (tracksData, albumsData, artistsData) = try await (tracksTask, albumsTask, artistsTask)

        return SearchResults(
            tracks: (tracksData?.listElements ?? []).compactMap { FeiniuMapping.track($0) },
            albums: (albumsData?.listElements ?? []).compactMap { FeiniuMapping.album($0) },
            artists: (artistsData?.listElements ?? []).compactMap { FeiniuMapping.artist($0) }
        )
    }

    // MARK: - 媒体

    /// 封面：`GET /api/v1/static/cover?coverId=&size=`（协议档 §3.7）。
    ///
    /// - `ref.itemID` 装的是 **coverId**（见 `FeiniuMapping.artwork` 的说明）；
    /// - `size` 由 `maxWidth` 映射到档位（取 `>= maxWidth` 的最小档）。
    ///   参考实现 [dart] `api_client.dart:99-102`（`coverUrl`，默认 `size=300`）。
    ///
    /// TODO(C)：这个 URL 本身**不带凭据**。如果真机上 authx/Cookie 对封面请求也是必需的，
    /// 取图方必须用 `mediaRequestAuthorization()` 注入同样的头（图片层是并行队友的活）。
    func artworkURL(_ ref: ArtworkRef) -> URL? {
        guard let client, let coverId = Self.nonEmpty(ref.itemID) else { return nil }
        return try? client.url(
            path: "/api/v1/static/cover",
            query: [
                URLQueryItem(name: "coverId", value: coverId),
                URLQueryItem(name: "size", value: String(Self.coverSize(for: ref.maxWidth))),
            ]
        )
    }

    /// 歌词：`GET /api/v1/lyric/list?trackGUID=`（协议档 §3.7）。
    ///
    /// 参数名是 **`trackGUID`（大写）**。返回 `{preferred, list:[{guid, content, isLRC, offset}]}`，
    /// 选取策略与两个参考实现一致：取 `guid == preferred` 的那条，否则取第一条。
    /// `content` 是 LRC 文本，交给纯函数 `FeiniuLyrics.parse` 解析。
    /// 封面请求的凭据：飞牛的封面同样是受保护资源，且经 FN Connect 中继时还要 `mode=relay`。
    ///
    /// 与播放链路复用同一套 `FeiniuRequestHeaders`，保证「图上能看」与「歌能播」
    /// 两条链路的凭据完全一致（否则会出现"有封面但放不出声"这类割裂现象）。
    func authorizedImageRequest(for url: URL) -> URLRequest? {
        guard let session else { return nil }
        let credentials = FeiniuCredentials(
            token: session.token,
            accessCode: accessCode,
            extraCookie: session.extraCookie
        )
        var request = URLRequest(url: url)
        let headers = FeiniuRequestHeaders.make(
            method: "GET",
            url: url,
            body: nil,
            credentials: credentials,
            authxEnabled: authxEnabled
        )
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }

    func lyrics(trackID: String) async throws -> [LyricLine] {
        let trackID = try Self.requireID(trackID, name: "曲目")
        let data = try await getData(
            "/api/v1/lyric/list",
            query: [URLQueryItem(name: "trackGUID", value: trackID)]
        )
        guard let list = data?["list"]?.arrayValue, !list.isEmpty else { return [] }

        let preferred = Self.nonEmpty(data?["preferred"]?.stringValue)
        let chosen = preferred.flatMap { preferredID in
            list.first { Self.nonEmpty($0["guid"]?.stringValue) == preferredID }
        } ?? list[0]

        let content = chosen["content"]?.stringValue ?? ""
        // `isLRC` 缺省 true（协议档 §3.7 的样例字段；[dart] `FnLyric` 同样缺省 true）。
        let isLRC = chosen["isLRC"]?.boolValue ?? true
        return FeiniuLyrics.parse(content, isLRC: isLRC)
    }

    /// 播放源（协议档 §4.1 / §4.2 / §7.6）。
    ///
    /// 直连 = `GET /api/v1/track/stream?guid=`，服务端支持标准 Range（实测 206），
    /// **音频字节由播放器读，这里不碰**；本方法只负责「给播放器什么 URL + 怎么带凭据」。
    ///
    /// 凭据注入策略是飞牛最大的不确定性（协议档 §7.6(b)）：
    /// - `authxEnabled == false` → Cookie 是静态头 → `isDynamic = false`，播放器可以一次性
    ///   塞进 `AVURLAssetHTTPHeaderFieldsKey`（方案 A，半天级）。
    /// - `authxEnabled == true` → authx 含 nonce+timestamp，AVPlayer 后续每个 Range 请求
    ///   都要重算 → `isDynamic = true`，播放器必须走 `AVAssetResourceLoader`（方案 B）。
    ///
    /// 转码回退（`transcodeFallback`）：确定性 HLS 地址
    /// `GET /api/v1/track/hls/{guid}/preset.m3u8`（协议档 §4.2 标 V）。
    /// 用户/格式要求转码时先 `POST /track/transcode` 拿 `data.url`，拿不到再退回这条路径。
    ///
    /// TODO(C)：**CUE 整轨未处理**。飞牛把「整轨 + CUE」拆成多条曲目但 `/track/stream`
    /// 返回整个整轨文件（协议档 §4.4），需要「同 album 同 audioSpec.path 按 discNo/trackNo
    /// 排序累加 duration 得到偏移 + forwardPlaybackEndTime」。这是播放器层的工作
    /// （AVPlayerItem 生命周期），后端拿不到 `audioSpec.path`（`MediaItem` 没这个字段），
    /// 因此本版本原样返回整轨流。
    func playableSource(for item: MediaItem) async throws -> PlayableSource {
        let client = try requireClient()
        guard item.kind == .track else {
            throw MusicBackendError.unsupported("非曲目条目的播放")
        }

        let streamURL = try client.url(
            path: "/api/v1/track/stream",
            query: [URLQueryItem(name: "guid", value: item.id)]
        )
        let authorization = mediaRequestAuthorization()
        let hlsURL = try? client.url(path: "/api/v1/track/hls/\(item.id)/preset.m3u8")

        let directPlayable = FeiniuPlaybackFormat.canDirectPlay(format: item.format)
        let wantsTranscode = playbackPreferences.requiresTranscode || directPlayable == false

        if wantsTranscode {
            if let transcoded = try? await requestTranscodeURL(trackID: item.id) {
                return PlayableSource(
                    url: transcoded,
                    authorization: authorization,
                    isHLS: true,
                    playMethod: .transcode,
                    unplayableReason: nil,
                    transcodeFallback: nil
                )
            }
            if directPlayable == false {
                // 已知不能直连、转码也失败 → 明确抛错，不静默跳歌（协议档 §7.5 的兜底建议）。
                throw MusicBackendError.unplayable(
                    reason: "该曲目的格式（\(item.format ?? "未知")）无法在本机直接播放，"
                        + "服务端转码也不可用"
                )
            }
            // 用户只是「想要转码档」但格式本来能播 → 退回直连（下一段）。
        }

        var source = PlayableSource(
            url: streamURL,
            authorization: authorization,
            isHLS: false,
            playMethod: .directPlay
        )
        // 直连失败时播放器可以改用 HLS 转码源。
        // TODO(C)：未预热时直接拉 `preset.m3u8` 会不会触发服务端生成，未实测；
        // 若 404，播放器应先调 `requestTranscodeURL` 再播（该方法已封装 POST）。
        source.transcodeFallback = hlsURL
        return source
    }

    // MARK: - 写

    /// 收藏 / 取消收藏：`POST /api/v1/favorite-track/{create,delete}`（协议档 §5.1）。
    ///
    /// 参数名是 **`trackGUID`（大写 GUID）**。
    /// ⚠️ 证据冲突：[dart] `favorite_service.dart:73,83` 的 body 用的是小写 `trackGuid`。
    /// 这里跟协议档（直连实测 + 官方 Web body 双重验证）走大写；
    /// 真机上若收藏「成功但没生效」，第一个要试的就是改成小写。
    ///
    /// 专辑/艺人收藏在飞牛不存在（协议档 §5.4）→ `.unsupported`。
    func setFavorite(itemID: String, kind: MediaKind, favorite: Bool) async throws {
        guard kind == .track else {
            throw MusicBackendError.unsupported("专辑 / 艺人收藏（飞牛只有曲目级收藏）")
        }
        let client = try requireClient()
        let itemID = try Self.requireID(itemID, name: "曲目")
        let payload = try Self.encodeJSON(["trackGUID": itemID])
        let path = favorite ? "/api/v1/favorite-track/create" : "/api/v1/favorite-track/delete"
        let response = try await client.send(path: path, method: "POST", body: payload)
        // 写接口同样要校验 envelope 的 code（HTTP 200 + 非 0 code 是常态）。
        _ = try FeiniuEnvelope.data(from: response.data)
    }

    /// 播放事件上报：`POST /api/v1/event/report`（协议档 §4.5）。
    ///
    /// 飞牛**只有 `track_play` 一种事件**，且 payload 里只有 `trackGUID`——没有位置、
    /// 没有时长、没有暂停状态（协议档 §7.4）。所以：
    /// - 仅 `event.kind == .started` 时上报；
    /// - `progress` / `stopped` 直接丢弃（进度只能本地存，见 `capabilities.playbackProgress`）。
    func report(_ event: PlaybackEvent) async {
        switch event.kind {
        case .started:
            break
        case .progress, .stopped:
            return
        }
        guard let client, session != nil else { return }
        let body: [String: Any] = [
            "events": [
                [
                    "eventType": "track_play",
                    // `occurredAt` 是 Unix **毫秒**（协议档 §4.5 标 V+S）。
                    "occurredAt": FeiniuTimestamp.milliseconds(from: Date()),
                    "payload": ["trackGUID": event.itemID],
                ]
            ]
        ]
        guard let payload = try? Self.encodeJSON(body) else { return }
        // 上报失败静默：播放统计不是关键路径，不值得把错误抛到 UI（与 Jellyfin 实现一致）。
        _ = try? await client.send(path: "/api/v1/event/report", method: "POST", body: payload)
    }

    // MARK: - 远程播放列表

    /// 歌单列表：`GET /api/v1/playlist/list`（协议档 §3.4）。
    func remotePlaylists() async throws -> [RemotePlaylist] {
        let raw = try await allPages(path: "/api/v1/playlist/list")
        return raw.compactMap { FeiniuMapping.remotePlaylist($0) }
    }

    /// 歌单曲目：`GET /api/v1/track/playlist-detail/list?playlistGUID=`（协议档 §3.2）。
    ///
    /// **读用 `playlistGUID`（大写），写用 `guid`（小写）** —— 协议档 §7.1 点名的分裂点。
    /// `entryID` 恒为 nil：飞牛没有「歌单条目 id」（服务端只认 trackGUID，
    /// 同一首歌可以重复入单），删条目时请把 `track.id` 传给 `removeRemotePlaylistEntries`。
    func remotePlaylistEntries(id: String) async throws -> [RemotePlaylistEntry] {
        let playlistID = try Self.requireID(id, name: "播放列表")
        let raw = try await allPages(
            path: "/api/v1/track/playlist-detail/list",
            query: [URLQueryItem(name: "playlistGUID", value: playlistID)]
        )
        return raw
            .compactMap { FeiniuMapping.track($0) }
            .map { RemotePlaylistEntry(track: $0, entryID: nil) }
    }

    /// 创建歌单：`POST /api/v1/playlist/create`（协议档 §5.2）。
    ///
    /// 名称 1–32 字符（官方 Web UI 限制）；`coverId` 需要先走 multipart 上传，
    /// 本后端暂不支持封面（TODO(C)：`POST /api/v1/static/cover/playlist`，
    /// 注意签名时 multipart 按 `JSON.stringify(FormData)` = `{}` 计算）。
    /// 业务错误码：160001 名称已存在、160002 数量达上限（已映射成中文）。
    func createRemotePlaylist(name: String, trackIDs: [String]) async throws -> RemotePlaylist {
        let playlistName = try Self.playlistName(name)
        let payload = try Self.encodeJSON(["name": playlistName])
        let data = try await postData("/api/v1/playlist/create", body: payload)
        guard let guid = Self.nonEmpty(data?["guid"]?.stringValue) else {
            throw MusicBackendError.server("创建歌单成功但响应里没有歌单标识")
        }
        if !trackIDs.isEmpty {
            try await addTracks(playlistID: guid, trackIDs: trackIDs)
        }
        return RemotePlaylist(id: guid, name: playlistName, trackCount: trackIDs.count)
    }

    /// 更新歌单：`POST /api/v1/playlist/edit`（协议档 §5.2）。
    ///
    /// 曲目集合的同步是**降级实现**：飞牛没有重排端点、也没有「批量替换」端点
    /// （协议档 §5.4 / §7.4），所以「按给定顺序同步」只能是「先清空再按序加」。
    ///
    /// TODO(C)：这个实现会**短暂清空歌单**，中途失败会留下空/半空的歌单；
    /// 协议档 §8#10 也把「playlist/* 写操作的幂等与并发语义」列为未解问题。
    /// 状态层在调用前最好先把整单内容缓存起来以便重试。
    func updateRemotePlaylist(id: String, name: String, trackIDs: [String]) async throws {
        let playlistID = try Self.requireID(id, name: "播放列表")
        let playlistName = try Self.playlistName(name)
        let client = try requireClient()

        let payload = try Self.encodeJSON(["guid": playlistID, "name": playlistName])
        let response = try await client.send(path: "/api/v1/playlist/edit", method: "POST", body: payload)
        _ = try FeiniuEnvelope.data(from: response.data)

        let existing = try await remotePlaylistEntries(id: playlistID).map(\.track.id)
        if !existing.isEmpty {
            try await removeTracks(playlistID: playlistID, trackIDs: existing)
        }
        if !trackIDs.isEmpty {
            try await addTracks(playlistID: playlistID, trackIDs: trackIDs)
        }
    }

    /// 删除歌单：`POST /api/v1/playlist/delete`（协议档 §5.2）。**不可恢复**。
    func deleteRemotePlaylist(id: String) async throws {
        let playlistID = try Self.requireID(id, name: "播放列表")
        let client = try requireClient()
        let payload = try Self.encodeJSON(["guid": playlistID])
        let response = try await client.send(path: "/api/v1/playlist/delete", method: "POST", body: payload)
        _ = try FeiniuEnvelope.data(from: response.data)
    }

    /// 批量加曲：`POST /api/v1/playlist/add-track`，body `{guid, trackGUIDs:[...]}`（协议档 §5.2）。
    func addRemotePlaylistTracks(id: String, trackIDs: [String]) async throws {
        let playlistID = try Self.requireID(id, name: "播放列表")
        guard !trackIDs.isEmpty else { return }
        try await addTracks(playlistID: playlistID, trackIDs: trackIDs)
    }

    /// 批量移曲：`POST /api/v1/playlist/remove-track`（协议档 §5.2）。
    ///
    /// ⚠️ 语义降级：飞牛没有 entryId 概念，`entryIDs` 在这里被当作 **trackGUID 列表**。
    /// 协议要求这个方法按「条目」删（Jellyfin 需要 EntryIds），但飞牛侧只能按曲目删；
    /// `remotePlaylistEntries` 已把 `entryID` 恒置 nil，调用方请传 `track.id`。
    func removeRemotePlaylistEntries(id: String, entryIDs: [String]) async throws {
        let playlistID = try Self.requireID(id, name: "播放列表")
        guard !entryIDs.isEmpty else { return }
        try await removeTracks(playlistID: playlistID, trackIDs: entryIDs)
    }

    // MARK: - 歌单写操作的内部实现

    private func addTracks(playlistID: String, trackIDs: [String]) async throws {
        let client = try requireClient()
        // 参数名 `guid` 是**小写**（与读接口的 `playlistGUID` 相反，协议档 §7.1）。
        let payload = try Self.encodeJSON([
            "guid": playlistID,
            "trackGUIDs": trackIDs,
        ])
        let response = try await client.send(
            path: "/api/v1/playlist/add-track",
            method: "POST",
            body: payload
        )
        _ = try FeiniuEnvelope.data(from: response.data)
    }

    private func removeTracks(playlistID: String, trackIDs: [String]) async throws {
        let client = try requireClient()
        let payload = try Self.encodeJSON([
            "guid": playlistID,
            "trackGUIDs": trackIDs,
        ])
        let response = try await client.send(
            path: "/api/v1/playlist/remove-track",
            method: "POST",
            body: payload
        )
        _ = try FeiniuEnvelope.data(from: response.data)
    }

    // MARK: - 转码

    /// 发起服务端转码并返回可播地址（协议档 §4.2）。
    ///
    /// 契约（V）：`POST /api/v1/track/transcode` body `{"guid":...}`，
    /// 成功时 `data.url` 是播放列表地址（**可能是相对路径**），`status` 为 `ready`/`success`。
    ///
    /// 参考实现：[dart] `api_client.dart:200-206`（`requestTranscode`，之后 `:216-226` 解析地址）。
    ///
    /// TODO(C)：`output`（codec/bitrate/channel）字段可选 —— 协议档里官方 Web 实测发过
    /// `{"codec":"opus","bitrate":128,"channel":2}`，而 [dart] 只发 `{guid}` 也能用。
    /// 这里跟 [dart]（更小的契约面），代价是**音质档位无法协商**：飞牛实际只有
    /// 「原始 / 默认 opus」两档（AAC 会返回 errno 8192，协议档 §4.2 标 V），
    /// 所以 `PlaybackPreferences.targetBitrate` 在飞牛上只能决定「要不要转码」，不决定清晰度。
    private func requestTranscodeURL(trackID: String) async throws -> URL? {
        let client = try requireClient()
        let payload = try Self.encodeJSON(["guid": trackID])
        let response = try await client.send(
            path: "/api/v1/track/transcode",
            method: "POST",
            body: payload
        )
        let data = try FeiniuEnvelope.data(from: response.data)

        // `status`/`errno` 的取值集合只有单一来源（协议档 §4.2）：只在 status 明确存在
        // 且不是 ready/success 时判失败，其余情况以「有没有 url」为准。
        let status = Self.nonEmpty(data?["status"]?.stringValue)?.lowercased()
        if let status, status != "ready", status != "success" { return nil }

        guard let rawURL = Self.nonEmpty(data?["url"]?.stringValue) else {
            // 没有 url 字段 → 退回确定性 HLS 路径（协议档 §4.2 实测存在的地址）。
            return try client.url(path: "/api/v1/track/hls/\(trackID)/preset.m3u8")
        }
        return resolveTranscodeURL(rawURL, client: client)
    }

    /// 把转码返回的相对地址解析成绝对 URL。
    ///
    /// [dart] `api_client.dart:216-226`（`resolvePlayUrl`）按 API 基址（`.../music/api/v1`）解析；
    /// 而 `HTTPClient.baseURL` 停在 `/music`，所以这里先补 `/api/v1`。
    /// 另外 base 无尾斜杠时相对解析会丢掉最后一段（`/music/api/v1` → `/music`），
    /// 所以显式补一个尾斜杠（这是 [dart] 注释里记录过的坑）。
    private func resolveTranscodeURL(_ raw: String, client: HTTPClient) -> URL? {
        if let absolute = URL(string: raw), absolute.scheme != nil { return absolute }
        var baseString = client.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .absoluteString
        if !baseString.hasSuffix("/") { baseString += "/" }
        guard let baseURL = URL(string: baseString) else { return nil }
        return URL(string: raw, relativeTo: baseURL)?.absoluteURL
    }

    // MARK: - 媒体请求授权

    /// 播放器（AVPlayer / 图片加载器）需要的凭据注入策略（协议档 §7.6）。
    private func mediaRequestAuthorization() -> RequestAuthorization {
        let credentials = FeiniuCredentials(
            token: session?.token,
            accessCode: accessCode,
            extraCookie: session?.extraCookie
        )
        guard authxEnabled else {
            var headers: [String: String] = FeiniuRequestHeaders.accessCodeHeaders(credentials)
            if let cookie = FeiniuRequestHeaders.cookieValue(credentials) {
                headers["Cookie"] = cookie
            }
            return .fixed(headers)
        }
        // 逐请求重签：闭包只捕获值类型（`FeiniuCredentials` 是 Sendable），
        // 所以能安全地在 `@Sendable` 上下文里算 —— 不碰 MainActor 状态。
        return RequestAuthorization(
            headers: { url in
                FeiniuRequestHeaders.make(
                    method: "GET",
                    url: url,
                    body: nil,
                    credentials: credentials,
                    authxEnabled: true
                )
            },
            isDynamic: true
        )
    }

    // MARK: - 传输层

    /// 建一个带凭据注入的客户端。
    ///
    /// `prepare` 里**不捕获 self**（只捕获值类型），避免「client → prepare → self → client」
    /// 的循环引用；authx 的随机数/时钟在 prepare 执行时现算，保证每个请求都是新签名。
    private func makeClient(
        baseURL: URL,
        token: String?,
        accessCode: String?,
        extraCookie: String?
    ) -> HTTPClient {
        let client = HTTPClient(baseURL: baseURL)
        let credentials = FeiniuCredentials(
            token: token,
            accessCode: accessCode,
            extraCookie: extraCookie
        )
        let signRequests = authxEnabled
        client.prepare = { request in
            guard let url = request.url else { return }
            let headers = FeiniuRequestHeaders.make(
                method: request.httpMethod ?? "GET",
                url: url,
                body: request.httpBody,
                credentials: credentials,
                authxEnabled: signRequests
            )
            for (name, value) in headers {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        // 飞牛是 camelCase 与大写 GUID 混排（`trackGUID`），**不做任何 key 转换**
        // （协议档 §7.1 / §7.3）。HTTPClient 默认就是 `.useDefaultKeys`，这里显式写出来。
        client.keyDecodingStrategy = .useDefaultKeys
        return client
    }

    private func requireClient() throws -> HTTPClient {
        guard let client, session != nil else { throw MusicBackendError.notSignedIn }
        return client
    }

    /// 紧凑 JSON（authx 的 `dataHash` 用的是**实际发出的字节**，签名在 `prepare` 里读 httpBody）。
    private static func encodeJSON(_ object: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object, options: [])
        } catch {
            throw MusicBackendError.decoding
        }
    }

    private func getData(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> FeiniuJSON? {
        let client = try requireClient()
        let response = try await client.send(path: path, query: query)
        return try FeiniuEnvelope.data(from: response.data)
    }

    private func postData(_ path: String, body: Data) async throws -> FeiniuJSON? {
        let client = try requireClient()
        let response = try await client.send(path: path, method: "POST", body: body)
        return try FeiniuEnvelope.data(from: response.data)
    }

    // MARK: - 分页

    /// 取一页（`{list,total}`；裸数组 / `items` / `rows` 也能解 —— 协议档 §6.6）。
    private func fetchPage(
        path: String,
        query: [URLQueryItem],
        page pageNumber: Int = 1,
        size: Int = FeiniuBackend.pageSize
    ) async throws -> (items: [FeiniuJSON], total: Int?) {
        var fullQuery = query
        fullQuery.append(URLQueryItem(name: "page", value: String(pageNumber)))
        fullQuery.append(URLQueryItem(name: "size", value: String(size)))
        let data = try await getData(path, query: fullQuery)
        let items = data?.listElements ?? []
        return (items, data?.totalCount)
    }

    /// 防御式翻页（协议档 §7.2 明确要求）。
    ///
    /// 为什么不能「一次要 500 条」：服务端很可能**静默 cap** `size`（[dart] 注释写默认
    /// 每页 50，[ps5] 却直接要 500 且不翻页 → 曲目多的专辑有截断风险）。
    /// 参考实现：[dart] `api_models.dart:32-46`（`paginateAll`，循环到收齐 total）。
    /// 这里循环到「收齐 total」/「空页」/「页数上限」三者之一。
    private func allPages(
        path: String,
        query: [URLQueryItem] = [],
        size: Int = FeiniuBackend.pageSize,
        maxPages: Int = 50
    ) async throws -> [FeiniuJSON] {
        var collected: [FeiniuJSON] = []
        var pageNumber = 1
        while pageNumber <= maxPages {
            let page = try await fetchPage(path: path, query: query, page: pageNumber, size: size)
            if page.items.isEmpty { break }
            collected.append(contentsOf: page.items)
            // `total <= 0` 一律当成「未知」（有的部署一直回 0，信它会第一页就停）。
            let total = page.total.flatMap { $0 > 0 ? $0 : nil }
            if let total, collected.count >= total { break }
            // total 未知时：本页不满 → 已是最后一页。
            if total == nil, page.items.count < size { break }
            pageNumber += 1
        }
        return collected
    }

    // MARK: - 映射与参数

    /// 映射一条 wire 记录到领域条目。
    private static func mapItem(_ json: FeiniuJSON, kind: MediaKind) -> MediaItem? {
        switch kind {
        case .track: return FeiniuMapping.track(json)
        case .album: return FeiniuMapping.album(json)
        case .artist: return FeiniuMapping.artist(json)
        default: return nil
        }
    }

    /// 领域排序 → 飞牛的 `sort=字段,方向`（协议档 §7.2、§10.3）。
    ///
    /// 已知实测值只有两个：`createdAt,desc`（track）与 `newTrackAddedAt,desc`（album）。
    /// 其余字段名**没有证据**（协议档 §7.2 末句把「排序字段全集」列为 C），标 TODO(C)。
    private static func sortValue(kind: MediaKind, sort: MediaSort) -> String? {
        switch (kind, sort) {
        case (.track, .dateAdded):
            return "createdAt,desc"
        case (.album, .dateAdded):
            return "newTrackAddedAt,desc"
        case (.artist, .dateAdded):
            // TODO(C)：艺人列表接口的参数列里没有 sort（协议档 §3.3），这一条多半会被忽略。
            return "createdAt,desc"
        case (.playlist, .dateAdded), (.folder, .dateAdded):
            // 这两类不走通用列表接口（歌单走 `remotePlaylists()`），防御性返回 nil。
            return nil
        case (_, .name):
            // TODO(C)：`name,asc` 未实测，只是按 `字段,方向` 的约定猜的字段名。
            return "name,asc"
        case (_, .playCount):
            // 飞牛没有播放次数（`capabilities.playStats == false`）→ 不传 sort，
            // 别发一个服务端不认识的字段去换 100002。
            return nil
        case (_, .albumOrder):
            // 专辑内顺位由 `albumTracks` 的接口默认顺序保证；通用列表不支持该排序。
            return nil
        }
    }

    /// `maxWidth` → 封面 `size` 档位（取 `>= maxWidth` 的最小档，超出取最大档）。
    static func coverSize(for maxWidth: Int) -> Int {
        let width = max(maxWidth, 1)
        return coverSizeTiers.first(where: { $0 >= width }) ?? coverSizeTiers.last ?? 400
    }

    // MARK: - 参数校验

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func requireID(_ raw: String, name: String) throws -> String {
        guard let id = nonEmpty(raw) else {
            // 飞牛对空 GUID 返回 100002（InvalidArgs），本地先拦掉，省一次往返。
            throw MusicBackendError.server("\(name)标识缺失，请返回刷新后重试")
        }
        return id
    }

    /// 歌单名约束（协议档 §5.2：名称 1–32 字符）。
    private static func playlistName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw MusicBackendError.server("歌单名称不能为空（1–32 个字符）")
        }
        guard name.count <= 32 else {
            throw MusicBackendError.server("歌单名称过长（最多 32 个字符）")
        }
        return name
    }
}

// MARK: - 能力声明（飞牛专用副本）

extension BackendCapabilities {
    /// 飞牛后端自己的能力副本。
    ///
    /// 为什么不直接用 `BackendCapabilities.feiniu`：协议层那份把 `search` 标成了 `false`，
    /// 而本后端用 `/api/v1/search/{track,album,artist}` 三个端点实现了搜索
    /// （协议档 §3.5，V+S 级证据；响应是分页结构 `{list,total}`）。
    /// 并行开发期间 `MusicBackend.swift` 由别人维护，所以这里**自建一份常量**，
    /// 不动协议层；等分支合并后再决定是否把协议层那份改成 `search: true`。
    ///
    /// 其余字段与协议层一致，理由：
    /// - `serverPaging`：飞牛强制 `page`/`size`；
    /// - `playbackProgress` / `playStats`：飞牛没有进度上报、没有播放统计（协议档 §7.4）；
    /// - `albumArtistFavorites`：只有曲目级收藏；
    /// - `transcode`：有 `/track/transcode`（仅 opus 一档）；
    /// - `playlistReorder`：**没有重排端点**（协议档 §5.4 / §7.4）。
    static let feiniuBackend = BackendCapabilities(
        serverPaging: true,
        playbackProgress: false,
        playStats: false,
        trackFavorites: true,
        albumArtistFavorites: false,
        transcode: true,
        lyrics: true,
        remotePlaylists: true,
        playlistReorder: false,
        search: true,
        artistBrowsing: true,
        instantMix: false
    )
}
