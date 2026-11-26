import SwiftUI

struct SongListPlaybackActions: View {
    var isPreparing = false
    let play: (Bool) -> Void

    var body: some View {
        HStack(spacing: 16) {
            action("ui.common.play", symbol: "play.fill", shuffled: false)
            action("ui.player.shuffle", symbol: "shuffle", shuffled: true)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .disabled(isPreparing)
        .listRowInsets(EdgeInsets(top: 2, leading: 20, bottom: 2, trailing: 20))
        .listRowSeparator(.hidden)
    }

    private func action(_ title: LocalizedStringKey, symbol: String, shuffled: Bool) -> some View {
        Button {
            play(shuffled)
        } label: {
            HStack {
                if isPreparing && !shuffled {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(Color.primary.opacity(0.10), in: .capsule)
        }
    }
}
