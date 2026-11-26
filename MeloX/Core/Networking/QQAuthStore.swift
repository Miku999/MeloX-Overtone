import Foundation

/// QQ 音乐登录态存储。
///
/// Cookie 来自 `y.qq.com` 网页登录（`uin` / `qqmusic_key` / `qm_keyst` / `p_skey` 等），
/// 与网易云一样只落本机 `UserDefaults`，不经过任何自有服务器。
///
/// 与 `QQMusicBackend` 同隔离域：不写 `nonisolated` 会被默认 MainActor 隔离，
/// 而 `QQMusicClient.comm()` 在后台构造请求体时需要读它。
nonisolated enum QQAuthStore {
    private static let cookieKey = "qq.melox.auth.cookie.v1"
    private static let uinKey = "qq.melox.auth.uin.v1"

    /// 完整 Cookie 头，形如 `uin=o0123; qqmusic_key=...; qm_keyst=...`。
    static var cookieHeader: String {
        UserDefaults.standard.string(forKey: cookieKey) ?? ""
    }

    /// QQ 号（纯数字）。未登录时为 0。
    static var uin: Int {
        UserDefaults.standard.integer(forKey: uinKey)
    }

    /// 登录态判据：拿到 `qqmusic_key` 或 `qm_keyst` 就算登录成功。
    static var isLoggedIn: Bool {
        !authst.isEmpty
    }

    /// `musicu.fcg` 的 `comm.authst` 字段。
    static var authst: String {
        let header = cookieHeader
        guard !header.isEmpty else { return "" }
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            for name in ["qqmusic_key", "qm_keyst"] {
                let prefix = name + "="
                if trimmed.hasPrefix(prefix) {
                    let value = String(trimmed.dropFirst(prefix.count))
                    if !value.isEmpty { return value }
                }
            }
        }
        return ""
    }

    /// 昵称缓存，账号页展示用；拿不到时返回空串。
    static var nickname: String {
        UserDefaults.standard.string(forKey: "qq.melox.auth.nickname.v1") ?? ""
    }

    static func save(cookieHeader: String, uin: Int) {
        let defaults = UserDefaults.standard
        defaults.set(cookieHeader, forKey: cookieKey)
        defaults.set(uin, forKey: uinKey)
    }

    static func saveNickname(_ value: String) {
        UserDefaults.standard.set(value, forKey: "qq.melox.auth.nickname.v1")
    }

    static func clear() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: cookieKey)
        defaults.removeObject(forKey: uinKey)
        defaults.removeObject(forKey: "qq.melox.auth.nickname.v1")
    }
}
