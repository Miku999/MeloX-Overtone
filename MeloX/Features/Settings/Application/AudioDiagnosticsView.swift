import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 音频链路诊断页。
///
/// 用户设备上没有控制台可看，播放失败时只能靠截图沟通。
/// 这一页把「登录态 / vkey 响应 / 镜像响应 / 播放器日志」全部摊开，
/// 一眼就能定位是 cookie 没带上、purl 为空、还是媒体流被拒。
struct AudioDiagnosticsView: View {
    @State private var reports: [String] = []
    @State private var isRunning = false
    @State private var logLines: [String] = []

    var body: some View {
        Form {
            Section {
                Button {
                    Task { await runDiagnostics() }
                } label: {
                    HStack {
                        Label("运行诊断", systemImage: "waveform.path.ecg")
                        Spacer()
                        if isRunning {
                            ProgressView()
                        }
                    }
                }
                .disabled(isRunning)
            } footer: {
                Text("依次检测登录 Cookie、QQ vkey 申请、公开镜像取流，结果可直接截图。")
            }

            if !reports.isEmpty {
                Section("诊断结果") {
                    ForEach(reports.indices, id: \.self) { index in
                        Text(reports[index])
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Section {
                    ShareLink(item: reports.joined(separator: "\n")) {
                        Label("导出报告", systemImage: "square.and.arrow.up")
                    }
                }
            }

            Section {
                if logLines.isEmpty {
                    Text("暂无播放日志。先回首页播一首歌，再回来看这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(logLines.indices, id: \.self) { index in
                        Text(logLines[index])
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } header: {
                Text("播放日志")
            } footer: {
                Text("只保留最近 160 条，退出 App 后清空。")
            }

            Section {
                Button(role: .destructive) {
                    QQPlaybackDiagnostics.shared.clear()
                    logLines = []
                } label: {
                    Text("清空播放日志")
                }
            }
        }
        .navigationTitle("音频诊断")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            logLines = Array(QQPlaybackDiagnostics.shared.snapshot().reversed())
        }
    }

    // MARK: - 诊断流程

    private func runDiagnostics() async {
        isRunning = true
        defer {
            isRunning = false
            logLines = Array(QQPlaybackDiagnostics.shared.snapshot().reversed())
        }

        var result: [String] = []
        result.append(contentsOf: environmentSnapshot())

        // 1. 登录态：cookie 名 + 长度，不打印值本身。
        let names = QQAuthStore.cookieNames
        let authst = QQAuthStore.authst
        result.append("cookie 条数: \(names.count)")
        result.append("cookie 名: \(names.sorted().joined(separator: ","))")
        result.append("qqmusic_key 长度: \(authst.count) 前缀: \(String(authst.prefix(4)))")
        result.append("uin: \(QQAuthStore.uin)  loginType: \(QQAuthStore.loginType)")

        // 2. 登录态服务端确认。
        result.append(contentsOf: await probeLogin())

        // 3. QQ 搜索 + vkey 实测。
        if let hit = await qqSearch(keyword: "甲乙丙丁") {
            result.append("QQ 搜索命中: \(hit.name) / \(hit.artist) mid=\(hit.songMID)")
            result.append(contentsOf: await probeVkey(songMID: hit.songMID, mediaMID: hit.mediaMID))
        } else {
            result.append("QQ 搜索失败：未拿到 songmid")
        }

        // 4. 公开镜像。
        result.append(contentsOf: await probeMirror(name: "甲乙丙丁", artist: "李佳薇"))

        reports = result
    }

    private func environmentSnapshot() -> [String] {
        var lines: [String] = []
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        lines.append("版本: \(version) (\(build))")
        #if os(iOS)
        lines.append("设备: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
        #else
        lines.append("设备: macOS")
        #endif
        lines.append("ATS: 由 Info.plist 控制（NSAllowsArbitraryLoads）")
        return lines
    }

    // MARK: - 单项探测

    /// `music.UserInfo.getLoginUserInfo` 在登录态下会回带 uin，
    /// 匿名时 uin 缺失或为 0。这是判断「cookie 到底有没有送到服务端」最快的一步。
    private func probeLogin() async -> [String] {
        let body: [String: Any] = [
            "comm": QQMusicClient.comm(ct: 24, cv: "0"),
            "req": [
                "module": "music.UserInfo.getLoginUserInfo",
                "method": "getLoginUserInfo",
                "param": [:],
            ],
        ]
        do {
            let data = try await QQMusicClient.shared.musicuRaw(body: body, timeout: 10)
            let text = String(data: data, encoding: .utf8) ?? ""
            if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let req = root["req"] as? [String: Any] {
                let code = req["code"] as? Int ?? -1
                let payload = req["data"] as? [String: Any] ?? [:]
                let uin = payload["uin"] as? Int ?? 0
                let nickname = payload["nick"] as? String ?? (payload["nickname"] as? String ?? "")
                return [
                    "登录探测: code=\(code) uin=\(uin) nick=\(nickname)",
                    text.isEmpty ? "登录探测: 空响应" : "登录探测原文: \(String(text.prefix(240)))",
                ]
            }
            return ["登录探测: 无法解析 \(String(text.prefix(200)))"]
        } catch {
            return ["登录探测失败: \(error)"]
        }
    }

    private func qqSearch(keyword: String) async -> (name: String, artist: String, songMID: String, mediaMID: String)? {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "w", value: keyword),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "n", value: "3"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "t", value: "0"),
        ]
        guard let url = components.url else { return nil }
        do {
            let data = try await QQMusicClient.shared.getData(url, timeout: 10)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = root["data"] as? [String: Any],
                  let song = payload["song"] as? [String: Any],
                  let list = song["list"] as? [[String: Any]],
                  let first = list.first else { return nil }
            let name = first["songname"] as? String ?? ""
            let mid = first["songmid"] as? String ?? ""
            var mediaMID = mid
            if let file = first["file"] as? [String: Any],
               let value = file["media_mid"] as? String, !value.isEmpty {
                mediaMID = value
            }
            var artist = ""
            if let singers = first["singer"] as? [[String: Any]] {
                artist = singers.compactMap { $0["name"] as? String }.joined(separator: " ")
            }
            guard !mid.isEmpty else { return nil }
            return (name, artist, mid, mediaMID)
        } catch {
            return nil
        }
    }

    private func probeVkey(songMID: String, mediaMID: String) async -> [String] {
        let uin = QQMusicClient.uinString
        let ladder: [(prefix: String, suffix: String)] = [
            ("M800", "mp3"), ("M500", "mp3"), ("C400", "m4a"),
        ]
        let filenames = [mediaMID, songMID].flatMap { mid in
            ladder.map { "\($0.prefix)\(mid).\($0.suffix)" }
        }
        let body: [String: Any] = [
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": filenames,
                    "guid": QQAuthStore.guid,
                    "songmid": Array(repeating: songMID, count: filenames.count),
                    "songtype": Array(repeating: 0, count: filenames.count),
                    "uin": uin,
                    "loginflag": 1,
                    "platform": "20",
                    "ctx": 1,
                ],
            ],
            "loginUin": uin,
            "comm": QQMusicClient.vkeyComm(),
        ]
        do {
            let data = try await QQMusicClient.shared.musicuVkeyRaw(body: body, timeout: 10)
            let text = String(data: data, encoding: .utf8) ?? ""
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["vkey: 无法解析 \(String(text.prefix(200)))"]
            }
            guard let req1 = (root["req_1"] as? [String: Any])
                ?? (root["req_0"] as? [String: Any]) else {
                return ["vkey: 响应缺少 req 段 \(String(text.prefix(200)))"]
            }
            let code = req1["code"] as? Int ?? -1
            let payload = req1["data"] as? [String: Any] ?? [:]
            let sip = (payload["sip"] as? [Any])?.compactMap { $0 as? String }.first ?? "-"
            let infos = payload["midurlinfo"] as? [[String: Any]] ?? []
            let purls = infos.compactMap { $0["purl"] as? String }.filter { !$0.isEmpty }
            let results = infos.compactMap { $0["result"] as? Int }
            return [
                "vkey: code=\(code) sip=\(sip)",
                "vkey: purl 非空 \(purls.count)/\(infos.count) result=\(Set(results).sorted())",
                purls.first.map { "vkey: purl 样例 \(String($0.prefix(90)))" } ?? "vkey: purl 全空",
            ]
        } catch {
            return ["vkey 请求失败: \(error)"]
        }
    }

    private func probeMirror(name: String, artist: String) async -> [String] {
        do {
            let candidates = try await QQMateMirror.search(name: name, artist: artist)
            guard let top = candidates.first else { return ["镜像: 搜索无结果"] }
            let source = try await QQMateMirror.playbackSource(name: name, artist: artist)
            return [
                "镜像: 候选 \(candidates.count) 条，首选 \(top.name) / \(top.artist)",
                "镜像: url=\(source.url.absoluteString.prefix(110))",
                "镜像: format=\(source.format ?? "-") bitrate=\(source.bitrate ?? 0)",
            ]
        } catch {
            return ["镜像失败: \(error)"]
        }
    }
}
