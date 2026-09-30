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
        static let password = "password"
    }
    private let defaults = UserDefaults.standard
    /// 会话恢复只执行一次（视图重建/重复 task 时避免并发竞态）
    private var didAttemptRestore = false

    var hasSavedSession: Bool {
        defaults.string(forKey: Keys.serverURL) != nil && defaults.string(forKey: Keys.token) != nil
    }

    func login(server rawServer: String, username: String, password: String) async throws {
        var server = rawServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !server.contains("://") { server = "http://" + server }
        while server.hasSuffix("/") { server.removeLast() }
        guard let url = URL(string: server) else { throw APIError.invalidURL }

        APIClient.shared.baseURL = url
        let body = try JSONEncoder().encode(AuthRequest(username: username, password: password))
        let response: AuthenticateResponse = try await APIClient.shared.post("/Users/AuthenticateByName", body: body)
        APIClient.shared.token = response.accessToken
        APIClient.shared.user = response.user
        defaults.set(server, forKey: Keys.serverURL)
        defaults.set(response.accessToken, forKey: Keys.token)
        // 保存凭据：下次启动自动登录（Keychain 为主，UserDefaults 兜底）
        defaults.set(username, forKey: Keys.username)
        defaults.set(password, forKey: Keys.password)
        _ = KeychainHelper.save(password: password, account: username)
        user = response.user
        phase = .signedIn
    }

    /// 启动恢复：token 有效直接进入；失效则用保存的账号密码自动重新登录
    func restoreSession() async {
        guard !didAttemptRestore else { return }
        defer { didAttemptRestore = true }
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
            let password = KeychainHelper.read(account: username) ?? defaults.string(forKey: Keys.password)
            if let password {
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
        if let username = defaults.string(forKey: Keys.username) {
            KeychainHelper.delete(account: username)
        }
        defaults.removeObject(forKey: Keys.serverURL)
        defaults.removeObject(forKey: Keys.token)
        defaults.removeObject(forKey: Keys.username)
        defaults.removeObject(forKey: Keys.password)
        phase = .signedOut
    }
}
