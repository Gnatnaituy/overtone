import AVFoundation
import Foundation

/// AVPlayer 的媒体资源加载器：给**每一个**媒体请求重新计算凭据头。
///
/// 为什么必须有它：飞牛音乐的 `authx` 是逐请求签名（path + nonce + timestamp 参与摘要），
/// 而 AVPlayer 对一首长曲会自己发起多个请求（起播探测、Range 读取、seek、转码 HLS 的分片），
/// 每次都要带「当时」的签名。把签名塞进 URL 或只在起播时带一次请求头都不成立。
///
/// 装配方式（`makeAssetAndLoader`）：
/// - **无 authorization**：`AVURLAsset(url:)`；
/// - **固定头**（`authorization.isDynamic == false`）：头一次性塞进 `AVURLAssetHTTPHeaderFieldsKey`；
/// - **动态头**（`isDynamic == true`）：URL 的 scheme 换成 `<scheme>-authz`（如 `https-authz`），
///   AVFoundation 不认识这个 scheme → 把请求交给本类的 delegate，由 delegate 用 `URLSession`
///   打真实 URL，并按 `authorization.headers(url)` 现算请求头。
///
/// 线程模型：
/// - 所有状态（在途请求表）与网络回调都收敛到一条串行 `workQueue`，**不碰任何 @MainActor 状态**；
/// - `RequestAuthorization.headers` 本身就是 `@Sendable`，可以在后台队列安全调用。
///
/// 生命周期（对应 `AVAssetResourceLoaderDelegate` 的约定）：
/// - `shouldWaitForLoadingOfRequestedResource` 返回 `true` 后必须**持有** loading request 并在
///   未来某刻调用一次 `finishLoading()` / `finishLoading(with:)` —— 本类用 `pending` 表持有；
/// - 同一个 delegate 会收到**多个并发** loading request（长曲 + seek），每个各自一条 `URLSessionDataTask`；
/// - `didCancel` 时 cancel 对应 task 并摘表（不再调用 finish —— AVFoundation 已取消该请求）。
final class MediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate {

    // MARK: - 常量

    /// 动态签名场景的自定义 scheme 后缀：`https` → `https-authz`，`http` → `http-authz`。
    ///
    /// 保留真实 scheme 前缀的好处：AVFoundation 的日志/遥测里还能看出原始协议，
    /// 排查「到底是被 loader 拦了还是走了系统网络栈」时一眼能认出来。
    static let dynamicSchemeSuffix = "-authz"

    /// `AVURLAssetHTTPHeaderFieldsKey` 没有导出到 Swift（SDK 里只有 C 符号），只能用字符串字面量。
    /// 这是固定头场景唯一可行的入口（Apple 未公开但在 AVFoundation 里稳定存在多年）。
    private static let headerFieldsKey = "AVURLAssetHTTPHeaderFieldsKey"

    /// 首个字节 / 空闲超时
    private static let requestTimeout: TimeInterval = 30
    /// 单请求总时长上限：`requestsAllDataToEndOfResource`（整首长曲）可能持续很久
    private static let resourceTimeout: TimeInterval = 3600

    private static let errorDomain = "com.overtone.MediaResourceLoader"

    // MARK: - 装配入口

    /// 同时给出 asset 与「动态签名场景下必须被播放器强引用持有」的 loader。
    ///
    /// 返回的 loader 在无 authorization / 固定头场景是 `nil`（不需要逐请求签名）；
    /// 播放器把它存到自己的属性里即可（换曲时替换，旧的自然释放）。
    ///
    /// 注意：本方法**不做任何网络请求**，只建 asset；真正的流量发生在 AVPlayer 开始加载后。
    static func makeAssetAndLoader(for source: PlayableSource) -> (AVURLAsset, MediaResourceLoader?) {
        guard let authorization = source.authorization, isHTTPURL(source.url) else {
            return (AVURLAsset(url: source.url), nil)
        }

        guard authorization.isDynamic else {
            let headers = authorization.headers(source.url)
            guard !headers.isEmpty else {
                return (AVURLAsset(url: source.url), nil)
            }
            let options: [String: Any] = [headerFieldsKey: headers]
            return (AVURLAsset(url: source.url, options: options), nil)
        }

        guard let playbackURL = customSchemeURL(for: source.url) else {
            return (AVURLAsset(url: source.url), nil)
        }
        let loader = MediaResourceLoader(authorization: authorization)
        let asset = RetainingURLAsset(url: playbackURL, resourceLoader: loader)
        asset.resourceLoader.setDelegate(loader, queue: loader.workQueue)
        return (asset, loader)
    }

    /// 便捷包装：仅用于「无 authorization / 固定头」场景（看 `makeAssetAndLoader` 的返回值即可）。
    ///
    /// 动态签名场景请用 `makeAssetAndLoader` 并把 loader 强引用住。这里返回的 asset 其实也能工作
    /// （`RetainingURLAsset` 内部强持 loader），保留这个包装只是让调用点简洁；**不要**依赖它的
    /// 兜底语义 —— AVAssetResourceLoader 的 delegate 是 weak，靠 asset 兜底属于防御性设计。
    static func makeAsset(for source: PlayableSource) -> AVURLAsset {
        makeAssetAndLoader(for: source).0
    }

    /// 把 https/http URL 换成自定义 scheme 版本（非 http(s) 返回 nil）。
    ///
    /// 刻意只替换 scheme 前缀、其余部分逐字节保留：走 `URLComponents` 往返虽然更"规范"，
    /// 但它可能对 query 的百分号编码做归一化 —— 签名 URL（authx）改一个字节就验签失败。
    static func customSchemeURL(for url: URL) -> URL? {
        let string = url.absoluteString
        guard let colon = string.firstIndex(of: ":"), colon != string.startIndex else { return nil }
        let scheme = string[string.startIndex..<colon].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return URL(string: scheme + dynamicSchemeSuffix + string[colon...])
    }

    /// 换回真实 scheme（不是本 loader 的 URL 返回 nil）
    private static func realURL(from url: URL) -> URL? {
        let string = url.absoluteString
        guard let colon = string.firstIndex(of: ":"), colon != string.startIndex else { return nil }
        let scheme = string[string.startIndex..<colon].lowercased()
        guard scheme.hasSuffix(dynamicSchemeSuffix) else { return nil }
        let realScheme = String(scheme.dropLast(dynamicSchemeSuffix.count))
        return URL(string: realScheme + string[colon...])
    }

    private static func isHTTPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    // MARK: - 状态

    private let authorization: RequestAuthorization
    /// 是否改写 HLS 播放列表里的 URI（让分片 / 子播放列表 / key 也回到本 loader 逐请求签名）。
    ///
    /// 默认开：飞牛转码 HLS 的分片需要 authx。排查兼容性问题时可关掉
    /// （届时只有 m3u8 本身被签名，分片按播放列表里的原 URL 直连）。
    private let rewritesHLSPlaylists: Bool

    /// 串行队列：在途请求表、URLSession 回调、delegate 回调都在这上面，无需加锁
    private let workQueue: DispatchQueue
    /// 一个 loader 一个 session（复用连接；不落 cookie —— 凭据全部由 headers 逐请求给）
    private let session: URLSession
    /// session 的 delegate 代理：session 强引用 delegate，而 delegate 只 **weak** 回指本对象，
    /// 这样 loader 释放时不会有「session → delegate → loader」的循环（见文件末尾 `SessionProxy`）
    private let sessionProxy: SessionProxy

    /// 在途请求（key = loading request 身份）
    private var pending: [ObjectIdentifier: PendingRequest] = [:]
    /// taskIdentifier → loading request 身份（URLSession 回调只给 task）
    private var pendingByTask: [Int: ObjectIdentifier] = [:]
    /// 极少数情况下 `didCancel` 早于 `begin` 入队：记下来，begin 时直接放弃（不要开始下载）
    private var cancelledBeforeStart: Set<ObjectIdentifier> = []

    // MARK: - 初始化

    init(authorization: RequestAuthorization, rewritesHLSPlaylists: Bool = true) {
        self.authorization = authorization
        self.rewritesHLSPlaylists = rewritesHLSPlaylists

        let queue = DispatchQueue(label: "com.overtone.media-resource-loader", qos: .userInitiated)
        self.workQueue = queue

        let proxy = SessionProxy()
        self.sessionProxy = proxy

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        // 凭据由 headers 逐请求给：不读也不写 cookie 存储（避免跨账号串味）
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.overtone.media-resource-loader.session"
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        configuration.httpMaximumConnectionsPerHost = 6

        self.session = URLSession(
            configuration: configuration,
            delegate: proxy,
            delegateQueue: delegateQueue
        )
        super.init()
        proxy.target = self
    }

    deinit {
        // session 强引用 delegate，不 invalidate 会把连接池留到进程结束；
        // 回调里的 `proxy.target` 是 weak，本对象开始析构后自然变 nil，不会再进来。
        session.invalidateAndCancel()
    }

    // MARK: - AVAssetResourceLoaderDelegate

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        // 返回 true 之后必须最终 finish：所有处理都进 workQueue，绝不在 delegate 队列上阻塞等待网络
        workQueue.async { [weak self] in
            self?.begin(loadingRequest)
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        workQueue.async { [weak self] in
            self?.cancel(loadingRequest)
        }
    }

    // MARK: - 请求生命周期

    private func begin(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)

        // 先被取消的请求（cancel 早于 begin 入队）：直接结束，不发起任何网络请求
        if cancelledBeforeStart.remove(key) != nil {
            loadingRequest.finishLoading(with: Self.makeError(code: NSURLErrorCancelled, message: "请求已取消"))
            return
        }
        guard pending[key] == nil else { return }

        guard let requestedURL = loadingRequest.request.url else {
            loadingRequest.finishLoading(with: Self.makeError(code: -1, message: "资源请求缺少 URL"))
            return
        }
        let realURL = Self.realURL(from: requestedURL) ?? requestedURL

        var urlRequest = URLRequest(url: realURL)
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = Self.requestTimeout

        // ① 继承 AVFoundation 原始请求里的头（Accept / User-Agent 等，它可能有用）
        if let fields = loadingRequest.request.allHTTPHeaderFields {
            for (field, value) in fields where field.caseInsensitiveCompare("Range") != .orderedSame {
                urlRequest.setValue(value, forHTTPHeaderField: field)
            }
        }
        // ② 本次现算的凭据（后写覆盖同名头：签名必须是最新的）
        for (field, value) in authorization.headers(realURL) {
            urlRequest.setValue(value, forHTTPHeaderField: field)
        }
        // TODO(C)：跨主机 302（签名 URL 跳 CDN）不会重新签名 —— URLSession 会自动跟随重定向，
        // 但不会回调 authorization.headers；若要支持，需要在 URLSessionTaskDelegate 的
        // willPerformHTTPRedirection 里按新 URL 重算头。见 docs/research/local-fallback-notes.md §2.6。
        // ③ Range：AVFoundation 大多数时候把范围放在 dataRequest 里，而不是请求头上
        if let range = Self.rangeHeaderValue(for: loadingRequest) {
            urlRequest.setValue(range, forHTTPHeaderField: "Range")
        }

        let dataRequest = loadingRequest.dataRequest
        let task = session.dataTask(with: urlRequest)
        var entry = PendingRequest(
            loadingRequest: loadingRequest,
            task: task,
            realURL: realURL,
            requestedOffset: dataRequest?.requestedOffset ?? 0,
            requestedLength: dataRequest?.requestedLength ?? 0,
            requestsAllDataToEnd: dataRequest?.requestsAllDataToEndOfResource ?? false
        )
        entry.response = nil
        pending[key] = entry
        pendingByTask[task.taskIdentifier] = key
        task.resume()
    }

    private func cancel(_ loadingRequest: AVAssetResourceLoadingRequest) {
        let key = ObjectIdentifier(loadingRequest)
        guard let entry = pending.removeValue(forKey: key) else {
            cancelledBeforeStart.insert(key)
            return
        }
        pendingByTask[entry.task.taskIdentifier] = nil
        entry.task.cancel()
        // 不调用 finishLoading()：AVFoundation 取消后该请求已经结束，重复 finish 无意义
    }

    /// 结束一个 loading request（**唯一出口**：保证 finishLoading 只调一次、且从两张表里摘干净）
    private func finish(_ key: ObjectIdentifier, error: Error?) {
        guard let entry = pending.removeValue(forKey: key) else { return }
        pendingByTask[entry.task.taskIdentifier] = nil
        if let error {
            entry.loadingRequest.finishLoading(with: error)
        } else {
            entry.loadingRequest.finishLoading()
        }
    }

    // MARK: - 响应处理

    private func receive(
        response: URLResponse,
        task: URLSessionDataTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let key = pendingByTask[task.taskIdentifier], var entry = pending[key] else {
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(key, error: Self.makeError(code: -1, message: "非 HTTP 响应"))
            return
        }
        guard (200...299).contains(http.statusCode) else {
            // 状态码透传：AVFoundation 只会看到「加载失败」，具体码放 error.userInfo 里
            completionHandler(.cancel)
            finish(key, error: Self.makeError(
                code: http.statusCode,
                message: "HTTP \(http.statusCode) \(http.url?.absoluteString ?? "")"
            ))
            return
        }

        entry.response = http
        entry.bodyStart = Self.bodyStart(for: http)
        entry.isHLSPlaylist = Self.isPlaylist(url: http.url ?? entry.realURL, mimeType: http.mimeType)
        pending[key] = entry

        // 允许继续收 body（之后在 didReceive data 里转发给 dataRequest）
        completionHandler(.allow)

        if !entry.isHLSPlaylist {
            entry.loadingRequest.response = http
            Self.fillContentInformation(entry.loadingRequest, with: http)
        }

        // 只要 contentInformationRequest、没有 dataRequest：信息填完就收工，不必下载 body
        guard entry.loadingRequest.dataRequest == nil else { return }
        if entry.isHLSPlaylist {
            entry.loadingRequest.response = http
            Self.applyContentType(Self.hlsPlaylistMimeType, to: entry.loadingRequest)
            entry.loadingRequest.contentInformationRequest?.isByteRangeAccessSupported = false
        }
        finish(key, error: nil)
        task.cancel()
    }

    private func receive(data: Data, task: URLSessionDataTask) {
        guard let key = pendingByTask[task.taskIdentifier], var entry = pending[key] else { return }

        // HLS 播放列表要整体改写（把分片 URI 换成自定义 scheme）后才能交给 AVFoundation
        if entry.isHLSPlaylist {
            entry.playlistData.append(data)
            pending[key] = entry
            return
        }

        let chunkStart = entry.receivedBytes
        entry.receivedBytes += Int64(data.count)

        if let dataRequest = entry.loadingRequest.dataRequest {
            // 本次响应体在「资源坐标」里的区间
            let bodyStartInResource = entry.bodyStart + chunkStart
            let bodyEndInResource = bodyStartInResource + Int64(data.count)
            // 请求区间（all-to-end 时没有上界）
            let requestedEnd: Int64 = entry.requestsAllDataToEnd
                ? Int64.max
                : entry.requestedOffset + Int64(max(entry.requestedLength, 0))
            let sliceStart = max(entry.requestedOffset, bodyStartInResource)
            let sliceEnd = min(requestedEnd, bodyEndInResource)

            if sliceEnd > sliceStart {
                let localStart = Int(sliceStart - bodyStartInResource)
                let localEnd = localStart + Int(sliceEnd - sliceStart)
                dataRequest.respond(with: data.subdata(in: localStart..<localEnd))
                entry.delivered += Int64(localEnd - localStart)
            }
        }
        pending[key] = entry

        // 请求的字节够了就提前收工：避免为了一次 seek 把整首（几十 MB）下完
        if !entry.requestsAllDataToEnd,
           entry.requestedLength > 0,
           entry.delivered >= Int64(entry.requestedLength) {
            finish(key, error: nil)
            task.cancel()
        }
    }

    private func complete(task: URLSessionTask, error: Error?) {
        guard let key = pendingByTask[task.taskIdentifier], let entry = pending[key] else {
            return // 已被 finish / cancel 摘表
        }

        if entry.isHLSPlaylist, error == nil {
            finishPlaylist(key: key, entry: entry)
            return
        }
        // 我们自己 cancel 过的 task 会带着 NSURLErrorCancelled 回来，但那些已摘表；
        // 这里若仍是 -999，说明 AVFoundation 侧取消，按正常结束处理。
        if let error, (error as NSError).code != NSURLErrorCancelled {
            finish(key, error: error)
        } else {
            // 数据不足也 finishLoading()：`#EXT-X-BYTERANGE` 之外的截断（EOF 附近）
            // 属于正常情况，让 AVFoundation 自己判断要不要再发请求
            finish(key, error: nil)
        }
    }

    // MARK: - HLS 播放列表

    /// 改写并交付 m3u8：`#EXT-X-STREAM-INF` 后的 URI 行、`#EXT-X-KEY` / `#EXT-X-MAP` 等
    /// 属性里的 `URI="..."` 全部换成自定义 scheme，这样分片/key 请求才会回到本 loader 重新签名。
    ///
    /// TODO(C)：**未实测** AVFoundation 的 HLS 内部加载路径是否真的把「播放列表内的分片请求」
    /// 交给 `AVAssetResourceLoaderDelegate`。若不走 delegate，改写后的 `-authz` 分片会取不到数据
    /// （回退方案是本地 loopback HTTP 代理，见 docs/research/local-fallback-notes.md §2.6）。
    private func finishPlaylist(key: ObjectIdentifier, entry: PendingRequest) {
        let payload: Data
        if rewritesHLSPlaylists,
           let rewritten = Self.rewritePlaylist(entry.playlistData, baseURL: entry.realURL) {
            payload = rewritten
        } else {
            payload = entry.playlistData
        }

        // 改写后的长度与原始 Content-Length 不同：先按新长度写 contentInformation 与响应头，再 respond
        if let info = entry.loadingRequest.contentInformationRequest {
            info.contentLength = Int64(payload.count)
            info.isByteRangeAccessSupported = false
        }
        Self.applyContentType(Self.hlsPlaylistMimeType, to: entry.loadingRequest)
        if let adjusted = Self.adjustedResponse(entry.response, contentLength: Int64(payload.count)) {
            entry.loadingRequest.response = adjusted
        } else if let original = entry.response {
            entry.loadingRequest.response = original
        }
        entry.loadingRequest.dataRequest?.respond(with: payload)
        finish(key, error: nil)
    }

    private static let hlsPlaylistMimeType = "application/vnd.apple.mpegurl"

    private static func isPlaylist(url: URL?, mimeType: String?) -> Bool {
        if let mimeType = mimeType?.lowercased(),
           mimeType.contains("mpegurl") || mimeType.contains("m3u") {
            return true
        }
        guard let url else { return false }
        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "m3u8" || pathExtension == "m3u"
    }

    /// 逐行改写播放列表；返回 nil 表示「无法解析/没有变化」，调用方原样转发。
    ///
    /// TODO(C)：`#EXT-X-KEY`（加密 HLS）这里只改写 URI —— 真正的密钥交付协议（AES-128 的
    /// loader 语义 / FairPlay 的 `skd://` + AVContentKeySession）没有实现，加密流能否播**未验证**。
    private static func rewritePlaylist(_ data: Data, baseURL: URL?) -> Data? {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return nil }
        // 已经是 UTF-8 的 m3u8；写成 split/join 而不是正则，逻辑更好读也更好测
        var changed = false
        let lines = text.components(separatedBy: "\n")
        var rewritten: [String] = []
        rewritten.reserveCapacity(lines.count)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                rewritten.append(line)
                continue
            }
            if trimmed.hasPrefix("#") {
                let newLine = rewriteAttributeURIs(in: line, baseURL: baseURL)
                changed = changed || newLine != line
                rewritten.append(newLine)
            } else {
                if let rewrittenURI = rewriteURI(trimmed, baseURL: baseURL) {
                    changed = true
                    rewritten.append(rewrittenURI)
                } else {
                    rewritten.append(line)
                }
            }
        }
        guard changed else { return nil }
        return rewritten.joined(separator: "\n").data(using: .utf8)
    }

    /// 改写一行标签里的 `URI="..."`（可能多个；HLS 属性值必带引号）
    private static func rewriteAttributeURIs(in line: String, baseURL: URL?) -> String {
        guard line.contains("URI=\"") else { return line }
        var result = ""
        var cursor = line.startIndex
        while let marker = line.range(of: "URI=\"", range: cursor..<line.endIndex) {
            result += line[cursor..<marker.upperBound]
            cursor = marker.upperBound
            guard let closing = line[cursor...].firstIndex(of: "\"") else {
                result += line[cursor...]
                cursor = line.endIndex
                break
            }
            let value = String(line[cursor..<closing])
            result += rewriteURI(value, baseURL: baseURL) ?? value
            cursor = closing
        }
        result += line[cursor...]
        return result
    }

    /// 相对 URI 先按播放列表 URL 解析成绝对 URL，再换成自定义 scheme
    private static func rewriteURI(_ raw: String, baseURL: URL?) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let resolved: URL
        if let absolute = URL(string: trimmed), absolute.scheme != nil {
            resolved = absolute
        } else if let baseURL, let relative = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL {
            resolved = relative
        } else {
            return nil
        }
        guard isHTTPURL(resolved) else { return nil } // 已是自定义 scheme / data: 等，保持原样
        return customSchemeURL(for: resolved)?.absoluteString
    }

    // MARK: - 响应头 / 内容信息

    /// 填 `contentInformationRequest`（AVFoundation 靠它知道媒体类型、总长度、能否 Range）
    private static func fillContentInformation(
        _ loadingRequest: AVAssetResourceLoadingRequest,
        with response: HTTPURLResponse
    ) {
        guard let info = loadingRequest.contentInformationRequest else { return }
        applyContentType(response.mimeType, to: loadingRequest)
        info.isByteRangeAccessSupported = supportsByteRanges(response)
        if let total = totalContentLength(response) {
            info.contentLength = total
        }
    }

    /// `contentType` 必须是 UTI 或 `allowedContentTypes` 里的值 ——
    /// `allowedContentTypes` 非空时乱设会让 `finishLoading` 直接抛异常（Apple 文档明确写了）。
    private static func applyContentType(
        _ mimeType: String?,
        to loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let info = loadingRequest.contentInformationRequest else { return }
        if let allowed = info.allowedContentTypes, !allowed.isEmpty {
            if let mimeType, allowed.contains(mimeType) {
                info.contentType = mimeType
            } else {
                info.contentType = allowed.first
            }
        } else if let mimeType {
            info.contentType = mimeType
        }
    }

    /// 206 的 `Content-Range: bytes a-b/total` 里的 `a`（响应体第一个字节在资源里的偏移）；
    /// 200 表示服务端忽略了 Range，body 从 0 开始。
    private static func bodyStart(for response: HTTPURLResponse) -> Int64 {
        guard response.statusCode == 206,
              let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
              let start = contentRangeStart(contentRange) else { return 0 }
        return start
    }

    private static func contentRangeStart(_ contentRange: String) -> Int64? {
        guard let space = contentRange.firstIndex(of: " ") else { return nil }
        let rest = contentRange[contentRange.index(after: space)...]
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        return Int64(rest[rest.startIndex..<dash])
    }

    private static func contentRangeTotal(_ contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        let total = contentRange[contentRange.index(after: slash)...]
            .trimmingCharacters(in: .whitespaces)
        guard total != "*" else { return nil }
        return Int64(total)
    }

    /// 资源总长度：206 用 `Content-Range` 的总长（`Content-Length` 只是本次分片长度），200 用 `Content-Length`
    private static func totalContentLength(_ response: HTTPURLResponse) -> Int64? {
        if let contentRange = response.value(forHTTPHeaderField: "Content-Range"),
           let total = contentRangeTotal(contentRange) {
            return total
        }
        if let length = response.value(forHTTPHeaderField: "Content-Length"),
           let value = Int64(length), value > 0 {
            return value
        }
        return nil
    }

    private static func supportsByteRanges(_ response: HTTPURLResponse) -> Bool {
        if response.statusCode == 206 { return true }
        let acceptRanges = response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased() ?? ""
        return acceptRanges.contains("bytes")
    }

    /// 把 206 的 `Content-Range` / `Accept-Ranges` / `Content-Length` 等关键头透传给 AVFoundation。
    /// 播放列表被改写后长度变了，用 `contentLength` 覆盖（并去掉 `Content-Range`，因为不再是分片响应）。
    private static func adjustedResponse(
        _ response: HTTPURLResponse?,
        contentLength: Int64
    ) -> HTTPURLResponse? {
        guard let response, let url = response.url else { return nil }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String {
                headers[key] = value
            }
        }
        headers["Content-Length"] = String(contentLength)
        headers.removeValue(forKey: "Content-Range")
        return HTTPURLResponse(
            url: url,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    // MARK: - Range

    /// 把 `AVAssetResourceLoadingDataRequest` 翻译成 HTTP `Range`。
    ///
    /// 两处都要看：有的系统版本把 Range 放进 loading request 的请求头，绝大多数时候只在 dataRequest 里。
    private static func rangeHeaderValue(for loadingRequest: AVAssetResourceLoadingRequest) -> String? {
        if let header = loadingRequest.request.value(forHTTPHeaderField: "Range"), !header.isEmpty {
            return header
        }
        guard let dataRequest = loadingRequest.dataRequest else {
            // 只有 contentInformationRequest 的探测请求：用 1 字节 Range 只拿响应头，
            // 否则会为了读媒体类型把整首（几十 MB）下载下来。
            if loadingRequest.contentInformationRequest != nil {
                return "bytes=0-1"
            }
            return nil
        }
        let offset = dataRequest.requestedOffset
        if dataRequest.requestsAllDataToEndOfResource {
            return offset > 0 ? "bytes=\(offset)-" : nil
        }
        let length = dataRequest.requestedLength
        guard length > 0, length < Int.max else {
            return offset > 0 ? "bytes=\(offset)-" : nil
        }
        return "bytes=\(offset)-\(offset + Int64(length) - 1)"
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(
            domain: errorDomain,
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    // MARK: - 网络回调（由 SessionProxy 转到 workQueue）

    fileprivate func handle(
        response: URLResponse,
        task: URLSessionDataTask,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        workQueue.async { [weak self] in
            self?.receive(response: response, task: task, completionHandler: completionHandler)
        }
    }

    fileprivate func handle(data: Data, task: URLSessionDataTask) {
        workQueue.async { [weak self] in
            self?.receive(data: data, task: task)
        }
    }

    fileprivate func handle(completionOf task: URLSessionTask, error: Error?) {
        workQueue.async { [weak self] in
            self?.complete(task: task, error: error)
        }
    }

    // MARK: - 在途请求

    private struct PendingRequest {
        let loadingRequest: AVAssetResourceLoadingRequest
        let task: URLSessionDataTask
        /// 去掉自定义 scheme 后的真实 URL（HLS 改写相对 URI 时作为 base）
        let realURL: URL
        let requestedOffset: Int64
        let requestedLength: Int
        let requestsAllDataToEnd: Bool
        /// 响应体第一个字节在资源里的偏移（200 → 0；206 → `Content-Range` 起点）
        var bodyStart: Int64 = 0
        /// 已收到的响应体字节数（含被裁掉的；服务端忽略 Range 时用它算偏移）
        var receivedBytes: Int64 = 0
        /// 已 `respond(with:)` 给 AVFoundation 的字节数
        var delivered: Int64 = 0
        /// 播放列表请求：先攒起来，完成时整体改写
        var playlistData = Data()
        var isHLSPlaylist = false
        /// 原始 HTTP 响应（透传状态码与关键头）
        var response: HTTPURLResponse?
    }
}

// MARK: - SessionProxy

/// `URLSession` 的 delegate 代理。
///
/// 为什么不让 loader 自己当 session delegate：`URLSession` **强引用** delegate，而 loader 又强引用
/// session，会形成循环（loader 永远不释放 → 每换一首曲子泄漏一个 session 与连接池）。
/// 代理对象由 session 强引用、只 **weak** 回指 loader，loop 断掉；loader `deinit` 里
/// `invalidateAndCancel()` 释放连接。
private final class SessionProxy: NSObject, URLSessionDataDelegate {
    weak var target: MediaResourceLoader?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let target else {
            completionHandler(.cancel)
            return
        }
        target.handle(response: response, task: dataTask, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        target?.handle(data: data, task: dataTask)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        target?.handle(completionOf: task, error: error)
    }
}

// MARK: - RetainingURLAsset

/// 强持有 resource loader 的 `AVURLAsset`。
///
/// `AVAssetResourceLoader.delegate` 是 **weak**（Apple 文档明确写「delegate 不会被 retain」），
/// 如果只把 loader 交给 asset、调用方自己不留引用，`makeAssetAndLoader` 返回后 loader 会立刻释放，
/// 所有请求永远等不到 `finishLoading` —— 表现是「播放器一直转圈 / 静默失败」。
/// 播放器已按成对 API 自己持有 loader；这里再强持一份是给「只拿 asset」的调用方兜底。
private final class RetainingURLAsset: AVURLAsset, @unchecked Sendable {
    /// 只为生命周期而存在（`makeAssetAndLoader` 的调用方也可以自己持有同一对象）
    let retainedResourceLoader: MediaResourceLoader?

    init(url: URL, resourceLoader: MediaResourceLoader?) {
        self.retainedResourceLoader = resourceLoader
        super.init(url: url, options: nil)
    }
}
