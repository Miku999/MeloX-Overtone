import Foundation

enum ListenedCollection: Codable {
    case album(Album)
    case playlist(Playlist)
}

struct RecentMusicCollection: Codable, Identifiable {
    let collection: ListenedCollection
    let playedAt: Date

    var id: String {
        switch collection {
        case .album(let album): "album.\(album.id)"
        case .playlist(let playlist): "playlist.\(playlist.id)"
        }
    }

    init(_ collection: ListenedCollection, at date: Date) {
        switch collection {
        case .album:
            self.collection = collection
        case .playlist(var playlist):
            // History only needs the summary to reopen the collection.
            playlist.tracks = []
            playlist.trackIDs = []
            self.collection = .playlist(playlist)
        }
        playedAt = date
    }
}
