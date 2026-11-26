import SwiftUI

enum MusicNavigationTransitionTiming {
    static let settleDelay = Duration.milliseconds(350)
}

private struct MusicNavigationNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var musicNavigationNamespace: Namespace.ID? {
        get { self[MusicNavigationNamespaceKey.self] }
        set { self[MusicNavigationNamespaceKey.self] = newValue }
    }
}

extension View {
    /// - Parameters:
    ///   - route: 目标路由，决定转场 ID 与是否使用卡片放大转场。
    ///   - prefetchArtworkAssets: 是否顺带预取封面「详情资产」（原图下载 + 缩放 +
    ///     高斯模糊 + 取平均色 + 流动光调色板）。长列表里每一行都会各算一份，
    ///     滚动时会把 CPU 和网络打满，所以列表行必须传 `false`。
    ///   - enabled: `false` 时完全不注册转场源，点击退化为普通 push。
    func musicMatchedTransitionSource(
        for route: MusicRoute,
        prefetchArtworkAssets: Bool = true,
        enabled: Bool = true
    ) -> some View {
        modifier(
            MusicMatchedTransitionSourceModifier(
                route: route,
                prefetchArtworkAssets: prefetchArtworkAssets,
                enabled: enabled
            )
        )
    }

    func musicNavigationTransition(
        for route: MusicRoute,
        in namespace: Namespace.ID
    ) -> some View {
        modifier(
            MusicNavigationTransitionModifier(
                route: route,
                namespace: namespace
            )
        )
    }
}

private struct MusicMatchedTransitionSourceModifier: ViewModifier {
    let route: MusicRoute
    var prefetchArtworkAssets = true
    var enabled = true

    @Environment(\.musicNavigationNamespace) private var namespace

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled, route.usesCardExpansionTransition, let namespace {
            content.matchedTransitionSource(
                id: route.transitionID,
                in: namespace
            )
            .modifier(
                ArtworkDetailAssetsPrefetchModifier(
                    artworkURL: prefetchArtworkAssets
                        ? route.transitionArtworkURL
                        : nil
                )
            )
        } else {
            content
        }
    }
}

private struct ArtworkDetailAssetsPrefetchModifier: ViewModifier {
    let artworkURL: URL?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let artworkURL {
            content.task(id: artworkURL) {
                _ = await ArtworkAccentColorProvider.shared.detailAssets(
                    for: artworkURL
                )
            }
        } else {
            content
        }
    }
}

private struct MusicNavigationTransitionModifier: ViewModifier {
    let route: MusicRoute
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        if route.usesCardExpansionTransition {
            content.navigationTransition(
                .zoom(sourceID: route.transitionID, in: namespace)
            )
        } else {
            content
        }
    }
}
