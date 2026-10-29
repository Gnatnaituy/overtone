import Foundation

// MARK: - 服务器地址规范化
//
// 证据：协议档 §1.1（两种入口）、§1.2（基址规范化表）、§1.4（默认端口）、
//      §2.1.4（反代前缀只影响签名路径）；[primuse] `endpointURL` 的判定顺序。
//
// 飞牛音乐有两种可达方式，本文件都支持：
//   A. 自定义域名 / 局域网直连 → `https://{host}/music/api/v1/...`（`normalize`）
//   B. FN Connect（`fnos.net/{fnId}/music` 或只填 FN ID）→ 引导页**不代理**音乐 API，
//      必须「定位 → 选路 → relay 激活」才能拿到真基址（`resolve` + `FeiniuFNConnect`，
//      协议档 §1.3）。
enum FeiniuAddress {

    /// 规范化结果：`scheme://host[:port]/[反代前缀/]music`（**不带**尾斜杠、
    /// **不含** `/api/v1`）。
    ///
    /// 为什么基址停在 `/music` 而不是 `/music/api/v1`：
    /// `HTTPClient` 的 `path` 参数统一写 `/api/v1/xxx`，把 `/music` 留在基址上，
    /// 拼接与签名路径（`FeiniuAuthxSigner.signingPath`）都只需一处约定。
    ///
    /// 接受的输入（协议档 §1.2 表）：
    /// ```
    /// nas.example.com              → https://nas.example.com/music   （端口启发式，见下）
    /// host:5666                    → http://host:5666/music
    /// http://192.168.1.10:5666     → http://192.168.1.10:5666/music
    /// https://nas.example.com/music/          → https://nas.example.com/music
    /// https://nas.example.com/music/api/v1    → https://nas.example.com/music
    /// https://x.com/nas/music/                → https://x.com/nas/music   （反代前缀保留）
    /// ```
    static func normalize(_ raw: String) throws -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MusicBackendError.invalidServer("请填写 NAS 地址") }

        // 裸 `host:5666` 会被 URL 解析成 scheme=host，所以先补 scheme 再解析。
        if !text.contains("://") {
            text = defaultScheme(for: text) + "://" + text
        }

        guard var components = URLComponents(string: text),
              let host = components.host?.trimmingCharacters(in: .whitespaces),
              !host.isEmpty
        else {
            throw MusicBackendError.invalidServer("无法解析服务器地址")
        }

        // FN Connect 引导地址不能当 API 基址（协议档 §1.1 的关键事实）。
        if isRelayHost(host) {
            throw MusicBackendError.invalidServer(
                "这是 FN Connect 引导地址，不能直接当音乐服务地址；请改填 FN ID（如 ravooo）或 NAS 地址"
            )
        }

        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw MusicBackendError.invalidServer("只支持 http 或 https 地址")
        }

        // 路径收敛：只保留到 `music` 这一段（含反代前缀），后面的 `api/v1/...` 丢掉；
        // 没有 `music` 段则补上。这样 `/music/`、`/music/api/v1`、空路径三种输入
        // 得到同一个基址。
        var segments = components.path.split(separator: "/").map(String.init)
        if let musicIndex = segments.lastIndex(where: { $0 == "music" }) {
            segments = Array(segments.prefix(through: musicIndex))
        } else {
            segments.append("music")
        }
        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw MusicBackendError.invalidServer("无法解析服务器地址")
        }
        return url
    }

    /// 解析后的连接目标（直连地址与 FN Connect 的统一结果）
    struct Target: Equatable {
        /// 音乐服务基址（已含 `/music`）
        let baseURL: URL
        /// FN Connect 中继时需要的 `mode=relay` Cookie；直连为 nil
        let relayCookie: String?
        /// 通过 FN Connect 解析时的 FN ID（直连为 nil）；会话会存下来，
        /// 中继地址变化/失效时据此重新定位
        let fnID: String?
        /// 诊断用：`局域网直连` / `FN Connect 中继` 等
        let via: String
    }

    /// 统一入口：FN ID / FN Connect 引导地址 / 普通地址都能吃。
    ///
    /// - 纯 FN ID（如 `ravooo`）→ FN Connect 定位 + 探测
    /// - `https://fnos.net/{fnId}/music` → 取出 FN ID 后同上（引导地址不能当基址）
    /// - 其余 → 直接规范化（`normalize`）
    static func resolve(_ raw: String) async throws -> Target {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MusicBackendError.invalidServer("请填写 NAS 地址或 FN ID") }

        if FeiniuFNConnect.isFNID(trimmed) {
            let resolution = try await FeiniuFNConnect.resolve(fnId: trimmed)
            return Target(
                baseURL: resolution.baseURL,
                relayCookie: resolution.relayCookie,
                fnID: trimmed,
                via: resolution.via
            )
        }
        if let fnID = FeiniuFNConnect.fnID(fromRelayURL: trimmed) {
            let resolution = try await FeiniuFNConnect.resolve(fnId: fnID)
            return Target(
                baseURL: resolution.baseURL,
                relayCookie: resolution.relayCookie,
                fnID: fnID,
                via: resolution.via
            )
        }
        return Target(baseURL: try normalize(trimmed), relayCookie: nil, fnID: nil, via: "直连地址")
    }

    /// 反代前缀之外的部分（调试/日志用）。
    ///
    /// TODO(C)：FN Connect 本阶段不做。FN ID 形如 `https://fnos.net/{fnId}/music`，
    /// 完整流程（定位 → 候选探测 → relay 激活 → `Cookie: mode=relay`）见协议档 §1.3；
    /// 实现时这里应返回中继基址，并在 `BackendSession.extraCookie` 写入 `mode=relay`。
    static func isRelayHost(_ host: String) -> Bool {
        let lowered = host.lowercased()
        return lowered == "fnos.net"
            || lowered == "5ddd.com"
            || lowered.hasSuffix(".fnos.net")
            || lowered.hasSuffix(".5ddd.com")
    }

    /// 没有显式 scheme 时猜一个。
    ///
    /// 依据协议档 §1.4：fNOS 默认 `http=5666` / `https=5667`；443 基本只会是
    /// https 反代。其余按 **http**（内网 NAS 直连是最常见场景，且协议档 §7.6(c)
    /// 建议第一版只支持「http 内网 + 可信 https」——自签 https 还要额外的信任策略）。
    ///
    /// TODO(C)：`nas.local` 这类内网域名如果只开了 https，会被猜成 http 而失败；
    /// 失败信息里已经提示用户显式写 `https://`，暂不做失败重试探测。
    static func defaultScheme(for text: String) -> String {
        let lowered = text.lowercased()
        if let port = explicitPort(in: lowered), port == 443 || port == 5667 {
            return "https"
        }
        // host 里带 fnos.net/5ddd.com 的一律先按 https 解析，随后必然被 isRelayHost 拦掉。
        if lowered.hasPrefix("fnos.net/") || lowered.hasPrefix("5ddd.com/")
            || lowered.contains(".fnos.net/") || lowered.contains(".5ddd.com/") {
            return "https"
        }
        return "http"
    }

    /// 从 `host:port/...` 里取端口（没有则 nil）。
    static func explicitPort(in text: String) -> Int? {
        let hostPart = text.split(separator: "/").first.map(String.init) ?? text
        let pieces = hostPart.split(separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        return Int(pieces[1])
    }
}
