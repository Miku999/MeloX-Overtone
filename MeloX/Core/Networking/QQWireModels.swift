import Foundation

// MARK: - 搜索

// musicu.fcg / music.search.SearchCgiService.DoSearchForQQMusicDesktop
// 无论 search_type 如何，body 里都同时返回 song/album/singer/songlist 等 key；
// 这里用一个"全量可选"的结构承接，再按 SearchKind 挑对应字段。

nonisolated struct QQSearchEnvelope: Decodable, Sendable {
    let req: Request

    nonisolated struct Request: Decodable, Sendable {
        let code: Int?
        let data: Data?
    }

    nonisolated struct Data: Decodable, Sendable {
        let body: Body?
    }

    nonisolated struct Body: Decodable, Sendable {
        let song: QQNamedList<QQWireSong>?
        let album: QQNamedList<QQWireAlbum>?
        let singer: QQNamedList<QQWireSinger>?
        let songlist: QQNamedList<QQWirePlaylist>?
    }
}

nonisolated struct QQNamedList<Element: Decodable & Sendable>: Decodable, Sendable {
    let list: [Element]?
}

// MARK: - 歌曲

/// 覆盖 5 个不同接口的 song 载体，字段名差异很大，逐个兜底：
///
/// - 搜索 / 单曲详情：`name`、`title`、`mid`、`file.media_mid`、`file.size_flac`、`album.mid`
/// - 歌单 / 榜单 / 专辑曲目：`songname`、`songmid`、`strMediaMid`、`sizeflac`、`albummid`
nonisolated struct QQWireSong: Decodable, Sendable {
    let songID: Int
    let mid: String
    let mediaMID: String
    let name: String
    let interval: Int
    let singers: [QQWireSinger]
    let album: QQWireAlbum?
    let albumMID: String
    let albumName: String
    let albumID: Int
    let indexAlbum: Int?
    let indexCD: Int?
    let payPlay: Int
    let hasFlac: Bool
    let hasHires: Bool
    let mvVID: String?

    enum CodingKeys: String, CodingKey {
        case id, mid, name, title, interval, album, file, pay, mv
        case songname, songmid, albummid, albumname, albumid
        case strMediaMid, sizeflac, sizehires
        case songID = "songid"
        case mediaMID = "media_mid"
        case singers = "singer"
        case indexAlbum = "index_album"
        case indexCD = "index_cd"
        case payPlay = "pay_play"
        case flacSize = "size_flac"
        case hiresSize = "size_hires"
        case mvVID = "vid"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let file = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .file)
        let pay = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .pay)
        let mv = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .mv)
        let albumContainer = try? container.nestedContainer(keyedBy: CodingKeys.self, forKey: .album)

        let primaryID = QQWireDecoding.int(container, .id)
        let fallbackID = QQWireDecoding.int(container, .songID)
        songID = primaryID != 0 ? primaryID : fallbackID

        mid = QQWireDecoding.nonEmptyString(container, .songmid, .mid)

        // media_mid 在搜索结果里是 file.media_mid，在歌单/榜单里是 strMediaMid。
        let fileMediaMID = QQWireDecoding.nonEmptyString(file, .mediaMID)
        let flatMediaMID = QQWireDecoding.nonEmptyString(container, .strMediaMid)
        mediaMID = fileMediaMID.isEmpty ? flatMediaMID : fileMediaMID

        name = QQWireDecoding.nonEmptyString(container, .name, .songname, .title)

        interval = QQWireDecoding.int(container, .interval)

        singers = (try? container.decode([QQWireSinger].self, forKey: .singers)) ?? []

        let embeddedAlbum = try? container.decode(QQWireAlbum.self, forKey: .album)
        album = embeddedAlbum

        // 专辑 mid 可能在 album.mid / album.albummid / 顶层 albummid。
        let albumMIDFromEmbedded = embeddedAlbum?.mid ?? ""
        let albumMIDFromNested = QQWireDecoding.nonEmptyString(albumContainer, .albummid, .mid)
        let albumMIDFromFlat = QQWireDecoding.nonEmptyString(container, .albummid)
        albumMID = [albumMIDFromEmbedded, albumMIDFromNested, albumMIDFromFlat]
            .first { !$0.isEmpty } ?? ""

        let albumNameFromEmbedded = embeddedAlbum?.name ?? ""
        let albumNameFromFlat = QQWireDecoding.nonEmptyString(container, .albumname)
        albumName = albumNameFromEmbedded.isEmpty ? albumNameFromFlat : albumNameFromEmbedded

        let albumIDFromEmbedded = embeddedAlbum?.id ?? 0
        let albumIDFromFlat = QQWireDecoding.int(container, .albumid)
        albumID = albumIDFromEmbedded != 0 ? albumIDFromEmbedded : albumIDFromFlat

        indexAlbum = QQWireDecoding.optionalInt(container, .indexAlbum)
        indexCD = QQWireDecoding.optionalInt(container, .indexCD)

        payPlay = QQWireDecoding.int(pay, .payPlay)

        // 无损标记：搜索是 file.size_flac，歌单/榜单是顶层 sizeflac。
        hasFlac = QQWireDecoding.int64(file, .flacSize) > 0
            || QQWireDecoding.int64(container, .sizeflac) > 0
        hasHires = QQWireDecoding.int64(file, .hiresSize) > 0
            || QQWireDecoding.int64(container, .sizehires) > 0

        if let mv, let value = try? mv.decode(String.self, forKey: .mvVID), !value.isEmpty {
            mvVID = value
        } else {
            mvVID = nil
        }
    }

    /// 用于 vkey filename：优先 media_mid，缺失时回退 songmid。
    var playbackMID: String { mediaMID.isEmpty ? mid : mediaMID }
}

// MARK: - 通用解码工具

/// 同一份 JSON 里同一个语义字段在不同接口是 Int / String / 缺失，
/// 这里统一用宽容解码，避免整包 throw。
nonisolated enum QQWireDecoding {
    static func int(
        _ container: KeyedDecodingContainer<QQWireSong.CodingKeys>?,
        _ keys: QQWireSong.CodingKeys...
    ) -> Int {
        guard let container else { return 0 }
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Int(text) {
                return value
            }
        }
        return 0
    }

    static func int64(
        _ container: KeyedDecodingContainer<QQWireSong.CodingKeys>?,
        _ keys: QQWireSong.CodingKeys...
    ) -> Int64 {
        guard let container else { return 0 }
        for key in keys {
            if let value = try? container.decode(Int64.self, forKey: key) {
                return value
            }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Int64(text) {
                return value
            }
        }
        return 0
    }

    static func nonEmptyString(
        _ container: KeyedDecodingContainer<QQWireSong.CodingKeys>?,
        _ keys: QQWireSong.CodingKeys...
    ) -> String {
        guard let container else { return "" }
        for key in keys {
            if let value = try? container.decode(String.self, forKey: key),
               !value.isEmpty {
                return value
            }
        }
        return ""
    }

    static func optionalInt(
        _ container: KeyedDecodingContainer<QQWireSong.CodingKeys>?,
        _ keys: QQWireSong.CodingKeys...
    ) -> Int? {
        guard let container else { return nil }
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Int(text) {
                return value
            }
        }
        return nil
    }
}

// MARK: - 歌手

nonisolated struct QQWireSinger: Decodable, Sendable {
    let id: Int
    let mid: String
    let name: String
    let pic: String?

    enum CodingKeys: String, CodingKey {
        case id, mid, name, pic
        case singerID = "singerID"
        case singerMID = "singerMID"
        case singerName = "singerName"
        case singerPic = "singerPic"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func intValue(_ key: CodingKeys) -> Int {
            if let value = try? container.decode(Int.self, forKey: key) {
                return value
            }
            if let text = try? container.decode(String.self, forKey: key),
               let value = Int(text) {
                return value
            }
            return 0
        }

        func stringValue(_ key: CodingKeys) -> String {
            if let value = try? container.decode(String.self, forKey: key), !value.isEmpty {
                return value
            }
            return ""
        }

        let primaryID = intValue(.id)
        let fallbackID = intValue(.singerID)
        id = primaryID != 0 ? primaryID : fallbackID

        let primaryMID = stringValue(.mid)
        let fallbackMID = stringValue(.singerMID)
        mid = primaryMID.isEmpty ? fallbackMID : primaryMID

        let primaryName = stringValue(.name)
        let fallbackName = stringValue(.singerName)
        name = primaryName.isEmpty ? fallbackName : primaryName

        let candidatePic = stringValue(.singerPic)
        if !candidatePic.isEmpty {
            pic = candidatePic
        } else if let value = try? container.decode(String.self, forKey: .pic), !value.isEmpty {
            pic = value
        } else {
            pic = nil
        }
    }
}

// MARK: - 专辑

nonisolated struct QQWireAlbum: Decodable, Sendable {
    let id: Int
    let mid: String
    let name: String
    let pic: String?
    let publicTime: String?
    let singerID: Int
    let singerMID: String
    let singerName: String
    let songCount: Int?
    let singers: [QQWireSinger]?

    /// 三种接口的专辑字段命名差异很大，全部列进 CodingKeys：
    ///
    /// - 搜索 / 单曲详情：`id`、`mid`、`name`、`title`、`time_public`
    /// - 专辑列表（music.musichallAlbum）：`albumID`、`albumMid`、`albumName`、`publishDate`、`totalNum`、`singerName`
    /// - 专辑详情：`mid`、`name`、`aDate`、`total`、`singername`
    enum CodingKeys: String, CodingKey {
        case id, mid, name, title, pic
        case singername, singermid, singerid
        case albumID, albumName, albumPic
        case albumMid = "albumMid"
        case albumMID = "albumMID"
        case publishDate, totalNum
        case publicTime
        case timePublic = "time_public"
        case aDate
        case singerID, singerMID, singerName
        case songCount = "song_count"
        case songNum = "songnum"
        case totalSongNum = "total_song_num"
        case singers = "singer_list"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func intValue(_ keys: CodingKeys...) -> Int {
            for key in keys {
                if let value = try? container.decode(Int.self, forKey: key) {
                    return value
                }
                if let text = try? container.decode(String.self, forKey: key),
                   let value = Int(text) {
                    return value
                }
            }
            return 0
        }

        func stringValue(_ keys: CodingKeys...) -> String {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key),
                   !value.isEmpty {
                    return value
                }
            }
            return ""
        }

        let primaryID = intValue(.id)
        let fallbackID = intValue(.albumID)
        id = primaryID != 0 ? primaryID : fallbackID

        mid = stringValue(.mid, .albumMID, .albumMid)
        name = stringValue(.name, .title, .albumName)

        let candidatePic = stringValue(.albumPic)
        if !candidatePic.isEmpty {
            pic = candidatePic
        } else if let value = try? container.decode(String.self, forKey: .pic), !value.isEmpty {
            pic = value
        } else {
            pic = nil
        }

        let candidateTime = stringValue(.publicTime, .timePublic, .aDate, .publishDate)
        publicTime = candidateTime.isEmpty ? nil : candidateTime

        singerID = intValue(.singerID, .singerid)
        singerMID = stringValue(.singerMID, .singermid)
        singerName = stringValue(.singerName, .singername)

        let counts = [
            intValue(.songCount),
            intValue(.songNum),
            intValue(.totalSongNum),
            intValue(.totalNum),
        ]
        songCount = counts.first { $0 > 0 }

        singers = (try? container.decode([QQWireSinger].self, forKey: .singers))
    }
}

// MARK: - 歌单

nonisolated struct QQWirePlaylist: Decodable, Sendable {
    /// FNV-1a 64 位，取正值，供纯字符串 ID 稳定映射到 Int。
    /// 不用 `hashValue`：它跨进程会变，会导致收藏/历史在重启后失配。
    static func stableID(_ value: String) -> Int {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_093_979_221_705_149_909
        }
        return Int(hash & 0x7fff_ffff_ffff_ffff)
    }

    let id: Int
    let dissID: String
    let name: String
    let logo: String?
    let playlistDescription: String?
    let songCount: Int
    let playCount: Int
    let creatorName: String?
    let creatorUIN: String?
    let songs: [QQWireSong]?

    enum CodingKeys: String, CodingKey {
        case logo, imgurl, creator, uin, nick, dissid, dissname, desc
        case introduction
        case songCount = "song_count"
        case songNum = "songnum"
        case playCount = "listennum"
        case songs = "songlist"
    }

    /// creator 在搜索结果里是对象（`name` / `creator_uin`），
    /// 在歌单详情里是平铺的 `nick` / `uin`。
    private enum CreatorCodingKeys: String, CodingKey {
        case name, nick
        case creatorUIN = "creator_uin"
        case uin
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        func intValue(_ keys: CodingKeys...) -> Int {
            for key in keys {
                if let value = try? container.decode(Int.self, forKey: key) {
                    return value
                }
                if let text = try? container.decode(String.self, forKey: key),
                   let value = Int(text) {
                    return value
                }
            }
            return 0
        }

        func stringValue(_ keys: CodingKeys...) -> String {
            for key in keys {
                if let value = try? container.decode(String.self, forKey: key),
                   !value.isEmpty {
                    return value
                }
            }
            return ""
        }

        let dissText = stringValue(.dissid)
        dissID = dissText
        id = Int(dissText) ?? Self.stableID(dissText)

        name = stringValue(.dissname)

        let candidateLogo = stringValue(.imgurl)
        if !candidateLogo.isEmpty {
            logo = candidateLogo
        } else if let value = try? container.decode(String.self, forKey: .logo), !value.isEmpty {
            logo = value
        } else {
            logo = nil
        }

        let candidateDesc = stringValue(.desc)
        if !candidateDesc.isEmpty {
            playlistDescription = candidateDesc
        } else if let value = try? container.decode(String.self, forKey: .introduction),
                  !value.isEmpty {
            playlistDescription = value
        } else {
            playlistDescription = nil
        }

        // 搜索结果用 song_count，歌单详情用 songnum。
        songCount = intValue(.songCount, .songNum)
        playCount = intValue(.playCount)

        songs = try? container.decode([QQWireSong].self, forKey: .songs)

        var resolvedName: String?
        var resolvedUIN: String?
        if let creator = try? container.nestedContainer(
            keyedBy: CreatorCodingKeys.self,
            forKey: .creator
        ) {
            if let value = try? creator.decode(String.self, forKey: .name), !value.isEmpty {
                resolvedName = value
            } else if let value = try? creator.decode(String.self, forKey: .nick), !value.isEmpty {
                resolvedName = value
            }

            if let value = try? creator.decode(String.self, forKey: .creatorUIN), !value.isEmpty {
                resolvedUIN = value
            } else if let value = try? creator.decode(Int.self, forKey: .creatorUIN) {
                resolvedUIN = String(value)
            } else if let value = try? creator.decode(String.self, forKey: .uin), !value.isEmpty {
                resolvedUIN = value
            }
        }
        if resolvedName == nil {
            let flat = stringValue(.nick)
            resolvedName = flat.isEmpty ? nil : flat
        }
        if resolvedUIN == nil {
            let flat = stringValue(.uin)
            resolvedUIN = flat.isEmpty ? nil : flat
        }
        creatorName = resolvedName
        creatorUIN = resolvedUIN
    }
}

// MARK: - 歌单详情（GET fcg_ucc_getcdinfo_byids_cp.fcg）

nonisolated struct QQPlaylistDetailEnvelope: Decodable, Sendable {
    let code: Int?
    let cdlist: [QQWirePlaylist]
}

// MARK: - 专辑详情（GET fcg_v8_album_info_cp.fcg）

nonisolated struct QQAlbumDetailEnvelope: Decodable, Sendable {
    let code: Int?
    let data: AlbumDetail?

    nonisolated struct AlbumDetail: Decodable, Sendable {
        let name: String
        let albumMID: String?
        let singerName: String?
        let pubtime: String?
        let total: Int?
        let list: [QQWireSong]?

        enum CodingKeys: String, CodingKey {
            case name, mid, pubtime, total, list
            case aDate
            case albumMID = "albummid"
            case singerName = "singername"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = (try? container.decode(String.self, forKey: .name)) ?? ""

            if let value = try? container.decode(String.self, forKey: .albumMID), !value.isEmpty {
                albumMID = value
            } else {
                albumMID = try? container.decode(String.self, forKey: .mid)
            }

            if let value = try? container.decode(String.self, forKey: .singerName), !value.isEmpty {
                singerName = value
            } else {
                singerName = nil
            }

            if let value = try? container.decode(String.self, forKey: .pubtime), !value.isEmpty {
                pubtime = value
            } else {
                pubtime = try? container.decode(String.self, forKey: .aDate)
            }

            total = try? container.decode(Int.self, forKey: .total)
            list = try? container.decode([QQWireSong].self, forKey: .list)
        }
    }
}

// MARK: - 歌手详情（GET musicu.fcg data=...）

nonisolated struct QQArtistDetailEnvelope: Decodable, Sendable {
    let singer: Singer?

    nonisolated struct Singer: Decodable, Sendable {
        let code: Int?
        let data: ArtistData?
    }

    nonisolated struct ArtistData: Decodable, Sendable {
        let singerInfo: QQWireSinger?
        let songlist: [QQWireSong]?
        let albumlist: [QQWireAlbum]?

        enum CodingKeys: String, CodingKey {
            case songlist, albumlist
            case singerInfo = "singer_info"
        }
    }
}

// MARK: - 排行榜（GET fcg_v8_toplist_cp.fcg）

nonisolated struct QQToplistEnvelope: Decodable, Sendable {
    let code: Int?
    let topinfo: TopInfo?
    let songlist: [ToplistItem]?

    nonisolated struct TopInfo: Decodable, Sendable {
        let listName: String?
        let pic: String?

        enum CodingKeys: String, CodingKey {
            case pic
            case listName = "ListName"
        }
    }

    nonisolated struct ToplistItem: Decodable, Sendable {
        let data: QQWireSong?
    }
}

// MARK: - client_search_cp 兜底搜索（GET）

nonisolated struct QQCPSearchEnvelope: Decodable, Sendable {
    let code: Int?
    let data: SearchData?

    nonisolated struct SearchData: Decodable, Sendable {
        let song: SongList?
    }

    nonisolated struct SongList: Decodable, Sendable {
        let list: [QQWireSong]?
    }
}

// MARK: - 播放地址（POST musicu.fcg vkey.GetVkeyServer.CgiGetVkey）

nonisolated struct QQVkeyEnvelope: Decodable, Sendable {
    let req1: Req

    enum CodingKeys: String, CodingKey {
        case req1 = "req_1"
    }

    nonisolated struct Req: Decodable, Sendable {
        let code: Int?
        let data: VkeyData?
    }

    nonisolated struct VkeyData: Decodable, Sendable {
        let sip: [String]?
        let midurlinfo: [MidURLInfo]?
    }

    nonisolated struct MidURLInfo: Decodable, Sendable {
        let purl: String?
        let result: Int?
        let vkey: String?
    }
}

// MARK: - 歌词（POST musicu.fcg music.musichallSong.PlayLyricInfo）

nonisolated struct QQLyricEnvelope: Decodable, Sendable {
    let req: Req?

    nonisolated struct Req: Decodable, Sendable {
        let code: Int?
        let data: LyricData?
    }

    nonisolated struct LyricData: Decodable, Sendable {
        let lyric: String?
        let trans: String?
        let roma: String?
    }
}

// MARK: - 歌词（GET fcg_query_lyric_new.fcg，明文兜底）

nonisolated struct QQPlainLyricEnvelope: Decodable, Sendable {
    let retcode: Int?
    let lyric: String?
    let trans: String?
    let roma: String?
}

// MARK: - 单曲详情（GET fcg_play_single_song.fcg）

nonisolated struct QQSingleSongEnvelope: Decodable, Sendable {
    let code: Int?
    let data: [QQWireSong]?
}
