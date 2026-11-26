import SwiftUI

extension MusicShelfLayout {
    var homeInset: CGFloat { max(horizontalPadding, 20) }
    var homeCoverSize: CGFloat {
        containerWidth >= 600 ? artworkSize(compact: 160) : containerWidth * 0.4
    }
}

struct HomeEditorialCard: View {
    let action: HomeQuickAction
    let artworkURL: URL?
    let detail: String

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: action.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            .aspectRatio(3.0 / 4, contentMode: .fit)
            .overlay {
                if let artworkURL {
                    ArtworkImage(url: artworkURL, cornerRadius: 0, aspectRatio: 3.0 / 4)
                } else {
                    RadialGradient(colors: [.white.opacity(0.32), .clear], center: .trailing,
                                   startRadius: 0, endRadius: 180)
                }
            }
            .overlay {
                LinearGradient(stops: [.init(color: .clear, location: 0.35),
                                       .init(color: .black.opacity(0.78), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: action.systemImage)
                    .font(.headline.weight(.semibold))
                    .padding(14)
                    .accessibilityHidden(true)
            }
            .overlay {
                if artworkURL == nil {
                    Text(action.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.eyebrow)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                    if artworkURL != nil {
                        Text(action.title).font(.title2.bold())
                    }
                    Text(detail)
                        .font(.subheadline)
                        .lineLimit(3)
                }
                .padding(16)
            }
            .foregroundStyle(.white)
            .clipShape(.rect(cornerRadius: 16))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(action.title)
            .accessibilityValue(detail)
    }
}

struct HomePlaylistCard: View {
    @Environment(\.musicShelfLayout) private var layout
    let playlist: Playlist

    var body: some View {
        MediaCardView(
            title: playlist.name,
            subtitle:
                playlist.copywriter
                ?? playlist.updateFrequency
                ?? playlist.creator?.nickname,
            artworkURL: playlist.artworkURL,
            artworkSize: layout.homeCoverSize
        )
        .frame(width: layout.homeCoverSize)
    }
}
