import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    private(set) var songIndex = LibraryIndexCache<LibrarySongIndex.Request, LibrarySongIndex>()
    let downloadIndex = LibraryIndexCache<LibrarySongIndex.Request, LibrarySongIndex>()
    private(set) var albumIndex = LibraryIndexCache<LibraryAlbumIndex.Request, LibraryAlbumIndex>()
    private(set) var artistIndex = LibraryIndexCache<ArtistIndexRequest, [ArtistSection]>()
    private(set) var profile: AccountProfile?
    private(set) var accountDetail: AccountDetail?
    private(set) var favoriteSongs: [Song] = []
    private(set) var favoritePlaylists: [Playlist] = []
    private(set) var favoriteAlbums: [Album] = []
    private(set) var favoriteArtists: [Artist] = []
    private(set) var subscribedPodcasts: [Podcast] = []
    private(set) var recentSongs: [Song] = []
    private(set) var recentCollections: [RecentMusicCollection] = []
    private(set) var playlistPlayDates: [Int: Date] = [:]
    private(set) var likedPlaylist: Playlist?
    var likedPlaylistID: Int? { likedPlaylist?.id }
    private(set) var favoriteSongTotalCount = 0
    private(set) var favoriteSongsNextOffset = 0
    private(set) var subscribedPodcastTotalCount = 0
    private(set) var subscribedPodcastsNextOffset = 0
    private(set) var hasMoreSubscribedPodcasts = false
    private(set) var isLoadingMoreSubscribedPodcasts = false
    private(set) var subscribedPodcastsLoadMoreError: String?
    private(set) var phase: LoadingPhase = .loaded
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let api: NeteaseAPI

    @ObservationIgnored
    private let settings: AppSettings

    @ObservationIgnored
    private var loadedCookie: String?

    @ObservationIgnored
    private var lastSuccessfulRefresh: Date?

    @ObservationIgnored
    private var refreshingCookie: String?

    @ObservationIgnored
    private(set) var favoriteAddedDates: [Int: Date] = [:]
    private var favoriteSongIDs: [Int] = []

    private var favoriteSongIDSet: Set<Int> = []

    @ObservationIgnored
    private let subscribedPodcastPageSize = 50

    @ObservationIgnored
    private var subscribedPodcastPageLoadTask: Task<Void, Never>?

    @ObservationIgnored
    private var subscribedPodcastPageLoadID: UUID?

    init(api: NeteaseAPI, settings: AppSettings) {
        self.api = api
        self.settings = settings
    }

    var isLoggedIn: Bool {
        !settings.cookie.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var ownedPlaylists: [Playlist] {
        guard let userID = profile?.id else { return [] }
        return favoritePlaylists.filter { $0.creator?.userID == userID }
    }

    var hasMoreFavoriteSongs: Bool {
        favoriteSongsNextOffset < favoriteSongTotalCount
    }

    var canStartHeartMode: Bool {
        likedPlaylistID != nil && favoriteSongTotalCount > 0
    }

    func randomHeartModeSeedSongID() -> Int? {
        favoriteSongIDs.randomElement()
    }

    func contains(song: Song) -> Bool {
        favoriteSongIDSet.contains(song.id)
    }

    func contains(playlist: Playlist) -> Bool {
        playlist.id == likedPlaylistID || favoritePlaylists.contains { $0.id == playlist.id }
    }

    func contains(artist: Artist) -> Bool {
        favoriteArtists.contains { $0.id == artist.id }
    }

    func contains(album: Album) -> Bool {
        favoriteAlbums.contains { $0.id == album.id }
    }

    func setArtistFollowed(_ artist: Artist, isFollowed: Bool) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        try await api.setArtistFollowed(id: artist.id, isFollowed: isFollowed)
        favoriteArtists.removeAll { $0.id == artist.id }
        if isFollowed {
            favoriteArtists.insert(artist, at: 0)
        }
        await persistContent()
    }

    func setAlbumSubscribed(
        _ album: Album,
        isSubscribed: Bool
    ) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        try await api.setAlbumSubscribed(id: album.id, isSubscribed: isSubscribed)
        favoriteAlbums.removeAll { $0.id == album.id }
        if isSubscribed {
            favoriteAlbums.insert(album, at: 0)
        }
        await persistContent()
    }

    func contains(podcast: Podcast) -> Bool {
        subscribedPodcasts.contains { $0.id == podcast.id }
    }

    func recordCollectionPlayback(_ collection: ListenedCollection) {
        guard isLoggedIn, settings.isContentFeatureEnabled(.listeningHistory) else { return }
        let now = Date()
        if case .playlist(let playlist) = collection {
            playlistPlayDates[playlist.id] = now
        }
        mergeRecentCollections([RecentMusicCollection(collection, at: now)])
        persistContentInBackground()
    }

    private func mergeRecentCollections(_ records: [RecentMusicCollection]) {
        var seen: Set<String> = []
        recentCollections = Array((recentCollections + records)
            .sorted { $0.playedAt > $1.playedAt }
            .filter { seen.insert($0.id).inserted }
            .prefix(24))
    }

    func recordRecentlyPlayed(_ song: Song) {
        guard settings.isContentFeatureEnabled(.listeningHistory) else {
            return
        }
        recentSongs.removeAll { $0.id == song.id }
        recentSongs.insert(song, at: 0)
        if recentSongs.count > 100 {
            recentSongs.removeLast(recentSongs.count - 100)
        }
        persistContentInBackground()
    }

    func canUnsubscribe(_ playlist: Playlist) -> Bool {
        playlist.id != likedPlaylistID && playlist.creator?.userID != profile?.id
    }

    func refresh(force: Bool = false) async {
        let cookie = settings.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cookie.isEmpty else {
            clearAccountData()
            return
        }
        guard refreshingCookie != cookie else { return }
        let isFresh = lastSuccessfulRefresh.map {
            Date().timeIntervalSince($0) < 300
        } ?? false
        guard force || loadedCookie != cookie || phase != .loaded || !isFresh else { return }
        refreshingCookie = cookie
        defer {
            if refreshingCookie == cookie {
                refreshingCookie = nil
            }
        }

        if loadedCookie != cookie {
            clearRemoteContent()
            loadedCookie = cookie
            if let snapshot: LibraryContentSnapshot = await api.pageContentCache.value(
                for: LibraryContentSnapshot.cacheKey
            ) {
                guard isCurrentRefresh(cookie) else { return }
                restoreContent(snapshot)
            }
            guard isCurrentRefresh(cookie) else { return }
        }
        phase = .loading
        errorMessage = nil
        subscribedPodcastsLoadMoreError = nil

        do {
            let loadedProfile = try await api.accountProfile()
            guard isCurrentRefresh(cookie) else { return }

            profile = loadedProfile
            loadedCookie = cookie

            var partialFailures: [String] = []
            do {
                let loadedAccountDetail = try await api.userDetail(
                    userID: loadedProfile.id
                )
                guard isCurrentRefresh(cookie) else { return }
                accountDetail = loadedAccountDetail
                profile = loadedAccountDetail.profile
            } catch is CancellationError {
                return
            } catch {
                // The account endpoint still provides enough identity data
                // for the settings row when extended profile details fail.
            }

            var loadedPlaylists: [Playlist] = []
            do {
                loadedPlaylists = try await api.userPlaylists(userID: loadedProfile.id)
                guard isCurrentRefresh(cookie) else { return }
                likedPlaylist = loadedPlaylists.first
                favoritePlaylists = Array(loadedPlaylists.dropFirst())
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(L10n.format("ui.library.error.playlists", error.localizedDescription))
            }

            var refreshedAlbums: [Album]?
            var refreshedArtists: [Artist]?
            let priorAlbums = favoriteAlbums
            let priorArtists = favoriteArtists
            do {
                let albums = try await api.subscribedAlbums()
                guard isCurrentRefresh(cookie) else { return }
                refreshedAlbums = albums
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(
                    L10n.format("ui.library.error.favorite_albums", error.localizedDescription)
                )
            }

            do {
                let artists = try await api.subscribedArtists()
                guard isCurrentRefresh(cookie) else { return }
                refreshedArtists = artists
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(
                    L10n.format("ui.library.error.favorite_artists", error.localizedDescription)
                )
            }

            if settings.isContentFeatureEnabled(.podcasts) {
                do {
                    let page = try await api.subscribedPodcasts(
                        limit: subscribedPodcastPageSize
                    )
                    guard isCurrentRefresh(cookie) else { return }
                    subscribedPodcasts = normalizedSubscribedPodcasts(
                        page.podcasts
                    )
                    subscribedPodcastTotalCount = max(
                        page.totalCount ?? subscribedPodcasts.count,
                        subscribedPodcasts.count
                    )
                    subscribedPodcastsNextOffset = page.podcasts.count
                    hasMoreSubscribedPodcasts = page.hasMore
                    subscribedPodcastsLoadMoreError = nil
                } catch is CancellationError {
                    return
                } catch {
                    partialFailures.append(
                        L10n.format("ui.library.error.subscribed_podcasts", error.localizedDescription)
                    )
                }
            }

            do {
                let priorIDs = favoriteSongIDs
                let (references, cover) = try await api.likedSongReferences(
                    userID: loadedProfile.id,
                    likedPlaylistID: likedPlaylistID
                )
                guard isCurrentRefresh(cookie) else { return }
                if let cover, !cover.isEmpty { likedPlaylist?.coverURLString = cover }
                let loadedSongIDs = references.map(\.id)
                // Resolve missing metadata before publishing any new ordering.
                let songs = try await api.songDetailsCollection(
                    ids: loadedSongIDs, prefetched: force ? [] : favoriteSongs
                )
                guard isCurrentRefresh(cookie) else { return }
                guard loadedSongIDs.isEmpty || !songs.isEmpty else { throw APIError.invalidResponse }
                if priorIDs == favoriteSongIDs {
                    favoriteAddedDates = references.reduce(into: [:]) { dates, track in
                        if let milliseconds = track.addedMilliseconds, milliseconds > 0 {
                            dates[track.id] = Date(timeIntervalSince1970: milliseconds / 1000)
                        } else {
                            dates[track.id] = favoriteAddedDates[track.id]
                        }
                    }
                    favoriteSongIDs = loadedSongIDs
                    favoriteSongIDSet = Set(loadedSongIDs)
                    favoriteSongTotalCount = loadedSongIDs.count
                    favoriteSongs = songs
                    favoriteSongsNextOffset = loadedSongIDs.count
                }
            } catch is CancellationError {
                return
            } catch {
                partialFailures.append(L10n.format("ui.library.error.favorite_songs", error.localizedDescription))
            }

            guard isCurrentRefresh(cookie) else { return }
            if let refreshedAlbums, favoriteAlbums == priorAlbums { favoriteAlbums = refreshedAlbums }
            if let refreshedArtists, favoriteArtists == priorArtists { favoriteArtists = refreshedArtists }

            if settings.isContentFeatureEnabled(.listeningHistory) {
                async let albums = try? api.recentAlbums()
                async let playlists = try? api.recentPlaylists()
                do {
                    let songs = try await api.recentSongs()
                    guard isCurrentRefresh(cookie) else { return }
                    recentSongs = songs
                } catch is CancellationError {
                    return
                } catch {
                    partialFailures.append(
                        L10n.format("ui.library.error.history", error.localizedDescription)
                    )
                }
                let records = await (albums ?? []) + (playlists ?? [])
                guard isCurrentRefresh(cookie) else { return }
                mergeRecentCollections(records)
            }

            guard isCurrentRefresh(cookie) else { return }
            if !partialFailures.isEmpty {
                errorMessage = L10n.format(
                    "ui.library.error.partial",
                    partialFailures.joined(separator: "\n")
                )
            }
            lastSuccessfulRefresh = partialFailures.isEmpty ? Date() : nil
            phase = .loaded
            await persistContent()
        } catch is CancellationError {
            return
        } catch APIError.notLoggedIn {
            guard isCurrentRefresh(cookie) else { return }
            settings.clearAccount()
            clearAccountData()
        } catch {
            guard isCurrentRefresh(cookie) else { return }
            lastSuccessfulRefresh = nil
            if profile == nil {
                phase = .failed(error.localizedDescription)
            } else {
                phase = .loaded
                errorMessage = L10n.format("ui.library.error.account_refresh", error.localizedDescription)
            }
        }
    }

    private func isCurrentRefresh(_ cookie: String) -> Bool {
        !Task.isCancelled && refreshingCookie == cookie
            && settings.cookie.trimmingCharacters(in: .whitespacesAndNewlines) == cookie
    }

    func loadMoreSubscribedPodcasts() async {
        guard settings.isContentFeatureEnabled(.podcasts) else { return }
        if let subscribedPodcastPageLoadTask {
            await subscribedPodcastPageLoadTask.value
            return
        }

        guard hasMoreSubscribedPodcasts else { return }

        let requestedOffset = subscribedPodcastsNextOffset
        let loadID = UUID()
        let loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadSubscribedPodcastPage(
                offset: requestedOffset
            )
        }
        subscribedPodcastPageLoadID = loadID
        subscribedPodcastPageLoadTask = loadTask

        await loadTask.value

        guard subscribedPodcastPageLoadID == loadID else { return }
        subscribedPodcastPageLoadTask = nil
        subscribedPodcastPageLoadID = nil
    }

    func loadRemainingSubscribedPodcasts() async {
        while hasMoreSubscribedPodcasts {
            guard !Task.isCancelled else { return }
            let previousOffset = subscribedPodcastsNextOffset
            await loadMoreSubscribedPodcasts()
            guard subscribedPodcastsNextOffset > previousOffset else {
                return
            }
        }
    }

    private func loadSubscribedPodcastPage(
        offset requestedOffset: Int
    ) async {
        isLoadingMoreSubscribedPodcasts = true
        subscribedPodcastsLoadMoreError = nil
        defer { isLoadingMoreSubscribedPodcasts = false }

        do {
            let page = try await api.subscribedPodcasts(
                offset: requestedOffset,
                limit: subscribedPodcastPageSize
            )
            try Task.checkCancellation()
            guard subscribedPodcastsNextOffset == requestedOffset else {
                return
            }

            var loadedIDs = Set(subscribedPodcasts.map(\.id))
            subscribedPodcasts.append(
                contentsOf: normalizedSubscribedPodcasts(
                    page.podcasts
                ).filter {
                    loadedIDs.insert($0.id).inserted
                }
            )
            subscribedPodcastsNextOffset =
                requestedOffset + page.podcasts.count
            subscribedPodcastTotalCount = max(
                page.totalCount ?? subscribedPodcastTotalCount,
                subscribedPodcasts.count
            )
            hasMoreSubscribedPodcasts =
                page.hasMore && !page.podcasts.isEmpty
            await persistContent()
        } catch is CancellationError {
            return
        } catch {
            subscribedPodcastsLoadMoreError =
                error.localizedDescription
        }
    }

    func toggle(song: Song) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }

        let wasLiked = contains(song: song)
        let previousDate = favoriteAddedDates[song.id]
        setLocalSong(song, isLiked: !wasLiked)

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.api.setSongLiked(id: song.id, isLiked: !wasLiked)
            } catch {
                self.setLocalSong(song, isLiked: wasLiked, addedAt: previousDate)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func toggle(playlist: Playlist) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }

        let wasSubscribed = contains(playlist: playlist)
        guard !wasSubscribed || canUnsubscribe(playlist) else { return }
        if wasSubscribed {
            favoritePlaylists.removeAll { $0.id == playlist.id }
        } else {
            var summary = playlist
            summary.tracks = []
            favoritePlaylists.insert(summary, at: 0)
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.api.setPlaylistSubscribed(
                    id: playlist.id,
                    isSubscribed: !wasSubscribed
                )
            } catch {
                if wasSubscribed {
                    self.favoritePlaylists.insert(playlist, at: 0)
                } else {
                    self.favoritePlaylists.removeAll { $0.id == playlist.id }
                }
                self.errorMessage = error.localizedDescription
            }
            await self.persistContent()
        }
    }

    func toggle(podcast: Podcast) {
        guard isLoggedIn else {
            errorMessage = APIError.notLoggedIn.localizedDescription
            return
        }

        let desiredState = !contains(podcast: podcast)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.setPodcastSubscribed(
                    podcast,
                    isSubscribed: desiredState
                )
            } catch is CancellationError {
                return
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func setPodcastSubscribed(
        _ podcast: Podcast,
        isSubscribed: Bool
    ) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }

        let previousPodcasts = subscribedPodcasts
        let previousTotalCount = subscribedPodcastTotalCount
        let previousNextOffset = subscribedPodcastsNextOffset
        let previousHasMore = hasMoreSubscribedPodcasts
        setLocalPodcast(podcast, isSubscribed: isSubscribed)

        do {
            try await api.setPodcastSubscribed(
                id: podcast.id,
                isSubscribed: isSubscribed
            )
        } catch {
            subscribedPodcasts = previousPodcasts
            subscribedPodcastTotalCount = previousTotalCount
            subscribedPodcastsNextOffset = previousNextOffset
            hasMoreSubscribedPodcasts = previousHasMore
            await persistContent()
            throw error
        }
    }

    func canDelete(_ playlist: Playlist) -> Bool {
        guard isLoggedIn, let userID = profile?.id else { return false }
        return playlist.creator?.userID == userID && playlist.id != likedPlaylistID
    }

    func deletePlaylist(_ playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard canDelete(playlist) else { throw LibraryOperationError.playlistIsNotOwned }
        try await api.deletePlaylist(id: playlist.id)
        favoritePlaylists.removeAll { $0.id == playlist.id }
        await persistContent()
    }

    func createPlaylist(name: String, isPrivate: Bool) async throws {
        guard isLoggedIn, let profile else { throw APIError.notLoggedIn }
        let created = try await api.createPlaylist(name: name, isPrivate: isPrivate)
        let summary = Playlist(
            id: created.id,
            name: created.name,
            coverURLString: created.coverURLString,
            creator: UserSummary(userID: profile.id, nickname: profile.nickname)
        )
        favoritePlaylists.insert(summary, at: 0)
        await persistContent()
    }

    func remove(song: Song, from playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard canDelete(playlist) else { throw LibraryOperationError.playlistIsNotOwned }
        try await api.removeSong(id: song.id, fromPlaylistID: playlist.id)
        if let index = favoritePlaylists.firstIndex(where: { $0.id == playlist.id }) {
            favoritePlaylists[index].removeSong(id: song.id)
        }
        await persistContent()
    }

    func add(song: Song, to playlist: Playlist) async throws {
        guard isLoggedIn else { throw APIError.notLoggedIn }
        guard playlist.creator?.userID == profile?.id else {
            throw LibraryOperationError.playlistIsNotOwned
        }
        try await api.addSong(id: song.id, toPlaylistID: playlist.id)
    }

    func clearAccountData() {
        if let cookie = loadedCookie {
            let cache = api.pageContentCache
            Task { await cache.removeAccount(cookie: cookie) }
        }
        loadedCookie = nil
        clearRemoteContent()
        phase = .loaded
        errorMessage = nil
    }

    func clearError() {
        errorMessage = nil
    }

    private func clearRemoteContent() {
        songIndex = LibraryIndexCache()
        albumIndex = LibraryIndexCache()
        artistIndex = LibraryIndexCache()
        lastSuccessfulRefresh = nil
        subscribedPodcastPageLoadTask?.cancel()
        subscribedPodcastPageLoadTask = nil
        subscribedPodcastPageLoadID = nil
        profile = nil
        accountDetail = nil
        favoriteSongs = []
        favoritePlaylists = []
        favoriteAlbums = []
        favoriteArtists = []
        subscribedPodcasts = []
        recentSongs = []
        recentCollections = []
        playlistPlayDates = [:]
        likedPlaylist = nil
        favoriteAddedDates = [:]
        favoriteSongIDs = []
        favoriteSongIDSet = []
        favoriteSongTotalCount = 0
        favoriteSongsNextOffset = 0
        subscribedPodcastTotalCount = 0
        subscribedPodcastsNextOffset = 0
        hasMoreSubscribedPodcasts = false
        isLoadingMoreSubscribedPodcasts = false
        subscribedPodcastsLoadMoreError = nil
    }

    private func setLocalSong(
        _ song: Song,
        isLiked: Bool,
        addedAt: Date? = Date()
    ) {
        if let index = favoriteSongIDs.firstIndex(of: song.id) {
            favoriteSongIDs.remove(at: index)
            if index < favoriteSongsNextOffset {
                favoriteSongsNextOffset -= 1
            }
        }
        favoriteAddedDates[song.id] = isLiked ? addedAt : nil
        favoriteSongIDSet.remove(song.id)
        favoriteSongs.removeAll { $0.id == song.id }

        if isLiked {
            favoriteSongIDs.insert(song.id, at: 0)
            favoriteSongIDSet.insert(song.id)
            favoriteSongs.insert(song, at: 0)
            favoriteSongsNextOffset += 1
        }
        favoriteSongTotalCount = favoriteSongIDs.count
        persistContentInBackground()
    }

    private func setLocalPodcast(
        _ podcast: Podcast,
        isSubscribed: Bool
    ) {
        let wasSubscribed =
            contains(podcast: podcast) || podcast.isSubscribed
        subscribedPodcasts.removeAll { $0.id == podcast.id }

        if isSubscribed {
            var summary = podcast
            summary.isSubscribed = true
            subscribedPodcasts.insert(summary, at: 0)
        }

        if wasSubscribed != isSubscribed {
            subscribedPodcastTotalCount += isSubscribed ? 1 : -1
        }
        subscribedPodcastTotalCount = max(
            subscribedPodcastTotalCount,
            subscribedPodcasts.count
        )
        subscribedPodcastsNextOffset = subscribedPodcasts.count
        hasMoreSubscribedPodcasts =
            subscribedPodcastsNextOffset < subscribedPodcastTotalCount
        persistContentInBackground()
    }

    private func restoreContent(_ snapshot: LibraryContentSnapshot) {
        profile = snapshot.profile
        accountDetail = snapshot.accountDetail
        favoriteSongs = snapshot.favoriteSongs
        favoriteAddedDates = snapshot.favoriteAddedDates ?? [:]
        favoriteSongIDs = snapshot.favoriteSongIDs
        favoriteSongIDSet = Set(snapshot.favoriteSongIDs)
        favoriteSongTotalCount = snapshot.favoriteSongIDs.count
        favoriteSongsNextOffset = snapshot.favoriteSongsNextOffset
        favoritePlaylists = snapshot.favoritePlaylists
        favoriteAlbums = snapshot.favoriteAlbums
        favoriteArtists = snapshot.favoriteArtists
        subscribedPodcasts = snapshot.subscribedPodcasts
        subscribedPodcastTotalCount = snapshot.subscribedPodcastTotalCount
        subscribedPodcastsNextOffset = snapshot.subscribedPodcastsNextOffset
        hasMoreSubscribedPodcasts = snapshot.hasMoreSubscribedPodcasts
        recentSongs = snapshot.recentSongs
        playlistPlayDates = snapshot.playlistPlayDates ?? [:]
        recentCollections = snapshot.recentCollections ?? []
        likedPlaylist = snapshot.likedPlaylist ?? snapshot.likedPlaylistID.map {
            Playlist(id: $0, name: L10n.string("ui.library.playlists.favorite_songs"), trackCount: snapshot.favoriteSongIDs.count)
        }
        if snapshot.recentCollections == nil {
            let knownPlaylists = favoritePlaylists + [likedPlaylist].compactMap { $0 }
            mergeRecentCollections(knownPlaylists.compactMap { playlist in
                playlistPlayDates[playlist.id].map { RecentMusicCollection(.playlist(playlist), at: $0) }
            })
        }
    }

    private func persistContentInBackground() {
        Task { [weak self] in await self?.persistContent() }
    }

    private func persistContent() async {
        guard let profile,
              loadedCookie == settings.cookie.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return
        }
        let snapshot = LibraryContentSnapshot(
            profile: profile,
            accountDetail: accountDetail,
            favoriteSongs: favoriteSongs,
            favoriteSongIDs: favoriteSongIDs,
            favoriteSongsNextOffset: favoriteSongsNextOffset,
            favoritePlaylists: favoritePlaylists,
            favoriteAlbums: favoriteAlbums,
            favoriteArtists: favoriteArtists,
            subscribedPodcasts: subscribedPodcasts,
            subscribedPodcastTotalCount: subscribedPodcastTotalCount,
            subscribedPodcastsNextOffset: subscribedPodcastsNextOffset,
            hasMoreSubscribedPodcasts: hasMoreSubscribedPodcasts,
            recentSongs: recentSongs,
            likedPlaylistID: likedPlaylistID,
            favoriteAddedDates: favoriteAddedDates,
            likedPlaylist: likedPlaylist,
            recentCollections: recentCollections,
            playlistPlayDates: playlistPlayDates
        )
        await api.pageContentCache.store(snapshot, for: LibraryContentSnapshot.cacheKey)
    }

    private func normalizedSubscribedPodcasts(
        _ podcasts: [Podcast]
    ) -> [Podcast] {
        var identifiers = Set<Int>()
        return podcasts.compactMap { podcast in
            guard podcast.id > 0,
                  identifiers.insert(podcast.id).inserted else {
                return nil
            }
            var subscribedPodcast = podcast
            subscribedPodcast.isSubscribed = true
            return subscribedPodcast
        }
    }
}

private enum LibraryOperationError: LocalizedError {
    case playlistIsNotOwned

    var errorDescription: String? {
        switch self {
        case .playlistIsNotOwned:
            L10n.string("ui.library.error.owned_playlist_only")
        }
    }
}
