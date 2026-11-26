import SwiftUI

struct SongRowArtwork: View {
    let songID: Int
    let url: URL?
    var cornerRadius: CGFloat = 6
    var representsCurrentEntry = true

    @Environment(PlayerStore.self) private var player

    var body: some View {
        ArtworkImage(url: url, cornerRadius: cornerRadius)
            .overlay {
                if representsCurrentEntry && player.currentSong?.id == songID {
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(.black.opacity(0.48))
                        .overlay { SongRowWaveform().foregroundStyle(.white) }
                        .allowsHitTesting(false)
                }
            }
    }
}

struct SongRowWaveform: View {
    @Environment(PlayerStore.self) private var player
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !player.isPlaying {
                bars(.zero)
            } else if reduceMotion {
                playIcon
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { _ in
                    if let levels = player.rowMeterLevels {
                        bars(levels)
                    } else {
                        playIcon
                    }
                }
            }
        }
        .frame(width: 20, height: 18)
        .accessibilityHidden(true)
    }

    private func bars(_ levels: SIMD8<Float>) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { band in
                Capsule()
                    .frame(width: 2, height: 2 + 15 * CGFloat(levels[band]))
                    .animation(.linear(duration: 0.05), value: levels[band])
            }
        }
    }

    private var playIcon: some View {
        Image(systemName: "play.fill").font(.system(size: 12, weight: .medium))
    }
}
