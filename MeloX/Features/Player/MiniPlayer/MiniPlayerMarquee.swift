import SwiftUI

struct MiniPlayerMarquee: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var direction
    @Environment(\.scenePhase) private var scenePhase
    @State private var start = Date.now

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(verbatim: text).fixedSize(horizontal: true, vertical: false)
            if reduceMotion {
                Text(verbatim: text).lineLimit(1)
            } else {
                MarqueeScrollingText(
                    text: text,
                    start: start,
                    direction: direction,
                    isActive: scenePhase == .active
                )
            }
        }
        .onChange(of: text) { start = .now }
        .onChange(of: scenePhase) { start = .now }
    }
}

/// 滚动文本：宽度只在本体布局阶段测量一次，`TimelineView` 内部不再写 `@State`。
///
/// 原实现在 `TimelineView` 每一帧里用 `onGeometryChange` 把文本宽度写回 `@State`，
/// 一次写入又触发一次 `body` 求值（30 fps 的自我反馈回路），外加每帧一次的
/// `layerEffect` Metal shader。mini player 常驻在 TabView 底部，这个回路会把主线程
/// 长期占住，任何列表滚动、页面切换都会被它拖慢；歌名越长越明显。
///
/// 现在宽度由隐藏的测量层在布局阶段拿到，滚动帧里只做 `offset` 计算，
/// 边缘羽化换成静态 `mask`（原 shader 每帧重新编码 GPU 管线）。
private struct MarqueeScrollingText: View {
    let text: String
    let start: Date
    let direction: LayoutDirection
    let isActive: Bool

    @State private var textWidth: CGFloat = 0

    private static let gap: CGFloat = 24
    private static let speed: CGFloat = 28
    private static let pause: TimeInterval = 1.4

    var body: some View {
        Text(verbatim: text)
            .lineLimit(1)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                Text(verbatim: text)
                    .lineLimit(1)
                    .fixedSize()
                    .hidden()
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { width in
                        guard width > 0, width != textWidth else { return }
                        textWidth = width
                    }
            }
            .overlay {
                GeometryReader { viewport in
                    TimelineView(
                        .animation(minimumInterval: 1.0 / 30, paused: !isActive)
                    ) { timeline in
                        let cycle = Self.pause
                            + (textWidth + Self.gap) / Self.speed
                        let elapsed = max(
                            0,
                            timeline.date.timeIntervalSince(start)
                        )
                        let offset = max(
                            0,
                            elapsed.truncatingRemainder(dividingBy: cycle)
                                - Self.pause
                        ) * Self.speed

                        HStack(spacing: Self.gap) {
                            Text(verbatim: text)
                            Text(verbatim: text)
                        }
                        .fixedSize()
                        .offset(
                            x: direction == .rightToLeft ? offset : -offset
                        )
                        .frame(
                            width: viewport.size.width,
                            height: viewport.size.height,
                            alignment: .leading
                        )
                    }
                }
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .clipped()
    }
}
