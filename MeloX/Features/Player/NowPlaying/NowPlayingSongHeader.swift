import SwiftUI

struct NowPlayingArtworkTransitionModifier<ID: Hashable>: ViewModifier {
    let id: ID
    let namespace: Namespace.ID
    let isEnabled: Bool
    let isSource: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.matchedGeometryEffect(
                id: id,
                in: namespace,
                properties: .frame,
                isSource: isSource
            )
        } else {
            content
        }
    }
}

extension View {
    func nowPlayingArtworkTransition<ID: Hashable>(
        id: ID,
        in namespace: Namespace.ID,
        isEnabled: Bool,
        isSource: Bool = true
    ) -> some View {
        modifier(
            NowPlayingArtworkTransitionModifier(
                id: id,
                namespace: namespace,
                isEnabled: isEnabled,
                isSource: isSource
            )
        )
    }
}

struct NowPlayingArtistLink: View {
    @Environment(\.openMusicRoute) private var openMusicRoute

    let song: Song
    var title: String? = nil

    var body: some View {
        let artists = song.artists.filter { $0.id > 0 }
        let label = Text(verbatim: title ?? song.artistText)
        if song.isPodcastProgram || artists.isEmpty {
            label
        } else if artists.count == 1, let artist = artists.first {
            Button { openMusicRoute(.artist(artist.id)) } label: { label }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.format("ui.artist.go_to", artist.name))
        } else {
            Menu {
                ForEach(artists) { artist in
                    Button(artist.name) { openMusicRoute(.artist(artist.id)) }
                }
            } label: { label }
            .buttonStyle(.plain)
            .accessibilityHint("ui.artist.go_to_generic")
        }
    }
}

struct NowPlayingSongHeader: View {
    static let referenceHeight: CGFloat = 72

    let song: Song
    let artworkNamespace: Namespace.ID
    let usesReferenceLayout: Bool
    let usesArtworkTransition: Bool
    let showsArtwork: Bool

    init(
        song: Song,
        artworkNamespace: Namespace.ID,
        usesReferenceLayout: Bool,
        usesArtworkTransition: Bool = true,
        showsArtwork: Bool = true
    ) {
        self.song = song
        self.artworkNamespace = artworkNamespace
        self.usesReferenceLayout = usesReferenceLayout
        self.usesArtworkTransition = usesArtworkTransition
        self.showsArtwork = showsArtwork
    }

    var body: some View {
        HStack(spacing: 12) {
            artwork
                .frame(width: artworkSize, height: artworkSize)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(song.name)
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)

                    HeartModeNowPlayingBadge()
                    ListenTogetherNowPlayingBadge()
                }

                NowPlayingArtistLink(song: song, title: artistText)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NowPlayingSongActions(
                song: song,
                portrait: usesReferenceLayout
            )
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if showsArtwork {
            ArtworkImage(
                url: song.album?.artworkURL,
                cornerRadius: usesReferenceLayout ? 12 : 10
            )
            .nowPlayingArtworkTransition(
                id: song.id,
                in: artworkNamespace,
                isEnabled: usesArtworkTransition,
                isSource: false
            )
        } else {
            Color.clear
        }
    }

    private var artworkSize: CGFloat {
        usesReferenceLayout ? Self.referenceHeight : 68
    }

    private var artistText: String {
        guard usesReferenceLayout else { return song.artistText }
        return song.artists.map(\.name).joined(separator: " & ")
    }
}

struct NowPlayingLandscapeSongHeader: View {
    let song: Song
    let onExpandLyrics: (() -> Void)?

    init(
        song: Song,
        onExpandLyrics: (() -> Void)? = nil
    ) {
        self.song = song
        self.onExpandLyrics = onExpandLyrics
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(song.name)
                        .font(.headline)
                        .lineLimit(1)
                        .layoutPriority(1)

                    HeartModeNowPlayingBadge()
                    ListenTogetherNowPlayingBadge()
                }

                NowPlayingArtistLink(song: song)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onExpandLyrics {
                Button(action: onExpandLyrics) {
                    Image(
                        systemName:
                            "arrow.up.left.and.arrow.down.right"
                    )
                    .font(.title3.weight(.medium))
                    .frame(width: 40, height: 40)
                    .background(.white.opacity(0.13), in: .circle)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("ui.settings.skyline.title")
            }

            NowPlayingSongActions(song: song)
        }
        .frame(height: 52)
    }
}
