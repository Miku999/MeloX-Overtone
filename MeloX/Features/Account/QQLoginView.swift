import SwiftUI
import WebKit

/// QQ 音乐登录页。
///
/// 直接加载 `y.qq.com` 的官方网页登录，登录完成后从 WKWebView 的 Cookie
/// 存储里读 `qqmusic_key` / `uin`，写入 `QQAuthStore`。
/// 走官方网页流程，不自己拼扫码签名，避开风控与接口变动。
struct QQLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library

    @State private var page: WebPage

    init() {
        _page = State(initialValue: QQWebCookieStore.makePage())
    }

    var body: some View {
        WebView(page)
            .webViewBackForwardNavigationGestures(.enabled)
            .overlay(alignment: .top) {
                if page.isLoading {
                    ProgressView(value: page.estimatedProgress)
                        .progressViewStyle(.linear)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    Text("在页面里点右上角「登录」，用 QQ 或微信扫码、或输入账号密码。登录成功会自动返回。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .navigationTitle("ui.settings.account.login")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ui.common.cancel", role: .cancel) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新登录页")
                }
            }
            .task {
                reload()
                await waitForQQCookie()
            }
    }

    private func reload() {
        guard let url = URL(string: "https://y.qq.com/") else { return }
        _ = page.load(url)
    }

    private func waitForQQCookie() async {
        while !Task.isCancelled {
            if let result = await QQWebCookieStore.authenticatedCookie() {
                QQAuthStore.save(cookieHeader: result.header, uin: result.uin)
                await library.refresh(force: true)
                dismiss()
                return
            }

            do {
                try await Task.sleep(for: .milliseconds(600))
            } catch {
                return
            }
        }
    }
}

@MainActor
enum QQWebCookieStore {
    private static let dataStore = WKWebsiteDataStore.default()

    static func makePage() -> WebPage {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = dataStore
        configuration.defaultNavigationPreferences.preferredContentMode = .desktop
        return WebPage(configuration: configuration)
    }

    /// 登录完成的判据是拿到 `qqmusic_key`（或 `qm_keyst`）。
    static func authenticatedCookie() async -> (header: String, uin: Int)? {
        let cookies = await allCookies()
            .filter(isQQCookie)
            .filter { $0.expiresDate.map { $0 > Date() } ?? true }
        let values = cookies.reduce(into: [String: String]()) { result, cookie in
            guard !cookie.value.isEmpty else { return }
            result[cookie.name] = cookie.value
        }
        guard let key = values["qqmusic_key"] ?? values["qm_keyst"], !key.isEmpty else {
            return nil
        }

        let uinRaw = values["uin"] ?? values["p_uin"] ?? ""
        let digits = uinRaw.filter { $0.isNumber }
        let header = values.keys.sorted()
            .map { "\($0)=\(values[$0] ?? "")" }
            .joined(separator: "; ")
        return (header, Int(digits) ?? 0)
    }

    static func clear() async {
        for cookie in await allCookies() where isQQCookie(cookie) {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }

    private static func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }

    private static func isQQCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == "qq.com" || domain.hasSuffix(".qq.com")
    }
}
