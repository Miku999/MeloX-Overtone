import SwiftUI

struct DailySongsView: View {
    @Environment(NeteaseAPI.self) private var api
    @Environment(PlayerStore.self) private var player

    @State private var songs: [Song] = []
    @State private var phase: LoadingPhase = .loading
    @State private var reloadToken = 0
    @State private var isRefreshing = false
    @State private var refreshErrorMessage: String?

    var body: some View {
        Group {
            switch phase {
            case .loading:
                ProgressView("ui.home.daily_songs.loading")
            case .failed(let message):
                ConnectionUnavailableView(message: message) {
                    reloadToken += 1
                }
            case .loaded:
                List {
                    if !songs.isEmpty {
                        SongListPlaybackActions { shuffled in
                            Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                        }
                    }
                    ForEach(songs) { song in
                        TrackRowView(song: song, showsArtwork: true) {
                            Task { await player.play(song, in: songs) }
                        }
                        .songSwipeActions(song)
                    }
                }
                .listStyle(.plain)
                .listRowSpacing(0)
                .environment(\.defaultMinListRowHeight, 56)
                .refreshable { await refresh() }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("ui.home.daily_songs.refresh", systemImage: "arrow.clockwise") {
                            Task { await refresh() }
                        }
                        .tint(.primary)
                        .disabled(isRefreshing)
                    }
                }
            }
        }
        .navigationTitle("ui.home.action.daily_songs")
        .navigationBarTitleDisplayMode(.large)
        .task(id: reloadToken) {
            guard phase != .loaded else { return }
            await load()
        }
        .alert(
            "ui.home.daily_songs.refresh_failed",
            isPresented: Binding(
                get: { refreshErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        refreshErrorMessage = nil
                    }
                }
            )
        ) {
            Button("ui.common.ok", role: .cancel) {
                refreshErrorMessage = nil
            }
        } message: {
            Text(refreshErrorMessage ?? L10n.string("ui.error.try_again_later"))
        }
    }

    private func load() async {
        phase = .loading
        do {
            songs = try await api.dailySongs()
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let refreshedSongs = try await api.dailySongs(afresh: true)
            try Task.checkCancellation()
            songs = refreshedSongs
        } catch is CancellationError {
            return
        } catch {
            refreshErrorMessage = error.localizedDescription
        }
    }
}
