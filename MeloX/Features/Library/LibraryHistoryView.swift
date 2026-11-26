import SwiftUI

struct LibraryHistoryView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player

    var body: some View {
        List {
            if !displayedSongs.isEmpty {
                SongListPlaybackActions { shuffled in
                    let songs = displayedSongs
                    Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                }
            }

            ForEach(displayedSongs) { song in
                TrackRowView(song: song, showsArtwork: true) {
                    Task { await player.play(song, in: displayedSongs) }
                }
                .songSwipeActions(song)
            }
        }
        .navigationBarTitleDisplayMode(.large)
        .listStyle(.plain)
        .refreshable {
            await library.refresh(force: true)
        }
        .overlay {
            if displayedSongs.isEmpty {
                if isSearching {
                    ContentUnavailableView.search(
                        text: normalizedSearchQuery
                    )
                } else {
                    ContentUnavailableView(
                        "ui.library.no_history",
                        systemImage: "clock",
                        description: Text(
                            "ui.library.no_history.message"
                        )
                    )
                }
            }
        }
    }

    private var normalizedSearchQuery: String {
        normalizedLibrarySearchQuery(searchQuery)
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var displayedSongs: [Song] {
        filterMusicCollectionTracks(
            library.recentSongs,
            query: normalizedSearchQuery
        )
    }
}
