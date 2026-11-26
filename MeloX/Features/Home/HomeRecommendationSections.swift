import SwiftUI

struct HomeRecommendationSectionView: View {
    @Environment(PlayerStore.self) private var player

    @Environment(\.musicShelfLayout) private var layout

    let section: HomeRecommendationSection

    var body: some View {
        switch section.content {
        case .playlists(let playlists):
            playlistSection(playlists)
        case .songs(let songs):
            songSection(songs)
        case .podcastPrograms(let programs):
            podcastSection(programs)
        }
    }

    private func playlistSection(
        _ playlists: [Playlist]
    ) -> some View {
        HomeMediaStrip(title: section.title) {
            ForEach(playlists) { playlist in
                let route = playlistRoute(for: playlist)
                NavigationLink(value: route) {
                    HomePlaylistCard(playlist: playlist)
                }
                .buttonStyle(.plain)
                .musicMatchedTransitionSource(for: route)
            }
        }
    }

    private func songSection(
        _ songs: [Song]
    ) -> some View {
        HomeMediaStrip(
            title: section.title,
            playAll: {
                Task { await player.playAll(songs) }
            }
        ) {
            ForEach(Array(stride(from: 0, to: songs.count, by: 3)), id: \.self) { start in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(songs[start..<min(start + 3, songs.count)]) { song in
                        Button {
                            Task { await player.play(song, in: songs) }
                        } label: {
                            TrackRowView(song: song, showsArtwork: true)
                                .frame(minHeight: 58)
                        }
                        .buttonStyle(.plain)
                        .songSwipeActions(song, inline: true, reservesArtworkForScrolling: true)
                        if song.id != songs[min(start + 2, songs.count - 1)].id {
                            Divider().padding(.leading, 56)
                        }
                    }
                }
                .frame(width: min(layout.containerWidth * 0.83, 390))
            }
        }
        .songSwipeGroup()
    }

    private func podcastSection(
        _ programs: [PodcastProgram]
    ) -> some View {
        HomeMediaStrip(title: section.title) {
            ForEach(programs) { program in
                NavigationLink(
                    value: MusicRoute.podcastProgram(program)
                ) {
                    HomePodcastProgramCard(program: program)
                }
                .buttonStyle(.plain)
                .musicMatchedTransitionSource(
                    for: MusicRoute.podcastProgram(program)
                )
            }
        }
    }

    private func playlistRoute(for playlist: Playlist) -> MusicRoute {
        section.slot == .charts
            ? .toplist(playlist)
            : .playlist(playlist)
    }
}

struct HomeMediaStrip<Content: View>: View {
    @Environment(\.musicShelfLayout) private var layout
    let title: String
    var destination: MusicRoute?
    var playAll: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let destination {
                    NavigationLink(value: destination) {
                        HStack(spacing: 5) {
                            Text(title)
                            Image(systemName: "chevron.right")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    Text(title)
                }

                Spacer()

                if let playAll {
                    Button(action: playAll) {
                        Label("ui.common.play_all", systemImage: "play.fill")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel(L10n.format("ui.common.play_named", title))
                }
            }
            .font(.title3.bold())
            .padding(.horizontal, layout.homeInset)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    content()
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, layout.homeInset, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
        }
    }
}

struct HomeSongCard: View {
    @Environment(\.musicShelfLayout) private var layout
    let song: Song

    var body: some View {
        MediaCardView(
            title: song.name,
            subtitle: song.artistText,
            artworkURL: song.album?.artworkURL,
            artworkSize: layout.homeCoverSize
        )
        .frame(width: layout.homeCoverSize)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

private struct HomePodcastProgramCard: View {
    @Environment(\.musicShelfLayout) private var layout
    let program: PodcastProgram

    var body: some View {
        MediaCardView(
            title: program.name,
            subtitle: program.radio.name,
            artworkURL: program.artworkURL,
            artworkSize: layout.homeCoverSize
        )
        .frame(width: layout.homeCoverSize)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

struct HomeAlbumSection: View {
    @Environment(\.musicShelfLayout) private var layout
    let albums: [Album]

    var body: some View {
        HomeMediaStrip(title: L10n.string("ui.albums.new.title"), destination: .newAlbums) {
            ForEach(albums) { album in
                let route = MusicRoute.album(album)
                NavigationLink(value: route) {
                    MediaCardView(title: album.name, subtitle: album.artistText,
                                  artworkURL: album.artworkURL, artworkSize: layout.homeCoverSize)
                        .frame(width: layout.homeCoverSize)
                }
                .buttonStyle(.plain)
                .musicMatchedTransitionSource(for: route)
            }
        }
    }
}
