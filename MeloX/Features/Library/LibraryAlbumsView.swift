import SwiftUI

struct LibraryAlbumsView: View {
    let searchQuery: String

    @Environment(\.openMusicRoute) private var openMusicRoute
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(PlayerStore.self) private var player
    @Environment(NeteaseAPI.self) private var api
    @Environment(\.locale) private var locale

    @AppStorage("library.albums.grid") private var grid = true
    @AppStorage("library.albums.sort") private var sort: LibraryAlbumSort = .artist
    @State private var filter: LibrarySongFilter = .all
    @State private var playbackTask: Task<Void, Never>?
    @State private var playbackError: String?

    private var request: LibraryAlbumIndex.Request {
        .init(subscribed: library.favoriteAlbums, songs: library.favoriteSongs,
              songDates: library.favoriteAddedDates, downloads: AppFeatureAvailability.downloads ? downloads.downloads : [],
              filter: filter, sort: sort, query: normalizedLibrarySearchQuery(searchQuery), locale: locale)
    }

    var body: some View {
        let request = request
        let cached = library.albumIndex.value(for: request)
        let index = cached ?? LibraryAlbumIndex()
        List {
            if !index.groups.isEmpty {
                SongListPlaybackActions(isPreparing: playbackTask != nil, play: playAlbums)
            }
            ForEach(index.groups) { group in
                Section {
                    if grid {
                        ForEach(0..<((group.entries.count + 1) / 2), id: \.self) { row in
                            let offset = row * 2
                            HStack(alignment: .top, spacing: 12) {
                                albumLink(group.entries[offset])
                                if offset + 1 < group.entries.count {
                                    albumLink(group.entries[offset + 1])
                                } else {
                                    Color.clear.frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(.init(top: 4, leading: 20, bottom: 16, trailing: 20))
                            .listRowSeparator(.hidden)
                        }
                    } else {
                        ForEach(group.entries) { albumLink($0) }
                    }
                } header: {
                    if !group.title.isEmpty {
                        Text(group.title).font(.headline).foregroundStyle(.primary)
                    }
                }
                .sectionIndexLabel(group.title.isEmpty ? nil : group.title)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .listSectionIndexVisibility(sort == .added ? .hidden : .visible)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                LibraryFilterMenu(selection: $filter, allTitle: "ui.library.albums.all", allSymbol: "square.stack")
                Menu {
                    LibraryLayoutPicker(grid: $grid)
                    Divider()
                    sortOption(.name, "ui.library.songs.sort.name")
                    sortOption(.added, "ui.library.songs.sort.added")
                    sortOption(.artist, "ui.library.songs.sort.artist")
                    sortOption(.year, "ui.library.sort.year")
                } label: {
                    Label("ui.common.more", systemImage: "ellipsis")
                }
                .tint(.primary)
            }
        }
        .task(id: request) {
            await library.albumIndex.load(request, isBrowsing: filter == .all && request.query.isEmpty) {
                try await LibraryAlbumIndex.build(request)
            }
        }
        .refreshable { await library.refresh(force: true) }
        .overlay {
            if index.groups.isEmpty {
                if cached == nil || library.phase == .loading {
                    ProgressView("ui.library.loading")
                } else if !request.query.isEmpty {
                    ContentUnavailableView.search(text: request.query)
                } else {
                    ContentUnavailableView("ui.library.albums.empty", systemImage: "square.stack")
                }
            }
        }
        .alert("ui.library.play_all_failed", isPresented: Binding(
            get: { playbackError != nil }, set: { if !$0 { playbackError = nil } }
        )) { Button("ui.common.ok", role: .cancel) {} } message: { Text(playbackError ?? "") }
        .onDisappear { playbackTask?.cancel() }
    }

    private func sortOption(_ value: LibraryAlbumSort, _ title: LocalizedStringKey) -> some View {
        Toggle(isOn: Binding(get: { sort == value }, set: { _ in sort = value })) {
            Text(title)
            if sort == value && (value == .name || value == .artist) { Text("ui.library.sort.ascending") }
        }
    }

    @ViewBuilder
    private func albumLink(_ entry: LibraryAlbumIndex.Entry) -> some View {
        let route = MusicRoute.album(entry.album)
        let details = VStack(alignment: .leading, spacing: 2) {
            Text(entry.album.name).font(grid ? .subheadline : .body)
            Text(entry.artistText).font(.subheadline).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        if grid {
            Button { openMusicRoute(route) } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ArtworkImage(url: entry.album.artworkURL, cornerRadius: 7)
                    details
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .musicMatchedTransitionSource(for: route)
        } else {
            NavigationLink(value: route) {
                HStack(spacing: 12) {
                    ArtworkImage(url: entry.album.artworkURL, cornerRadius: 6).frame(width: 48, height: 48)
                    details
                }
            }
            .musicMatchedTransitionSource(for: route)
        }
    }

    private func playAlbums(shuffled: Bool) {
        guard playbackTask == nil else { return }
        guard let index = library.albumIndex.value(for: request) else { return }
        let displayed = index.groups.flatMap(\.entries)
        let selection = request
        playbackTask = Task {
            defer { playbackTask = nil }
            let subscribed = Set(selection.subscribed.map(\.id))
            let localSongs = selection.downloads.map(\.song)
            let known = Dictionary(grouping: selection.filter == .downloaded ? localSongs : selection.songs + localSongs) { $0.album?.id }
            var queue: [Song] = []
            var seen: Set<Int> = []
            do {
                for entry in displayed {
                    try Task.checkCancellation()
                    let tracks: [Song]
                    if selection.filter != .downloaded && subscribed.contains(entry.id) {
                        tracks = try await api.album(id: entry.id).1
                    } else {
                        tracks = (known[entry.id] ?? []).sorted {
                            ($0.disc ?? "", $0.trackNumber ?? 0, $0.id) < ($1.disc ?? "", $1.trackNumber ?? 0, $1.id)
                        }
                    }
                    queue.append(contentsOf: tracks.filter { seen.insert($0.id).inserted })
                }
                try Task.checkCancellation()
                if !queue.isEmpty { await player.playAll(shuffled ? queue.shuffled() : queue) }
            } catch {
                if !Task.isCancelled { playbackError = error.localizedDescription }
            }
        }
    }
}
