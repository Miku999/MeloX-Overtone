import SwiftUI

struct MiniPlayerMarquee: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @Environment(\.scenePhase) private var scenePhase
    @State private var textWidth: CGFloat = 0
    @State private var start = Date.now

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: text).fixedSize(horizontal: true, vertical: false)
            if reduceMotion {
                Text(verbatim: text).lineLimit(1)
            } else {
                scrollingText
            }
        }
        .onChange(of: text) { start = .now }
        .onChange(of: scenePhase) { start = .now }
    }

    private var scrollingText: some View {
        Text(verbatim: text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                GeometryReader { viewport in
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active)) { timeline in
                        let gap: CGFloat = 24
                        let speed: CGFloat = 28
                        let pause: TimeInterval = 1.4
                        let cycle = pause + (textWidth + gap) / speed
                        let elapsed = max(0, timeline.date.timeIntervalSince(start))
                        let offset = max(0, elapsed.truncatingRemainder(dividingBy: cycle) - pause) * speed

                        HStack(spacing: gap) {
                            Text(verbatim: text)
                                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                    textWidth = width
                                }
                            Text(verbatim: text)
                        }
                        .fixedSize()
                        .offset(x: direction == .rightToLeft ? offset : -offset)
                        .frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
                        .layerEffect(
                            ShaderLibrary.marqueeEdges(
                                .boundingRect,
                                .float(Float(min(offset, 14) / 14)),
                                .float(direction == .rightToLeft ? 1 : 0)
                            ),
                            maxSampleOffset: CGSize(width: 2, height: 2)
                        )
                    }
                }
            }
            .clipped()
    }
}
