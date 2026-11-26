import SwiftUI
import UIKit

enum SongRowRemoval {
    case library
    case download
    case action(LocalizedStringKey, () -> Void)
    case none
}

private extension EnvironmentValues {
    @Entry var openSongSwipeRow: Binding<UUID?>?
}

private struct SongSwipeGroup: ViewModifier {
    @State private var openRow: UUID?
    func body(content: Content) -> some View {
        content.environment(\.openSongSwipeRow, $openRow)
    }
}

extension View {
    func songSwipeGroup() -> some View { modifier(SongSwipeGroup()) }

    func songSwipeActions(_ song: Song, removal: SongRowRemoval = .library, inline: Bool = false,
                          reservesArtworkForScrolling: Bool = false, enabled: Bool = true, next: (() -> Void)? = nil) -> some View {
        modifier(SongRowSwipeActions(song: song, removal: removal, inline: inline,
                                     reservesArtworkForScrolling: reservesArtworkForScrolling, enabled: enabled, next: next))
    }
}

private struct RowAction {
    let title: LocalizedStringKey
    let symbol: String
    let color: Color
    let perform: () -> Void

    var button: some View {
        Button(action: perform) { Label(title, systemImage: symbol) }.tint(color)
    }
}

private struct SongRowSwipeActions: ViewModifier {
    let song: Song
    let removal: SongRowRemoval
    let inline: Bool
    let reservesArtworkForScrolling: Bool
    let enabled: Bool
    let next: (() -> Void)?
    @Environment(PlayerStore.self) private var player
    @Environment(DownloadStore.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        let playNext = RowAction(title: "ui.player.play_next", symbol: "text.line.first.and.arrowtriangle.forward",
                                 color: .purple, perform: next ?? { Task { await player.playNext(song) } })
        let remove = removalAction
        let download = downloadAction
        if !enabled {
            content
        } else if inline {
            content.modifier(InlineSongSwipe(leading: playNext, trailing: [remove, download].compactMap { $0 },
                                             reservesArtworkForScrolling: reservesArtworkForScrolling))
        } else {
            content
                .swipeActions(edge: .leading) { playNext.button }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    remove?.button
                    download?.button
                }
        }
    }

    private var removalAction: RowAction? {
        switch removal {
        case .action(let title, let action):
            return RowAction(title: title, symbol: "trash", color: .red, perform: action)
        case .none:
            return nil
        case .library:
            if library.isLoggedIn && library.contains(song: song) {
                return RowAction(title: "ui.song.unlike", symbol: "trash", color: .red) {
                    if library.contains(song: song) { library.toggle(song: song) }
                }
            }
            fallthrough
        case .download:
            guard AppFeatureAvailability.downloads && downloads.contains(songID: song.id) else { return nil }
            return RowAction(title: "ui.downloads.delete", symbol: "trash", color: .red) {
                downloads.remove(songID: song.id)
            }
        }
    }

    private var downloadAction: RowAction? {
        guard AppFeatureAvailability.downloads, settings.isContentFeatureEnabled(.downloads),
              !downloads.contains(songID: song.id) else { return nil }
        if downloads.isDownloading(songID: song.id) {
            return RowAction(title: "ui.downloads.cancel", symbol: "xmark.circle", color: .blue) {
                downloads.cancel(songID: song.id)
            }
        }
        return RowAction(title: "ui.common.download", symbol: "arrow.down.circle", color: .blue) {
            downloads.start(song, quality: settings.quality)
        }
    }
}

// Collection detail screens use scroll views with full-bleed artwork. Native list
// swipe actions don't render there, so reveal the same actions alongside the row.
private struct InlineSongSwipe: ViewModifier {
    let leading: RowAction
    let trailing: [RowAction]
    let reservesArtworkForScrolling: Bool
    @State private var rowID = UUID()
    @Environment(\.openSongSwipeRow) private var openRow
    @State private var resting: CGFloat = 0
    @State private var drag: CGFloat = 0
    @Environment(\.layoutDirection) private var direction
    private let width: CGFloat = 64

    func body(content: Content) -> some View {
        let sign: CGFloat = direction == .rightToLeft ? -1 : 1
        let limit = -width * CGFloat(trailing.count)
        let offset = min(width, max(limit, resting + drag))
        content
            .overlay {
                if resting != 0 {
                    Color.clear.contentShape(.rect).onTapGesture { close() }
                }
            }
            .offset(x: sign * offset)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .overlay(alignment: offset >= 0 ? .leading : .trailing) {
                if offset != 0 {
                    HStack(spacing: 0) {
                        if offset > 0 { tile(leading) }
                        else {
                            ForEach(trailing.indices.reversed(), id: \.self) { tile(trailing[$0]) }
                        }
                    }
                    .frame(width: abs(offset), alignment: offset > 0 ? .leading : .trailing)
                    .clipped()
                }
            }
            .clipped()
            .gesture(RowPan(reservesArtwork: reservesArtworkForScrolling && resting == 0) { translation, velocity, state in
                switch state {
                case .began: openRow?.wrappedValue = rowID
                case .changed: drag = sign * translation
                case .ended:
                    if resting == 0 && sign * translation > 118 {
                        close()
                        leading.perform()
                        return
                    }
                    let projected = resting + sign * (translation + velocity * 0.09)
                    withAnimation(.snappy(duration: 0.2)) {
                        resting = projected > 28 ? width : projected < -28 ? limit : 0
                        drag = 0
                    }
                case .cancelled, .failed: close()
                default: break
                }
            })
            .accessibilityActions {
                leading.button
                ForEach(trailing.indices, id: \.self) { trailing[$0].button }
            }
            .onChange(of: openRow?.wrappedValue) { _, newValue in
                if newValue != rowID && resting != 0 { close() }
            }
            .onChange(of: trailing.count) { close() }
            .onDisappear { resting = 0; drag = 0 }
    }

    private func tile(_ action: RowAction) -> some View {
        Button {
            close()
            action.perform()
        } label: {
            Image(systemName: action.symbol)
                .font(.title3.weight(.medium))
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .foregroundStyle(.white)
                .background(action.color)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.title)
    }

    private func close() {
        withAnimation(.snappy(duration: 0.2)) {
            resting = 0
            drag = 0
        }
    }
}

private struct RowPan: UIGestureRecognizerRepresentable {
    let reservesArtwork: Bool
    let update: (CGFloat, CGFloat, UIGestureRecognizer.State) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.reservesArtwork = reservesArtwork
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        update(recognizer.translation(in: recognizer.view).x, recognizer.velocity(in: recognizer.view).x, recognizer.state)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var reservesArtwork = false

        init(converter: CoordinateSpaceConverter) { self.converter = converter }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            guard let scroll = other.view as? UIScrollView else { return false }
            return other === scroll.panGestureRecognizer
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            let startX = converter.localLocation.x - pan.translation(in: pan.view).x
            return abs(velocity.x) > abs(velocity.y) * 1.4 && startX > (reservesArtwork ? 48 : 16)
        }
    }
}
