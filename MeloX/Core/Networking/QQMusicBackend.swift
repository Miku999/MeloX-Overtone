import Foundation

/// 数据源开关。默认使用 QQ 音乐；把 UserDefaults 里的值设为 false
/// 即可在不改代码的情况下回退到原网易云链路。
nonisolated enum QQMusicBackend {
    static let enabledKey = "qq.melox.backend.enabled.v1"

    /// 编译期总开关：设为 false 可彻底移除 QQ 链路并保留原网易云行为。
    static let compilationEnabled = true

    static var enabled: Bool {
        get {
            guard compilationEnabled else { return false }
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: enabledKey) != nil else { return true }
            return defaults.bool(forKey: enabledKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
        }
    }
}
