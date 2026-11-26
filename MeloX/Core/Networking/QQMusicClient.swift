import Foundation

/// 轻量 HTTP 传输层，只负责发请求与解码，不含任何网易云加密逻辑。
/// QQ 音乐全部公开 CGI 均为明文 JSON（POST musicu.fcg / GET *.qq.com）。
///
/// 与 `NeteaseDirectClient` 一样是 `@MainActor` 类型：网络请求本身是 async，
/// 不在主线程阻塞；同 actor 调用避免 `[String: Any]` 与模型跨 actor 传递。
@MainActor
final class QQMusicClient {
    static let shared = QQMusicClient()

    private let session: URLSession
    private let userAgent: String
    private let referer: String

    init(
        session: URLSession = .shared,
        userAgent: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        referer: String = "https://y.qq.com/"
    ) {
        self.session = session
        self.userAgent = userAgent
        self.referer = referer
    }

    // MARK: - 通用请求

    func getJSON<Response: Decodable>(
        _ url: URL,
        timeout: TimeInterval = 20
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
        timeout: TimeInterval = 20
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

    /// 登录态：有 Cookie 就整串带上，`uin` / `qqmusic_key` 决定接口返回个性化数据。
    private static func applyAuth(_ request: inout URLRequest) {
        let header = QQAuthStore.cookieHeader
        guard !header.isEmpty else { return }
        request.setValue(header, forHTTPHeaderField: "Cookie")
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
        request.timeoutInterval = 20
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response)
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) else {
            throw APIError.invalidResponse
        }
        return text
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

    func musicu<Response: Decodable>(
        body: [String: Any],
        timeout: TimeInterval = 20
    ) async throws -> Response {
        guard let url = URL(string: "https://u.y.qq.com/cgi-bin/musicu.fcg") else {
            throw APIError.requestEncoding
        }
        return try await postJSON(url, body: body, timeout: timeout)
    }
}
