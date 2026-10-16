import SwiftUI

@MainActor
final class AppState: ObservableObject {
    /// 单例：会话恢复由 AppDelegate 驱动，不受视图重建/取消影响
    static let shared = AppState()

    private init() {}

    enum Phase {
        case signedOut
        case signedIn
    }

    @Published var phase: Phase = .signedOut
    @Published var user: UserDto?
    @Published var libraries: [BaseItemDto] = []

    private enum Keys {
        static let serverURL = "serverURL"
        static let token = "token"
        static let username = "username"
        /// 历史遗留：密码曾经明文写在 UserDefaults 里。
        /// 现在只在钥匙串写入成功之前作为兜底保留，读到即迁移。
        static let legacyPassword = "password"
    }
    private let defaults = UserDefaults.standard
    /// 会话恢复只执行一次（视图重建/重复 task 时避免并发竞态）
    private var didAttemptRestore = false

    /// 会话凭据是否还在（token 在 UserDefaults，密码在钥匙串）
    var hasSavedSession: Bool {
        defaults.string(forKey: Keys.serverURL) != nil && defaults.string(forKey: Keys.token) != nil
    }

    func login(server rawServer: String, username: String, password: String) async throws {
        let server = normalize(server: rawServer)
        guard let url = URL(string: server) else { throw APIError.invalidURL }

        APIClient.shared.baseURL = url
        let body = try JSONEncoder().encode(AuthRequest(username: username, password: password))
        let response: AuthenticateResponse = try await APIClient.shared.post("/Users/AuthenticateByName", body: body)
        APIClient.shared.token = response.accessToken
        APIClient.shared.user = response.user
        defaults.set(server, forKey: Keys.serverURL)
        defaults.set(response.accessToken, forKey: Keys.token)
        defaults.set(username, forKey: Keys.username)
        // 密码只进钥匙串：**写入成功才**清掉旧版遗留在 UserDefaults 里的明文，
        // 否则保留兜底（钥匙串被拒绝访问时自动登录还能用）。
        //
        // 访问 token 不进钥匙串是有意为之：本应用是 ad-hoc 签名，重建后 cdhash 变化，
        // 钥匙串 ACL 就会失配并弹一次系统授权框——token 读写在启动路径上，
        // 那等于每次重新构建都弹一次密码框。token 可用服务端吊销，留在 default 里
        // （0600 权限的 plist）与改动前的行为一致，见 docs/build-notes.md。
        if await KeychainHelper.saveAsync(password: password, account: username) {
            defaults.removeObject(forKey: Keys.legacyPassword)
        }
        user = response.user
        phase = .signedIn
    }

    /// 启动恢复：token 有效直接进入；失效则用保存的账号密码自动重新登录
    func restoreSession() async {
        guard !didAttemptRestore else { return }
        defer { didAttemptRestore = true }
        // 0. 旧版遗留的明文密码：搬进钥匙串（写入成功才删除明文，避免迁移失败丢凭据）
        await migrateLegacyPassword()
        // 1. 尝试 token 恢复
        if let server = defaults.string(forKey: Keys.serverURL),
           let url = URL(string: server),
           let token = defaults.string(forKey: Keys.token) {
            APIClient.shared.baseURL = url
            APIClient.shared.token = token
            do {
                let me: UserDto = try await APIClient.shared.get("/Users/Me")
                APIClient.shared.user = me
                user = me
                phase = .signedIn
                return
            } catch {
                // token 失效，继续尝试凭据自动登录
            }
        }
        // 2. 账号密码自动登录
        if let username = defaults.string(forKey: Keys.username),
           let server = defaults.string(forKey: Keys.serverURL) {
            // 钥匙串读取是同步 XPC：这是启动路径，必须挪出主线程（首帧之前）
            let stored = await KeychainHelper.readAsync(account: username)
            if let password = stored ?? defaults.string(forKey: Keys.legacyPassword) {
                do {
                    try await login(server: server, username: username, password: password)
                    return
                } catch {
                    print("[AppState] auto login failed: \(error)")
                }
            }
        }
        // 3. 无法恢复：停在登录页（保留凭据，服务器恢复后下次启动可自动登录）
        APIClient.shared.reset()
        user = nil
        libraries = []
        phase = .signedOut
    }

    /// 一次性迁移：旧版本把密码明文写在 UserDefaults 里。
    /// 读到即搬进钥匙串，并在**写入成功之后**才删除明文条目。
    private func migrateLegacyPassword() async {
        guard let username = defaults.string(forKey: Keys.username),
              let legacy = defaults.string(forKey: Keys.legacyPassword) else { return }
        if await KeychainHelper.saveAsync(password: legacy, account: username) {
            defaults.removeObject(forKey: Keys.legacyPassword)
        }
    }

    /// 设置里关掉「启动时自动连接」：直接停在登录页，不尝试恢复会话（保留已存凭据供手动登录）
    func prepareWithoutAutoConnect() {
        didAttemptRestore = true
        APIClient.shared.reset()
        user = nil
        libraries = []
        phase = .signedOut
    }

    func loadLibraries() async {
        guard let userId = APIClient.shared.user?.id else { return }
        do {
            let result: QueryResult<BaseItemDto> = try await APIClient.shared.get("/Users/\(userId)/Views")
            let allowed: Set<String> = ["movies", "tvshows", "music", "mixed", "homevideos", "boxsets", "books"]
            libraries = (result.items ?? []).filter { lib in
                guard let type = lib.collectionType else { return false }
                return allowed.contains(type)
            }
        } catch {
            // 侧栏只显示主菜单即可，忽略错误
        }
    }

    func logout() {
        APIClient.shared.reset()
        user = nil
        libraries = []
        let account = defaults.string(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.token)
        defaults.removeObject(forKey: Keys.username)
        // 历史遗留的明文条目一并清掉
        defaults.removeObject(forKey: Keys.legacyPassword)
        phase = .signedOut
        // 钥匙串删除也是同步 XPC：先切到登录页，再在后台清理凭据
        Task {
            if let account {
                await KeychainHelper.deleteAsync(account: account)
            }
            await KeychainHelper.deleteAsync(account: KeychainHelper.tokenAccount)
        }
    }

    /// 服务器地址规范化：补协议、去尾部斜杠
    private func normalize(server rawServer: String) -> String {
        var server = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.contains("://") { server = "http://" + server }
        while server.hasSuffix("/") { server.removeLast() }
        return server
    }
}
