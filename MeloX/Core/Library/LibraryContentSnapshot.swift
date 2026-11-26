import Foundation

struct LibraryContentSnapshot: Codable {
    static let cacheKey = "library.v1"

    let profile: AccountProfile
    let accountDetail: AccountDetail?
    let favoriteSongs: [Song]
    let favoriteSongIDs: [Int]
    let favoriteSongsNextOffset: Int
    let favoritePlaylists: [Playlist]
    let favoriteAlbums: [Album]
    let favoriteArtists: [Artist]
    let subscribedPodcasts: [Podcast]
    let subscribedPodcastTotalCount: Int
    let subscribedPodcastsNextOffset: Int
    let hasMoreSubscribedPodcasts: Bool
    let recentSongs: [Song]
    let likedPlaylistID: Int?
    var favoriteAddedDates: [Int: Date]?
    var likedPlaylist: Playlist?
    var recentCollections: [RecentMusicCollection]?
    var playlistPlayDates: [Int: Date]?
}
