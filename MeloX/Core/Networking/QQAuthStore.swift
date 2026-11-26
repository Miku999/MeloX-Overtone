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

    /// 登录方式：1 = QQ，2 = 微信。
    ///
    /// `musicu.fcg` 的 `comm.tmeLoginType` 必须与真实方式一致，
    /// 微信登录的 cookie 塞成 1 时服务端按「凭证类型不匹配」处理，
    /// 表现为 code 0 但 purl 全空。
    static var loginType: Int {
        let header = cookieHeader.lowercased()
        guard !header.isEmpty else { return 1 }
        if header.contains("wxuin=") || header.contains("wxskey=")
            || header.contains("wx_refresh_token=") {
            return 2
        }
        return 1
    }

    /// vkey 请求的设备号。32 位十六进制，首次启动生成后持久化。
    /// QQ 侧用 guid 做频控与风控画像，每次随机容易被判异常。
    static var guid: String {
        let key = "qq.melox.auth.guid.v1"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), existing.count == 32 {
            return existing
        }
        var raw = ""
        for _ in 0..<32 {
            raw += String(format: "%x", Int.random(in: 0...15))
        }
        defaults.set(raw, forKey: key)
        return raw
    }

    /// 诊断用：cookie 名列表（不含值），便于判断 qqmusic_key 有没有抓到。
    static var cookieNames: [String] {
        let header = cookieHeader
        guard !header.isEmpty else { return [] }
        return header.split(separator: ";").compactMap { pair in
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { return nil }
            let name = String(trimmed[..<separator])
            return name.isEmpty ? nil : name
        }
    }

    /// 取单个 cookie 值，找不到返回 nil。
    static func cookieValue(_ name: String) -> String? {
        let header = cookieHeader
        guard !header.isEmpty else { return nil }
        let prefix = name + "="
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix) else { continue }
            let value = String(trimmed.dropFirst(prefix.count))
            if !value.isEmpty { return value }
        }
        return nil
    }

    /// `musicu.fcg` 的 CSRF token，算法是腾讯通用的 hash33。
    ///
    /// 取 `p_skey` 优先，其次 `skey`，最后退回 `qqmusic_key`。
    /// vkey 接口对 `g_tk` 校验不严，但缺了会被当成「来源不明」的网页请求，
    /// 登录态下也可能只回空 purl。
    static var gTk: Int {
        let key = cookieValue("p_skey")
            ?? cookieValue("skey")
            ?? cookieValue("qqmusic_key")
            ?? cookieValue("qm_keyst")
            ?? ""
        guard !key.isEmpty else { return 5381 }
        var hash = 5381
        for scalar in key.unicodeScalars {
            hash = hash &+ ((hash << 5) &+ Int(scalar.value))
            hash &= 0x7FFF_FFFF
        }
        return hash
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
