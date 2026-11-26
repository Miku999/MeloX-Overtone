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
    func songDetails(ids: [Int]) async throws -> [Song] {
        var result: [Song] = []
        var missing: [Int] = []

        for id in ids {
            if let mid = QQIDRegistry.shared.mid(for: id) {
                result.append(contentsOf: try await songDetails(mids: [mid]))
            } else {
                missing.append(id)
            }
        }

        for id in missing {
            guard let mid = try? await resolveSongMID(songID: id) else { continue }
            if let song = try? await songDetails(mids: [mid]).first {
                result.append(song)
            }
        }
        return result
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
        try await playbackSource(id: id, quality: .high)
    }

    func playbackSource(for song: Song) async throws -> PlaybackSource {
        try await playbackSource(id: song.id, quality: .high)
    }

    func downloadSource(for song: Song, quality: MusicQuality) async throws -> PlaybackSource {
        try await playbackSource(id: song.id, quality: quality)
    }

    /// 按品质回退链依次申请 vkey。QQ 对部分歌曲只放行某些档位，
    /// 单档失败不应该直接判整首不可播。
    private func playbackSource(
        id: Int,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        guard let songMID = try await resolveSongMID(songID: id) else {
            throw APIError.noPlayableSource
        }
        // vkey 的 filename 用 media_mid；与 songmid 不同，缺失时退回 songmid。
        let mediaMID = QQIDRegistry.shared.mid(entity: "media", numericID: id) ?? songMID

        var lastError: Error = APIError.noPlayableSource
        for candidate in quality.playbackFallbacks {
            do {
                return try await requestVkey(
                    songMID: songMID,
                    mediaMID: mediaMID,
                    quality: candidate
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func requestVkey(
        songMID: String,
        mediaMID: String,
        quality: MusicQuality
    ) async throws -> PlaybackSource {
        let filenameTuple: (prefix: String, suffix: String, bitrate: Int?) = {
            switch quality {
            case .standard: return ("M500", "mp3", 128_000)
            case .high: return ("M800", "mp3", 320_000)
            case .lossless: return ("C600", "flac", nil)
            case .hiResolution: return ("RS01", "flac", 1_800_000)
            default: return ("C400", "m4a", 128_000)
            }
        }()

        // filename 规则：<前缀><media_mid>.<后缀>，例如 M800003Qui1q2u1Zho.mp3。
        let filename = "\(filenameTuple.prefix)\(mediaMID).\(filenameTuple.suffix)"
        let body: [String: Any] = [
            "req_1": [
                "module": "vkey.GetVkeyServer",
                "method": "CgiGetVkey",
                "param": [
                    "filename": [filename],
                    "guid": "10000",
                    "songmid": [songMID],
                    "songtype": [0],
                    "uin": "0",
                    "loginflag": 1,
                    "platform": "20",
                ],
            ],
            "loginUin": "0",
            "comm": ["uin": "0", "format": "json", "ct": 24, "cv": 0],
        ]
        let envelope: QQVkeyEnvelope = try await client.musicu(body: body)
        guard let info = envelope.req1.data?.midurlinfo?.first,
              let purl = info.purl, !purl.isEmpty,
              let sip = envelope.req1.data?.sip?.first, !sip.isEmpty else {
            throw APIError.noPlayableSource
        }
        guard let url = URL(string: sip + purl) else {
            throw APIError.noPlayableSource
        }
        return PlaybackSource(
            url: url,
            bitrate: filenameTuple.bitrate,
            format: filenameTuple.suffix,
            quality: quality
        )
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
        // 原来是 15 个榜单串行请求、单个 20 秒超时，首页和排行榜页会长时间空白
        // （就是「正在为你准备推荐」一直转圈的原因）。改成并发取 6 个主榜，
        // 单个 8 秒超时，最坏 8 秒内返回。
        async let hot = fetchToplist(topID: 26, timeout: 8)
        async let fresh = fetchToplist(topID: 27, timeout: 8)
        async let rising = fetchToplist(topID: 4, timeout: 8)
        async let newSongs = fetchToplist(topID: 3, timeout: 8)
        async let original = fetchToplist(topID: 5, timeout: 8)
        async let ktv = fetchToplist(topID: 16, timeout: 8)

        let results: [Playlist?] = [
            try? await hot,
            try? await fresh,
            try? await rising,
            try? await newSongs,
            try? await original,
            try? await ktv,
        ]
        return results.compactMap { $0 }
    }

    /// 单个榜单。首页与排行榜页共用，`timeout` 决定 UI 最多等多久。
    func fetchToplist(
        topID: Int,
        timeout: TimeInterval = 20
    ) async throws -> Playlist {
        guard var components = URLComponents(
            string: "https://c.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg"
        ) else {
            throw APIError.requestEncoding
        }
        components.queryItems = [
            URLQueryItem(name: "g_tk", value: "5381"),
            URLQueryItem(name: "uin", value: String(QQAuthStore.uin)),
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
        // QQ 无匿名每日推荐，用排行榜首榜替代。
        let playlists = try await toplists()
        return playlists.first?.tracks ?? []
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
        let playlists = try await toplists()
        return Array((playlists.first?.tracks ?? []).prefix(max(limit, 0)))
    }

    func personalizedNewSongs(region: HomeMusicRegion, limit: Int = 12) async throws -> [Song] {
        let playlists = try await toplists()
        return Array((playlists.dropFirst().first?.tracks ?? []).prefix(max(limit, 0)))
    }

    func personalFM(mode: PersonalFMMode, limit: Int = 30) async throws -> [Song] {
        let playlists = try await toplists()
        return Array((playlists.randomElement()?.tracks ?? []).prefix(max(limit, 0)))
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
