import Foundation

/// QQ 音乐的 `vkey.GetVkeyServer / CgiGetVkey` 在匿名（`uin = 0`）下对
/// 任何歌曲都返回 `result = 104003`（无权限），而 104003 的判定在服务端，
/// 客户端拿不到任何 purl。登录后也只对账号有权限的曲目放行。
///
/// 这层兜底解决「装了就是一直转圈」的问题：用 QQ 侧的「歌名 + 歌手」
/// 去网易云公开接口搜同名曲目，取可匿名访问的播放地址。
///
/// 取舍：
/// - 只用匿名可访问的 `/api/search/get` 与 `/api/song/enhance/player/url`，
///   不依赖任何账号。
/// - 搜索结果按「歌名归一化相等 + 歌手归一化相等」打分，过滤伴奏 / 铃声 /
///   纯音乐等明显不是同一首歌的条目；Live / 翻唱 / DJ 版保留，因为很多
///   曲目在网易云只有这些版本。
/// - 服务端对 VIP 曲目匿名只给 30 秒试听片段（约 480 KB）。命中片段时
///   记下但继续找，找到完整曲目就用完整的；全部候选都是片段时才用最大的那个。
nonisolated enum QQMateMirror {

    // MARK: - 对外入口

    /// 用歌名与歌手解析一条可播放的地址。全部候选失败时抛 `noPlayableSource`。
    static func playbackSource(name: String, artist: String) async throws -> PlaybackSource {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { throw APIError.noPlayableSource }

        let candidates = try await search(name: trimmedName, artist: artist)
        guard !candidates.isEmpty else { throw APIError.noPlayableSource }

        var partial: PlaybackSource?
        var partialSize = 0

        // 候选按得分降序，最多试 3 个：正常情况第一个就命中，失败才继续。
        for candidate in candidates.prefix(3) {
            guard let resolved = try? await resolve(songID: candidate.id) else { continue }
            if resolved.size >= fullTrackThreshold {
                return resolved.source
            }
            if resolved.size > partialSize {
                partialSize = resolved.size
                partial = resolved.source
            }
        }

        if let partial { return partial }
        throw APIError.noPlayableSource
    }

    /// 仅搜索，暴露出来便于调试与日志。
    static func search(name: String, artist: String) async throws -> [Candidate] {
        let keyword = artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? name
            : "\(name) \(artist)"

        guard var components = URLComponents(
            string: "https://music.163.com/api/search/get"
        ) else {
            throw APIError.requestEncoding
        }
        components.queryItems = [
            URLQueryItem(name: "s", value: keyword),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "offset", value: "0"),
        ]
        guard let url = components.url else { throw APIError.requestEncoding }

        let data = try await request(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let songs = result["songs"] as? [[String: Any]] else {
            return []
        }

        let targetName = normalize(name)
        let targetArtist = normalize(artist)

        var scored: [Candidate] = []
        for song in songs {
            let rawName = (song["name"] as? String) ?? ""
            guard !rawName.isEmpty else { continue }
            guard !isExcluded(rawName) else { continue }

            let rawArtist = artists(of: song)
            let candidateName = normalize(rawName)
            let candidateArtist = normalize(rawArtist)
            guard !candidateName.isEmpty else { continue }

            var score = 0
            if candidateName == targetName {
                score += 100
            } else if candidateName.contains(targetName) {
                score += 60
            } else if targetName.contains(candidateName) {
                score += 40
            } else {
                // 歌名对不上，只靠歌手无法确认是同一首，直接丢弃。
                continue
            }

            if !targetArtist.isEmpty {
                if candidateArtist == targetArtist {
                    score += 50
                } else if candidateArtist.contains(targetArtist)
                            || targetArtist.contains(candidateArtist) {
                    score += 30
                }
            } else {
                score += 10
            }

            guard let identifier = intValue(song["id"]) else { continue }
            scored.append(Candidate(
                id: identifier,
                name: rawName,
                artist: rawArtist,
                score: score
            ))
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.id < rhs.id
        }
    }

    // MARK: - 数据

    struct Candidate: Sendable {
        let id: Int
        let name: String
        let artist: String
        let score: Int
    }

    /// 约 60 秒以上的 128 kbps mp3 才会超过这个体积。低于它通常是试听片段。
    private static let fullTrackThreshold = 900_000

    /// 明显不是同一首歌的条目。
    private static let excludedTokens = [
        "伴奏", "纯音乐", "铃声", "片段", "抖音", "慢速", "加速", "dj版", "mashup",
    ]

    private static let userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 10
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: - 取流

    private static func resolve(
        songID: Int
    ) async throws -> (source: PlaybackSource, size: Int) {
        guard let url = URL(
            string: "https://music.163.com/api/song/enhance/player/url?ids=[\(songID)]&br=320000"
        ) else {
            throw APIError.requestEncoding
        }
        let data = try await request(url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["data"] as? [[String: Any]],
              let item = list.first else {
            throw APIError.noPlayableSource
        }

        let rawURL = (item["url"] as? String) ?? ""
        guard !rawURL.isEmpty, let resolvedURL = URL(string: rawURL) else {
            throw APIError.noPlayableSource
        }

        let size = intValue(item["size"]) ?? 0
        let bitrate = intValue(item["br"]) ?? 128_000
        let format = (item["type"] as? String) ?? "mp3"

        return (
            PlaybackSource(
                url: resolvedURL,
                bitrate: bitrate,
                format: format,
                quality: .standard
            ),
            size
        )
    }

    private static func request(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://music.163.com/", forHTTPHeaderField: "Referer")
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200...299).contains(http.statusCode) {
            throw APIError.server(statusCode: http.statusCode, message: "netease mirror")
        }
        return data
    }

    // MARK: - 匹配

    private static func artists(of song: [String: Any]) -> String {
        if let list = song["artists"] as? [[String: Any]] {
            return list.compactMap { $0["name"] as? String }.joined(separator: " ")
        }
        if let list = song["ar"] as? [[String: Any]] {
            return list.compactMap { $0["name"] as? String }.joined(separator: " ")
        }
        return ""
    }

    private static func isExcluded(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return excludedTokens.contains { lowered.contains($0) }
    }

    /// 归一化：转小写、去掉括号里的修饰、去掉空白与标点。
    /// `晴天 (弦乐版)` → `晴天`，`孤勇者 (Live版)` → `孤勇者`。
    private static func normalize(_ value: String) -> String {
        var text = value.lowercased()

        let openers: Set<Character> = ["(", "（", "[", "【"]
        let closers: Set<Character> = [")", "）", "]", "】"]
        while let openIndex = text.firstIndex(where: { openers.contains($0) }) {
            if let closeIndex = text[openIndex...].firstIndex(where: { closers.contains($0) }) {
                text.removeSubrange(openIndex...closeIndex)
            } else {
                text.removeSubrange(openIndex...)
                break
            }
        }

        let punctuation = CharacterSet(
            charactersIn: " \t\n-_·,，.。!！?？'\"“”‘’~～|/\\+&"
        )
        text = text.components(separatedBy: punctuation).joined()
        return text
    }

    private static func intValue(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? String { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        return nil
    }
}
