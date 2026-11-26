import Foundation

/// 播放地址规范化。
///
/// QQ 音乐 vkey 与网易云取流接口返回的 purl 绝大多数落在 `http://` 上：
/// `http://ws.stream.qqmusic.qq.com/...`、`http://aqqmusic.tc.qq.com/...`、
/// `http://m702.music.126.net/...`。这些主机本身都支持 TLS，但把 http 地址
/// 直接交给 `AudioStreaming` 会让底层 URLSession 撞上 ATS
/// （`NSURLErrorAppTransportSecurityRequiresSecureConnection`, -1022），
/// 表现为「点播放一直转圈、进度条停在 0:00」。
///
/// 这里做两层：
/// 1. Info.plist 已开 `NSAllowsArbitraryLoads`，http 本身可通；
/// 2. 已知支持 TLS 的 CDN 统一升级成 https，少走一次明文握手，也能绕开
///    运营商对 80 端口的劫持。
nonisolated enum PlaybackURLNormalizer {
    /// 已知可 TLS 的音频 CDN。命中则把 scheme 换成 https。
    private static let secureHostSuffixes = [
        "music.126.net",
        "qqmusic.qq.com",
        "stream.qqmusic.qq.com",
        "aqqmusic.tc.qq.com",
        "isure.stream.qqmusic.qq.com",
        "dl.stream.qqmusic.qq.com",
        "ws.stream.qqmusic.qq.com",
        "ws6.stream.qqmusic.qq.com",
        "y.qq.com",
        "music.163.com",
        "migu.com",
    ]

    static func normalize(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host?.lowercased(),
              !host.isEmpty else {
            return url
        }
        let tlsCapable = secureHostSuffixes.contains { suffix in
            host == suffix || host.hasSuffix("." + suffix)
        }
        guard tlsCapable else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "https"
        return components?.url ?? url
    }

    /// 同样规则作用在字符串上，供 `purl` 拼接后直接规范化。
    static func normalize(rawURL: String) -> URL? {
        guard let url = URL(string: rawURL) else { return nil }
        return normalize(url)
    }
}

/// 播放链路诊断日志。
///
/// 用户设备上没有控制台可看，所有关键节点写进这个环形缓冲，
/// 设置 → 关于 → 音频诊断 里原文展示，截图即可复现问题。
nonisolated final class QQPlaybackDiagnostics: @unchecked Sendable {
    static let shared = QQPlaybackDiagnostics()

    private let lock = NSLock()
    private var storage: [String] = []
    private let limit = 160
    private let formatter: DateFormatter

    private init() {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        self.formatter = formatter
    }

    func log(_ message: String) {
        lock.lock()
        let line = "[\(formatter.string(from: Date()))] \(message)"
        storage.append(line)
        if storage.count > limit {
            storage.removeFirst(storage.count - limit)
        }
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
    }
}
