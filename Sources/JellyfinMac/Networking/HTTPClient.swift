import Foundation

/// HTTP 响应（含原始 Data，供后端自己解 envelope）
struct HTTPResponse {
    let data: Data
    let statusCode: Int
    let headers: [AnyHashable: Any]
}

/// 后端无关的 HTTP 传输层。
///
/// 只做四件事：拼 URL、注入凭据、发请求、把传输/状态码错误映射成 `MusicBackendError`。
/// **不**假设响应形状（Jellyfin 直接返回对象、飞牛包一层 `{code,msg,data}`），
/// 也不假设大小写策略（Jellyfin 是 PascalCase，飞牛是 camelCase/GUID 混排）。
final class HTTPClient {
    /// 服务基址（已规范化，无尾部斜杠）
    var baseURL: URL

    /// 逐请求注入凭据（Authorization 头 / Cookie）
    var prepare: ((inout URLRequest) -> Void)?

    /// JSON 解码策略（Jellyfin 用 .custom(camelize)，飞牛用默认）
    var keyDecodingStrategy: JSONDecoder.KeyDecodingStrategy = .useDefaultKeys

    /// 超时（秒）
    var timeout: TimeInterval = 30

    private let session: URLSession

    init(baseURL: URL, timeout: TimeInterval = 30) {
        self.baseURL = baseURL
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        // 每个客户端独立 cookie 存储：飞牛的会话就在 Cookie 里，
        // 不能与其它后端/URLSession 共享（否则切后端会串会话）
        config.httpCookieStorage = HTTPCookieStorage()
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL

    func url(path: String, query: [URLQueryItem] = []) throws -> URL {
        guard var comps = URLComponents(
            url: baseURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        ) else { throw MusicBackendError.invalidServer("无法拼接请求地址") }
        if !query.isEmpty { comps.queryItems = (comps.queryItems ?? []) + query }
        guard let url = comps.url else { throw MusicBackendError.invalidServer("无法拼接请求地址") }
        return url
    }

    // MARK: - 发送

    @discardableResult
    func send(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        accepts: Int? = nil,
        expectedStatusRange: Range<Int> = 200..<300
    ) async throws -> HTTPResponse {
        var request = URLRequest(url: try url(path: path, query: query))
        request.httpMethod = method
        request.timeoutInterval = timeout
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        prepare?(&request)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw MusicBackendError.network(error)
        } catch {
            throw MusicBackendError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw MusicBackendError.decoding
        }
        if accepts == nil, !expectedStatusRange.contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw MusicBackendError.unauthorized(String(message.prefix(200)))
            }
            throw MusicBackendError.server("HTTP \(http.statusCode) \(String(message.prefix(200)))")
        }
        return HTTPResponse(data: data, statusCode: http.statusCode, headers: http.allHeaderFields)
    }

    // MARK: - JSON

    /// 允许空响应体的解码（服务端 204/空 body 时返回 nil）
    func decodeOptional<T: Decodable>(_ type: T.Type, from response: HTTPResponse) throws -> T? {
        guard !response.data.isEmpty else { return nil }
        return try decode(type, from: response.data)
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = keyDecodingStrategy
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw MusicBackendError.decoding
        }
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let response = try await send(path: path, query: query)
        return try decode(T.self, from: response.data)
    }

    func post<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> T {
        let response = try await send(path: path, query: query, method: "POST", body: body)
        return try decode(T.self, from: response.data)
    }

    func postIgnoringResponse(
        _ path: String,
        query: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws {
        _ = try await send(path: path, query: query, method: "POST", body: body)
    }

    func deleteIgnoringResponse(_ path: String, query: [URLQueryItem] = []) async throws {
        _ = try await send(path: path, query: query, method: "DELETE")
    }

    // MARK: - 工具

    /// PascalCase / snake_case → camelCase（Jellyfin 的 `Items`→`items`、`ParentId`→`parentId`）。
    /// 注意：`convertFromSnakeCase` 对无下划线的 key 原样返回，所以这里自己转首字母。
    static func camelize(_ key: String) -> String {
        let parts = key.split(separator: "_").map(String.init)
        guard let first = parts.first else { return key }
        var result = first.prefix(1).lowercased() + first.dropFirst()
        for part in parts.dropFirst() {
            result += part.prefix(1).uppercased() + part.dropFirst()
        }
        return result
    }

    static let pascalToCamel: JSONDecoder.KeyDecodingStrategy = .custom { keys in
        let key = keys.last!.stringValue
        return CamelizedKey(stringValue: camelize(key))!
    }
}

/// 自定义 CodingKey（配合 camelize 使用）
struct CamelizedKey: CodingKey {
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
