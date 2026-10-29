import SwiftUI

/// 应用会话状态：负责「选哪个后端 → 登录 / 恢复会话 → 加载媒体库」。
///
/// 与改造前的区别：不再直接持有 `APIClient` 单例的可变字段，而是通过
/// `BackendRegistry` 取活动后端的 `MusicBackend` 实现；凭据按后端命名空间
/// 存进 `SessionPersistence`（钥匙串账号形如 `feiniu|用户名`，两台服务器上的
/// 同名用户不会再互相覆盖）。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Phase {
        case signedOut
        case signedIn
    }

    @Published var phase: Phase = .signedOut
    @Published var user: BackendUser?
    @Published var libraries: [MusicLibrary] = []
    /// 当前活动后端（设置页 / 登录页读写）
    @Published private(set) var backendKind: BackendKind = .jellyfin
    /// 自动登录过程中的状态（登录页显示进度用）
    @Published private(set) var isRestoring = false

    private let persistence = SessionPersistence.shared
    private var didAttemptRestore = false

    private init() {
        BackendRegistry.shared.factory = { kind in
            switch kind {
            case .jellyfin: return JellyfinBackend()
            case .feiniu: return FeiniuBackend()
            }
        }
        backendKind = BackendRegistry.shared.activeKind
        syncPlaybackPreferences()
    }

    // MARK: - 后端访问

    var backend: MusicBackend { BackendRegistry.shared.active }
    var capabilities: BackendCapabilities { backend.capabilities }

    /// 本地兜底数据的账号档案标识（**跨后端共享**）。
    ///
    /// 取归一化用户名：Jellyfin 的 `ravooo` 与飞牛的 `ravooo` 视为同一个人，
    /// 于是同一首歌在两边的播放进度/播放次数/收藏只记一份（见 `LocalLibraryState`）。
    /// 用户名拿不到时退回「后端 + 服务器」，至少不会把所有人混在一起。
    var profileKey: String {
        guard let session = backend.session else { return "anonymous" }
        let normalized = ContentIdentity.normalize(session.username)
        if !normalized.isEmpty { return normalized }
        return "\(backendKind.rawValue)|\(session.serverURL.host ?? "")"
    }

    // MARK: - 会话

    var hasSavedSession: Bool {
        persistence.loadSession(backendKind) != nil
    }

    /// 登录（成功后写会话、加载媒体库）
    func signIn(
        server: String,
        username: String,
        password: String,
        backend kind: BackendKind,
        accessCode: String? = nil
    ) async throws {
        BackendRegistry.shared.setActive(kind)
        backendKind = kind
        let target = BackendRegistry.shared.backend(for: kind)
        let request = SignInRequest(
            server: server,
            username: username,
            password: password,
            accessCode: accessCode,
            clientName: nil
        )
        var session = try await target.signIn(request)
        // 服务端用户 id / 显示名以会话为准
        if session.userID.isEmpty {
            session = BackendSession(
                backend: session.backend,
                serverURL: session.serverURL,
                username: session.username,
                token: session.token,
                userID: session.userID,
                userDisplayName: session.userDisplayName,
                extraCookie: session.extraCookie
            )
        }
        persistence.saveSession(session)
        persistence.storeAccessCode(accessCode, kind: kind)
        // 密码只进钥匙串（写入成功才认为凭据可用；失败不阻塞登录）
        _ = await persistence.savePassword(password, kind: kind, username: username)

        user = BackendUser(id: session.userID, name: session.userDisplayName, backend: kind)
        phase = .signedIn
        syncPlaybackPreferences()
        await loadLibraries()
        await MusicDataStore.shared.resetForBackendSwitch()
    }

    /// 启动恢复：token 有效直接进入；失效则用保存的账号密码自动重新登录
    func restoreSession() async {
        guard !didAttemptRestore else { return }
        defer { didAttemptRestore = true }
        isRestoring = true
        defer { isRestoring = false }

        // 旧版单后端数据 → Jellyfin 命名空间（只在新命名空间为空时迁移）
        persistence.migrateLegacyJellyfinCredentialsIfNeeded()
        await persistence.migrateLegacyPasswordIfNeeded()

        let kind = BackendRegistry.shared.activeKind
        backendKind = kind
        // 统一走「内存会话 → 磁盘会话 → 密码兜底」三级恢复；失败停在登录页
        // （保留凭据，服务器恢复后下次启动可自动登录）。
        _ = await activateBackend(kind)
    }

    /// 设置里关掉「启动时自动连接」：直接停在登录页，不尝试恢复会话
    func prepareWithoutAutoConnect() {
        didAttemptRestore = true
        user = nil
        libraries = []
        phase = .signedOut
    }

    /// 切换后端。**不注销旧后端**：已登录的凭证要原样留着，切回来免登录。
    ///
    /// 这里最容易写错的一行是「切之前先 `signOut()`」——那会向服务器吊销 token
    /// （Jellyfin 是 `POST /Sessions/Logout`），等于把刚登录的凭证作废，
    /// 用户切回去还得重新输密码。正确做法是：只切换「活动后端」，
    /// 旧后端的实例留在 `BackendRegistry` 缓存里（会话与 HTTP 客户端都还在）。
    func switchBackend(to kind: BackendKind) async {
        guard kind != backendKind else { return }
        await LocalLibraryState.shared.flushNow()
        // 旧后端的队列/播放源属于旧服务器，切走后继续播会串后端（封面、上报都会错乱）
        MusicPlayerModel.shared.clearQueue()
        BackendRegistry.shared.setActive(kind)
        backendKind = kind
        user = nil
        libraries = []
        _ = await activateBackend(kind)
    }

    /// 登录页里切换服务器类型：目标后端有已保存凭证就直接进去，没有就留在登录页。
    func activateFromLogin(_ kind: BackendKind) async {
        let hasMemorySession = BackendRegistry.shared.backend(for: kind).session != nil
        let hasStoredSession = persistence.loadSession(kind) != nil
        let hasPassword = persistence.lastUsername(kind) != nil
        guard hasMemorySession || hasStoredSession || hasPassword else { return }
        await LocalLibraryState.shared.flushNow()
        BackendRegistry.shared.setActive(kind)
        backendKind = kind
        user = nil
        libraries = []
        _ = await activateBackend(kind)
    }

    /// 激活某个后端的登录态：内存会话 → 磁盘会话（校验）→ 账号密码兜底。
    /// 返回是否成功进入已登录状态；失败时把会话状态复位到 `signedOut`。
    @discardableResult
    func activateBackend(_ kind: BackendKind) async -> Bool {
        let target = BackendRegistry.shared.backend(for: kind)

        // 1. 内存里已有会话（本次启动内登录过 / 刚从另一个后端切回来）。
        //    `userID` 为空说明是旧版迁移来的会话，没经过 `/Users/Me` 校验 —— 交给第 2 步。
        if let session = target.session, !session.userID.isEmpty {
            user = BackendUser(
                id: session.userID,
                name: session.userDisplayName,
                backend: kind
            )
            phase = .signedIn
            syncPlaybackPreferences()
            await loadLibraries()
            await MusicDataStore.shared.resetForBackendSwitch()
            return true
        }

        // 2. 磁盘上有会话：校验 token / cookie 是否仍有效
        if let stored = persistence.loadSession(kind) {
            do {
                let me = try await target.validateSession(stored)
                persistence.saveSession(target.session ?? stored)
                user = me
                phase = .signedIn
                syncPlaybackPreferences()
                await loadLibraries()
                await MusicDataStore.shared.resetForBackendSwitch()
                return true
            } catch {
                // token/cookie 失效（服务端重启、凭证过期、中继地址变化等）→ 走密码兜底
                print("[AppState] \(kind.rawValue) session invalid: \(error)")
            }
        }

        // 3. 用保存的账号密码自动登录（钥匙串里按后端命名空间存的）
        if let username = persistence.lastUsername(kind),
           let server = persistence.lastServerURL(kind),
           let password = await persistence.password(kind: kind, username: username) {
            do {
                try await signIn(
                    server: server,
                    username: username,
                    password: password,
                    backend: kind,
                    accessCode: persistence.accessCode(kind)
                )
                return true
            } catch {
                print("[AppState] auto login failed for \(kind.rawValue): \(error)")
            }
        }

        // 4. 无法恢复：停在登录页（凭据保留，下次可再试）
        await resetToSignedOut()
        return false
    }

    func loadLibraries() async {
        guard phase == .signedIn else { return }
        do {
            libraries = try await backend.libraries()
        } catch {
            // 侧栏只显示主菜单即可，忽略错误
            libraries = []
        }
    }

    func logout() async {
        // 先把 debounce 中的进度落盘，再清会话（本地数据按账号作用域保留）
        await LocalLibraryState.shared.flushNow()
        // 队列快照也属于当前账号：不清掉的话，同后端重新登录会「复活」登出前的队列。
        MusicPlayerModel.shared.clearQueue()
        let username = backend.session?.username
        await backend.signOut()
        persistence.clearSession(backendKind)
        user = nil
        libraries = []
        MusicDataStore.shared.clearAll()
        phase = .signedOut
        if let username {
            await persistence.deletePassword(kind: backendKind, username: username)
        }
    }

    /// 把设置页的播放偏好同步给活动后端（音质 / 直连优先 / 音量均衡）
    func syncPlaybackPreferences() {
        let settings = AppSettings.shared
        var preferences = PlaybackPreferences()
        preferences.preferDirectPlay = settings.preferDirectPlay
        preferences.targetBitrate = settings.quality.bitrate
        preferences.normalizeVolume = settings.volumeNormalization
        backend.playbackPreferences = preferences
    }

    private func resetToSignedOut() async {
        user = nil
        libraries = []
        phase = .signedOut
    }
}
