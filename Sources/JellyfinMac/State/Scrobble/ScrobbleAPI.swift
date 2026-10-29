import CryptoKit
import Foundation

// MARK: - 外部听歌服务的共享模型

/// 听歌记录服务（同一时间只向一个服务提交，见 `ScrobbleSettings.service`）。
enum ScrobbleServiceKind: String, CaseIterable, Identifiable, Codable {
    case lastFM = "lastfm"
    case listenBrainz = "listenbrainz"

    var id: String { rawValue }

    /// 设置页展示名（也是隐私说明里的目标服务名）
    var displayName: String {
        switch self {
        case .lastFM: return "Last.fm"
        case .listenBrainz: return "ListenBrainz"
        }
    }
}

/// 一次「可提交」的听歌记录：只保留两个服务都需要的最小元数据。
///
/// `playedAt` 是**开始播放**的 Unix 秒（Last.fm 的 `timestamp` / ListenBrainz 的 `listened_at`），
/// 原样提交、不做时区换算 —— 两个 API 都按 UTC 秒解释。
struct ScrobbleListen: Codable, Equatable {
    var title: String
    var artist: String
    var album: String?
    var duration: Double
    var trackNumber: Int?
    var playedAt: Int

    /// 从领域曲目构造；缺艺人或歌名时返回 nil（两个服务都不接受空字段）。
    init?(item: MediaItem, playedAt: Int) {
        guard let title = item.title.trimmedForScrobble,
              let artist = (item.artistName ?? item.subtitle ?? "").trimmedForScrobble else {
            return nil
        }
        self.init(
            title: title,
            artist: artist,
            album: item.albumTitle?.trimmedForScrobble,
            duration: item.duration,
            trackNumber: item.trackNumber,
            playedAt: playedAt
        )
    }

    init(
        title: String,
        artist: String,
        album: String? = nil,
        duration: Double = 0,
        trackNumber: Int? = nil,
        playedAt: Int
    ) {
        self.title = title
        self.artist = artist
        self.album = album.flatMap { $0.trimmedForScrobble }
        self.duration = duration.isFinite ? max(duration, 0) : 0
        self.trackNumber = (trackNumber ?? 0) > 0 ? trackNumber : nil
        self.playedAt = max(playedAt, 0)
    }
}

/// 一次待提交（或重试中）的听歌记录。
///
/// 记录来源服务：用户可能在两次播放之间切换 Last.fm / ListenBrainz，
/// 队列里的旧条目仍应提交给它当初对应的服务。
struct ScrobblePendingEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var service: ScrobbleServiceKind
    var listen: ScrobbleListen

    init(id: UUID = UUID(), service: ScrobbleServiceKind, listen: ScrobbleListen) {
        self.id = id
        self.service = service
        self.listen = listen
    }
}

// MARK: - 通用工具

extension String {
    /// 去掉首尾空白与换行；空串视为 `nil`（听歌服务的元数据字段不接受空值）。
    ///
    /// 命名带 `Scrobble` 前缀以避免与其他并行改动撞名。
    var trimmedForScrobble: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 外网听歌服务的错误。文案全部是脱敏的：**不允许**把 token / secret 拼进错误描述。
enum ScrobbleAPIError: Error, LocalizedError {
    case transport
    case http(Int)
    case malformed
    case service(code: Int?, message: String)

    var errorDescription: String? {
        switch self {
        case .transport:
            return "网络不可用"
        case .http(let status):
            return "服务返回 HTTP \(status)"
        case .malformed:
            return "服务响应格式异常"
        case .service(_, let message):
            return message
        }
    }
}

// MARK: - HTTP 传输

/// 外网服务的最小 HTTP 层。
///
/// 与后端的 `HTTPClient` 无关：这里没有会话 cookie、没有 envelope、没有重试 ——
/// 失败一律抛错，由 `ScrobbleService` 静默入待补报队列，绝不影响播放。
enum ScrobbleHTTP {
    struct Response {
        let statusCode: Int
        let data: Data
    }

    /// 独立 ephemeral 会话：不共享 cookie / 缓存；超时短一些，离线时尽快失败入队。
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    static func send(_ request: URLRequest) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ScrobbleAPIError.malformed
            }
            return Response(statusCode: http.statusCode, data: data)
        } catch let error as ScrobbleAPIError {
            throw error
        } catch {
            throw ScrobbleAPIError.transport
        }
    }

    static func postForm(_ url: URL, params: [String: String]) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = formBody(params)
        return try await send(request)
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ScrobbleAPIError.malformed
        }
        return object
    }

    /// x-www-form-urlencoded 编码（严格 unreserved 字符集：中文/`[` 等全部 %XX）。
    static func formBody(_ params: [String: String]) -> Data {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        let pairs = params.map { name, value in
            let key = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(key)=\(encoded)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }
}

// MARK: - Last.fm

/// Last.fm Web Service API（`https://ws.audioscrobbler.com/2.0/`）。
///
/// 签名规则（官方 authspec §8）：参数名按 ASCII 排序，逐个 `name+value` 直接拼接，
/// 末尾接 API Secret，取 MD5 小写 hex。**`format` 与 `callback` 不参与签名**，
/// 所以本实现先签名、后追加 `format=json`。
///
/// 本应用不内置任何 API Key / Secret：两者都由用户在设置页填写（Secret 存钥匙串）。
enum LastFMAPI {
    static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    private static let authorizationBase = "https://www.last.fm/api/auth/"

    /// 桌面端授权页：用户确认后回到应用点「完成授权」。
    static func authorizationURL(apiKey: String, token: String) -> URL? {
        var components = URLComponents(string: authorizationBase)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return components?.url
    }

    /// `api_sig = MD5(排序后的 name+value 串 + secret)`。
    static func signature(params: [String: String], secret: String) -> String {
        let canonical = params.keys.sorted().map { name in
            "\(name)\(params[name] ?? "")"
        }.joined()
        return md5Hex(canonical + secret)
    }

    /// 小写十六进制 MD5（`Insecure.MD5`：Last.fm 协议本身只要求 MD5，这里不承担安全职责）。
    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: 认证

    /// 桌面授权第 1 步：取未授权的 request token（60 分钟内有效、一次性）。
    static func requestToken(apiKey: String, secret: String) async throws -> String {
        let json = try await call(method: "auth.getToken", params: [:], apiKey: apiKey, secret: secret)
        guard let token = (json["token"] as? String)?.trimmedForScrobble else {
            throw ScrobbleAPIError.malformed
        }
        return token
    }

    /// 桌面授权第 3 步：用 token 换永久 session key。
    static func createSession(
        apiKey: String,
        secret: String,
        token: String
    ) async throws -> (name: String, key: String) {
        let json = try await call(
            method: "auth.getSession",
            params: ["token": token],
            apiKey: apiKey,
            secret: secret
        )
        guard let session = json["session"] as? [String: Any],
              let name = (session["name"] as? String)?.trimmedForScrobble,
              let key = (session["key"] as? String)?.trimmedForScrobble else {
            throw ScrobbleAPIError.malformed
        }
        return (name, key)
    }

    /// 验证 session key 是否仍有效（用户可在 Last.fm 设置页撤销授权）。
    static func userName(
        apiKey: String,
        secret: String,
        sessionKey: String
    ) async throws -> String {
        let json = try await call(
            method: "user.getInfo",
            params: [:],
            apiKey: apiKey,
            secret: secret,
            sessionKey: sessionKey
        )
        guard let user = json["user"] as? [String: Any],
              let name = (user["name"] as? String)?.trimmedForScrobble else {
            throw ScrobbleAPIError.malformed
        }
        return name
    }

    // MARK: 听歌记录

    static func updateNowPlaying(
        _ listen: ScrobbleListen,
        apiKey: String,
        secret: String,
        sessionKey: String
    ) async throws {
        _ = try await call(
            method: "track.updateNowPlaying",
            params: metadataParams(listen),
            apiKey: apiKey,
            secret: secret,
            sessionKey: sessionKey
        )
    }

    /// 单条 scrobble。`track.scrobble` 的参数名用数组下标写法（`artist[0]`），
    /// 签名时按 ASCII 排序即可（`authspec` 特别说明过 `artist[10]` 排在 `artist[1]` 之前）。
    static func scrobble(
        _ listen: ScrobbleListen,
        apiKey: String,
        secret: String,
        sessionKey: String
    ) async throws {
        var params: [String: String] = [
            "artist[0]": listen.artist,
            "track[0]": listen.title,
            "timestamp[0]": String(listen.playedAt),
        ]
        if let album = listen.album { params["album[0]"] = album }
        if listen.duration >= 1 { params["duration[0]"] = String(Int(listen.duration.rounded())) }
        if let number = listen.trackNumber { params["trackNumber[0]"] = String(number) }
        _ = try await call(
            method: "track.scrobble",
            params: params,
            apiKey: apiKey,
            secret: secret,
            sessionKey: sessionKey
        )
    }

    private static func metadataParams(_ listen: ScrobbleListen) -> [String: String] {
        var params: [String: String] = [
            "artist": listen.artist,
            "track": listen.title,
        ]
        if let album = listen.album { params["album"] = album }
        if listen.duration >= 1 { params["duration"] = String(Int(listen.duration.rounded())) }
        if let number = listen.trackNumber { params["trackNumber"] = String(number) }
        return params
    }

    // MARK: 调用

    @discardableResult
    private static func call(
        method: String,
        params: [String: String],
        apiKey: String,
        secret: String,
        sessionKey: String? = nil
    ) async throws -> [String: Any] {
        var signed = params
        signed["method"] = method
        signed["api_key"] = apiKey
        if let sessionKey { signed["sk"] = sessionKey }
        signed["api_sig"] = signature(params: signed, secret: secret)
        // ⚠️ `format` 必须**在签名之后**追加：官方明确要求它不参与 api_sig 计算。
        signed["format"] = "json"

        let response = try await ScrobbleHTTP.postForm(endpoint, params: signed)
        if !(200..<300).contains(response.statusCode) {
            throw error(from: response.data, fallback: .http(response.statusCode))
        }
        let json = try ScrobbleHTTP.jsonObject(response.data)
        if let code = json["error"] as? Int {
            throw ScrobbleAPIError.service(code: code, message: message(from: json))
        }
        return json
    }

    private static func error(from data: Data, fallback: ScrobbleAPIError) -> ScrobbleAPIError {
        guard let json = try? ScrobbleHTTP.jsonObject(data),
              let code = json["error"] as? Int else { return fallback }
        return .service(code: code, message: message(from: json))
    }

    private static func message(from json: [String: Any]) -> String {
        let raw = (json["message"] as? String)?.trimmedForScrobble ?? "服务返回错误"
        return String(raw.prefix(120))
    }
}

// MARK: - ListenBrainz

/// ListenBrainz API（`https://api.listenbrainz.org/1`）。
///
/// 鉴权只用用户令牌（`Authorization: Token xxx`，存钥匙串）；提交格式见
/// <https://listenbrainz.readthedocs.io/en/latest/users/api/>：
/// `playing_now` 不带 `listened_at`，`single` 必须带。
enum ListenBrainzAPI {
    private static let baseURL = URL(string: "https://api.listenbrainz.org/1")!

    /// 校验令牌；有效时返回用户名。令牌无效返回的也是 HTTP 200（`valid=false`），要读 body。
    static func validateToken(_ token: String) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("validate-token"))
        request.httpMethod = "GET"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")

        let response = try await ScrobbleHTTP.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw ScrobbleAPIError.http(response.statusCode)
        }
        let json = try ScrobbleHTTP.jsonObject(response.data)
        guard (json["valid"] as? Bool) == true else {
            let message = (json["message"] as? String)?.trimmedForScrobble ?? "令牌无效"
            throw ScrobbleAPIError.service(code: nil, message: message)
        }
        guard let name = (json["user_name"] as? String)?.trimmedForScrobble else {
            throw ScrobbleAPIError.malformed
        }
        return name
    }

    static func submitNowPlaying(_ listen: ScrobbleListen, token: String) async throws {
        try await submit(listen, listenType: "playing_now", token: token, includeTimestamp: false)
    }

    static func submitSingle(_ listen: ScrobbleListen, token: String) async throws {
        try await submit(listen, listenType: "single", token: token, includeTimestamp: true)
    }

    private static func submit(
        _ listen: ScrobbleListen,
        listenType: String,
        token: String,
        includeTimestamp: Bool
    ) async throws {
        let payload: [String: Any] = [
            "listen_type": listenType,
            "payload": [listenPayload(listen, includeTimestamp: includeTimestamp)],
        ]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            throw ScrobbleAPIError.malformed
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("submit-listens"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = body

        let response = try await ScrobbleHTTP.send(request)
        guard (200..<300).contains(response.statusCode) else {
            if let json = try? ScrobbleHTTP.jsonObject(response.data),
               let message = (json["error"] as? String)?.trimmedForScrobble {
                throw ScrobbleAPIError.service(code: json["code"] as? Int, message: message)
            }
            throw ScrobbleAPIError.http(response.statusCode)
        }
    }

    /// 两种 `listen_type` 共用同一份 listen 载荷（纯函数，自检可直接断言）。
    static func listenPayload(_ listen: ScrobbleListen, includeTimestamp: Bool) -> [String: Any] {
        var metadata: [String: Any] = [
            "artist_name": listen.artist,
            "track_name": listen.title,
        ]
        if let album = listen.album { metadata["release_name"] = album }

        var additional: [String: Any] = [
            "submission_client": "Overtone",
            "media_player": "Overtone",
        ]
        if listen.duration > 0 {
            additional["duration_ms"] = Int((listen.duration * 1000).rounded())
        }
        if let number = listen.trackNumber {
            additional["tracknumber"] = number
        }
        metadata["additional_info"] = additional

        var payload: [String: Any] = ["track_metadata": metadata]
        if includeTimestamp {
            payload["listened_at"] = listen.playedAt
        }
        return payload
    }
}
