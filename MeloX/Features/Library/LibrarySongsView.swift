import SwiftUI

struct LibrarySongsView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player

    @Environment(DownloadStore.self) private var downloads
    @Environment(\.locale) private var locale

    @AppStorage("library.songs.sort") private var sort: LibrarySongSort = .artist
    @State private var filter: LibrarySongFilter = .all
    @State private var isStartingHeartMode = false
    @State private var heartModeErrorMessage: String?

    private var request: LibrarySongIndex.Request {
        LibrarySongIndex.Request(favorites: library.favoriteSongs, favoriteDates: library.favoriteAddedDates,
                                 downloads: AppFeatureAvailability.downloads ? downloads.downloads : [],
                                 filter: filter, sort: sort, query: normalizedLibrarySearchQuery(searchQuery),
                                 locale: locale)
    }

    var body: some View {
        let request = request
        let cached = library.songIndex.value(for: request)
        let index = cached ?? LibrarySongIndex()
        List {
            if !index.songs.isEmpty {
                SongListPlaybackActions { shuffled in
                    let songs = index.songs
                    Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                }
            }
            ForEach(index.sections) { section in
                Section {
                    ForEach(section.songs) { song in
                        TrackRowView(song: song, showsArtwork: true) {
                            Task { await player.play(song, in: index.songs) }
                        }
                        .overlay(alignment: .leading) {
                            if library.contains(song: song) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.yellow)
                                    .offset(x: -14)
                                    .accessibilityHidden(true)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 4, trailing: 16))
                        .songSwipeActions(song, removal: filter == .downloaded ? .download : .library)
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                .sectionIndexLabel(section.title.isEmpty ? nil : section.title)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .listSectionIndexVisibility(sort == .added ? .hidden : .visible)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(selection: $filter, allTitle: "ui.library.songs.filter.all",
                                  allSymbol: "music.note.list")

                Menu {
                    Picker("ui.library.songs.sort", selection: $sort) {
                        Label("ui.library.songs.sort.artist", systemImage: "music.microphone").tag(LibrarySongSort.artist)
                        Label("ui.library.songs.sort.added", systemImage: "calendar").tag(LibrarySongSort.added)
                        Label("ui.library.songs.sort.name", systemImage: "textformat").tag(LibrarySongSort.name)
                    }
                    Divider()
                    Button("ui.home.action.heart_mode", systemImage: "heart.circle.fill", action: startHeartMode)
                        .disabled(!library.canStartHeartMode || isStartingHeartMode)
                } label: {
                    Label("ui.common.more", systemImage: "ellipsis")
                }
                .tint(.primary)
            }
        }
        .refreshable { await library.refresh(force: true) }
        .task(id: request) {
            await library.songIndex.load(request, isBrowsing: filter == .all && request.query.isEmpty) {
                try await LibrarySongIndex.build(request)
            }
        }
        .overlay {
            if index.songs.isEmpty {
                if cached == nil || library.phase == .loading {
                    ProgressView("ui.library.loading")
                } else if !request.query.isEmpty {
                    ContentUnavailableView.search(text: request.query)
                } else {
                    ContentUnavailableView("ui.songs.empty", systemImage: "music.note.list")
                }
            }
        }
        .alert(
            "ui.library.heart_mode_failed",
            isPresented: Binding(
                get: { heartModeErrorMessage != nil },
                set: { presented in
                    if !presented {
                        heartModeErrorMessage = nil
                    }
                }
            )
        ) {
            Button("ui.common.ok", role: .cancel) {
                heartModeErrorMessage = nil
            }
        } message: {
            Text(heartModeErrorMessage ?? L10n.string("ui.error.try_again_later"))
        }
    }

    private func startHeartMode() {
        guard !isStartingHeartMode,
              let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else {
            return
        }

        isStartingHeartMode = true
        heartModeErrorMessage = nil
        Task { @MainActor in
            defer { isStartingHeartMode = false }
            do {
                try await player.playHeartMode(
                    playlistID: playlistID,
                    seedSongID: seedSongID
                )
            } catch is CancellationError {
                return
            } catch {
                heartModeErrorMessage = error.localizedDescription
            }
        }
    }
}
