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

    /// 当前允许渲染的行数预算。
    ///
    /// 收藏列表动辄两千多首、几百个分区。把全部行一次性交给 `List`/`ForEach`，
    /// SwiftUI 每次 `body` 求值都要对几千个 `Identifiable` 元素做一次 diff，
    /// 再叠加每行的 `contextMenu`、`swipeActions`、收藏星标 overlay，
    /// 表现就是「滑几下卡一下、点一下卡一两秒」。
    /// 首屏只渲染约 120 行，滚到底再按 120 行追加；`index.songs` 仍是全量，
    /// 播放队列不受影响。
    @State private var visibleRowBudget = LibrarySongsView.initialRowBudget

    /// 上一次构建成功的索引。收藏变更会让缓存键失配，
    /// 这时继续显示旧内容（stale-while-revalidate），后台重建完成后再替换，
    /// 列表不会先塌成空白再弹回来——那一下的观感也是一秒级的卡顿。
    @State private var lastIndex: LibrarySongIndex?

    private static let initialRowBudget = 120
    private static let rowBudgetPage = 120

    private var request: LibrarySongIndex.Request {
        LibrarySongIndex.Request(
            favorites: library.favoriteSongs,
            favoriteDates: library.favoriteAddedDates,
            downloads: AppFeatureAvailability.downloads ? downloads.downloads : [],
            filter: filter,
            sort: sort,
            query: normalizedLibrarySearchQuery(searchQuery),
            locale: locale,
            favoritesRevision: library.favoriteSongsRevision
        )
    }

    /// 决定索引是否必须重建的结构参数。收藏内容变化不改变它。
    private var structureKey: String {
        let filterKey = String(describing: filter)
        return "\(filterKey)|\(sort.rawValue)|\(normalizedLibrarySearchQuery(searchQuery))|\(locale.identifier)"
    }

    var body: some View {
        let request = request
        let cached = library.songIndex.value(for: request)
        let index = cached ?? lastIndex ?? LibrarySongIndex()
        // 收藏列表动辄两千多首：逐行注册 zoom 转场源会拖慢滚动，
        // 短列表（搜索、筛选后）保留转场动画。
        let usesCardTransition = index.songs.count <= 240
        let page = Self.page(of: index.sections, rowBudget: visibleRowBudget)
        let visibleSections = page.shown
        let hasMoreSections = page.hasMore

        List {
            if !index.songs.isEmpty {
                SongListPlaybackActions { shuffled in
                    let songs = index.songs
                    Task { await player.playAll(shuffled ? songs.shuffled() : songs) }
                }
            }
            ForEach(visibleSections) { section in
                Section {
                    ForEach(section.songs) { song in
                        TrackRowView(
                            song: song,
                            showsArtwork: true,
                            prefetchesTransitionArtwork: false,
                            usesCardTransition: usesCardTransition
                        ) {
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
            if hasMoreSections {
                Section {
                    HStack {
                        Spacer()
                        Text("ui.library.loading")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ProgressView()
                            .controlSize(.small)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .onAppear {
                        guard visibleRowBudget < index.songs.count else {
                            visibleRowBudget = index.songs.count
                            return
                        }
                        visibleRowBudget = min(
                            index.songs.count,
                            visibleRowBudget + Self.rowBudgetPage
                        )
                    }
                }
                .sectionIndexLabel(nil)
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
        .onChange(of: structureKey) {
            // 换了筛选 / 排序 / 搜索词，结果集整体换了，预算从首屏重算。
            visibleRowBudget = Self.initialRowBudget
        }
        .task(id: request) {
            if library.songIndex.value(for: request) == nil {
                await library.songIndex.load(
                    request,
                    isBrowsing: filter == .all && request.query.isEmpty
                ) {
                    try await LibrarySongIndex.build(request)
                }
            }
            if let built = library.songIndex.value(for: request) {
                lastIndex = built
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

    /// 按行数预算截取分区。分区边界整块取，超出预算时把最后一个分区收窄，
    /// 保证任何时刻渲染的行数都在预算附近，而不是整份两千多行。
    private static func page(
        of sections: [LibrarySongIndex.Section],
        rowBudget: Int
    ) -> (shown: [LibrarySongIndex.Section], hasMore: Bool) {
        guard !sections.isEmpty else { return ([], false) }
        var shown: [LibrarySongIndex.Section] = []
        shown.reserveCapacity(min(sections.count, 32))
        var rows = 0
        for section in sections {
            if rows >= rowBudget { break }
            if rows + section.songs.count <= rowBudget {
                shown.append(section)
                rows += section.songs.count
            } else {
                var trimmed = section
                trimmed.songs = Array(section.songs.prefix(rowBudget - rows))
                shown.append(trimmed)
                rows = rowBudget
            }
        }
        return (shown, shown.count < sections.count)
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
