import SwiftUI

private enum LibraryPlaylistSort: String, CaseIterable {
    case name, added, lastPlayed, updated, type

    var title: LocalizedStringKey {
        switch self {
        case .name: "ui.library.songs.sort.name"
        case .added: "ui.library.songs.sort.added"
        case .lastPlayed: "ui.library.playlists.sort.last_played"
        case .updated: "ui.library.playlists.sort.updated"
        case .type: "ui.library.playlists.sort.type"
        }
    }
}

private enum PlaylistOwnership { case all, owned, saved }

struct LibraryPlaylistsView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library
    @Environment(NeteaseAPI.self) private var api
    @Environment(AppSettings.self) private var settings
    @Environment(\.openMusicRoute) private var openMusicRoute
    @AppStorage("library.playlists.grid") private var grid = false
    @AppStorage("library.playlists.sort") private var sort: LibraryPlaylistSort = .type
    @State private var filter: PlaylistOwnership = .all
    @State private var lastPlayed: [Int: Double] = [:]
    @State private var showsCreation = false
    @State private var pendingDeletion: Playlist?
    @State private var isDeletingPlaylist = false
    @State private var operationError: String?

    var body: some View {
        let playlists = displayedPlaylists
        List {
            if grid {
                ForEach(0..<((playlists.count + 1) / 2), id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        gridCard(playlists[2 * row])
                        if 2 * row + 1 < playlists.count { gridCard(playlists[2 * row + 1]) }
                        else { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 4, leading: 20, bottom: 16, trailing: 20))
                }
            } else {
                ForEach(playlists) { playlist in
                    NavigationLink(value: MusicRoute.playlist(playlist)) {
                        HStack(spacing: 12) {
                            artwork(playlist).frame(width: 64, height: 64)
                            details(playlist)
                        }
                        .overlay(alignment: .leading) {
                            if isFavorite(playlist) { LibraryFavoriteStar() }
                        }
                    }
                    .musicMatchedTransitionSource(for: .playlist(playlist))
                    .listRowInsets(.init(top: 8, leading: 20, bottom: 8, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                    .swipeActions { actions(for: playlist) }
                }
            }
        }
        .listStyle(.plain)
        .disabled(isDeletingPlaylist)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("ui.playlists.create.title", systemImage: "plus") { showsCreation = true }
                    .disabled(!library.isLoggedIn)
                    .tint(.primary)
                Menu {
                    filterOption(.all, "ui.library.playlists.all", "music.note.list")
                    Divider()
                    filterOption(.owned, "ui.library.playlists.owned", "person")
                    filterOption(.saved, "ui.library.playlists.saved", "star")
                } label: {
                    Label("ui.library.songs.filter", systemImage: "line.3.horizontal.decrease")
                }
                .tint(.primary)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryLayoutPicker(grid: $grid)
                    Divider()
                    Picker("ui.library.songs.sort", selection: $sort) {
                        ForEach(LibraryPlaylistSort.allCases, id: \.self) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                } label: { Label("ui.common.more", systemImage: "ellipsis") }
                .tint(.primary)
            }
        }
        .sheet(isPresented: $showsCreation) {
            PlaylistCreationSheet { name, isPrivate in
                try await library.createPlaylist(name: name, isPrivate: isPrivate)
            }
            .presentationDetents([.medium])
        }
        .confirmationDialog("ui.playlists.delete.title", isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), titleVisibility: .visible, presenting: pendingDeletion) { playlist in
            Button("ui.playlists.delete.action", role: .destructive) {
                Task {
                    isDeletingPlaylist = true
                    defer { isDeletingPlaylist = false }
                    do { try await library.deletePlaylist(playlist) }
                    catch { operationError = error.localizedDescription }
                }
            }
            Button("ui.common.cancel", role: .cancel) {}
        } message: { Text(L10n.format("ui.playlists.delete.message", $0.name)) }
        .alert("ui.library.error.title", isPresented: Binding(
            get: { operationError != nil }, set: { if !$0 { operationError = nil } }
        )) { Button("ui.common.ok", role: .cancel) {} } message: { Text(operationError ?? "") }
        .overlay {
            if playlists.isEmpty {
                if library.phase == .loading {
                    ProgressView("ui.library.loading")
                } else if !searchQuery.isEmpty {
                    ContentUnavailableView.search(text: searchQuery)
                } else {
                    ContentUnavailableView("ui.library.playlists.empty", systemImage: "music.note.list")
                }
            }
        }
        .refreshable {
            await library.refresh(force: true)
            if sort == .lastPlayed { await loadHistory() }
        }
        .task(id: sort == .lastPlayed ? library.profile?.id : nil) {
            if sort == .lastPlayed, library.isLoggedIn { await loadHistory() }
        }
    }

    private func filterOption(_ option: PlaylistOwnership, _ title: LocalizedStringKey, _ symbol: String) -> some View {
        Toggle(isOn: Binding(get: { filter == option }, set: { _ in filter = option })) {
            Label(title, systemImage: symbol)
        }
    }

    private var allPlaylists: [Playlist] {
        [library.likedPlaylist].compactMap { $0 } + library.favoritePlaylists
    }

    private var displayedPlaylists: [Playlist] {
        let query = normalizedLibrarySearchQuery(searchQuery)
        let candidates = allPlaylists.filter { playlist in
            switch filter {
            case .all: true
            case .owned: isOwned(playlist)
            case .saved: !isOwned(playlist)
            }
        }
        var items = filterLibraryPlaylists(candidates, query: query)
        if let liked = library.likedPlaylist, !items.contains(where: { $0.id == liked.id }),
           candidates.contains(where: { $0.id == liked.id }), title(liked).localizedCaseInsensitiveContains(query) {
            items.append(liked)
        }
        return items.sorted { a, b in
            switch sort {
            case .type:
                let x = typeOrder(a), y = typeOrder(b)
                if x != y { return x < y }
            case .added, .updated, .lastPlayed:
                let x = timestamp(a), y = timestamp(b)
                if x != y { return x > y }
            case .name: break
            }
            let order = title(a).localizedStandardCompare(title(b))
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }

    private func title(_ playlist: Playlist) -> String {
        playlist.id == library.likedPlaylistID ? L10n.string("ui.library.playlists.favorite_songs") : playlist.name
    }

    private func isOwned(_ playlist: Playlist) -> Bool {
        playlist.id == library.likedPlaylistID || library.canDelete(playlist)
    }

    private func isFavorite(_ playlist: Playlist) -> Bool {
        playlist.id == library.likedPlaylistID || playlist.subscribed || library.canUnsubscribe(playlist)
    }

    private func typeOrder(_ playlist: Playlist) -> Int {
        if playlist.id == library.likedPlaylistID { return 0 }
        return isFavorite(playlist) ? 2 : 1
    }

    private func timestamp(_ playlist: Playlist) -> Double {
        switch sort {
        case .added: return max(playlist.subscribedTime ?? 0, playlist.createTime ?? 0)
        case .updated: return max(playlist.trackUpdateTime ?? 0, playlist.updateTime ?? 0)
        case .lastPlayed: return max(lastPlayed[playlist.id] ?? 0, (library.playlistPlayDates[playlist.id]?.timeIntervalSince1970 ?? 0) * 1000)
        default: return 0
        }
    }

    private func artwork(_ playlist: Playlist) -> some View {
        let fallback = playlist.id == library.likedPlaylistID ? library.favoriteSongs.first?.album?.artworkURL : nil
        return ArtworkImage(url: playlist.artworkURL ?? fallback, cornerRadius: 6)
    }

    private func details(_ playlist: Playlist) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title(playlist)).font(grid ? .subheadline : .body)
            if playlist.id != library.likedPlaylistID, playlist.creator?.userID != library.profile?.id,
               let name = playlist.creator?.nickname, !name.isEmpty {
                Text(name).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
    }

    private func gridCard(_ playlist: Playlist) -> some View {
        Button { openMusicRoute(.playlist(playlist)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                artwork(playlist)
                HStack(spacing: 4) {
                    if isFavorite(playlist) { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                    details(playlist)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .musicMatchedTransitionSource(for: .playlist(playlist))
        .contextMenu { actions(for: playlist) }
    }

    @ViewBuilder private func actions(for playlist: Playlist) -> some View {
        if library.canDelete(playlist) {
            Button("ui.playlists.delete.action", systemImage: "trash", role: .destructive) { pendingDeletion = playlist }
        } else if library.canUnsubscribe(playlist) {
            Button("ui.common.unfavorite", systemImage: "star.slash", role: .destructive) { library.toggle(playlist: playlist) }
        }
    }

    private func loadHistory() async {
        guard settings.isContentFeatureEnabled(.listeningHistory) else {
            lastPlayed = [:]
            return
        }
        do {
            let dates = try await api.recentPlaylistPlayTimes()
            try Task.checkCancellation()
            lastPlayed = dates
        } catch {
            if !Task.isCancelled { operationError = error.localizedDescription }
        }
    }
}
