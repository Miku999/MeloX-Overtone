import SwiftUI

struct QueueView: View {
    @Environment(PlayerStore.self) private var player

    var body: some View {
        List(Array(player.queue.enumerated()), id: \.offset) { index, song in
            Button {
                Task { await player.playFromQueue(at: index) }
            } label: {
                TrackRowView(song: song, showsArtwork: true, representsCurrentEntry: index == player.currentIndex)
            }
            .buttonStyle(.plain)
            .songSwipeActions(song, removal: index == player.currentIndex ? .none : .action("ui.player.remove_from_queue") {
                player.removeQueuedSong(at: index, matching: song.id)
            }, next: { Task { await player.promoteQueuedSong(at: index, matching: song) } })
        }
        .listStyle(.plain)
        .navigationTitle("ui.player.up_next")
        .overlay {
            if player.queue.isEmpty {
                ContentUnavailableView("ui.player.queue_empty", systemImage: "list.bullet")
            }
        }
    }
}
