import SwiftUI

struct LibraryArtistsView: View {
    let searchQuery: String
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(\.locale) private var locale
    @State private var filter: LibrarySongFilter = .all

    var body: some View {
        let request = ArtistIndexRequest(
            followed: library.favoriteArtists, albums: library.favoriteAlbums, songs: library.favoriteSongs,
            downloads: AppFeatureAvailability.downloads ? downloads.downloadedSongs : [], filter: filter,
            query: normalizedLibrarySearchQuery(searchQuery), locale: locale,
            favoritesRevision: library.favoriteSongsRevision
        )
        let cached = library.artistIndex.value(for: request)
        let sections = cached ?? []
        List {
            ForEach(sections) { section in
                Section {
                    ForEach(section.artists) { artist in
                        NavigationLink(value: MusicRoute.artist(artist.id)) {
                            HStack(spacing: 12) {
                                ArtworkImage(url: artist.artworkURL, cornerRadius: 24, placeholderSymbol: "music.microphone")
                                    .frame(width: 48, height: 48)
                                Text(artist.name).lineLimit(1)
                            }
                            .overlay(alignment: .leading) {
                                if section.followedIDs.contains(artist.id) {
                                    LibraryFavoriteStar()
                                }
                            }
                        }
                        .musicMatchedTransitionSource(
                            for: .artist(artist.id),
                            prefetchArtworkAssets: false
                        )
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 16))
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 60 }
                    }
                } header: {
                    Text(section.title).font(.headline).foregroundStyle(.primary)
                }
                .sectionIndexLabel(section.title)
            }
        }
        .listStyle(.plain)
        .listSectionIndexVisibility(.visible)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFilterMenu(selection: $filter, allTitle: "ui.library.artists.all", allSymbol: "music.microphone")
            }
        }
        .task(id: request) {
            await library.artistIndex.load(request, isBrowsing: filter == .all && request.query.isEmpty) {
                try await request.build()
            }
        }
        .refreshable { await library.refresh(force: true) }
        .overlay {
            if sections.isEmpty {
                if cached == nil || library.phase == .loading {
                    ProgressView("ui.library.loading")
                } else if !request.query.isEmpty {
                    ContentUnavailableView.search(text: request.query)
                } else {
                    ContentUnavailableView("ui.library.artists.empty", systemImage: "music.microphone")
                }
            }
        }
    }
}

nonisolated struct ArtistSection: Identifiable {
    var id: String { title }
    let title: String
    let artists: [Artist]
    let followedIDs: Set<Int>
}

nonisolated struct ArtistIndexRequest: Equatable {
    let followed: [Artist]
    let albums: [Album]
    let songs: [Song]
    let downloads: [Song]
    let filter: LibrarySongFilter
    let query: String
    let locale: Locale

    init(
        followed: [Artist],
        albums: [Album],
        songs: [Song],
        downloads: [Song],
        filter: LibrarySongFilter,
        query: String,
        locale: Locale,
        favoritesRevision: Int = 0
    ) {
        self.followed = followed
        self.albums = albums
        self.songs = songs
        self.downloads = downloads
        self.filter = filter
        self.query = query
        self.locale = locale
        self.favoritesRevision = favoritesRevision
        self.followedCount = followed.count
        self.followedFirstID = followed.first?.id
        self.songsCount = songs.count
        self.songsFirstID = songs.first?.id
        self.albumsCount = albums.count
    }

    /// O(1) 指纹，避免每次 `body` 求值都深比较两千多首 `Song`。
    private let favoritesRevision: Int
    private let followedCount: Int
    private let followedFirstID: Int?
    private let songsCount: Int
    private let songsFirstID: Int?
    private let albumsCount: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.filter == rhs.filter
            && lhs.query == rhs.query
            && lhs.locale.identifier == rhs.locale.identifier
            && lhs.downloads.count == rhs.downloads.count
            && lhs.followedCount == rhs.followedCount
            && lhs.followedFirstID == rhs.followedFirstID
            && lhs.songsCount == rhs.songsCount
            && lhs.songsFirstID == rhs.songsFirstID
            && lhs.albumsCount == rhs.albumsCount
            && lhs.favoritesRevision == rhs.favoritesRevision
    }

    @concurrent func build() async throws -> [ArtistSection] {
        let favoriteIDs = Set(followed.map(\.id))
        let downloadedArtists = downloads.filter { !$0.isPodcastProgram }.flatMap(\.artists)
        let downloadedIDs = Set(downloadedArtists.map(\.id))
        var byID: [Int: Artist] = [:]
        let candidates: [Artist]
        switch filter {
        case .all: candidates = followed + albums.flatMap(\.artists) + songs.flatMap(\.artists) + downloadedArtists
        case .favorites: candidates = followed
        case .downloaded: candidates = followed.filter { downloadedIDs.contains($0.id) } + downloadedArtists
        }
        for artist in candidates where artist.id > 0 {
            try Task.checkCancellation()
            if byID[artist.id] == nil || (byID[artist.id]?.artworkURL == nil && artist.artworkURL != nil) {
                byID[artist.id] = artist
            }
        }
        var groups: [String: [(artist: Artist, key: String)]] = [:]
        for artist in byID.values {
            try Task.checkCancellation()
            guard query.isEmpty || ([artist.name] + artist.aliases).contains(where: { $0.localizedCaseInsensitiveContains(query) }) else { continue }
            let key = LibrarySongIndex.collationKey(artist.name, locale: locale)
            let letter = key.first.map { ("A"..."Z").contains($0) ? String($0) : "#" } ?? "#"
            groups[letter, default: []].append((artist, key))
        }
        var titles = groups.keys.filter { $0 != "#" }.sorted()
        if groups["#"] != nil { titles.append("#") }
        return titles.map { title in
            let artists = groups[title, default: []].sorted {
                let order = $0.key.compare($1.key, options: .numeric, locale: locale)
                return order == .orderedSame ? $0.artist.id < $1.artist.id : order == .orderedAscending
            }.map(\.artist)
            return ArtistSection(title: title, artists: artists, followedIDs: favoriteIDs)
        }
    }
}
