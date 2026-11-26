import SwiftUI

struct ArtistDetailView: View {
    let id: Int

    @Environment(NeteaseAPI.self) private var api
    @Environment(PlayerStore.self) private var player
    @Environment(LibraryStore.self) private var library

    @Environment(\.colorScheme) private var colorScheme
    @State private var artworkAssets: ArtworkDetailAssets?
    @State private var showsInformation = false
    @State private var showsAllSongs = false
    @State private var showsBarTitle = false
    @State private var artist: Artist?
    @State private var isFollowed = false
    @State private var isChangingFollowState = false
    @State private var followError: String?
    @State private var songs: [Song] = []
    @State private var albums: [Album] = []
    @State private var phase: LoadingPhase = .loading
    @State private var reloadToken = 0

    var body: some View {
        Group {
            switch phase {
            case .loading where artist == nil:
                ProgressView("ui.artist.loading")
            case .failed(let message) where artist == nil:
                ConnectionUnavailableView(message: message) {
                    reloadToken += 1
                }
            default:
                if let artist {
                    content(artist)
                }
            }
        }
        .alert("ui.desktop.artist.follow_failed", isPresented: Binding(
            get: { followError != nil },
            set: { if !$0 { followError = nil } }
        )) {
            Button("ui.common.ok", role: .cancel) { followError = nil }
        } message: { Text(followError ?? "") }
        .navigationTitle(showsBarTitle ? artist?.name ?? "" : "")
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if let artist {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let url = URL(string: "https://music.163.com/artist?id=\(artist.id)") {
                        ShareLink(item: url) {
                            Label("ui.common.share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.primary)
                    }
                    Menu {
                        Button("ui.player.shuffle", systemImage: "shuffle") {
                            Task { await player.playAll(songs.shuffled(), sourceID: artist.id) }
                        }
                        .disabled(songs.isEmpty)
                        Button(followTitle, systemImage: isFollowed ? "star.slash" : "star") {
                            Task { await toggleFollow(artist) }
                        }
                        .disabled(!library.isLoggedIn || isChangingFollowState)
                    } label: {
                        Label("ui.common.more", systemImage: "ellipsis")
                    }
                    .tint(.primary)
                }
            }
        }
        .sheet(isPresented: $showsInformation) {
            if let artist {
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if !artist.aliases.isEmpty {
                                Text(L10n.joined(artist.aliases, separatorKey: "ui.common.artist_separator"))
                                    .foregroundStyle(.secondary)
                            }
                            if let biography = artist.biography { Text(biography) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                    }
                    .navigationTitle(artist.name)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("ui.common.close") { showsInformation = false }
                                .tint(.primary)
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
        .navigationDestination(isPresented: $showsAllSongs) {
            List(songs) { song in
                songRow(song).songSwipeActions(song)
            }
            .listStyle(.plain)
            .navigationTitle("ui.artist.song_chart")
            .visibleDetailNavigationBar()
        }
        .task(id: artist?.artworkURL) {
            guard let url = artist?.artworkURL else { artworkAssets = nil; return }
            if let cached = ArtworkAccentColorProvider.cachedDetailAssets(for: url) {
                artworkAssets = cached
            } else {
                let assets = await ArtworkAccentColorProvider.shared.detailAssets(for: url)
                if !Task.isCancelled { artworkAssets = assets }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadToken) {
            guard artist == nil else { return }
            await load()
        }
    }

    private func content(_ artist: Artist) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = min(width * 1.22, max(300, geometry.size.height * 0.78), 620)
            ZStack {
                MusicCollectionArtworkBackdrop(blurredArtworkImage: artworkAssets?.blurredBackdropImage,
                                               palette: palette)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        hero(artist, width: width, height: height)
                        if !songs.isEmpty { chart }
                        if !albums.isEmpty { albumShelf(width: width) }
                    }
                    .padding(.bottom, 24)
                }
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentOffset.y + $0.contentInsets.top > height - 90
                } action: { _, scrolled in
                    showsBarTitle = scrolled
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var palette: ArtworkDetailPalette {
        artworkAssets?.palette.collectionPalette(for: colorScheme)
            ?? .fallback(prefersDarkAppearance: colorScheme == .dark)
    }

    private var followTitle: String {
        L10n.string(isFollowed ? "ui.desktop.artist.following" : "ui.desktop.artist.follow")
    }

    private func hero(_ artist: Artist, width: CGFloat, height: CGFloat) -> some View {
        VStack(spacing: 16) {
            Spacer(minLength: 80)
            Text(artist.name)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 24) {
                Button {
                    showsInformation = true
                } label: {
                    Image(systemName: "info")
                        .frame(width: 48, height: 48)
                        .background(.primary.opacity(0.12), in: .circle)
                }
                .disabled(artist.aliases.isEmpty && artist.biography?.isEmpty != false)
                .accessibilityLabel("ui.artist.information")

                Button {
                    Task { await player.playAll(songs, sourceID: artist.id) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(palette.backgroundColor)
                        .frame(width: 72, height: 72)
                        .background(.primary, in: .circle)
                }
                .disabled(songs.isEmpty)
                .accessibilityLabel("ui.artist.play_popular_songs")

                Button {
                    Task { await toggleFollow(artist) }
                } label: {
                    Image(systemName: isFollowed ? "star.fill" : "star")
                        .frame(width: 48, height: 48)
                        .background(.primary.opacity(0.12), in: .circle)
                }
                .disabled(!library.isLoggedIn || isChangingFollowState)
                .accessibilityLabel(followTitle)
            }
            .font(.title2.weight(.semibold))
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, minHeight: height)
        .padding(.bottom, 8)
        .background(alignment: .top) {
            if artist.artworkURL != nil {
                ImmersiveCollectionArtwork(url: artist.artworkURL, width: width, height: height)
            }
        }
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                showsAllSongs = true
            } label: {
                HStack(spacing: 6) {
                    Text("ui.artist.song_chart")
                    Image(systemName: "chevron.right").font(.headline)
                }
                .font(.title3.bold())
            }
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                ForEach(songs.prefix(5)) { song in
                    songRow(song).songSwipeActions(song, inline: true)
                    if song.id != songs.prefix(5).last?.id {
                        Divider().padding(.leading, 60)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .songSwipeGroup()
    }

    private func songRow(_ song: Song) -> some View {
        let album = albums.first { $0.id == song.album?.id }
        let metadata = [song.album?.name, releaseYear(for: album ?? song.album)].compactMap { $0 }
        return TrackRowView(song: song, showsArtwork: true,
                            subtitleOverride: metadata.isEmpty ? nil : L10n.joined(metadata, separatorKey: "ui.common.metadata_separator")) {
            Task { await player.play(song, in: songs, sourceID: id) }
        }
        .frame(minHeight: 55)
        .overlay(alignment: .leading) {
            if library.contains(song: song) {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .offset(x: -14)
                    .accessibilityHidden(true)
            }
        }
    }

    private func albumShelf(width: CGFloat) -> some View {
        let size = min(width * 0.4, 210)
        return VStack(alignment: .leading, spacing: 12) {
            Text("ui.common.albums")
                .font(.title3.bold())
                .padding(.horizontal, 20)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(albums) { album in
                        let route = MusicRoute.album(album)
                        NavigationLink(value: route) {
                            MediaCardView(title: album.name, subtitle: releaseYear(for: album) ?? album.type,
                                          artworkURL: album.artworkURL, artworkSize: size)
                                .frame(width: size)
                        }
                        .buttonStyle(.plain)
                        .musicMatchedTransitionSource(for: route)
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }

    private func releaseYear(for album: Album?) -> String? {
        guard let milliseconds = album?.publishTime, milliseconds > 0 else { return nil }
        let year = Calendar(identifier: .gregorian).component(.year, from: Date(timeIntervalSince1970: milliseconds / 1000))
        return L10n.format("ui.common.year", year)
    }

    private func toggleFollow(_ artist: Artist) async {
        guard !isChangingFollowState else { return }
        let previous = isFollowed
        isFollowed.toggle()
        isChangingFollowState = true
        defer { isChangingFollowState = false }
        do {
            try await library.setArtistFollowed(artist, isFollowed: isFollowed)
        } catch {
            isFollowed = previous
            followError = error.localizedDescription
        }
    }

    private func load() async {
        phase = .loading
        do {
            (artist, songs, albums) = try await api.artist(id: id)
            if let artist {
                isFollowed = artist.isFollowed || library.contains(artist: artist)
            }
            phase = .loaded
        } catch is CancellationError {
            return
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
