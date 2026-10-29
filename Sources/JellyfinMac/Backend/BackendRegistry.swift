import Foundation

// MARK: - 凭据作用域

/// 凭据命名空间。
///
/// 原来的实现把一个服务器地址 / token / 用户名写在无前缀的 UserDefaults 键里，
/// 密码的钥匙串 account 直接就是**用户名** —— 两台服务器上的同名用户会互相覆盖。
/// 现在统一走 `backend.<kind>.…` 前缀与 `<kind>|<username>` 的钥匙串账号，
/// 并保留对旧键的一次性迁移（迁移失败不删旧数据，保证还能回滚）。
enum CredentialNamespace {
    static func serverURL(_ kind: BackendKind) -> String { "backend.\(kind.rawValue).serverURL" }
    static func session(_ kind: BackendKind) -> String { "backend.\(kind.rawValue).session" }
    static func username(_ kind: BackendKind) -> String { "backend.\(kind.rawValue).username" }
    static func accessCode(_ kind: BackendKind) -> String { "backend.\(kind.rawValue).accessCode" }

    static let activeKind = "backend.active"

    /// 旧版（单 Jellyfin 后端）键名
    enum Legacy {
        static let serverURL = "serverURL"
        static let token = "token"
        static let username = "username"
        static let password = "password"
    }

    static func keychainAccount(kind: BackendKind, username: String) -> String {
        "\(kind.rawValue)|\(username)"
    }
}

// MARK: - 会话持久化

@MainActor
final class SessionPersistence {
    static let shared = SessionPersistence()

    private let defaults = UserDefaults.standard
    private init() {}

    // MARK: 会话

    func loadSession(_ kind: BackendKind) -> BackendSession? {
        guard let data = defaults.data(forKey: CredentialNamespace.session(kind)),
              let session = try? JSONDecoder().decode(BackendSession.self, from: data) else {
            return nil
        }
        return session
    }

    func saveSession(_ session: BackendSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: CredentialNamespace.session(session.backend))
        defaults.set(session.serverURL.absoluteString, forKey: CredentialNamespace.serverURL(session.backend))
        defaults.set(session.username, forKey: CredentialNamespace.username(session.backend))
    }

    func clearSession(_ kind: BackendKind) {
        defaults.removeObject(forKey: CredentialNamespace.session(kind))
        defaults.removeObject(forKey: CredentialNamespace.serverURL(kind))
        defaults.removeObject(forKey: CredentialNamespace.username(kind))
    }

    // MARK: 上次登录信息（登录页预填）

    func lastServerURL(_ kind: BackendKind) -> String? {
        defaults.string(forKey: CredentialNamespace.serverURL(kind))
    }

    func lastUsername(_ kind: BackendKind) -> String? {
        defaults.string(forKey: CredentialNamespace.username(kind))
    }

    func accessCode(_ kind: BackendKind) -> String? {
        defaults.string(forKey: CredentialNamespace.accessCode(kind))
    }

    func storeAccessCode(_ code: String?, kind: BackendKind) {
        if let code, !code.isEmpty {
            defaults.set(code, forKey: CredentialNamespace.accessCode(kind))
        } else {
            defaults.removeObject(forKey: CredentialNamespace.accessCode(kind))
        }
    }

    // MARK: 密码（钥匙串，按后端命名空间）

    func savePassword(_ password: String, kind: BackendKind, username: String) async -> Bool {
        await KeychainHelper.saveAsync(
            password: password,
            account: CredentialNamespace.keychainAccount(kind: kind, username: username)
        )
    }

    func password(kind: BackendKind, username: String) async -> String? {
        if let scoped = await KeychainHelper.readAsync(
            account: CredentialNamespace.keychainAccount(kind: kind, username: username)
        ) {
            return scoped
        }
        // 兼容：旧版把 account 直接写成用户名的 Jellyfin 凭据
        if kind == .jellyfin {
            return await KeychainHelper.readAsync(account: username)
        }
        return nil
    }

    func deletePassword(kind: BackendKind, username: String) async {
        await KeychainHelper.deleteAsync(
            account: CredentialNamespace.keychainAccount(kind: kind, username: username)
        )
        if kind == .jellyfin {
            await KeychainHelper.deleteAsync(account: username)
        }
    }

    // MARK: 旧版迁移（单后端 → Jellyfin 命名空间）

    /// 只在「Jellyfin 还没有任何已存会话」时迁移，避免覆盖用户已经换过服务器的新状态。
    func migrateLegacyJellyfinCredentialsIfNeeded() {
        guard loadSession(.jellyfin) == nil else { return }
        guard let server = defaults.string(forKey: CredentialNamespace.Legacy.serverURL),
              let token = defaults.string(forKey: CredentialNamespace.Legacy.token),
              let url = URL(string: normalize(server: server)) else { return }
        let username = defaults.string(forKey: CredentialNamespace.Legacy.username) ?? ""
        let session = BackendSession(
            backend: .jellyfin,
            serverURL: url,
            username: username,
            token: token,
            userID: "",
            userDisplayName: username,
            extraCookie: nil
        )
        saveSession(session)
    }

    /// 旧版明文密码迁移：搬进按后端命名空间的钥匙串条目，**写入成功才删除**明文。
    func migrateLegacyPasswordIfNeeded() async {
        guard let username = defaults.string(forKey: CredentialNamespace.Legacy.username),
              let legacy = defaults.string(forKey: CredentialNamespace.Legacy.password) else { return }
        if await KeychainHelper.saveAsync(
            password: legacy,
            account: CredentialNamespace.keychainAccount(kind: .jellyfin, username: username)
        ) {
            defaults.removeObject(forKey: CredentialNamespace.Legacy.password)
        }
    }

    func normalize(server raw: String) -> String {
        var server = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return server }
        if !server.contains("://") { server = "http://" + server }
        while server.hasSuffix("/") { server.removeLast() }
        return server
    }
}

// MARK: - 后端注册表

/// 活动后端登记处。
///
/// 运行时只有**一个**活动后端（登录页选一个、设置页可切换，切换即重登），
/// 但状态层通过注册表访问后端，不直接持有具体类型 —— 加第三个后端不需要改状态层。
@MainActor
final class BackendRegistry {
    static let shared = BackendRegistry()

    /// 后端工厂（由 `AppState` 注入，避免注册表依赖具体实现）
    var factory: ((BackendKind) -> MusicBackend)?

    private var cache: [BackendKind: MusicBackend] = [:]

    private(set) var activeKind: BackendKind

    private init() {
        let raw = UserDefaults.standard.string(forKey: CredentialNamespace.activeKind) ?? ""
        activeKind = BackendKind(rawValue: raw) ?? .jellyfin
    }

    /// 当前活动后端（首次访问时实例化）
    var active: MusicBackend {
        backend(for: activeKind)
    }

    func backend(for kind: BackendKind) -> MusicBackend {
        if let existing = cache[kind] { return existing }
        guard let factory else {
            fatalError("BackendRegistry.factory 未注入")
        }
        let created = factory(kind)
        cache[kind] = created
        return created
    }

    /// 后端是否已实现可用的实例（UI 展示后端选择器时用）
    func isAvailable(_ kind: BackendKind) -> Bool { true }

    func setActive(_ kind: BackendKind) {
        guard kind != activeKind else { return }
        activeKind = kind
        UserDefaults.standard.set(kind.rawValue, forKey: CredentialNamespace.activeKind)
    }

    /// 当前活动后端的已存会话（未登录为 nil）
    var activeSession: BackendSession? { active.session }
}
