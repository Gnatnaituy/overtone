import Foundation
import Security

/// 钥匙串封装：保存/读取 Jellyfin 密码用于启动自动登录
enum KeychainHelper {
    private static let service = "com.jellyfin.mac-client"

    static func save(password: String, account: String) -> Bool {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary) // 先删旧值
        var attrs = query
        attrs[kSecValueData as String] = data
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - 异步封装

/// `SecItem*` 是**同步** XPC 往返（典型 1–10ms，securityd 繁忙或被锁时更久）。
/// 调用点全在主 actor 上 —— 启动自动登录（`AppState.restoreSession`）、登录、退出登录 ——
/// 同步调用会把这段时间直接压在主线程上（启动路径上尤其明显，发生在首帧之前）。
/// 这里统一挪到后台线程。
extension KeychainHelper {
    static func readAsync(account: String) async -> String? {
        await Task.detached(priority: .userInitiated) { read(account: account) }.value
    }

    static func saveAsync(password: String, account: String) async {
        await Task.detached(priority: .utility) {
            _ = save(password: password, account: account)
        }.value
    }

    static func deleteAsync(account: String) async {
        await Task.detached(priority: .utility) { delete(account: account) }.value
    }
}
