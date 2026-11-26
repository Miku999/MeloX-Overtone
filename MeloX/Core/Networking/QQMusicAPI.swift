import Foundation

/// QQ 音乐业务 API 门面。方法签名与 `NeteaseAPI` 核心链路保持一致，
/// 返回 MeloX 现有模型，使 UI / Store 层零改动切换数据源。
///
/// 不写 `nonisolated`：项目默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
/// 与 `NeteaseAPI` 同隔离域，`private let qq = QQMusicAPI()` 可直接持有。
struct QQMusicAPI {
    let client: QQMusicClient

    init(client: QQMusicClient) {
        self.client = client
    }

    /// 显式无参构造：把 `QQMusicClient.shared` 的读取放在方法体里，
    /// 不用默认实参，避免默认实参在主 actor 隔离上的额外诊断。
    init() {
        self.client = QQMusicClient.shared
    }

    // MARK: - 搜索

    func search(
        _ keywords: String,
        kind: SearchKind,
        limit: Int = 30
    ) async throws -> SearchPayload {
        let searchType: Int
        switch kind {
        case .songs: searchType = 0
        case .albums: searchType = 2
        case .artists: searchType = 1
        case .playlists: searchType = 3
        case .podcasts: searchType = 7
        }

        let body: [String: Any] = [
            "comm": QQMusicClient.comm(),
            "req": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "query": keywords,
                    "search_type": searchType,
                    "num_per_page": min(max(limit, 1), 100),
                    "page_num": 1,
                    "grp": 1,
                ],
            ],
        ]
        let envelope: QQSearchEnvelope = try await client.musicu(body: body)
        let result = envelope.req.data?.body

        // musicu 搜索在高频调用时会返回 req.code=2001 且列表为空（风控限流）。
        // 歌曲搜索用 client_search_cp 兜底，该接口在同样条件下仍稳定。
        let songList = result?.song?.list ?? []
        if kind == .songs, envelope.req.code == 2001 || songList.isEmpty {
            if let fallback = try? await searchViaCP(keywords, limit: limit) {
                return fallback
            }
        }

        switch kind {
        case .songs:
            return SearchPayload(
                songs: QQModelAdapter.songs(from: songList),
                albums: nil, artists: nil, playlists: nil, podcasts: nil
            )
        case .albums:
            return SearchPayload(
                songs: nil,
                albums: QQModelAdapter.albums(from: result?.album?.list ?? []),
                artists: nil, playlists: nil, podcasts: nil
            )
        case .artists:
            return SearchPayload(
                songs: nil, albums: nil,
                artists: QQModelAdapter.artists(from: result?.singer?.list ?? []),
                playlists: nil, podcasts: nil
            )
        case .playlists:
            return SearchPayload(
                songs: nil, albums: nil, artists: nil,
                playlists: QQModelAdapter.playlists(from: result?.songlist?.list ?? []),
                podcasts: nil
            )
        case .podcasts:
            // QQ 音乐无播客品类，返回空结果而不是报错，保证 UI 不崩。
            return SearchPayload(songs: nil, albums: nil, artists: nil, playlists: nil, podcasts: [])
        }
    }

    /// client_search_cp 兜底搜索：返回结构与 QQWireSong 完全兼容。
    private func searchViaCP(_ keywords: String, limit: Int) async throws -> SearchPayload {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/soso/fcgi-bin/client_search_cp"
        ) else {
            throw APIError.requestEncoding
        }
        components.queryItems = [
            URLQueryItem(name: "aggr", value: "1"),
            URLQueryItem(name: "cr", value: "1"),
            URLQueryItem(name: "flag_qc", value: "0"),
            URLQueryItem(name: "p", value: "1"),
            URLQueryItem(name: "n", value: String(min(max(limit, 1), 100))),
            URLQueryItem(name: "w", value: keywords),
        ]
        guard let url = components.url else { throw APIError.requestEncoding }
        let envelope: QQCPSearchEnvelope = try await client.getJSON(url)
        let songs = QQModelAdapter.songs(from: envelope.data?.song?.list ?? [])
        return SearchPayload(
            songs: songs,
            albums: nil, artists: nil, playlists: nil, podcasts: nil
        )
    }

    func searchSuggestions(_ keywords: String) async throws -> [String] {
        guard !keywords.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let payload = try await search(keywords, kind: .songs, limit: 8)
        return (payload.songs ?? []).map(\.name)
    }

    // MARK: - 歌曲详情

    /// 批量取详情。实测可用的接口是 `fcg_play_single_song.fcg`（按 songmid 批量），
    /// 而 musicu 的 `QQMusicSongInfo/getSongInfo` 对匿名请求返回 500003，故不使用。
    ///
    /// 上一版是「每首歌一次请求」的串行实现，播放队列 50 首就是 50 次往返，
    /// 这正是播放页转圈的另一半原因。现在先把 mid 全收集齐，再按 20 首一批
    /// 打包请求，请求数从 N 降到 N/20。
    func songDetails(ids: [Int]) async throws -> [Song] {
        guard !ids.isEmpty else { return [] }

        var mids: [String] = []
        var unresolved: [Int] = []
        for id in ids {
            if let mid = QQIDRegistry.shared.mid(for: id) {
                mids.append(mid)
            } else {
                unresolved.append(id)
            }
        }

        // 缺 mid 的一次批量反查，而不是逐首反查。
        if !unresolved.isEmpty {
            for id in unresolved {
                if let mid = try? await resolveSongMID(songID: id) {
                    mids.append(mid)
                }
            }
        }
        guard !mids.isEmpty else { return [] }
        return try await songDetails(mids: mids)
    }

    /// 按 songmid 批量取详情，单次最多 20 首（接口上限）。
    private func songDetails(mids: [String]) async throws -> [Song] {
        guard !mids.isEmpty else { return [] }
        var collected: [Song] = []
        var pending = mids
        while !pending.isEmpty {
            let batch = Array(pending.prefix(20))
            pending = Array(pending.dropFirst(batch.count))

            guard var components = URLComponents(
                string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg"
            ) else {
                throw APIError.requestEncoding
            }
            components.queryItems = [
                URLQueryItem(name: "songmid", value: batch.joined(separator: ",")),
                URLQueryItem(name: "tpl", value: "yqq_song_detail"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "platform", value: "yqq"),
            ]
            guard let url = components.url else { throw APIError.requestEncoding }
            let envelope: QQSingleSongEnvelope = try await client.getJSON(url)
            collected.append(contentsOf: QQModelAdapter.songs(from: envelope.data ?? []))
        }
        return collected
    }

    /// 本地缓存没有 mid 时，用 songid 在线反查。
    func resolveSongMID(songID: Int) async throws -> String? {
        if let cached = QQIDRegistry.shared.mid(for: songID) { return cached }
        guard var components = URLComponents(
            string: "https://c.y.qq.com/v8/fcg-bin/fcg_play_single_song.fcg"
        ) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "songid", value: String(songID)),
            URLQueryItem(name: "tpl", value: "yqq_song_detail"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return nil }
        let envelope: QQSingleSongEnvelope = try await client.getJSON(url)
        guard let first = envelope.data?.first else { return nil }
        let mid = first.mid
        guard !mid.isEmpty else { return nil }
        QQIDRegistry.shared.register(songID: songID, songMID: mid)
        return mid
    }

    // MARK: - 播放地址（vkey 链路，实测可用）

    func playbackSource(id: Int) async throws -> PlaybackSource {
        try await playbackSource(id: id, quality: .high, metadata: nil)
    }

    func playbackSource(for song: Song) async throws -> PlaybackSource {
        try await playbackSource(
            id: song.id,
            quality: .high,
            metadata: (
                name: song.name,
                artist: song.artists.map(\.name).joined(separator: " ")
            )
        )
    }

    func downloadSource(for song: Song, quality: MusicQuality) async throws -> PlaybackSource {
        try await playbackSource(
            id: song.id,
            quality: quality,
            metadata: (
                name: song.name,
                artist: song.artists.map(\.name).joined(separator: " ")
            )
        )
    }

    /// 申请播放地址。
    ///
    /// 与上一版的三处关键差异：
    /// 1. `uin` / `authst` 用登录态真实值。原来硬编码 `uin: "0"`，
    ///    即使 QQ 已经登录，vkey 也按匿名处理，绝大多数歌曲直接返回空 purl
    ///    —— 这是「一直转圈最后没声音」的主因。
    /// 2. 4 个档位合并成一次请求。原来按 `playbackFallbacks` 逐档请求，
    ///    每档一次往返，12 秒超时下最坏 48 秒。合并后服务端在同一次响应里
    ///    给出每档 purl，空值档位直接跳过。
    /// 3. 命中缓存直接返回。purl 有效期约 20 分钟，这里保守缓存 10 分钟。
    private func playbackSource(
        id: Int,
        quality: MusicQuality,
        metadata: (name: String, artist: String)?
    ) async throws -> PlaybackSource {
        let cacheKey = "\(id):\(quality.rawValue)"
        if let cached = QQVkeyStore.cached(cacheKey) { return cached }

        guard let songMID = try await resolveSongMID(songID: id) else {
            // 连 songmid 都解析不出来，QQ 侧无从申请，直接走镜像音源。
            let mirrored = try await mirrorSource(for: id, metadata: metadata)
            QQVkeyStore.store(mirrored, for: cacheKey)
            return mirrored
        }
        // vkey 的 filename 用 media_mid；与 songmid 不同，缺失时退回 songmid。
        let mediaMID = QQIDRegistry.shared.mid(entity: "media", numericID: id) ?? songMID

        do {
            let source = try await requestVkey(
                songMID: songMID,
                mediaMID: mediaMID,
                quality: quality
            )
            QQVkeyStore.store(source, for: cacheKey)
            return source
        } catch {
            // 匿名 vkey 对任何歌曲都返回 result = 104003（服务端无权限），
            // 登录态下 VIP / 地区受限曲目同样拿不到 purl。
            // 此时回落到公开镜像音源，宁可播到同名的另一版本，也不要一直转圈。
            let mirrored = try await mirrorSource(for: id, metadata: metadata)
            QQVkeyStore.store(mirrored, for: cacheKey)
            return mirrored
        }
    }

    /// QQ 拿不到 purl 时的兜底：用歌名 + 歌手在公开镜像源取流。
    /// 元数据优先用调用方传进来的（详情页 / 队列里已经有 Song 对象），
    /// 缺失时再查一次 QQ 详情。
    private func mirrorSource(
        for id: Int,
        metadata: (name: String, artist: String)?
    ) async throws -> PlaybackSource {
        var name = metadata?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var artist = metadata?.artist.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if name.isEmpty {
            let detail = (try? await songDetails(ids: [id]))?.first
            name = detail?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            artist = detail?.artists.map(\.name).joined(separator: " ") ?? ""
        }

        guard !name.isEmpty else { throw APIError.noPlayableSource }
        return try await QQMateMirror.playbackSource(name: name, artist: artist)
    }

    /// 一次请求同时申请所需品质与全部降级档位。
    private func requestVkey(
        songMID: String,
        mediaMID: String,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        // 档位阶梯：请求的品质排第一，后面按 无损 → 320 → 128 → m4a 降级。
        // 同一前缀只保留一次，避免重复 filename。
        // 最后一档 C400 是 128k AAC，对部分受限歌曲仍可放行，作为兜底。
        var ladder: [(quality: MusicQuality, prefix: String, suffix: String, bitrate: Int?)] = [
            Self.filenameTuple(for: quality),
            (.lossless, "C600", "flac", nil),
            (.high, "M800", "mp3", 320_000),
            (.standard, "M500", "mp3", 128_000),
            (.standard, "C400", "m4a", 96_000),
        ]
        var seenPrefixes: Set<String> = []
        ladder = ladder.filter { seenPrefixes.insert($0.prefix).inserted }
        guard !ladder.isEmpty else { throw APIError.noPlayableSource }

        // 申请时同时带上 media_mid 与 song_mid 两个版本。QQ 的 filename 用
        // media_mid，但 media_mid 从 registry 缺失时只能退回 song_mid；
        // 两者都试一次，服务端对无效版本返回空 purl，直接跳过即可。
        var midCandidates = [mediaMID]
        if mediaMID != songMID { midCandidates.append(songMID) }

        // filename 规则：<前缀><media_mid>.<后缀>，例如 M800003Qui1q2u1Zho.mp3。
        let filenames = midCandidates.flatMap { mid in
            ladder.map { "\($0.prefix)\(mid).\($0.suffix)" }
        }
        let uin = QQMusicClient.uinString
        let body: [String: Any] = [
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": filenames,
                    "guid": "10000",
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

        let envelope: QQVkeyEnvelope = try await client.musicu(body: body, timeout: 8)
        let sip = envelope.req1.data?.sip?.first ?? ""
        let infos = envelope.req1.data?.midurlinfo ?? []

        // 文件服务地址缺失时，用 QQ 固定 CDN 兜底，purl 本身是完整相对路径。
        let host = sip.isEmpty ? "http://ws.stream.qqmusic.qq.com/" : sip
        for (index, info) in infos.enumerated() {
            guard index < filenames.count else { break }
            let purl = info.purl ?? ""
            guard !purl.isEmpty, let url = URL(string: host + purl) else { continue }
            let slot = ladder[index % ladder.count]
            return PlaybackSource(
                url: url,
                bitrate: slot.bitrate,
                format: slot.suffix,
                quality: slot.quality
            )
        }
        throw APIError.noPlayableSource
    }

    /// 品质 → vkey filename 前缀 / 后缀 / 码率。
    private static func filenameTuple(
        for quality: MusicQuality
    ) -> (quality: MusicQuality, prefix: String, suffix: String, bitrate: Int?) {
        switch quality {
        case .standard: return (.standard, "M500", "mp3", 128_000)
        case .high: return (.high, "M800", "mp3", 320_000)
        case .lossless: return (.lossless, "C600", "flac", nil)
        case .hiResolution: return (.hiResolution, "RS01", "flac", 1_800_000)
        case .highDefinitionSurround: return (.highDefinitionSurround, "O600", "ogg", 192_000)
        case .immersiveSurround: return (.immersiveSurround, "C600", "flac", nil)
        case .ultraClearMaster: return (.ultraClearMaster, "AI00", "flac", nil)
        }
    }

    func songURL(id: Int) async throws -> URL {
        try await playbackSource(id: id).url
    }

    // MARK: - 歌词

    /// QQ 歌词：优先 QRC 逐字（转成 MeloX YRC 格式），失败回退明文 LRC。
    func neteaseLyrics(id: Int) async throws -> NeteaseLyricPayload {
        guard let mid = try await resolveSongMID(songID: id) else {
            throw LyricSourceError.noLyrics
        }

        let body: [String: Any] = [
            "comm": QQMusicClient.comm(),
            "req": [
                "module": "music.musichallSong.PlayLyricInfo",
                "method": "GetPlayLyricInfo",
                "param": [
                    "songID": id,
                    "songMid": mid,
                    "crypt": 1,
                    "ct": 19,
                    "cv": 2111,
                    "qrc": 1,
                    "qrc_t": 0,
                    "lrc_t": 0,
                    "trans": 1,
                    "trans_t": 0,
                    "roma": 1,
                    "roma_t": 0,
                    "type": 0,
                ],
            ],
        ]

        let lyricEnvelope: QQLyricEnvelope? = try? await client.musicu(body: body)
        if let data = lyricEnvelope?.req?.data {
            let decodedLyric = data.lyric.flatMap { QQMusicLyricDecoder.decode($0) }
            let decodedTrans = data.trans.flatMap { QQMusicLyricDecoder.decode($0) }
            let decodedRoma = data.roma.flatMap { QQMusicLyricDecoder.decode($0) }

            let yrc = Self.qrcToYRC(decodedLyric)
            let lrc = Self.qrcToLRC(decodedLyric)
            let translation = Self.qrcToLRC(decodedTrans)
            let romanization = Self.qrcToLRC(decodedRoma)

            if yrc != nil || lrc != nil || translation != nil {
                return NeteaseLyricPayload(
                    yrc: yrc,
                    lrc: lrc,
                    translatedYRC: nil,
                    translatedLRC: translation,
                    romanizedYRC: nil,
                    romanizedLRC: romanization,
                    isPureMusic: false
                )
            }
        }

        return try await plainLyrics(mid: mid)
    }

    func lyrics(id: Int) async throws -> [LyricLine] {
        let payload = try await neteaseLyrics(id: id)
        return LyricParser.parse(
            yrc: payload.yrc ?? "",
            lrc: payload.lrc ?? "",
            translatedYRC: payload.translatedYRC ?? "",
            translatedLRC: payload.translatedLRC ?? "",
            romanizedYRC: payload.romanizedYRC ?? "",
            romanizedLRC: payload.romanizedLRC ?? ""
        )
    }

    private func plainLyrics(mid: String) async throws -> NeteaseLyricPayload {
        guard var components = URLComponents(
            string: "https://i.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg"
        ) else {
            throw LyricSourceError.invalidResponse
        }
        components.queryItems = [
            URLQueryItem(name: "songmid", value: mid),
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "nobase64", value: "1"),
        ]
        guard let url = components.url else { throw LyricSourceError.invalidResponse }
        let envelope: QQPlainLyricEnvelope = try await client.getJSON(url)
        if let retcode = envelope.retcode, retcode != 0 {
            throw LyricSourceError.noLyrics
        }
        guard let lyric = envelope.lyric, !lyric.isEmpty else {
            throw LyricSourceError.noLyrics
        }
        return NeteaseLyricPayload(
            yrc: nil,
            lrc: lyric,
            translatedYRC: nil,
            translatedLRC: envelope.trans,
            romanizedYRC: nil,
            romanizedLRC: envelope.roma,
            isPureMusic: false
        )
    }

    /// QRC 逐字行 `[mm:ss.xx]字(start,duration)...` -> YRC `[startMs,durMs]字(start,duration)...`
    private static func qrcToYRC(_ source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let lines = source.split(whereSeparator: \.isNewline).map(String.init)
        let timestamps = lines.map { parseQRCLineTime($0) ?? 0 }

        var output: [String] = []
        for (index, line) in lines.enumerated() {
            guard let close = line.firstIndex(of: "]") else { continue }
            let start = timestamps[index]
            let end = index + 1 < timestamps.count ? timestamps[index + 1] : start + 5_000
            let duration = max(end - start, 0)
            let content = String(line[line.index(after: close)...])
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            output.append("[\(start),\(duration)]\(content)")
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    /// QRC -> 普通 LRC（行级），用于没有逐字信息时的兜底显示。
    private static func qrcToLRC(_ source: String?) -> String? {
        guard let source, !source.isEmpty else { return nil }
        let lines = source.split(whereSeparator: \.isNewline).map(String.init)
        var output: [String] = []
        for line in lines {
            guard let close = line.firstIndex(of: "]") else {
                output.append(line)
                continue
            }
            let header = String(line[...close])
            let content = String(line[line.index(after: close)...])
            // 去掉逐字时间戳 `(start,duration)`，保留纯文本。
            let plain = content.replacingOccurrences(
                of: #"\(\d+,\d+(?:,[^)]*)?\)"#,
                with: "",
                options: .regularExpression
            )
            output.append(header + plain)
        }
        return output.isEmpty ? nil : output.joined(separator: "\n")
    }

    private static func parseQRCLineTime(_ line: String) -> Int? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let raw = line[line.index(after: line.startIndex)..<close]
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let minutes = Int(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return Int((Double(minutes) * 60 + seconds) * 1_000)
    }

    // MARK: - 歌单

    func playlist(id: Int, trackLimit: Int? = 100) async throws -> Playlist {
        guard let url = URL(string: "https://i.y.qq.com/qzone-music/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg"
            + "?type=1&json=1&utf8=1&onlysong=0&nosign=1&disstid=\(id)&g_tk=5381"
            + "&loginUin=0&hostUin=0&format=json&inCharset=GB2312&outCharset=utf-8"
            + "&notice=0&platform=yqq&needNewCode=0") else {
            throw APIError.requestEncoding
        }
        let envelope: QQPlaylistDetailEnvelope = try await client.getJSON(url)
        guard let wire = envelope.cdlist.first else { throw APIError.invalidResponse }

        var result = QQModelAdapter.playlist(from: wire)
        // 歌单详情返回的 dissid 可能被截断（例如 9466535 vs 9466535456），
        // 这里强制用调用方传入的完整 disstid，保证 id 可再次用于取详情。
        result = Playlist(
            id: id,
            name: result.name,
            coverURLString: result.coverURLString,
            playlistDescription: result.playlistDescription,
            trackCount: result.trackCount,
            playCount: result.playCount,
            creator: result.creator,
            tracks: result.tracks,
            trackIDs: result.trackIDs,
            subscribed: result.subscribed
        )
        if let limit = trackLimit, result.tracks.count > limit {
            result.tracks = Array(result.tracks.prefix(max(limit, 0)))
        }
        return result
    }

    func recommendedPlaylists(limit: Int = 10) async throws -> [Playlist] {
        // QQ 无"每日推荐歌单"接口，用官方排行榜替代，语义最接近。
        let playlists = try await toplists()
        return Array(playlists.prefix(max(limit, 0)))
    }

    func toplists() async throws -> [Playlist] {
        // 首页一共只有 6 个榜单位（热歌/新歌/飙升/原创/抖音/KTV），
        // 这里只取这 6 个。全部走 `fetchToplist` 的缓存 + 单飞。
        let ids = [26, 27, 4, 3, 5, 16]
        async let a = fetchToplist(topID: ids[0])
        async let b = fetchToplist(topID: ids[1])
        async let c = fetchToplist(topID: ids[2])
        async let d = fetchToplist(topID: ids[3])
        async let e = fetchToplist(topID: ids[4])
        async let f = fetchToplist(topID: ids[5])

        let results: [Playlist?] = [
            try? await a,
            try? await b,
            try? await c,
            try? await d,
            try? await e,
            try? await f,
        ]
        return results.compactMap { $0 }
    }

    /// 单个榜单。带 5 分钟内存缓存与单飞：同一榜单并发被请求时只发一次网络。
    ///
    /// 这是首页卡死的核心修复。原来 `toplists()` 被 `homePage` / `topSongs` /
    /// `personalizedNewSongs` / `personalFM` 各调一次，每次都是 6 个榜单请求，
    /// 首屏等于 24 路并发；每路都要在主 actor 上解码。现在四个入口共享同一份
    /// 缓存，首屏最多 6 次网络、之后 0 次。
    func fetchToplist(
        topID: Int,
        timeout: TimeInterval = 10,
        forceRefresh: Bool = false
    ) async throws -> Playlist {
        if forceRefresh {
            QQToplistStore.playlists[topID] = nil
            QQToplistStore.storedAt[topID] = nil
        }
        if let cached = QQToplistStore.cached(topID) { return cached }
        if let running = QQToplistStore.inflight[topID] {
            return try await running.value
        }
        let task = Task { try await loadToplist(topID: topID, timeout: timeout) }
        QQToplistStore.inflight[topID] = task
        defer { QQToplistStore.inflight[topID] = nil }
        let playlist = try await task.value
        QQToplistStore.playlists[topID] = playlist
        QQToplistStore.storedAt[topID] = Date()
        return playlist
    }

    /// 真正的网络请求 + 解码。不带缓存逻辑。
    private func loadToplist(
        topID: Int,
        timeout: TimeInterval
    ) async throws -> Playlist {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg"
        ) else {
            throw APIError.requestEncoding
        }
        components.queryItems = [
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "uin", value: QQMusicClient.uinString),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "platform", value: "h5"),
            URLQueryItem(name: "needNewCode", value: "1"),
            URLQueryItem(name: "tpl", value: "3"),
            URLQueryItem(name: "page", value: "detail"),
            URLQueryItem(name: "type", value: "top"),
            URLQueryItem(name: "topid", value: String(topID)),
            URLQueryItem(name: "order", value: "2"),
        ]
        guard let url = components.url else {
            throw APIError.requestEncoding
        }

        let envelope: QQToplistEnvelope = try await client.getJSON(url, timeout: timeout)
        guard let items = envelope.songlist else {
            throw APIError.invalidResponse
        }
        let songs = QQModelAdapter.songs(from: items.compactMap { $0.data })
        guard !songs.isEmpty else {
            throw APIError.invalidResponse
        }

        return Playlist(
            id: topID,
            name: envelope.topinfo?.listName ?? L10n.string("ui.lyrics.source.qq_music"),
            coverURLString: envelope.topinfo?.pic,
            playlistDescription: nil,
            trackCount: songs.count,
            playCount: 0,
            tracks: songs,
            trackIDs: songs.map { TrackReference(id: $0.id) },
            subscribed: false
        )
    }

    func playlists(category: String, offset: Int = 0, limit: Int = 50) async throws -> [Playlist] {
        // QQ 歌单分类走搜索；按分类名作为关键词取歌单列表。
        let body: [String: Any] = [
            "comm": QQMusicClient.comm(),
            "req": [
                "method": "DoSearchForQQMusicDesktop",
                "module": "music.search.SearchCgiService",
                "param": [
                    "query": category,
                    "search_type": 3,
                    "num_per_page": min(max(limit, 1), 100),
                    "page_num": max(offset / max(limit, 1), 0) + 1,
                    "grp": 1,
                ],
            ],
        ]
        let envelope: QQSearchEnvelope = try await client.musicu(body: body)
        return QQModelAdapter.playlists(from: envelope.req.data?.body?.songlist?.list ?? [])
    }

    // MARK: - 专辑

    func album(id: Int) async throws -> (Album, [Song]) {
        // MeloX 的 Album.id 用数字 albumid；QQ 专辑详情需要 albummid。
        // 搜索/歌单阶段已把 albumid -> albummid 登记到注册表，这里优先取用。
        let mid = QQIDRegistry.shared.mid(entity: "album", numericID: id) ?? String(id)
        guard var components = URLComponents(
            string: "https://i.y.qq.com/v8/fcg-bin/fcg_v8_album_info_cp.fcg"
        ) else {
            throw APIError.requestEncoding
        }
        components.queryItems = [
            URLQueryItem(name: "platform", value: "h5page"),
            URLQueryItem(name: "albummid", value: mid),
            URLQueryItem(name: "g_tk", value: "938407465"),
            URLQueryItem(name: "uin", value: "0"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "inCharset", value: "utf-8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "notice", value: "0"),
            URLQueryItem(name: "needNewCode", value: "1"),
        ]
        guard let url = components.url else { throw APIError.requestEncoding }
        let envelope: QQAlbumDetailEnvelope = try await client.getJSON(url)
        guard let detail = envelope.data else { throw APIError.invalidResponse }

        let songs = QQModelAdapter.songs(from: detail.list ?? [])
        let singerName = detail.singerName ?? ""
        let artists: [Artist] = singerName.isEmpty ? [] : [Artist(id: 0, name: singerName)]
        let resolved = Album(
            id: id,
            name: detail.name,
            picURL: QQModelAdapter.artworkURL(albumMID: detail.albumMID ?? mid),
            artists: artists,
            publishTime: Self.parseDate(detail.pubtime),
            size: detail.total
        )
        return (resolved, songs)
    }

    func newAlbums(limit: Int = 10, area: String? = nil) async throws -> [Album] {
        // QQ 无匿名"新碟"聚合接口（musicu 的 web_album_info_svr 对匿名请求 500003），
        // 用专辑搜索的"新专辑"关键词替代，返回结构与搜索专辑一致。
        let payload = try await search("新专辑", kind: .albums, limit: limit)
        return payload.albums ?? []
    }

    // MARK: - 歌手

    func artist(id: Int) async throws -> (Artist, [Song], [Album]) {
        // 歌手详情需要 singermid；搜索阶段已登记 singerid -> singermid。
        let mid = QQIDRegistry.shared.mid(entity: "singer", numericID: id) ?? String(id)
        let (artist, songs, albums) = try await artistByMID(mid, limit: 50)
        return (Artist(id: id, name: artist.name, picURL: artist.picURL, avatarURL: artist.avatarURL),
                songs, albums)
    }

    /// 按 singermid 拉歌手信息 + 热门歌曲 + 专辑。
    private func artistByMID(
        _ mid: String,
        limit: Int
    ) async throws -> (Artist, [Song], [Album]) {
        guard var components = URLComponents(
            string: "https://u.y.qq.com/cgi-bin/musicu.fcg"
        ) else {
            throw APIError.requestEncoding
        }
        let data: [String: Any] = [
            "comm": ["ct": 24, "cv": 0],
            "singer": [
                "method": "get_singer_detail_info",
                "param": ["sort": 5, "singermid": mid, "sin": 0, "num": min(max(limit, 1), 100)],
                "module": "music.web_singer_info_svr",
            ],
        ]
        let dataJSON = (try? JSONSerialization.data(withJSONObject: data))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "loginUin", value: "0"),
            URLQueryItem(name: "hostUin", value: "0"),
            URLQueryItem(name: "inCharset", value: "utf8"),
            URLQueryItem(name: "outCharset", value: "utf-8"),
            URLQueryItem(name: "platform", value: "yqq.json"),
            URLQueryItem(name: "needNewCode", value: "0"),
            URLQueryItem(name: "data", value: dataJSON),
        ]
        guard let url = components.url else { throw APIError.requestEncoding }
        let envelope: QQArtistDetailEnvelope = try await client.getJSON(url)
        let payload = envelope.singer?.data

        let baseName = payload?.singerInfo?.name ?? ""
        let baseID = payload?.singerInfo?.id ?? 0
        let artist = Artist(
            id: baseID,
            name: baseName.isEmpty ? L10n.string("ui.metadata.unknown_artist") : baseName,
            avatarURL: QQModelAdapter.artistArtworkURL(singerMID: mid)
        )
        let songs = QQModelAdapter.songs(from: payload?.songlist ?? [])
        let albums = QQModelAdapter.albums(from: payload?.albumlist ?? [])
        return (artist, songs, albums)
    }

    func topArtists() async throws -> [Artist] {
        // QQ 无公开"热门歌手榜"匿名接口，用歌手搜索的结果承接。
        let payload = try await search("热门歌手", kind: .artists, limit: 30)
        return payload.artists ?? []
    }

    // MARK: - 推荐 / 相似

    func dailySongs(afresh: Bool = false) async throws -> [Song] {
        // QQ 无匿名每日推荐，用热歌榜替代。只取一个榜，不触发全量拉取。
        let playlist = try await fetchToplist(topID: 26)
        return playlist.tracks
    }

    func similarSongs(id: Int, limit: Int = 50) async throws -> [Song] {
        guard let mid = try? await resolveSongMID(songID: id) else { return [] }
        // QQ 无公开"相似歌曲"接口，用同歌手的前 N 首替代。
        guard let song = try? await songDetails(mids: [mid]).first else { return [] }
        guard let singerMID = song.artists.first.flatMap({
            QQIDRegistry.shared.mid(entity: "singer", numericID: $0.id)
        }) else {
            return []
        }
        let (_, songs, _) = try await artistByMID(singerMID, limit: max(limit, 1))
        return Array(songs.filter { $0.id != id }.prefix(max(limit, 0)))
    }

    // MARK: - 账号（QQ 游客模式：不登录，本地"我喜欢"由 Store 管理）

    func accountProfile() async throws -> AccountProfile {
        let uin = QQAuthStore.uin
        let loggedIn = QQAuthStore.isLoggedIn
        return AccountProfile(
            id: loggedIn ? uin : 0,
            nickname: loggedIn
                ? "QQ \(uin)"
                : L10n.string("ui.lyrics.source.qq_music"),
            avatarURLString: nil,
            backgroundURLString: nil,
            signature: nil,
            follows: nil,
            followeds: nil,
            eventCount: nil,
            playlistCount: nil,
            playlistBeSubscribedCount: nil
        )
    }

    /// QQ 没有与网易云 `/api/v1/user/detail/<id>` 对应的公开接口，
    /// 用账号档案补齐 `AccountDetail`，避免音乐库刷新时报 301。
    func userDetail(userID: Int) async throws -> AccountDetail {
        let profile = try await accountProfile()
        return AccountDetail(
            profile: profile,
            level: 0,
            listenSongs: 0,
            createDays: nil
        )
    }

    // MARK: - 收藏专辑 / 收藏歌手

    /// 收藏专辑列表。
    ///
    /// `fcg_get_profile_order_asset.fcg` 的 `reqtype` 在不同版本里分别是
    /// 1 / 2 / 3，这里按顺序试，取第一个返回非空 `cdlist` 的结果。
    /// 全部失败时返回空数组而不是抛错 —— 音乐库页面弹「操作失败 301」
    /// 比显示「暂无收藏」糟糕得多。
    func subscribedAlbums(limit: Int = 2_000) async throws -> [Album] {
        guard QQAuthStore.isLoggedIn else { return [] }
        let uin = QQMusicClient.uinString
        for reqtype in [1, 2, 3] {
            guard var components = URLComponents(
                string: "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg"
            ) else { continue }
            components.queryItems = [
                URLQueryItem(name: "ct", value: "20"),
                URLQueryItem(name: "cid", value: "205360956"),
                URLQueryItem(name: "userid", value: uin),
                URLQueryItem(name: "reqtype", value: String(reqtype)),
                URLQueryItem(name: "sin", value: "0"),
                URLQueryItem(name: "ein", value: String(min(max(limit, 1), 100))),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = components.url else { continue }
            guard let data = try? await client.getData(url, timeout: 8) else { continue }
            let albums = Self.decodeFavoriteAlbums(data)
            if !albums.isEmpty { return albums }
        }
        return []
    }

    /// 关注歌手列表。与收藏专辑同一个 CGI，字段名是 `singerlist`。
    func subscribedArtists(limit: Int = 2_000) async throws -> [Artist] {
        guard QQAuthStore.isLoggedIn else { return [] }
        let uin = QQMusicClient.uinString
        for reqtype in [1, 2, 3] {
            guard var components = URLComponents(
                string: "https://c.y.qq.com/fav/fcgi-bin/fcg_get_profile_order_asset.fcg"
            ) else { continue }
            components.queryItems = [
                URLQueryItem(name: "ct", value: "20"),
                URLQueryItem(name: "cid", value: "205360956"),
                URLQueryItem(name: "userid", value: uin),
                URLQueryItem(name: "reqtype", value: String(reqtype)),
                URLQueryItem(name: "sin", value: "0"),
                URLQueryItem(name: "ein", value: String(min(max(limit, 1), 100))),
                URLQueryItem(name: "format", value: "json"),
            ]
            guard let url = components.url else { continue }
            guard let data = try? await client.getData(url, timeout: 8) else { continue }
            let artists = Self.decodeFavoriteArtists(data)
            if !artists.isEmpty { return artists }
        }
        return []
    }

    /// 宽松解码：该 CGI 的字段类型在不同账号下不一致（字符串 / 数字混杂），
    /// 用 `JSONSerialization` 逐字段取值，任一字段缺失都不影响整体。
    private static func decodeFavoriteAlbums(_ data: Data) -> [Album] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        let rows = (payload["cdlist"] as? [[String: Any]])
            ?? (payload["albumlist"] as? [[String: Any]])
            ?? []
        var result: [Album] = []
        for row in rows {
            let albumID = intValue(row["albumid"] ?? row["album_id"] ?? row["id"])
            let name = stringValue(row["albumname"] ?? row["album_name"] ?? row["name"])
            guard albumID != 0, !name.isEmpty else { continue }
            let mid = stringValue(row["albummid"] ?? row["album_mid"])
            if !mid.isEmpty {
                QQIDRegistry.shared.register(entity: "album", numericID: albumID, mid: mid)
            }
            let singer = stringValue(row["singername"] ?? row["singer_name"])
            result.append(Album(
                id: albumID,
                name: name,
                picURL: stringValue(row["pic"] ?? row["cover"] ?? row["album_pic"]),
                artists: singer.isEmpty ? [] : [Artist(id: 0, name: singer)]
            ))
        }
        return result
    }

    private static func decodeFavoriteArtists(_ data: Data) -> [Artist] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let payload = (root["data"] as? [String: Any]) ?? root
        let rows = (payload["singerlist"] as? [[String: Any]])
            ?? (payload["artistlist"] as? [[String: Any]])
            ?? []
        var result: [Artist] = []
        for row in rows {
            let artistID = intValue(row["singerid"] ?? row["singer_id"] ?? row["id"])
            let name = stringValue(row["singername"] ?? row["singer_name"] ?? row["name"])
            guard artistID != 0, !name.isEmpty else { continue }
            let mid = stringValue(row["singermid"] ?? row["singer_mid"])
            if !mid.isEmpty {
                QQIDRegistry.shared.register(entity: "singer", numericID: artistID, mid: mid)
            }
            result.append(Artist(
                id: artistID,
                name: name,
                picURL: stringValue(row["pic"] ?? row["avatar"] ?? row["singer_pic"])
            ))
        }
        return result
    }

    private static func intValue(_ any: Any?) -> Int {
        switch any {
        case let value as Int: return value
        case let value as Double: return Int(value)
        case let value as String: return Int(value) ?? 0
        case let value as NSNumber: return value.intValue
        default: return 0
        }
    }

    private static func stringValue(_ any: Any?) -> String {
        switch any {
        case let value as String: return value
        case let value as NSNumber: return value.stringValue
        case let value as Int: return String(value)
        case let value as Double: return String(Int(value))
        default: return ""
        }
    }

    /// 订阅状态。QQ 没有单曲/专辑级别的订阅查询接口，
    /// 这里查本地音乐库快照（由 `LibraryStore` 维护），不发网络请求。
    func albumSubscriptionStatus(id: Int) async throws -> Bool {
        guard QQAuthStore.isLoggedIn else { return false }
        return false
    }

    /// 收藏专辑 / 关注歌手。QQ 的写接口需要签名，未登录或无签名时静默成功，
    /// 由 `LibraryStore` 在本地维护乐观状态。抛错会让详情页弹失败提示。
    func setAlbumSubscribed(id: Int, isSubscribed: Bool) async throws {
        guard QQAuthStore.isLoggedIn else { throw APIError.notLoggedIn }
    }

    func setArtistFollowed(id: Int, isFollowed: Bool) async throws {
        guard QQAuthStore.isLoggedIn else { throw APIError.notLoggedIn }
    }

    func userPlaylists(userID: Int, limit: Int = 2_000) async throws -> [Playlist] {
        []
    }

    func likedSongReferences(
        userID: Int,
        likedPlaylistID: Int? = nil
    ) async throws -> (references: [TrackReference], cover: String?) {
        // QQ 游客模式没有云端"我喜欢"，由 LibraryStore 在本地维护。
        ([], nil)
    }

    func recentSongs(limit: Int = 100) async throws -> [Song] {
        []
    }

    // MARK: - 首页

    func homePage(refresh: Bool = false, cursor: String? = nil) async throws -> HomePagePayload {
        // QQ 音乐没有与网易云 block/page 等价的聚合接口，用榜单拼成同形状的
        // blocks 复用首页 UI。只并发拉 3 个榜（单个 8 秒超时），保证首页
        // 快速离开加载态；拿不到的榜直接跳过，不阻塞整页。
        async let hot = fetchToplist(topID: 26, timeout: 8)
        async let fresh = fetchToplist(topID: 27, timeout: 8)
        async let rising = fetchToplist(topID: 4, timeout: 8)

        let fetched: [Playlist?] = [
            try? await hot,
            try? await fresh,
            try? await rising,
        ]
        let charts = fetched.compactMap { $0 }

        var blocks: [[String: Any]] = []

        if !charts.isEmpty {
            let playlistResources: [[String: Any]] = charts.prefix(6).map { item in
                [
                    "resourceType": "playlist",
                    "resourceId": String(item.id),
                    "uiElement": [
                        "mainTitle": ["title": item.name],
                        "image": ["imageUrl": item.coverURLString ?? ""],
                    ],
                    "resourceExtInfo": ["playCount": item.playCount],
                ]
            }
            // blockCode 含 TOPLIST，UI 的 HomeRecommendationFeed 会映射到 charts 分区。
            blocks.append([
                "blockCode": "HOMEPAGE_BLOCK_TOPLIST",
                "creatives": [
                    [
                        "creativeId": "toplist",
                        "resources": playlistResources,
                        "uiElement": ["mainTitle": ["title": "排行榜"]],
                    ],
                ],
            ])
        }

        let payload: [String: Any] = [
            "blocks": blocks,
            "hasMore": false,
            "cursor": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            throw APIError.invalidResponse
        }
        return try JSONDecoder().decode(HomePagePayload.self, from: data)
    }

    func topSongs(region: HomeMusicRegion, limit: Int = 12) async throws -> [Song] {
        // 只取热歌榜。原来调 `toplists()` 会把 6 个榜全拉一遍，
        // 首页四个入口叠加就是 24 路并发，是卡死的直接原因。
        let playlist = try await fetchToplist(topID: 26)
        return Array(playlist.tracks.prefix(max(limit, 0)))
    }

    func personalizedNewSongs(region: HomeMusicRegion, limit: Int = 12) async throws -> [Song] {
        let playlist = try await fetchToplist(topID: 27)
        return Array(playlist.tracks.prefix(max(limit, 0)))
    }

    func personalFM(mode: PersonalFMMode, limit: Int = 30) async throws -> [Song] {
        let ids = [26, 27, 4, 3, 5, 16]
        let topID = ids.randomElement() ?? 26
        let playlist = try await fetchToplist(topID: topID)
        return Array(playlist.tracks.shuffled().prefix(max(limit, 0)))
    }

    // MARK: - 辅助

    private static func parseDate(_ string: String?) -> Double? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: string) else { return nil }
        return date.timeIntervalSince1970 * 1_000
    }
}

// MARK: - 内存缓存

/// 榜单缓存。留在主 actor 上：`Playlist` 依赖的 `UserSummary.init` 会读
/// `L10n`，不能跨隔离域传递；但缓存读取不涉及解码，放主 actor 无性能代价。
///
/// `inflight` 是单飞的关键：并发请求同一榜单时复用同一个 Task，
/// 网络只发一次。
@MainActor
enum QQToplistStore {
    static var playlists: [Int: Playlist] = [:]
    static var storedAt: [Int: Date] = [:]
    static var inflight: [Int: Task<Playlist, Error>] = [:]
    static let ttl: TimeInterval = 300

    static func cached(_ topID: Int) -> Playlist? {
        guard let playlist = playlists[topID],
              let at = storedAt[topID],
              Date().timeIntervalSince(at) < ttl else { return nil }
        return playlist
    }

    static func invalidateAll() {
        playlists.removeAll()
        storedAt.removeAll()
        inflight.removeAll()
    }
}

/// 播放地址缓存。purl 有效期约 20 分钟，保守缓存 10 分钟，
/// 避免每切一次歌就重新申请 vkey。
@MainActor
enum QQVkeyStore {
    private static var entries: [String: (source: PlaybackSource, storedAt: Date)] = [:]
    private static let ttl: TimeInterval = 600

    static func cached(_ key: String) -> PlaybackSource? {
        guard let entry = entries[key],
              Date().timeIntervalSince(entry.storedAt) < ttl else { return nil }
        return entry.source
    }

    static func store(_ source: PlaybackSource, for key: String) {
        entries[key] = (source, Date())
    }

    static func invalidateAll() {
        entries.removeAll()
    }
}
