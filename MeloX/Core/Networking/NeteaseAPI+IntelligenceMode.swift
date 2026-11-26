import Foundation

extension NeteaseAPI {
    func intelligenceModeSongs(
        seedSongID: Int,
        playlistID: Int
    ) async throws -> [Song] {
        // QQ 音乐没有这个接口，走后端内的本地生成实现。
        // 不打这条分流的话请求会落到 eapi，未带网易云登录态时返回 301，
        // 用户看到的就是「音乐服务返回了错误（301）」。
        if QQMusicBackend.enabled {
            return try await qq.heartModeSongs(
                seedSongID: seedSongID,
                playlistID: playlistID
            )
        }
        // Mirrors @neteaseapireborn/api/module/playmode_intelligence_list.js.
        let response: IntelligenceModeResponse = try await client.eapi(
            "/api/playmode/intelligence/list",
            data: [
                "songId": seedSongID,
                "type": "fromPlayOne",
                "playlistId": playlistID,
                "startMusicId": seedSongID,
                "count": 1,
            ],
            authenticated: true
        )
        try validate(
            responseCode: response.code,
            message: response.message
        )

        let songIDs = response.data
            .map(\.id)
            .filter { $0 > 0 }
        guard !songIDs.isEmpty else {
            throw IntelligenceModeError.emptyRecommendations
        }

        let songs = try await songDetails(ids: songIDs)
        var songsByID: [Int: Song] = [:]
        for song in songs {
            songsByID[song.id] = song
        }
        let orderedSongs = songIDs.compactMap { songsByID[$0] }
        guard !orderedSongs.isEmpty else {
            throw IntelligenceModeError.emptyRecommendations
        }
        return orderedSongs
    }
}

private enum IntelligenceModeError: LocalizedError {
    case emptyRecommendations

    var errorDescription: String? {
        L10n.string("ui.error.heart_mode.no_playable_song")
    }
}
