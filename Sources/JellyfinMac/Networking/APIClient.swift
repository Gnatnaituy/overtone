import Foundation

enum APIError: LocalizedError {
    case notConfigured
    case invalidURL
    case invalidResponse
    case server(statusCode: Int, message: String)
    case decoding(Error)
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "尚未配置服务器"
        case .invalidURL: return "服务器地址无效"
        case .invalidResponse: return "服务器返回了无效响应"
        case .server(let code, let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "服务器错误（\(code)）" : "服务器错误（\(code)）：\(trimmed)"
        case .decoding: return "数据解析失败"
        case .network(let error): return "无法连接到服务器：\(error.localizedDescription)"
        }
    }
}

final class APIClient {
    static let shared = APIClient()
    private init() {}

    var baseURL: URL?
    var token: String?
    var user: UserDto?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()
    /// 客户端名可在登录页「高级选项」里改（写入 UserDefaults，服务端会话按此显示设备）
    private var clientName: String {
        let custom = UserDefaults.standard.string(forKey: "clientName")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (custom?.isEmpty == false ? custom! : "Overtone")
    }
    private let deviceName = "Mac"
    /// 设备 ID：**跨启动稳定**。
    ///
    /// 原实现每次启动都 `UUID().uuidString` 现生成 —— Jellyfin 以 `DeviceId` 识别设备，
    /// 于是每次启动都会在服务端新建一个会话 / 设备记录，旧记录不会被清理：
    /// 设备列表与 `/Sessions` 响应随启动次数无限增长，多端播放进度的归并也会
    /// 把同一台机器当成新设备。首次启动生成后落盘复用。
    private let deviceId: String = {
        let key = "clientDeviceId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = "mac-\(UUID().uuidString)"
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()
    private let appVersion = "1.0.0"

    // MARK: - 请求

    private func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard let base = baseURL else { throw APIError.notConfigured }
        guard var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidURL
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        return url
    }

    /// Jellyfin 12 起只认标准 `Authorization` 头（旧的 X-Emby-Authorization 被忽略，
    /// 缺 Client 会让服务端建会话时抛 ArgumentNullException 并返回 400）；
    /// 带 token 时并入同一头，登录时只发客户端信息。
    func authorizationHeader() -> String {
        var fields = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(appVersion)\"",
        ]
        if let token { fields.append("Token=\"\(token)\"") }
        return "MediaBrowser " + fields.joined(separator: ", ")
    }

    private func request(
        path: String,
        method: String = "GET",
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> Data {
        var req = URLRequest(url: try makeURL(path: path, query: query))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authorizationHeader(), forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw APIError.network(error)
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw APIError.server(statusCode: http.statusCode, message: String(msg.prefix(200)))
        }
        return data
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await request(path: path, query: query)
        return try decode(T.self, from: data)
    }

    func post<T: Decodable>(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> T {
        let data = try await request(path: path, method: "POST", query: query, body: body)
        return try decode(T.self, from: data)
    }

    func postEmpty(_ path: String, query: [URLQueryItem] = [], body: Data? = nil) async throws {
        _ = try await request(path: path, method: "POST", query: query, body: body)
    }

    func deleteEmpty(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await request(path: path, method: "DELETE", query: query)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Jellyfin 返回 PascalCase（Items/Name/Id…），Swift 模型是 camelCase。
        // 注意：convertFromSnakeCase 对无下划线的 key 原样返回，必须用自定义策略转首字母。
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { keys in
            let key = keys.last!.stringValue
            return AnyCodingKey(stringValue: Self.camelize(key))!
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    /// PascalCase / snake_case → camelCase（"Items"→"items"，"ParentId"→"parentId"）
    private static func camelize(_ key: String) -> String {
        let parts = key.split(separator: "_").map(String.init)
        guard let first = parts.first else { return key }
        var result = first.prefix(1).lowercased() + first.dropFirst()
        for part in parts.dropFirst() {
            result += part.prefix(1).uppercased() + part.dropFirst()
        }
        return result
    }

    // MARK: - 图片与播放地址

    enum ImageKind {
        case primary
        case backdrop(Int)
        case thumb
    }

    func imageURL(itemId: String, kind: ImageKind = .primary, width: Int = 400, tag: String? = nil) -> URL? {
        var path = "/Items/\(itemId)/Images/"
        switch kind {
        case .primary: path += "Primary"
        case .backdrop(let index): path += "Backdrop/\(index)"
        case .thumb: path += "Thumb"
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "maxWidth", value: "\(width)"),
            URLQueryItem(name: "quality", value: "90"),
        ]
        if let tag { query.append(URLQueryItem(name: "tag", value: tag)) }
        if let token { query.append(URLQueryItem(name: "api_key", value: token)) }
        return try? makeURL(path: path, query: query)
    }

    /// 海报图；单集没有海报时回退到所属剧集的海报
    func primaryImageURL(for item: BaseItemDto, width: Int = 400) -> URL? {
        if let tag = item.primaryImageTag { return imageURL(itemId: item.id, width: width, tag: tag) }
        if let seriesId = item.seriesId { return imageURL(itemId: seriesId, width: width) }
        return nil
    }

    func backdropURL(for item: BaseItemDto, width: Int = 1280) -> URL? {
        if let tag = item.backdropImageTag { return imageURL(itemId: item.id, kind: .backdrop(0), width: width, tag: tag) }
        if let pid = item.parentBackdropItemId, let tag = item.parentBackdropImageTags?.first {
            return imageURL(itemId: pid, kind: .backdrop(0), width: width, tag: tag)
        }
        return nil
    }

    func reset() {
        token = nil
        user = nil
        baseURL = nil
    }

    // MARK: - 收藏与歌词

    /// 标记/取消收藏（服务端UserData同步）
    func setFavorite(itemId: String, favorite: Bool) async throws {
        let userId = user?.id ?? ""
        if favorite {
            try await postEmpty("/Users/\(userId)/FavoriteItems/\(itemId)")
        } else {
            try await deleteEmpty("/Users/\(userId)/FavoriteItems/\(itemId)")
        }
    }

    /// 拉取歌词（Jellyfin 10.9+；无歌词时服务端返回 404 → 抛错）
    func fetchLyrics(itemId: String) async throws -> [LyricLine] {
        let response: LyricsResponse = try await get("/Audio/\(itemId)/Lyrics")
        return response.lyrics ?? []
    }
}

/// 自定义 CodingKey（配合 camelize 使用）
private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
