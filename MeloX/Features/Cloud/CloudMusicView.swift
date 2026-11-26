import SwiftUI
import UniformTypeIdentifiers

struct CloudMusicView: View {
    let searchQuery: String

    @Environment(CloudMusicStore.self) private var cloud
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings

    @Environment(\.locale) private var locale
    @AppStorage("library.cloud.sort") private var sort: LibrarySongSort = .added
    @State private var sections: [CloudMusicSection] = []
    @State private var indexedRequest: CloudMusicIndexRequest?
    @State private var preparingPlayback = false
    @State private var showsFileImporter = false
    @State private var pendingDeletion: CloudSong?
    @State private var searchReloadToken = 0
    @State private var searchPreparationID: UUID?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showsFileImporter = true
                    } label: {
                        if cloud.isUploading {
                            ProgressView()
                        } else {
                            Label("ui.cloud.upload_music", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(cloud.isUploading)
                    .accessibilityLabel(
                        cloud.isUploading
                            ? L10n.string("ui.cloud.uploading_music")
                            : L10n.string("ui.cloud.upload_music")
                    )
                    .tint(.primary)

                    Menu {
                        Picker("ui.library.songs.sort", selection: $sort) {
                            Label("ui.library.songs.sort.added", systemImage: "calendar").tag(LibrarySongSort.added)
                            Label("ui.library.songs.sort.name", systemImage: "textformat").tag(LibrarySongSort.name)
                            Label("ui.library.songs.sort.artist", systemImage: "music.microphone").tag(LibrarySongSort.artist)
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("ui.common.more", systemImage: "ellipsis")
                    }
                    .tint(.primary)
                }
            }
            .fileImporter(
                isPresented: $showsFileImporter,
                allowedContentTypes: [.audio],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task { await cloud.upload(fileAt: url) }
                case .failure(let error):
                    cloud.reportImportError(error)
                }
            }
            .confirmationDialog(
                "ui.cloud.delete.confirmation",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { isPresented in
                        if !isPresented { pendingDeletion = nil }
                    }
                ),
                titleVisibility: .visible,
                presenting: pendingDeletion
            ) { item in
                Button(
                    L10n.format("ui.cloud.delete_named", item.songName),
                    role: .destructive
                ) {
                    Task { await cloud.delete(item) }
                }
                Button("ui.common.cancel", role: .cancel) {}
            } message: { _ in
                Text("ui.cloud.delete.message")
            }
            .alert(
                "ui.cloud.error.title",
                isPresented: Binding(
                    get: { cloud.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented { cloud.clearError() }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    cloud.clearError()
                }
            } message: {
                Text(cloud.errorMessage ?? L10n.string("ui.common.unknown_error"))
            }
            .task(id: settings.cookie) {
                await cloud.refresh()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch cloud.phase {
        case .loading where cloud.items.isEmpty:
            ProgressView("ui.cloud.loading")
        case .failed(let message) where cloud.items.isEmpty:
            ConnectionUnavailableView(message: message) {
                Task { await cloud.refresh(force: true) }
            }
        default:
            cloudList
        }
    }

    private var indexRequest: CloudMusicIndexRequest {
        CloudMusicIndexRequest(items: filterCloudSongs(cloud.items, query: normalizedSearchQuery), sort: sort, locale: locale)
    }

    private var cloudList: some View {
        let request = indexRequest
        return List {
            if cloud.isUploading {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("ui.cloud.uploading_foreground")
                        .foregroundStyle(.secondary)
                }
            }

            if !sections.isEmpty {
                SongListPlaybackActions(isPreparing: preparingPlayback) { shuffled in
                    Task { await playAll(shuffled: shuffled) }
                }
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.items) { item in
                        TrackRowView(song: item.simpleSong, showsArtwork: true, subtitleOverride: item.artist) {
                            let queue = sections.flatMap { $0.items.map(\.simpleSong) }
                            Task { await player.play(item.simpleSong, in: queue) }
                        }
                        .listRowInsets(.init(top: 4, leading: 20, bottom: 4, trailing: 16))
                        .disabled(cloud.isDeleting(item))
                        .songSwipeActions(item.simpleSong, removal: .action("ui.cloud.delete") { pendingDeletion = item })
                    }
                } header: {
                    if !section.title.isEmpty {
                        Text(section.title).font(.headline).foregroundStyle(.primary)
                    }
                }
                .sectionIndexLabel(section.title.isEmpty ? nil : section.title)
            }

            paginationFooter

            if !sections.isEmpty {
                VStack(spacing: 3) {
                    Text(isSearching ? L10n.format("ui.common.search_result_count", request.items.count)
                         : L10n.format("ui.cloud.total_song_count", cloud.totalCount))
                    if !isSearching, let quota = cloud.quotaDescription { Text(quota) }
                }
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(4)
        .listSectionIndexVisibility(sort == .added ? .hidden : .visible)
        .task(id: request) {
            guard let result = try? await request.build(), !Task.isCancelled else { return }
            sections = result
            indexedRequest = request
        }
        .refreshable {
            await cloud.refresh(force: true)
            if needsAllPages { await prepareSearchResults(debounced: false) }
        }
        .overlay {
            if sections.isEmpty, indexedRequest == request,
               !cloud.isUploading,
               !isPreparingSearchResults,
               !hasSearchLoadFailure {
                if isSearching {
                    ContentUnavailableView.search(
                        text: normalizedSearchQuery
                    )
                } else {
                    ContentUnavailableView {
                        Label(
                            "ui.cloud.empty",
                            systemImage: "externaldrive"
                        )
                    } description: {
                        Text(
                            "ui.cloud.empty.message"
                        )
                    } actions: {
                        Button("ui.cloud.upload_music") {
                            showsFileImporter = true
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .task(
            id: CloudMusicSearchRequest(
                query: normalizedSearchQuery,
                reloadToken: searchReloadToken,
                sort: sort,
                hasMore: cloud.hasMore
            )
        ) {
            await prepareSearchResults(debounced: true)
        }
    }

    private var normalizedSearchQuery: String {
        normalizedLibrarySearchQuery(searchQuery)
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var needsAllPages: Bool { isSearching || sort != .added }

    private func playAll(shuffled: Bool) async {
        guard !preparingPlayback else { return }
        preparingPlayback = true
        defer { preparingPlayback = false }
        let cookie = settings.cookie
        await cloud.loadRemaining()
        guard !cloud.hasMore, !Task.isCancelled, settings.cookie == cookie,
              let result = try? await indexRequest.build() else { return }
        let queue = result.flatMap { $0.items.map(\.simpleSong) }
        if !queue.isEmpty { await player.playAll(shuffled ? queue.shuffled() : queue) }
    }

    private var isPreparingSearchResults: Bool {
        searchPreparationID != nil
    }

    private var hasSearchLoadFailure: Bool {
        isSearching && cloud.loadMoreError != nil && cloud.hasMore
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if isSearching, isPreparingSearchResults {
            HStack(spacing: 8) {
                ProgressView()
                Text("ui.cloud.searching_all")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .listRowSeparator(.hidden)
        } else if let failureMessage = cloud.loadMoreError,
                  cloud.hasMore {
            VStack(spacing: 8) {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button(
                    isSearching
                        ? L10n.string("ui.library.search_again")
                        : L10n.string("ui.common.reload")
                ) {
                    if needsAllPages {
                        searchReloadToken += 1
                    } else {
                        Task { await cloud.loadMore() }
                    }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .listRowSeparator(.hidden)
        } else if !isSearching, cloud.hasMore {
            MusicCollectionPaginationFooter(isLoading: cloud.isLoadingMore, failureMessage: nil,
                                            loadToken: cloud.items.count) { await cloud.loadMore() }
                .listRowSeparator(.hidden)
        }
    }

    private func prepareSearchResults(debounced: Bool) async {
        guard needsAllPages else {
            searchPreparationID = nil
            return
        }

        guard cloud.hasMore else { return }

        let preparationID = UUID()
        searchPreparationID = preparationID
        defer {
            if searchPreparationID == preparationID {
                searchPreparationID = nil
            }
        }

        if debounced && isSearching {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        await cloud.loadRemaining()
    }
}

private struct CloudMusicSearchRequest: Hashable {
    let query: String
    let reloadToken: Int
    let sort: LibrarySongSort
    let hasMore: Bool
}

private struct CloudMusicSection: Identifiable {
    let title: String
    var items: [CloudSong]
    var id: String { title }
}

private struct CloudMusicIndexRequest: Equatable {
    let items: [CloudSong]
    let sort: LibrarySongSort
    let locale: Locale

    @concurrent func build() async throws -> [CloudMusicSection] {
        guard !items.isEmpty else { return [] }
        if sort == .added {
            return [CloudMusicSection(title: "", items: items.sorted {
                $0.addTime == $1.addTime ? $0.songID < $1.songID : $0.addTime > $1.addTime
            })]
        }
        var groups: [String: [(key: String, item: CloudSong)]] = [:]
        for item in items {
            try Task.checkCancellation()
            let key = LibrarySongIndex.collationKey(sort == .artist ? item.artist : item.songName, locale: locale)
            let letter = key.first.map { ("A"..."Z").contains($0) ? String($0) : "#" } ?? "#"
            groups[letter, default: []].append((key, item))
        }
        var letters = groups.keys.filter { $0 != "#" }.sorted()
        if groups["#"] != nil { letters.append("#") }
        return letters.map { letter in
            let items = groups[letter, default: []].sorted {
                let order = $0.key.compare($1.key, options: .numeric, locale: locale)
                if order != .orderedSame { return order == .orderedAscending }
                let titleOrder = $0.item.songName.localizedStandardCompare($1.item.songName)
                return titleOrder == .orderedSame ? $0.item.songID < $1.item.songID : titleOrder == .orderedAscending
            }
            return CloudMusicSection(title: letter, items: items.map(\.item))
        }
    }
}
