import Nuke
import NukeUI
import SwiftUI

struct ArtworkImage: View {
    let url: URL?
    var cornerRadius: CGFloat = 10
    var aspectRatio: CGFloat = 1
    var placeholderSymbol = "music.note"
    /// 已知尺寸时直接使用，跳过 `GeometryReader`。
    /// 列表行每行一个 `GeometryReader` 会让滚动时的布局次数翻倍。
    var fixedSize: CGSize? = nil

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    var body: some View {
        Group {
            if let fixedSize {
                lazyImage(size: fixedSize)
                    .frame(width: fixedSize.width, height: fixedSize.height)
            } else {
                GeometryReader { proxy in
                    lazyImage(size: proxy.size)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius))
        .accessibilityHidden(true)
    }

    private func lazyImage(size: CGSize) -> some View {
        LazyImage(
            request: imageRequest(for: size),
            transaction: Transaction(animation: imageLoadAnimation)
        ) { state in
            content(image: state.image, hasError: state.error != nil)
        }
        .onDisappear(.lowerPriority)
    }

    private func imageRequest(for size: CGSize) -> ImageRequest? {
        guard let url else { return nil }

        var request = ImageRequest(url: url)
        request.thumbnail = ImageRequest.ThumbnailOptions(
            size: CGSize(
                width: max(size.width, 1),
                height: max(size.height, 1)
            ),
            contentMode: .aspectFill
        )
        return request
    }

    private var imageLoadAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.18)
    }

    @ViewBuilder
    private func content(image: Image?, hasError: Bool) -> some View {
        if let image {
            image
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        } else if hasError || url == nil {
            placeholder
        } else {
            ZStack {
                Color.secondary.opacity(0.12)
                ProgressView()
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: placeholderSymbol)
                .font(.title2)
                .foregroundStyle(.secondary)
        }
    }
}
