import SwiftUI

struct ImmersiveCollectionArtwork: View {
    let url: URL?
    let width: CGFloat
    var height: CGFloat? = nil

    var body: some View {
        let topBleed = min(width * 0.03, 12)
        let centerDrop = min(width * 0.035, 15)
        let side = width + 2 * (topBleed + centerDrop)

        let imageHeight = height.map { $0 + topBleed } ?? side

        return ArtworkImage(url: url, cornerRadius: 0, aspectRatio: side / max(imageHeight, 1))
            .frame(width: side, height: imageHeight)
            .frame(width: width)
            .clipped()
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0.50),
                        .init(color: .white.opacity(0.92), location: 0.60),
                        .init(color: .white.opacity(0.70), location: 0.70),
                        .init(color: .white.opacity(0.32), location: 0.82),
                        .init(color: .white.opacity(0.06), location: 0.94),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .padding(.top, -topBleed)
    }
}
