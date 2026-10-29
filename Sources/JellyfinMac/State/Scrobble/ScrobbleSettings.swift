import AppKit
import Combine
import Foundation

// MARK: - 连接状态

/// 设置页展示的连接状态（进行中 / 等待授权 / 失败；失败文案一律脱敏）。
enum ScrobbleLinkState: Equatable {
    /// 没有配置凭据
    case unconfigured
    /// 凭据齐了但还没有会话
    case disconnected
    /// 正在连接 / 验证（附进行中的提示）
    case working(String)
    /// Last.fm 已打开浏览器授权页，等待用户确认后回来点「完成授权」
    case awaitingAuthorization
    /// 已连接（显示用户名）
    case connected(username: String)
    /// 失败（文案不含任何凭据）
    case failed(String)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// 进行中 / 等待授权 / 失败：刷新凭据时不要覆盖这些状态，否则用户看不到提示。
    var isTransient: Bool {
        switch self {
        case .working, .awaitingAuthorization, .failed: return true
        case .unconfigured, .disconnected, .connected: return false
        }
    }
}

// MARK: - 钥匙串

/// 听歌服务的钥匙串账号。
///
/// `KeychainHelper` 的 service 固定为 `com.jellyfin.mac-client`，这里只约定 account：
/// Secret / session key / 用户令牌三类凭据都带 `scrobble.` 前缀，绝不落到 UserDefaults / 日志。
enum ScrobbleKeychainAccount: String {
    /// Last.fm API Secret（用户自备，非内置）
    case lastFMSecret = "scrobble.lastfm.secret"
    /// Last.fm session key（auth.getSession 换取，用户可撤销）
    case lastFMSession = "scrobble.lastfm.session"
    /// ListenBrainz 用户令牌
    case listenBrainzToken = "scrobble.listenbrainz.token"
}

enum ScrobbleKeychain {
    static func read(_ account: ScrobbleKeychainAccount) async -> String? {
        await KeychainHelper.readAsync(account: account.rawValue)?.trimmedForScrobble
    }

    @discardableResult
    static func save(_ value: String, to account: ScrobbleKeychainAccount) async -> Bool {
        guard let trimmed = value.trimmedForScrobble else { return false }
        return await KeychainHelper.saveAsync(password: trimmed, account: account.rawValue)
    }

    static func delete(_ account: ScrobbleKeychainAccount) async {
        await KeychainHelper.deleteAsync(account: account.rawValue)
    }
}

// MARK: - 设置模型

/// 「听歌记录」设置：开关、服务选择、Last.fm / ListenBrainz 凭据与连接状态。
///
/// 安全约定：
/// - **不内置任何 API Key / Secret**，全部由用户填写；
/// - Secret / session key / ListenBrainz 令牌只存本机钥匙串（见 `ScrobbleKeychain`）；
/// - 只有非机密的 API Key 与用户名存 `UserDefaults`；
/// - 状态文案与日志都不打印凭据。
@MainActor
final class ScrobbleSettings: ObservableObject {
    static let shared = ScrobbleSettings()

    private enum Key {
        static let enabled = "scrobble.enabled"
        static let service = "scrobble.service"
        static let lastFMAPIKey = "scrobble.lastfm.apiKey"
        static let lastFMUsername = "scrobble.lastfm.username"
        static let lastFMPendingToken = "scrobble.lastfm.pendingToken"
        static let listenBrainzUsername = "scrobble.listenbrainz.username"
    }

    // MARK: 开关

    /// 总开关：默认**关闭**（不经用户明确开启不上报任何数据）。
    @Published var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: Key.enabled)
            if enabled {
                // `bootstrap` 幂等（只做一次启动结算），重新开启时还要显式补报一次队列
                ScrobbleService.shared.bootstrap()
                ScrobbleService.shared.flushPending(force: true)
            } else {
                ScrobbleService.shared.discardSession()
            }
        }
    }

    /// 当前提交目标（同一时间只向一个服务提交）。
    @Published var service: ScrobbleServiceKind {
        didSet { defaults.set(service.rawValue, forKey: Key.service) }
    }

    // MARK: Last.fm

    /// 用户自备的 Last.fm API Key（非机密，存偏好设置；Secret 在钥匙串）。
    @Published var lastFMAPIKey: String {
        didSet { defaults.set(lastFMAPIKey, forKey: Key.lastFMAPIKey) }
    }

    @Published private(set) var lastFMState: ScrobbleLinkState = .unconfigured
    @Published private(set) var hasLastFMSecret = false
    @Published private(set) var hasLastFMSession = false
    @Published private(set) var lastFMUsername: String?

    // MARK: ListenBrainz

    @Published private(set) var listenBrainzState: ScrobbleLinkState = .unconfigured
    @Published private(set) var hasListenBrainzToken = false
    @Published private(set) var listenBrainzUsername: String?

    private let defaults = UserDefaults.standard
    /// Last.fm 桌面授权中间态：request token 一次性、60 分钟有效，不算机密（仍需在完成后清掉）。
    private var pendingLastFMToken: String?

    private init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? false
        service = ScrobbleServiceKind(rawValue: defaults.string(forKey: Key.service) ?? "") ?? .lastFM
        lastFMAPIKey = defaults.string(forKey: Key.lastFMAPIKey) ?? ""
        lastFMUsername = defaults.string(forKey: Key.lastFMUsername)
        listenBrainzUsername = defaults.string(forKey: Key.listenBrainzUsername)
        pendingLastFMToken = defaults.string(forKey: Key.lastFMPendingToken)
    }

    // MARK: 状态文案（设置页可见）

    var lastFMStatusText: String {
        switch lastFMState {
        case .unconfigured:
            return "未配置：填写 API Key 与 Shared Secret 后连接"
        case .disconnected:
            return "已保存凭据，尚未连接"
        case .working(let text):
            return text
        case .awaitingAuthorization:
            return "已打开浏览器授权页，确认后点「完成授权」"
        case .connected(let username):
            return "已连接：\(username)"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    var listenBrainzStatusText: String {
        switch listenBrainzState {
        case .unconfigured:
            return "未配置：粘贴用户令牌后保存并验证"
        case .disconnected:
            return "已保存令牌，尚未验证"
        case .working(let text):
            return text
        case .awaitingAuthorization:
            return "等待授权"
        case .connected(let username):
            return "已连接：\(username)"
        case .failed(let message):
            return "失败：\(message)"
        }
    }

    // MARK: 凭据存在性（启动 / 进入设置页时异步刷新，避免主线程同步查钥匙串）

    /// 读钥匙串并更新「是否已保存」标记与状态。`onAppear` / 保存 / 断开后调用。
    func refreshCredentialPresence() async {
        async let secret = ScrobbleKeychain.read(.lastFMSecret)
        async let session = ScrobbleKeychain.read(.lastFMSession)
        async let token = ScrobbleKeychain.read(.listenBrainzToken)
        let (storedSecret, storedSession, storedToken) = await (secret, session, token)
        hasLastFMSecret = storedSecret != nil
        hasLastFMSession = storedSession != nil
        hasListenBrainzToken = storedToken != nil
        refreshStates()
    }

    private func refreshStates() {
        if !lastFMState.isTransient {
            if hasLastFMSession {
                lastFMState = .connected(username: lastFMUsername ?? "已连接")
            } else if hasLastFMSecret, lastFMAPIKey.trimmedForScrobble != nil {
                lastFMState = .disconnected
            } else {
                lastFMState = .unconfigured
            }
        }
        if !listenBrainzState.isTransient {
            if hasListenBrainzToken {
                listenBrainzState = .connected(username: listenBrainzUsername ?? "已连接")
            } else {
                listenBrainzState = .unconfigured
            }
        }
    }

    // MARK: Last.fm 授权 / 验证 / 断开

    /// 只保存 Secret（不发起网络请求）。保存成功后刷新「已配置」标记。
    func saveLastFMSecret(_ secret: String) {
        guard let trimmed = secret.trimmedForScrobble else { return }
        Task { [weak self] in
            guard let self else { return }
            let saved = await ScrobbleKeychain.save(trimmed, to: .lastFMSecret)
            self.hasLastFMSecret = saved
            if saved {
                self.refreshStates()
            } else {
                self.lastFMState = .failed("Shared Secret 保存失败")
            }
        }
    }

    /// 桌面授权第 1 步：保存输入框里的 Secret（若有）→ auth.getToken → 用系统浏览器打授权页。
    ///
    /// 之后由用户点「完成授权」走 `completeLastFMAuth()`。全程失败静默，只在设置页更新状态。
    func connectLastFM(secretInput: String? = nil) {
        guard !lastFMState.isWorking else { return }
        guard let apiKey = lastFMAPIKey.trimmedForScrobble else {
            lastFMState = .failed("请先填写 Last.fm API Key")
            return
        }
        lastFMState = .working("正在获取授权链接…")
        Task { [weak self] in
            guard let self else { return }
            if let input = secretInput?.trimmedForScrobble {
                guard await ScrobbleKeychain.save(input, to: .lastFMSecret) else {
                    self.lastFMState = .failed("Shared Secret 保存失败")
                    return
                }
                self.hasLastFMSecret = true
            }
            guard let secret = await ScrobbleKeychain.read(.lastFMSecret) else {
                self.lastFMState = .failed("请先填写并保存 Shared Secret")
                return
            }
            do {
                let token = try await LastFMAPI.requestToken(apiKey: apiKey, secret: secret)
                self.pendingLastFMToken = token
                self.defaults.set(token, forKey: Key.lastFMPendingToken)
                guard let url = LastFMAPI.authorizationURL(apiKey: apiKey, token: token) else {
                    self.lastFMState = .failed("授权地址无效")
                    return
                }
                NSWorkspace.shared.open(url)
                self.lastFMState = .awaitingAuthorization
            } catch {
                self.lastFMState = .failed(Self.describe(error))
            }
        }
    }

    /// 桌面授权第 3 步：auth.getSession 换 session key（存钥匙串），成功后顺手 flush 待补报队列。
    func completeLastFMAuth() {
        guard !lastFMState.isWorking else { return }
        guard let apiKey = lastFMAPIKey.trimmedForScrobble else {
            lastFMState = .failed("请先填写 Last.fm API Key")
            return
        }
        guard let token = pendingLastFMToken ?? defaults.string(forKey: Key.lastFMPendingToken) else {
            lastFMState = .failed("没有待完成的授权，请重新点「连接」")
            return
        }
        lastFMState = .working("正在完成授权…")
        Task { [weak self] in
            guard let self else { return }
            guard let secret = await ScrobbleKeychain.read(.lastFMSecret) else {
                self.lastFMState = .failed("Shared Secret 丢失，请重新填写")
                return
            }
            do {
                let session = try await LastFMAPI.createSession(
                    apiKey: apiKey,
                    secret: secret,
                    token: token
                )
                guard await ScrobbleKeychain.save(session.key, to: .lastFMSession) else {
                    self.lastFMState = .failed("会话密钥保存失败")
                    return
                }
                self.hasLastFMSession = true
                self.lastFMUsername = session.name
                self.defaults.set(session.name, forKey: Key.lastFMUsername)
                self.clearPendingToken()
                self.lastFMState = .connected(username: session.name)
                ScrobbleService.shared.flushPending()
            } catch {
                self.lastFMState = .failed(Self.describe(error))
            }
        }
    }

    /// 验证已保存的 session key（用户可能在 Last.fm 设置页撤销授权）。
    func verifyLastFM() {
        guard !lastFMState.isWorking else { return }
        guard let apiKey = lastFMAPIKey.trimmedForScrobble else {
            lastFMState = .failed("请先填写 Last.fm API Key")
            return
        }
        lastFMState = .working("正在验证…")
        Task { [weak self] in
            guard let self else { return }
            guard let secret = await ScrobbleKeychain.read(.lastFMSecret),
                  let sessionKey = await ScrobbleKeychain.read(.lastFMSession) else {
                self.hasLastFMSession = false
                self.lastFMState = .disconnected
                return
            }
            do {
                let name = try await LastFMAPI.userName(
                    apiKey: apiKey,
                    secret: secret,
                    sessionKey: sessionKey
                )
                self.hasLastFMSession = true
                self.lastFMUsername = name
                self.defaults.set(name, forKey: Key.lastFMUsername)
                self.lastFMState = .connected(username: name)
                ScrobbleService.shared.flushPending()
            } catch {
                if Self.isInvalidSession(error) {
                    // 错误码 9 = Invalid session key：授权已被撤销，清掉本地会话（保留 API Key/Secret）
                    await ScrobbleKeychain.delete(.lastFMSession)
                    self.hasLastFMSession = false
                    self.lastFMState = .disconnected
                } else {
                    self.lastFMState = .failed(Self.describe(error))
                }
            }
        }
    }

    /// 断开 = 删除 session key；**保留**用户填写的 API Key 与 Secret（下次连接不用重填）。
    func disconnectLastFM() {
        lastFMState = .disconnected
        clearPendingToken()
        Task { [weak self] in
            await ScrobbleKeychain.delete(.lastFMSession)
            guard let self else { return }
            self.hasLastFMSession = false
            if self.hasLastFMSecret, self.lastFMAPIKey.trimmedForScrobble != nil {
                self.lastFMState = .disconnected
            } else {
                self.lastFMState = .unconfigured
            }
        }
    }

    // MARK: ListenBrainz 连接 / 验证 / 断开

    /// 保存并验证用户令牌：只有验证通过才写入钥匙串（避免存下无效令牌）。
    func connectListenBrainz(tokenInput: String?) {
        guard !listenBrainzState.isWorking else { return }
        guard let token = tokenInput?.trimmedForScrobble else {
            listenBrainzState = .failed("请先填写 ListenBrainz 用户令牌")
            return
        }
        listenBrainzState = .working("正在验证令牌…")
        Task { [weak self] in
            guard let self else { return }
            do {
                let userName = try await ListenBrainzAPI.validateToken(token)
                guard await ScrobbleKeychain.save(token, to: .listenBrainzToken) else {
                    self.listenBrainzState = .failed("令牌保存失败")
                    return
                }
                self.hasListenBrainzToken = true
                self.listenBrainzUsername = userName
                self.defaults.set(userName, forKey: Key.listenBrainzUsername)
                self.listenBrainzState = .connected(username: userName)
                ScrobbleService.shared.flushPending()
            } catch {
                self.listenBrainzState = .failed(Self.describe(error))
            }
        }
    }

    /// 用钥匙串里已存的令牌重新验证（不要求用户重新输入）。
    func verifyListenBrainz() {
        guard !listenBrainzState.isWorking else { return }
        listenBrainzState = .working("正在验证…")
        Task { [weak self] in
            guard let self else { return }
            guard let token = await ScrobbleKeychain.read(.listenBrainzToken) else {
                self.hasListenBrainzToken = false
                self.listenBrainzState = .unconfigured
                return
            }
            do {
                let userName = try await ListenBrainzAPI.validateToken(token)
                self.hasListenBrainzToken = true
                self.listenBrainzUsername = userName
                self.defaults.set(userName, forKey: Key.listenBrainzUsername)
                self.listenBrainzState = .connected(username: userName)
                ScrobbleService.shared.flushPending()
            } catch {
                self.listenBrainzState = .failed(Self.describe(error))
            }
        }
    }

    func disconnectListenBrainz() {
        listenBrainzState = .unconfigured
        Task { [weak self] in
            await ScrobbleKeychain.delete(.listenBrainzToken)
            guard let self else { return }
            self.hasListenBrainzToken = false
            self.listenBrainzUsername = nil
            self.defaults.removeObject(forKey: Key.listenBrainzUsername)
            self.listenBrainzState = .unconfigured
        }
    }

    // MARK: 工具

    private func clearPendingToken() {
        pendingLastFMToken = nil
        defaults.removeObject(forKey: Key.lastFMPendingToken)
    }

    private static func describe(_ error: Error) -> String {
        if let api = error as? ScrobbleAPIError, let text = api.errorDescription {
            return text
        }
        return "未知错误"
    }

    private static func isInvalidSession(_ error: Error) -> Bool {
        if case .service(let code, _)? = error as? ScrobbleAPIError {
            return code == 9
        }
        return false
    }
}
