import SwiftUI

struct MusicToolbarSymbol: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .accessibilityHidden(true)
    }
}
