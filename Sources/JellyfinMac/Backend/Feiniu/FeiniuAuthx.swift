import CryptoKit
import Foundation

// MARK: - 签名常量
//
// 证据：`docs/research/fnos-music-api.md` §2.1.1 / §2.1.2（协议档，下称「协议档」）
//      ＋ `/tmp/fnresearch/seasonyuu_FnMusic/api.md` §5.1–5.3（下称「api.md」）。
//
// ⚠️ 脆弱点：这两个常量来自**官方 Web 静态包的反向结果**，不是用户的凭据，
// 也**没有任何稳定性承诺**。fnOS 大版本升级时最可能先变的就是它们
// （协议档附录 A 把「静态签名常量」列为第 1 号维护风险）。
// 因此：
//   1. 常量只在这一个 enum 里出现，改动点唯一；
//   2. 后端提供 `authxEnabled` 开关 —— 协议档 §2.1 的判读是「当前固件不强制签名」
//      （Dart / C++ 两个实现完全不签也能读写），关掉签名即可绕开常量失效；
//   3. 打开签名时若出现 401/403，优先怀疑常量漂移而不是密码错误。
enum FeiniuAuthxConstants {
    /// 音乐 API 与 FN Connect 定位**共用**的前缀。
    static let prefix = "NDzZTVxnRKP8Z0jXg1VAMonaG8akvh"

    /// 音乐 API 专用 key（与 FN Connect 定位用的 key 不同，不能混用）。
    static let musicAPIKey = "6D5602D4-A342-4799-A0F0-BB795E7167D0"

    /// FN Connect 定位专用 key（本后端**不做** FN Connect，仅留档，见 §1.3）。
    static let fnConnectAPIKey = "zIGtkc3dqZnJpd29qZXJqa2w7c"

    /// 规范 API 路径前缀：签名只认 `/music/api/v1/...`，不含反代前缀（§2.1.4）。
    static let canonicalAPIPath = "/music/api/v1"
}

// MARK: - 摘要

/// MD5 / SHA-256（协议档 §2.1.2、§2.2）。
///
/// MD5 在这里是**协议兼容要求**，不是安全选型：服务端就是这么算的。
/// 纯函数，无状态、无时间/随机依赖 → 可直接单测。
enum FeiniuHash {
    static func md5Hex(_ data: Data) -> String {
        hex(Insecure.MD5.hash(data: data))
    }

    static func md5Hex(_ string: String) -> String {
        md5Hex(Data(string.utf8))
    }

    /// 登录密码摘要：`SHA256_UTF8(明文密码)` 的小写 hex（协议档 §2.2，四个客户端一致）。
    static func sha256Hex(_ string: String) -> String {
        hex(SHA256.hash(data: Data(string.utf8)))
    }

    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - authx 签名

/// 飞牛 `authx` 请求签名（协议档 §2.1.2–§2.1.4；api.md §5.1–5.3）。
///
/// 一句话：`authx: nonce={6位}&timestamp={毫秒}&sign={md5}`，其中
/// ```
/// sign = MD5( PREFIX _ path _ nonce _ timestamp _ dataHash _ MUSIC_API_KEY )
/// path = /music/api/v1/...        （含 /music，不含反代前缀）
/// dataHash: GET  = MD5( 按参数名排序后的 query 串 )
///           非GET = MD5( 实际发出的 body 字节；无 body 为 MD5("") )
/// ```
///
/// **本 enum 的所有方法都是纯函数**（nonce / timestamp 由调用方传入），
/// 随机数与时钟依赖集中在 `FeiniuRequestHeaders`，便于单测签名结果。
enum FeiniuAuthxSigner {

    // MARK: GET dataHash

    /// 把 query 规范化成参与签名（哈希）的字符串。
    ///
    /// 服务端（官方 Web）的步骤是：丢 `undefined`/`null` → 按名排序 →
    /// URLSearchParams 编码（空格→`+`）→ `+`→`%20` → 对整个串 `decodeURIComponent`
    /// → MD5。第 4–6 步「先编码再整体解码」的净效果就是**用原始值拼串**
    /// （编码→解码是恒等变换），所以这里直接拼原始 `name=value`。
    ///
    /// 例：`?size=50&page=1` → `page=1&size=50`（协议档 §2.1.3 的样例）。
    static func canonicalQuery(_ items: [URLQueryItem]) -> String {
        let kept = items.filter { item in
            // 值为 nil 等价于 Web 侧的 `undefined`：不参与查询串，也不参与签名。
            // （本后端从不在 query 里传 nil 值，这里只做防御。）
            guard let value = item.value else { return false }
            let lowered = value.lowercased()
            return lowered != "undefined" && lowered != "null"
        }
        // 稳定排序：同名参数保持原顺序（协议档只要求「按参数名排序」）。
        let sorted = kept.enumerated()
            .sorted { lhs, rhs in
                lhs.element.name == rhs.element.name
                    ? lhs.offset < rhs.offset
                    : lhs.element.name < rhs.element.name
            }
            .map(\.element)
        return sorted
            .map { "\($0.name)=\($0.value ?? "")" }
            .joined(separator: "&")
    }

    // MARK: 签名路径

    /// 取参与签名的 pathname。
    ///
    /// 反代前缀（`https://x.com/nas/music/api/v1/...`）**必须截掉**，服务端只认
    /// `/music/api/v1/...`；整串拿去签名会稳定 401（协议档 §2.1.4，[primuse]
    /// `authxPath(for:)` 同做法）。实现为「取最后一次出现的 `/music/api/v1`」。
    static func signingPath(for url: URL) -> String {
        let path = url.path
        if let range = path.range(of: FeiniuAuthxConstants.canonicalAPIPath, options: .backwards) {
            return String(path[range.lowerBound...])
        }
        // 兜底：路径里没有规范前缀（多半是基址规范化出错），原样签，便于从
        // 服务端 401 反推出真实路径。
        return path
    }

    /// 参与 MD5 的 payload（GET 是规范化 query，其它是 body 字节）。
    ///
    /// 注意：**签名用的 JSON 必须与实际发出的字节完全一致**（协议档 §2.1.3）。
    /// 这里直接用 `URLRequest.httpBody`，所以不存在「签了格式化 JSON 却发紧凑 JSON」的问题。
    static func dataPayload(method: String, url: URL, body: Data?) -> Data {
        guard method.uppercased() == "GET" else { return body ?? Data() }
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Data(canonicalQuery(queryItems).utf8)
    }

    // MARK: header

    /// 生成 `authx` 头的值（纯函数：nonce / timestamp 由调用方给）。
    static func authxHeader(
        method: String,
        url: URL,
        body: Data?,
        nonce: String,
        timestampMs: Int64
    ) -> String {
        let dataHash = FeiniuHash.md5Hex(dataPayload(method: method, url: url, body: body))
        let signingText = [
            FeiniuAuthxConstants.prefix,
            signingPath(for: url),
            nonce,
            String(timestampMs),
            dataHash,
            FeiniuAuthxConstants.musicAPIKey,
        ].joined(separator: "_")
        let sign = FeiniuHash.md5Hex(signingText)
        return "nonce=\(nonce)&timestamp=\(timestampMs)&sign=\(sign)"
    }

    /// 6 位数字 nonce（协议档 §2.1.2：100000–999999，每请求新取）。
    static func randomNonce() -> String {
        String(Int.random(in: 100_000...999_999))
    }

    /// 当前 Unix 毫秒。
    static func currentTimestampMs(now: Date = Date()) -> Int64 {
        Int64((now.timeIntervalSince1970 * 1000).rounded())
    }
}

// MARK: - 请求头

/// 一次请求需要携带的凭据（值类型，便于安全地拷进 `@Sendable` 闭包）。
struct FeiniuCredentials: Sendable, Equatable {
    /// 登录返回的 `music-token`（= `BackendSession.token`）
    var token: String?
    /// NAS 安全码（明码；发送时 base64 —— 协议档 §2.4）
    var accessCode: String?
    /// 额外 Cookie（FN Connect 中继的 `mode=relay`；本阶段恒为 nil）
    var extraCookie: String?
}

/// 请求头构造。
///
/// 与 `FeiniuAuthxSigner` 的分工：签名算法保持纯函数，随机数/时钟在这里注入。
/// 这一层同时被「HTTP 传输层」与「AVPlayer 媒体请求授权」复用，
/// 保证两条链路算出来的头完全一致。
enum FeiniuRequestHeaders {

    /// `Cookie: music-token=...`（协议档 §2.3）。
    ///
    /// TODO(C)：[primuse] 会先按 unreserved 集百分号编码 token、再把 `%20` 换回 `+`；
    /// [dart]/[ps5] 则直接原样塞。这里跟随 **dart/ps5（原样）** —— 它们是在真机上
    /// 跑通的实现，而编码规则只有单一来源、未经实测；若联调出现「登录成功但立刻
    /// 401」，第一个要试的就是改成百分号编码。
    static func cookieValue(_ credentials: FeiniuCredentials) -> String? {
        var parts: [String] = []
        if let token = credentials.token, !token.isEmpty {
            parts.append("music-token=\(token)")
        }
        if let extra = credentials.extraCookie?.trimmingCharacters(in: .whitespacesAndNewlines),
           !extra.isEmpty {
            parts.append(extra)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// 安全码头（协议档 §2.4 / [dart] `access_code_service.dart`）。
    ///
    /// NAS 开了「安全码」时，**所有**请求（含封面与音频流）都要带，缺了会一直 401/403
    /// 且看不出原因。`x-access-code` 的值是 `base64(安全码)`（UTF-8）。
    static func accessCodeHeaders(_ credentials: FeiniuCredentials) -> [String: String] {
        guard let code = credentials.accessCode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !code.isEmpty else { return [:] }
        return [
            "x-access-code": Data(code.utf8).base64EncodedString(),
            "x-access-source": "app",
        ]
    }

    /// 构造发往 `url` 的全部凭据头（Cookie + 安全码 + authx）。
    ///
    /// - Parameter authxEnabled: 关闭时只发 Cookie（协议档 §2.1 的两套实现都能用）。
    static func make(
        method: String,
        url: URL,
        body: Data?,
        credentials: FeiniuCredentials,
        authxEnabled: Bool
    ) -> [String: String] {
        var headers = accessCodeHeaders(credentials)
        if let cookie = cookieValue(credentials) {
            headers["Cookie"] = cookie
        }
        if authxEnabled {
            headers["authx"] = FeiniuAuthxSigner.authxHeader(
                method: method,
                url: url,
                body: body,
                nonce: FeiniuAuthxSigner.randomNonce(),
                timestampMs: FeiniuAuthxSigner.currentTimestampMs()
            )
        }
        return headers
    }
}
