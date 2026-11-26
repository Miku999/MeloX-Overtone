import Foundation

/// 轻量 HTTP 传输层，只负责发请求与解码，不含任何网易云加密逻辑。
/// QQ 音乐全部公开 CGI 均为明文 JSON（POST musicu.fcg / GET *.qq.com）。
///
/// 隔离说明：这里必须 `nonisolated`。项目默认 `SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor`，若本类型留在主 actor 上，`JSONSerialization` 构体与
/// `JSONDecoder` 解码会全部排到主线程；首页一次拉 4 个榜单 × 6 首榜时
/// 就是十几份解码同时在主线程排队，表现为「划两下就卡死」。
/// 标成 `nonisolated` 后请求与解码都在后台执行，主 actor 只接收最终模型。
nonisolated final class QQMusicClient: @unchecked Sendable {
    static let shared = QQMusicClient()

    private let session: URLSession
    private let userAgent: String
    private let referer: String

    init(
        session: URLSession = QQMusicClient.makeSession(),
        userAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        referer: String = "https://y.qq.com/"
    ) {
        self.session = session
        self.userAgent = userAgent
        self.referer = referer
    }

    /// 独立 session：并发上限收紧到 6，请求超时压到 12 秒。
    /// 用 `.shared` 时首页的十几路请求会互相排队，且默认 60 秒超时
    /// 会让一次失败拖住整个首屏。
    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = ["Accept-Encoding": "gzip, deflate"]
        return URLSession(configuration: configuration)
    }

    // MARK: - 通用请求

    func getJSON<Response: Decodable>(
        _ url: URL,
        timeout: TimeInterval = 12
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        Self.applyAuth(&request)
        return try await perform(request)
    }

    func postJSON<Response: Decodable>(
        _ url: URL,
        body: [String: Any],
        timeout: TimeInterval = 12
    ) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        Self.applyAuth(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    /// 登录态注入。
    ///
    /// 这里有两层，缺一不可：
    /// 1. `HTTPCookieStorage` —— URLSession **不允许**通过 `setValue` 手动设置
    ///    `Cookie` 请求头，手写的头会被 session 自己的 cookie storage 覆盖。
    ///    必须把 `uin` / `qqmusic_key` 解析成 `HTTPCookie` 塞进 storage，
    ///    请求才会真的带上登录态。上一版只做了第 2 步，所以登录后所有接口
    ///    仍然是匿名调用，vkey 一律返回空 purl —— 播放转圈就是这么来的。
    /// 2. `setValue` —— 对少数不走 cookie storage 的 CGI 作为兜底。
    private static func applyAuth(_ request: inout URLRequest) {
        let header = QQAuthStore.cookieHeader
        guard !header.isEmpty else { return }
        syncCookies(header)
        request.setValue(header, forHTTPHeaderField: "Cookie")
    }

    /// 上次同步过的 Cookie 串。只在内容变化时重新解析，避免每次请求都建 cookie。
    nonisolated(unsafe) private static var lastSyncedCookieHeader = ""
    private static let cookieLock = NSLock()
    private static let cookieDomains = [".qq.com", ".y.qq.com", ".u.y.qq.com", ".c.y.qq.com"]

    private static func syncCookies(_ header: String) {
        cookieLock.lock()
        defer { cookieLock.unlock() }
        guard lastSyncedCookieHeader != header else { return }
        lastSyncedCookieHeader = header

        let storage = HTTPCookieStorage.shared
        let expires = Date().addingTimeInterval(60 * 60 * 24 * 30)
        for pair in header.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let name = String(trimmed[..<separator])
            let value = String(trimmed[trimmed.index(after: separator)...])
            guard !name.isEmpty, !value.isEmpty else { continue }
            for domain in cookieDomains {
                let properties: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: domain,
                    .path: "/",
                    .secure: "TRUE",
                    .expires: expires,
                ]
                guard let cookie = HTTPCookie(properties: properties) else { continue }
                storage.setCookie(cookie)
            }
        }
    }

    /// 退出登录时清掉域名下的 QQ cookie，避免下次启动仍带旧凭证。
    static func clearCookies() {
        cookieLock.lock()
        lastSyncedCookieHeader = ""
        cookieLock.unlock()
        let storage = HTTPCookieStorage.shared
        for cookie in storage.cookies ?? [] where cookie.domain.hasSuffix("qq.com") {
            storage.deleteCookie(cookie)
        }
    }

    /// 部分 QQ CGI 会返回 JSONP 包裹（callback(...)），这里剥壳后解码。
    func getJSONP<Response: Decodable>(
        _ url: URL,
        strippingPrefix prefix: String = ""
    ) async throws -> Response {
        let text = try await getText(url)
        var json = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prefix.isEmpty, json.hasPrefix(prefix) {
            json = String(json.dropFirst(prefix.count))
        }
        if let open = json.firstIndex(of: "{"), let close = json.lastIndex(of: "}") {
            json = String(json[open...close])
        } else if let open = json.firstIndex(of: "["), let close = json.lastIndex(of: "]") {
            json = String(json[open...close])
        }
        guard let data = json.data(using: .utf8) else {
            throw APIError.invalidResponse
        }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private func getText(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        Self.applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw APIError.invalidResponse
        }
        return text
    }

    /// 原样取回字节，供需要宽松解析（字段类型不稳定）的 CGI 使用。
    func getData(_ url: URL, timeout: TimeInterval = 12) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        Self.applyAuth(&request)
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        return data
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        try Self.validate(response)
        guard !data.isEmpty else { throw APIError.invalidResponse }
        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw APIError.invalidResponse
        }
    }

    private static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.server(statusCode: http.statusCode, message: "QQMusic HTTP \(http.statusCode)")
        }
    }

    // MARK: - musicu.fcg 通用封装

    /// 构造 musicu.fcg 的 comm 段，与 QQ 音乐轻量客户端一致。
    /// 已登录时把 `uin` / `authst` 换成真实值，匿名调用一律 0 / 空串。
    static func comm(
        ct: Int = 11,
        cv: String = "1003006"
    ) -> [String: Any] {
        let loggedIn = QQAuthStore.isLoggedIn
        return [
            "ct": ct,
            "cv": cv,
            "uin": loggedIn ? QQAuthStore.uin : 0,
            "tmeAppID": "qqmusiclight",
            "authst": loggedIn ? QQAuthStore.authst : "",
            "tmeLoginType": loggedIn ? 2 : 0,
            "psrf_qqaccess_token": "",
            "psrf_qqopenid": "",
            "psrf_qqunionid": "",
        ]
    }

    /// vkey 链路的 comm 段。`uin` 必须是字符串，与 `loginUin` 保持同型，
    /// 型别不一致时服务端会按匿名处理并直接返回空 purl。
    static func vkeyComm() -> [String: Any] {
        let loggedIn = QQAuthStore.isLoggedIn
        let uin = loggedIn ? String(QQAuthStore.uin) : "0"
        return [
            "ct": 24,
            "cv": 0,
            "uin": uin,
            "authst": loggedIn ? QQAuthStore.authst : "",
            "tmeLoginType": loggedIn ? 2 : 0,
        ]
    }

    /// 当前请求应使用的 uin 字符串。未登录为 "0"。
    static var uinString: String {
        QQAuthStore.isLoggedIn ? String(QQAuthStore.uin) : "0"
    }

    func musicu<Response: Decodable>(
        body: [String: Any],
        timeout: TimeInterval = 12
    ) async throws -> Response {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else {
            throw APIError.requestEncoding
        }
        return try await postJSON(url, body: body, timeout: timeout)
    }
}
