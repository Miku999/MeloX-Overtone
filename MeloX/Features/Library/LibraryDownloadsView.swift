import SwiftUI

struct LibraryDownloadsView: View {
    let searchQuery: String

    @Environment(DownloadStore.self) private var downloads
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(\.locale) private var locale
    @AppStorage("library.downloads.sort") private var sort: LibrarySongSort = .added

    var body: some View {
        let query = normalizedLibrarySearchQuery(searchQuery)
        let request = LibrarySongIndex.Request(favorites: [], favoriteDates: [:], downloads: downloads.downloads,
                                              filter: .downloaded, sort: sort, query: query, locale: locale)
        let index = library.downloadIndex.value(for: request)
        let songs = index?.songs ?? []
        let active = filterMusicCollectionTracks(Array(downloads.activeSongs.values), query: query)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        List {
            if !songs.isEmpty {
                SongListPlaybackActions { shuffled in
                    Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                }
            }
            if !active.isEmpty {
                Section("ui.downloads.active") {
                    ForEach(active) { song in
                        VStack(alignment: .leading, spacing: 4) {
                            TrackRowView(song: song, showsArtwork: true)
                            if let fraction = downloads.activeDownloads[song.id]?.fractionCompleted {
                                ProgressView(value: fraction)
                            }
                        }
                        .songSwipeActions(song, removal: .download)
                    }
                }
            }
            ForEach(index?.sections ?? []) { section in
                Section {
                    ForEach(section.songs) { song in
                        TrackRowView(song: song, showsArtwork: true) {
                            Task { await player.play(song, in: songs) }
                        }
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 16))
                        .songSwipeActions(song, removal: .download)
                    }
                } header: {
                    if !section.title.isEmpty { Text(section.title).font(.headline).foregroundStyle(.primary) }
                }
                .sectionIndexLabel(section.title.isEmpty ? nil : section.title)
            }
            if !songs.isEmpty {
                Text(query.isEmpty
                     ? L10n.format("ui.downloads.summary", songs.count, L10n.byteCount(downloads.totalByteCount))
                     : L10n.format("ui.common.search_result_count", songs.count))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .listSectionIndexVisibility(sort == .added ? .hidden : .visible)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                NavigationLink {
                    DownloadsView()
                } label: {
                    Label("ui.downloads.management", systemImage: "slider.horizontal.3")
                }
                .tint(.primary)
                Menu {
                    Picker("ui.library.songs.sort", selection: $sort) {
                        Label("ui.library.songs.sort.added", systemImage: "calendar").tag(LibrarySongSort.added)
                        Label("ui.library.songs.sort.name", systemImage: "textformat").tag(LibrarySongSort.name)
                        Label("ui.library.songs.sort.artist", systemImage: "music.microphone").tag(LibrarySongSort.artist)
                    }
                    .pickerStyle(.inline)
                } label: { Label("ui.common.more", systemImage: "ellipsis") }
                .tint(.primary)
            }
        }
        .task(id: request) {
            await library.downloadIndex.load(request, isBrowsing: query.isEmpty) {
                try await LibrarySongIndex.build(request)
            }
        }
        .overlay {
            if songs.isEmpty && active.isEmpty {
                if index == nil {
                    ProgressView()
                } else if !query.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    ContentUnavailableView("ui.downloads.empty", systemImage: "arrow.down.circle",
                                           description: Text("ui.downloads.empty.message"))
                }
            }
        }
    }
}
