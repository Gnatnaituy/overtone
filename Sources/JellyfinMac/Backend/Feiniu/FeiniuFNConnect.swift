import Foundation

// MARK: - FN Connect 定位（FN ID → 真实基址）
//
// 为什么需要它：`https://fnos.net/{fnId}/music/` **只是引导页，不代理音乐 API**
// （直接请求 `/music/api/v1/...` 会拿回一张 HTML）。真正可用的基址必须先「定位」：
//
//   POST https://5ddd.com/api/v1/fn/con      （只带 authx）
//   POST https://fnos.net/api/v1/fn/con      （authx + fn-sign）
//   body {"fnId":"..."}
//     → data: 内网/公网/DDNS/relay 候选 + 端口
//     → 逐个探测 `{candidate}/api/v1/sys/config`（relay 需带 `Cookie: mode=relay`）
//     → 拿到能返回 JSON 的基址
//
// 实测（2026-10-29，FN ID `ravooo`，macOS 本机）：
// - 两个定位主机都 200，返回同一份候选；
// - relay `ravooo.fnos.net:443` 首个请求 302 + `Set-Cookie: mode=relay`；
// - **带 `Cookie: mode=relay` 直接请求 `/music/api/v1/sys/config` 即返回真 JSON**
//   （不带则 302 HTML）→ 与 [primuse] 的做法一致，不需要先握手拿 cookie。
//
// 证据等级：定位/签名 V（协议档 §1.3，本机实测复核）；候选探测顺序 S（[primuse]/[dart]）；
// relay 握手兼容性 C（若某些固件强制握手，见 `FeiniuFNConnectError.relayNeedsHandshake`）。

// MARK: - 常量

enum FeiniuFNConnectConstants {
    /// 与音乐 API **共用**的前缀（协议档 §4.3 明确复用 AUTHX_PREFIX）
    static let authxPrefix = FeiniuAuthxConstants.prefix

    /// 定位专用 key。⚠️ 与音乐 API 的 `6D5602D4-…` **不是同一个**，混用会稳定 401。
    static let connectAPIKey = "zIGtkc3dqZnJpd29qZXJqa2w7c"

    /// 定位接口的签名路径（**不含** `/music` 前缀）
    static let lookupPath = "/api/v1/fn/con"

    /// 两个定位主机：`5ddd.com` 是老域名（只验 authx），`fnos.net` 是新品牌域名（还要 fn-sign）。
    /// 先试前者（少一个头，失败面更小），失败再试后者。
    static let lookupHosts = ["5ddd.com", "fnos.net"]

    /// 允许当作 relay 的域名后缀（防止把定位结果当任意 URL 用）
    static let allowedRelaySuffixes = [".fnos.net", ".5ddd.com"]

    /// 默认端口（定位响应缺 `port` 时用；协议档 §1.3.1）
    static let defaultHTTPPort = 5666
    static let defaultHTTPSPort = 5667

    /// 中继恒定走 443（协议档 §1.4）
    static let relayPort = 443

    /// relay 路由 Cookie（值就是 `mode=relay`，Path=/，HttpOnly）
    static let relayCookie = "mode=relay"
}

// MARK: - 错误

enum FeiniuFNConnectError: LocalizedError {
    case invalidFNID
    case notFound(fnId: String)
    case serviceUnavailable
    case badResponse(String)
    case noReachableCandidate(tried: [String])
    case relayNeedsHandshake
    case network(Error)

    var errorDescription: String? {
        switch self {
        case .invalidFNID:
            return "FN ID 格式不正确（只允许字母、数字、下划线、连字符）"
        case .notFound(let fnId):
            return "找不到 FN ID「\(fnId)」，请在飞牛 App 的 FN Connect 页面确认"
        case .serviceUnavailable:
            return "FN Connect 定位服务暂时不可用，请稍后再试或直接填 NAS 地址"
        case .badResponse(let detail):
            return "FN Connect 返回了无法识别的数据：\(detail)"
        case .noReachableCandidate(let tried):
            return "FN ID 解析成功，但所有候选地址都连不上（尝试过：\(tried.joined(separator: "、"))）。可直接填 NAS 内网地址试试"
        case .relayNeedsHandshake:
            return "该 FN Connect 中继要求先握手，当前版本未支持，请直接填 NAS 地址"
        case .network(let error):
            return "无法连接 FN Connect 服务：\(error.localizedDescription)"
        }
    }
}

// MARK: - 定位结果

/// `/api/v1/fn/con` 的 `data` 段（字段名照抄服务端，包括厂商拼写错误 `forbbidPublicIpv6`）
struct FnConnectEndpoints: Equatable {
    var fnId: String
    var lanIPv4: [String] = []
    var lanIPv6: [String] = []
    var publicIPv4: [String] = []
    var publicIPv6: [String] = []
    var ddns: [String] = []
    /// relay 候选，形如 `ravooo.fnos.net:443`
    var relay: [String] = []
    var httpPort: Int = FeiniuFNConnectConstants.defaultHTTPPort
    var httpsPort: Int = FeiniuFNConnectConstants.defaultHTTPSPort
    var serverVersion: String = ""
    var forbidsPublicIPv6 = false
}

/// 一个可探测的候选基址（已含 `/music` 路径）
struct FnCandidate: Equatable {
    let baseURL: URL
    let usesRelay: Bool
    /// 诊断用标签（登录失败时告诉用户试过什么）
    let label: String
    let timeout: TimeInterval
}

/// 解析成功的最终结果
struct FnConnectResolution {
    let baseURL: URL
    let relayCookie: String?
    let endpoints: FnConnectEndpoints
    let via: String
}

// MARK: - 解析器

enum FeiniuFNConnect {

    // MARK: 识别

    /// 输入是否像 FN ID：没有 scheme、没有点、没有斜杠、非空、长度合理。
    ///
    /// `ravooo` → true；`192.168.1.10` / `nas.local` / `http://x` / `ravooo.fnos.net` → false（按地址处理）。
    static func isFNID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64 else { return false }
        guard !value.contains("://"), !value.contains("/"), !value.contains("."), !value.contains(":") else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// 从 `https://fnos.net/{fnId}/music` 之类的引导地址里取出 FN ID
    static func fnID(fromRelayURL raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.contains("://") ? value : "https://" + value),
              let host = url.host?.lowercased() else { return nil }
        let isRelayHost = host == "fnos.net" || host == "5ddd.com"
            || FeiniuFNConnectConstants.allowedRelaySuffixes.contains { host.hasSuffix($0) }
        guard isRelayHost || host == "fnos.net" || host == "5ddd.com" else { return nil }
        // 路径首段即 FN ID（`/ravooo/music`）
        let segments = url.path.split(separator: "/").map(String.init)
        guard let first = segments.first, isFNID(first) else { return nil }
        return first
    }

    // MARK: 签名（纯函数）

    /// 定位请求体（紧凑 JSON，签名与实际发送的字节必须一致）
    static func lookupBody(fnId: String) -> Data {
        Data(#"{"fnId":"\#(fnId)"}"#.utf8)
    }

    static func authxHeader(fnId: String, nonce: String, timestampMs: Int64) -> String {
        let bodyHash = FeiniuHash.md5Hex(lookupBody(fnId: fnId))
        let signingText = [
            FeiniuFNConnectConstants.authxPrefix,
            FeiniuFNConnectConstants.lookupPath,
            nonce,
            String(timestampMs),
            bodyHash,
            FeiniuFNConnectConstants.connectAPIKey,
        ].joined(separator: "_")
        let sign = FeiniuHash.md5Hex(signingText)
        return "nonce=\(nonce)&timestamp=\(timestampMs)&sign=\(sign)"
    }

    /// `fn-sign: SHA256("trim_connect`{fnId}`{timestamp}`anna")`，与 authx 用**同一个**时间戳
    static func fnSign(fnId: String, timestampMs: Int64) -> String {
        FeiniuHash.sha256Hex("trim_connect`\(fnId)`\(timestampMs)`anna")
    }

    // MARK: 候选地址（纯函数）

    /// 候选顺序（[primuse]/[dart] 一致，内网 http 优先以绕开自签证书）：
    /// 内网 v4/v6 (http) → 内网 (https) → 公网 v6 (https) → 公网 v4 (https) → ddns → relay
    static func candidates(from endpoints: FnConnectEndpoints) -> [FnCandidate] {
        var result: [FnCandidate] = []

        func append(_ urlString: String, relay: Bool, label: String, timeout: TimeInterval) {
            guard let url = URL(string: urlString) else { return }
            result.append(FnCandidate(baseURL: url, usesRelay: relay, label: label, timeout: timeout))
        }

        // 1. 内网（http 优先：内网多是自签证书，明文 http 直接绕开）
        for ip in endpoints.lanIPv4 where !ip.isEmpty {
            // 内网探测 3s：实测 LAN 通常 10–20ms，但冷连接（ARP/DNS/唤醒后首包）
            // 偶尔要 1s+；超时太短会误判不可达、白白降级到中继。
            append("http://\(ip):\(endpoints.httpPort)/music", relay: false, label: "内网 IPv4", timeout: 3)
        }
        for ip in endpoints.lanIPv6 where !ip.isEmpty {
            append("http://[\(ip)]:\(endpoints.httpPort)/music", relay: false, label: "内网 IPv6", timeout: 3)
        }
        for ip in endpoints.lanIPv4 where !ip.isEmpty {
            append("https://\(ip):\(endpoints.httpsPort)/music", relay: false, label: "内网 https", timeout: 3)
        }

        // 2. 公网（一律 https）
        if !endpoints.forbidsPublicIPv6 {
            for ip in endpoints.publicIPv6 where !ip.isEmpty {
                append("https://[\(ip)]:\(endpoints.httpsPort)/music", relay: false, label: "公网 IPv6", timeout: 5)
            }
        }
        for ip in endpoints.publicIPv4 where !ip.isEmpty {
            append("https://\(ip):\(endpoints.httpsPort)/music", relay: false, label: "公网 IPv4", timeout: 5)
        }

        // 3. DDNS（可能自带端口）
        for entry in endpoints.ddns where !entry.isEmpty {
            let hostPart = entry.contains(":") ? entry : "\(entry):\(endpoints.httpsPort)"
            append("https://\(hostPart)/music", relay: false, label: "DDNS", timeout: 5)
        }

        // 4. relay（恒 443；只接受白名单后缀 —— 定位结果不可信，防止被当任意 URL 请求）
        for entry in endpoints.relay where !entry.isEmpty {
            let host = entry.split(separator: ":").first.map(String.init) ?? entry
            let lowered = host.lowercased()
            guard FeiniuFNConnectConstants.allowedRelaySuffixes.contains(where: { lowered.hasSuffix($0) }) else {
                continue
            }
            append("https://\(host)/music", relay: true, label: "FN Connect 中继", timeout: 10)
        }

        return result
    }

    // MARK: 定位请求

    /// 依次尝试两个定位主机；`5ddd.com` 只要 authx，`fnos.net` 另需 fn-sign。
    static func lookup(fnId: String, session: URLSession) async throws -> FnConnectEndpoints {
        guard isFNID(fnId) else { throw FeiniuFNConnectError.invalidFNID }
        var lastError: Error?

        for host in FeiniuFNConnectConstants.lookupHosts {
            do {
                return try await lookup(fnId: fnId, host: host, session: session)
            } catch let error as FeiniuFNConnectError {
                // FN ID 不存在是终局错误：换主机也没有
                if case .notFound = error { throw error }
                lastError = error
            } catch {
                lastError = error
            }
        }
        throw lastError ?? FeiniuFNConnectError.serviceUnavailable
    }

    private static func lookup(fnId: String, host: String, session: URLSession) async throws -> FnConnectEndpoints {
        guard let url = URL(string: "https://\(host)\(FeiniuFNConnectConstants.lookupPath)") else {
            throw FeiniuFNConnectError.badResponse("定位地址非法")
        }
        // 两个时间戳读取在同一毫秒内（协议档 §4.3 的注意点）：只读一次时钟。
        let timestamp = FeiniuAuthxSigner.currentTimestampMs()
        let nonce = FeiniuAuthxSigner.randomNonce()

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(
            authxHeader(fnId: fnId, nonce: nonce, timestampMs: timestamp),
            forHTTPHeaderField: "authx"
        )
        // `fnos.net` 路线还需要 fn-sign；多带一个头对 `5ddd.com` 无副作用（实测忽略）。
        request.setValue(fnSign(fnId: fnId, timestampMs: timestamp), forHTTPHeaderField: "fn-sign")
        request.httpBody = lookupBody(fnId: fnId)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw FeiniuFNConnectError.network(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw FeiniuFNConnectError.badResponse("非 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw FeiniuFNConnectError.badResponse("HTTP \(http.statusCode)")
        }
        return try decodeLookup(data, fnId: fnId)
    }

    /// 解 envelope `{msg,code,data}`；`data` 结构照抄服务端。
    static func decodeLookup(_ data: Data, fnId: String) throws -> FnConnectEndpoints {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FeiniuFNConnectError.badResponse("不是 JSON")
        }
        let code = (root["code"] as? Int) ?? -1
        switch code {
        case 0:
            break
        case 404, 1001, 1004, 3000006, 3000037:
            throw FeiniuFNConnectError.notFound(fnId: fnId)
        case 3000009:
            throw FeiniuFNConnectError.serviceUnavailable
        default:
            let message = (root["msg"] as? String) ?? ""
            throw FeiniuFNConnectError.badResponse("code=\(code) \(message)")
        }

        guard let payload = root["data"] as? [String: Any] else {
            throw FeiniuFNConnectError.badResponse("缺少 data")
        }
        func strings(_ key: String) -> [String] {
            (payload[key] as? [Any])?.compactMap { $0 as? String } ?? []
        }
        let port = payload["port"] as? [String: Any]
        var endpoints = FnConnectEndpoints(fnId: fnId)
        endpoints.lanIPv4 = strings("ipv4")
        endpoints.lanIPv6 = strings("ipv6")
        endpoints.publicIPv4 = strings("publicIpv4")
        endpoints.publicIPv6 = strings("publicIpv6")
        endpoints.ddns = strings("ddns")
        endpoints.relay = strings("fn")
        endpoints.httpPort = (port?["httpPort"] as? Int) ?? FeiniuFNConnectConstants.defaultHTTPPort
        endpoints.httpsPort = (port?["httpsPort"] as? Int) ?? FeiniuFNConnectConstants.defaultHTTPSPort
        endpoints.serverVersion = (payload["ver"] as? String) ?? ""
        // 厂商拼写错误（`forbbid`）照抄服务端字段
        endpoints.forbidsPublicIPv6 = (payload["forbbidPublicIpv6"] as? Bool) ?? false
        return endpoints
    }

    // MARK: 探测

    /// 探测一个候选：请求 `{base}/api/v1/sys/config`，返回 200 + JSON（且带 `code`）才算通。
    ///
    /// 为什么用 `sys/config`：它**不要求会话**（协议档 §2.6 标 V），可以只验证「网络与 relay
    /// 是否通」；同时它返回 JSON —— relay 掉线时服务端会回 HTML，正好能识别出来。
    static func probe(_ candidate: FnCandidate, session: URLSession) async -> Bool {
        guard var comps = URLComponents(
            url: candidate.baseURL.appendingPathComponent("api/v1/sys/config"),
            resolvingAgainstBaseURL: false
        ) else { return false }
        comps.query = nil
        guard let url = comps.url else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = candidate.timeout
        if candidate.usesRelay {
            // 实测（2026-10-29）：直接带这个 Cookie 即可访问中继后的音乐 API，无需先握手。
            request.setValue(FeiniuFNConnectConstants.relayCookie, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, response) = try await withTimeout(candidate.timeout) {
                try await session.data(for: request)
            }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return false
            }
            return object["code"] != nil
        } catch {
            return false
        }
    }

    /// 把候选**按优先级分批**并发探测：先内网（2s），再公网（5s），最后 relay（10s）。
    ///
    /// 不一次性并发全部的原因：远端场景下内网候选必然超时，一次性发出去只会白等最长的那个。
    static func resolveReachable(
        from candidates: [FnCandidate],
        session: URLSession
    ) async throws -> FnCandidate {
        let groups: [[FnCandidate]] = [
            candidates.filter { $0.label.hasPrefix("内网") },
            candidates.filter { !$0.label.hasPrefix("内网") && !$0.usesRelay },
            candidates.filter { $0.usesRelay },
        ]
        for group in groups where !group.isEmpty {
            if let hit = await firstReachable(in: group, session: session) {
                return hit
            }
        }
        throw FeiniuFNConnectError.noReachableCandidate(tried: candidates.map(\.label))
    }

    private static func firstReachable(
        in group: [FnCandidate],
        session: URLSession
    ) async -> FnCandidate? {
        await withTaskGroup(of: (Int, Bool).self) { taskGroup in
            for (index, candidate) in group.enumerated() {
                taskGroup.addTask {
                    (index, await probe(candidate, session: session))
                }
            }
            var winners: [Int] = []
            for await (index, ok) in taskGroup where ok {
                winners.append(index)
            }
            guard let best = winners.min() else { return nil }
            return group[best]
        }
    }

    // MARK: 顶层入口

    /// FN ID → 可用基址 + relay Cookie
    static func resolve(fnId: String, session: URLSession? = nil) async throws -> FnConnectResolution {
        let session = session ?? makeSession()
        let endpoints = try await lookup(fnId: fnId, session: session)
        let candidates = candidates(from: endpoints)
        guard !candidates.isEmpty else {
            throw FeiniuFNConnectError.badResponse("定位结果里没有可用候选地址")
        }
        let reachable = try await resolveReachable(from: candidates, session: session)
        return FnConnectResolution(
            baseURL: reachable.baseURL,
            relayCookie: reachable.usesRelay ? FeiniuFNConnectConstants.relayCookie : nil,
            endpoints: endpoints,
            via: reachable.label
        )
    }

    /// 解析器专用会话：不复用后端会话的 Cookie 存储（避免 music-token 与 mode=relay 互相干扰）
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        // 内网候选多为自签证书：默认信任策略会直接失败。
        // 这里只放行「私网地址 + 裸 IP / .local 域名」，公网与 relay 仍走系统校验。
        return URLSession(configuration: configuration, delegate: SelfSignedHostDelegate(), delegateQueue: nil)
    }

    // MARK: 超时包装

    /// `URLSession` 自身的超时对「连上但不响应」不一定生效，这里再加一层。
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0.1) * 1_000_000_000))
                throw FeiniuFNConnectError.badResponse("探测超时")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw FeiniuFNConnectError.badResponse("探测无结果")
            }
            return result
        }
    }
}

// MARK: - 自签证书放行（仅私网）

/// 只对**私网地址**（RFC1918 / IPv6 ULA / `.local`）放行自签证书。
///
/// 家用 NAS 的 https 几乎都是自签；但把"信任所有证书"做成全局策略会顺带削弱 relay 的
/// TLS（中继是公网域名，必须走系统校验）。所以这里按主机名判断，公网主机一律交回系统。
final class SelfSignedHostDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.isPrivateHost(challenge.protectionSpace.host)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    /// 私网判定：10/8、172.16/12、192.168/16、127/8、169.254/16、IPv6 ULA/link-local、`.local`
    static func isPrivateHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") || value.hasSuffix(".lan") { return true }
        if value.contains(":") {
            // IPv6：fc00::/7 (ULA) 与 fe80::/10 (link-local)
            return value.hasPrefix("fc") || value.hasPrefix("fd") || value.hasPrefix("fe8")
                || value.hasPrefix("fe9") || value.hasPrefix("fea") || value.hasPrefix("feb")
                || value == "::1"
        }
        let parts = value.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 || parts[0] == 127 { return true }
        if parts[0] == 192 && parts[1] == 168 { return true }
        if parts[0] == 172 && (16...31).contains(parts[1]) { return true }
        if parts[0] == 169 && parts[1] == 254 { return true }
        return false
    }
}
