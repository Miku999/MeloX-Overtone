import SwiftUI

struct SubscribedPodcastsView: View {
    let searchQuery: String

    @Environment(LibraryStore.self) private var library

    @Environment(\.openMusicRoute) private var openMusicRoute
    @AppStorage("library.podcasts.grid") private var grid = false
    @State private var searchReloadToken = 0
    @State private var searchPreparationID: UUID?

    var body: some View {
        let podcasts = displayedPodcasts
        List {
            if grid {
                ForEach(0..<((podcasts.count + 1) / 2), id: \.self) { row in
                    HStack(alignment: .top, spacing: 12) {
                        gridCard(podcasts[2 * row])
                        if 2 * row + 1 < podcasts.count { gridCard(podcasts[2 * row + 1]) }
                        else { Color.clear.frame(maxWidth: .infinity) }
                    }
                    .listRowSeparator(.hidden)
                    .listRowInsets(.init(top: 4, leading: 20, bottom: 16, trailing: 20))
                }
            } else {
                ForEach(podcasts) { podcast in
                    NavigationLink(value: MusicRoute.podcast(podcast)) {
                        HStack(spacing: 12) {
                            artwork(podcast).frame(width: 64, height: 64)
                            details(podcast)
                        }
                    }
                    .musicMatchedTransitionSource(for: .podcast(podcast))
                    .listRowInsets(.init(top: 8, leading: 20, bottom: 8, trailing: 16))
                    .alignmentGuide(.listRowSeparatorLeading) { _ in 76 }
                    .swipeActions { unsubscribe(podcast) }
                }
            }

            if isSearching {
                searchPaginationFooter
            } else if library.hasMoreSubscribedPodcasts {
                MusicCollectionPaginationFooter(
                    isLoading:
                        library.isLoadingMoreSubscribedPodcasts,
                    failureMessage:
                        library.subscribedPodcastsLoadMoreError,
                    loadToken:
                        library.subscribedPodcastsNextOffset,
                    loadingTitle: L10n.string("ui.podcasts.loading_more")
                ) {
                    await library.loadMoreSubscribedPodcasts()
                }
                .listRowSeparator(.hidden)
            }

            if !podcasts.isEmpty {
                Text(isSearching
                     ? L10n.format("ui.common.search_result_count", podcasts.count)
                     : L10n.format("ui.library.subscribed_podcast_count", library.subscribedPodcastTotalCount))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    LibraryLayoutPicker(grid: $grid)
                } label: {
                    Label("ui.common.more", systemImage: "ellipsis")
                }
                .tint(.primary)
            }
        }
        .listStyle(.plain)
        .refreshable {
            await library.refresh(force: true)
            if isSearching {
                await prepareSearchResults(debounced: false)
            }
        }
        .overlay {
            if displayedPodcasts.isEmpty,
               !isPreparingSearchResults,
               !hasSearchLoadFailure {
                if isSearching {
                    ContentUnavailableView.search(
                        text: normalizedSearchQuery
                    )
                } else if !library.hasMoreSubscribedPodcasts {
                    ContentUnavailableView(
                        "ui.library.no_subscribed_podcasts",
                        systemImage: "mic",
                        description: Text(
                            "ui.library.no_subscribed_podcasts.message"
                        )
                    )
                }
            }
        }
        .task(
            id: LibraryPodcastSearchRequest(
                query: normalizedSearchQuery,
                reloadToken: searchReloadToken
            )
        ) {
            await prepareSearchResults(debounced: true)
        }
    }

    private func gridCard(_ podcast: Podcast) -> some View {
        Button { openMusicRoute(.podcast(podcast)) } label: {
            VStack(alignment: .leading, spacing: 6) {
                artwork(podcast)
                details(podcast)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .musicMatchedTransitionSource(for: .podcast(podcast))
        .contextMenu { unsubscribe(podcast) }
    }

    private func artwork(_ podcast: Podcast) -> some View {
        ArtworkImage(url: podcast.artworkURL, cornerRadius: 6, placeholderSymbol: "mic")
    }

    private func details(_ podcast: Podcast) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(podcast.name).font(grid ? .subheadline : .body)
            Text(podcast.host?.nickname ?? podcast.subtitle ?? L10n.format("ui.podcasts.episode_count_short", podcast.programCount))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func unsubscribe(_ podcast: Podcast) -> some View {
        Button("ui.common.unsubscribe", systemImage: "mic.slash", role: .destructive) {
            library.toggle(podcast: podcast)
        }
    }

    private var normalizedSearchQuery: String {
        normalizedLibrarySearchQuery(searchQuery)
    }

    private var isSearching: Bool {
        !normalizedSearchQuery.isEmpty
    }

    private var displayedPodcasts: [Podcast] {
        filterLibraryPodcasts(
            library.subscribedPodcasts,
            query: normalizedSearchQuery
        )
    }

    private var isPreparingSearchResults: Bool {
        searchPreparationID != nil
    }

    private var hasSearchLoadFailure: Bool {
        isSearching
            && library.subscribedPodcastsLoadMoreError != nil
            && library.hasMoreSubscribedPodcasts
    }

    @ViewBuilder
    private var searchPaginationFooter: some View {
        if isPreparingSearchResults {
            HStack(spacing: 8) {
                ProgressView()
                Text("ui.library.searching_all_subscribed_podcasts")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .listRowSeparator(.hidden)
        } else if let failureMessage =
                    library.subscribedPodcastsLoadMoreError,
                  library.hasMoreSubscribedPodcasts {
            VStack(spacing: 8) {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Button("ui.library.search_again") {
                    searchReloadToken += 1
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .listRowSeparator(.hidden)
        }
    }

    private func prepareSearchResults(debounced: Bool) async {
        guard isSearching else {
            searchPreparationID = nil
            return
        }

        guard library.hasMoreSubscribedPodcasts else { return }

        let preparationID = UUID()
        searchPreparationID = preparationID
        defer {
            if searchPreparationID == preparationID {
                searchPreparationID = nil
            }
        }

        if debounced {
            do {
                try await Task.sleep(for: .milliseconds(300))
            } catch {
                return
            }
        }

        guard !Task.isCancelled else { return }
        await library.loadRemainingSubscribedPodcasts()
    }
}

private struct LibraryPodcastSearchRequest: Hashable {
    let query: String
    let reloadToken: Int
}
