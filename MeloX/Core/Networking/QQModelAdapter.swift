import Foundation

/// 把 QQ 音乐的原始解码结构转换成 MeloX 现有模型。
/// 所有输出模型保持 MeloX 原有 init 与字段语义，UI 层无需改动。
///
/// 注意：`Playlist` / `UserSummary` / `TrackReference` 在项目里没有标记
/// `nonisolated`，随工程默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 隔离，
/// 所以这里也跟随默认隔离，不写 `nonisolated`。
enum QQModelAdapter {

    // MARK: - 封面

    /// QQ 音乐封面：albummid 拼 gtimg CDN，指定 800×800。
    static func artworkURL(albumMID: String, dimension: Int = 800) -> String? {
        guard !albumMID.isEmpty else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T002R\(dimension)x\(dimension)M000\(albumMID).jpg"
    }

    static func artistArtworkURL(singerMID: String, dimension: Int = 300) -> String? {
        guard !singerMID.isEmpty else { return nil }
        return "https://y.gtimg.cn/music/photo_new/T001R\(dimension)x\(dimension)M000\(singerMID).jpg"
    }

    // MARK: - 歌手

    static func artist(from wire: QQWireSinger) -> Artist {
        QQIDRegistry.shared.register(entity: "singer", numericID: wire.id, mid: wire.mid)
        return Artist(
            id: wire.id,
            name: wire.name.isEmpty ? L10n.string("ui.metadata.unknown_artist") : wire.name,
            picURL: wire.pic,
            avatarURL: artistArtworkURL(singerMID: wire.mid)
        )
    }

    // MARK: - 专辑

    static func album(from wire: QQWireAlbum) -> Album {
        QQIDRegistry.shared.register(entity: "album", numericID: wire.id, mid: wire.mid)

        var resolvedArtists = artists(from: wire.singers ?? [])
        if resolvedArtists.isEmpty, !wire.singerName.isEmpty {
            QQIDRegistry.shared.register(entity: "singer", numericID: wire.singerID, mid: wire.singerMID)
            resolvedArtists = [
                Artist(
                    id: wire.singerID,
                    name: wire.singerName,
                    avatarURL: artistArtworkURL(singerMID: wire.singerMID)
                )
            ]
        }

        return Album(
            id: wire.id,
            name: wire.name.isEmpty ? L10n.string("ui.metadata.unknown_album") : wire.name,
            picURL: wire.pic ?? artworkURL(albumMID: wire.mid),
            artists: resolvedArtists,
            publishTime: publishTime(from: wire.publicTime),
            size: wire.songCount
        )
    }

    static func album(fromSong song: QQWireSong) -> Album? {
        guard !song.albumMID.isEmpty || !song.albumName.isEmpty else { return nil }
        QQIDRegistry.shared.register(entity: "album", numericID: song.albumID, mid: song.albumMID)
        return Album(
            id: song.albumID,
            name: song.albumName.isEmpty ? L10n.string("ui.metadata.unknown_album") : song.albumName,
            picURL: artworkURL(albumMID: song.albumMID),
            artists: [],
            size: nil
        )
    }

    // MARK: - 歌曲

    static func song(from wire: QQWireSong) -> Song {
        // 登记 id -> mid，供播放/歌词阶段反查。
        QQIDRegistry.shared.register(songID: wire.songID, songMID: wire.mid)
        // vkey 的 filename 需要 media_mid（与 songmid 不一定相同），单独存一份。
        QQIDRegistry.shared.register(entity: "media", numericID: wire.songID, mid: wire.mediaMID)

        let resolvedArtists = artists(from: wire.singers)
        let resolvedAlbum: Album?
        if let embedded = wire.album {
            resolvedAlbum = album(from: embedded)
        } else {
            resolvedAlbum = album(fromSong: wire)
        }

        return Song(
            id: wire.songID,
            name: wire.name.isEmpty ? L10n.string("ui.metadata.unknown_song") : wire.name,
            artists: resolvedArtists,
            album: resolvedAlbum,
            durationMS: max(wire.interval, 0) * 1_000,
            trackNumber: wire.indexAlbum,
            disc: wire.indexCD.map { String($0) },
            fee: wire.payPlay,
            aliases: [],
            popularity: nil,
            publishTime: nil,
            copyright: nil,
            musicVideoID: nil,
            podcastMetadata: nil,
            audioAvailability: availability(for: wire)
        )
    }

    /// 用可用的音频位构造 availability，让音质选择器能判断可用档位。
    /// M4A(128k/AAC) -> standard；MP3 320 -> high；FLAC -> lossless。
    private static func availability(for wire: QQWireSong) -> SongAudioAvailability {
        var dict: [String: Any] = ["_meloxAudioAvailabilityKnown": true]
        dict["l"] = ["br": 128_000]
        dict["h"] = ["br": 320_000]
        if wire.hasFlac {
            dict["sq"] = ["br": 999_000]
        }
        if wire.hasHires {
            dict["hr"] = ["br": 1_800_000]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let decoded = try? JSONDecoder().decode(SongAudioAvailability.self, from: data) else {
            return .unknown
        }
        return decoded
    }

    // MARK: - 歌单

    static func playlist(from wire: QQWirePlaylist, tracks: [Song]? = nil) -> Playlist {
        let songs = tracks ?? songs(from: wire.songs ?? [])
        let creatorID = wire.creatorUIN.flatMap { Int($0) } ?? 0
        return Playlist(
            id: wire.id,
            name: wire.name.isEmpty ? L10n.string("ui.metadata.unknown_playlist") : wire.name,
            coverURLString: wire.logo,
            playlistDescription: wire.playlistDescription,
            trackCount: wire.songCount > 0 ? wire.songCount : songs.count,
            playCount: wire.playCount,
            creator: UserSummary(
                userID: creatorID,
                nickname: wire.creatorName ?? L10n.string("ui.lyrics.source.qq_music")
            ),
            tracks: songs,
            trackIDs: songs.map { TrackReference(id: $0.id) },
            subscribed: false
        )
    }

    // MARK: - 批量转换
    //
    // 不用 `.map(QQModelAdapter.song(from:))` 这种函数引用：
    // 本类型随工程默认 MainActor 隔离，函数引用传给非隔离的 `map`
    // 会触发「loses global actor」诊断。这里包一层普通方法调用。

    static func songs(from wires: [QQWireSong]) -> [Song] {
        var result: [Song] = []
        result.reserveCapacity(wires.count)
        for wire in wires {
            result.append(song(from: wire))
        }
        return result
    }

    static func albums(from wires: [QQWireAlbum]) -> [Album] {
        var result: [Album] = []
        result.reserveCapacity(wires.count)
        for wire in wires {
            result.append(album(from: wire))
        }
        return result
    }

    static func artists(from wires: [QQWireSinger]) -> [Artist] {
        var result: [Artist] = []
        result.reserveCapacity(wires.count)
        for wire in wires {
            result.append(artist(from: wire))
        }
        return result
    }

    static func playlists(from wires: [QQWirePlaylist]) -> [Playlist] {
        var result: [Playlist] = []
        result.reserveCapacity(wires.count)
        for wire in wires {
            result.append(playlist(from: wire))
        }
        return result
    }

    // MARK: - 时间

    private static func publishTime(from string: String?) -> Double? {
        guard let string, !string.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        guard let date = formatter.date(from: string) else { return nil }
        return date.timeIntervalSince1970 * 1_000
    }
}
