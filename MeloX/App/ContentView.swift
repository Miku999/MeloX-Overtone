import SwiftUI
import UIKit

private enum ContentSheet: String, Identifiable {
    case settings

    var id: String { rawValue }
}

private struct HeartModeLaunchReadiness: Equatable {
    let hasRestoredPlayback: Bool
    let isLoggedIn: Bool
    let canStartHeartMode: Bool
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(PlayerStore.self) private var player
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadStore.self) private var downloads
    @Environment(LyricsStore.self) private var lyrics
    @Environment(FloatingLyricsController.self) private var floatingLyrics

    @State private var searchFocusRequestToken = 0
    @State private var selectedTab: AppTab
    @State private var navigationPaths = Dictionary(
        uniqueKeysWithValues: AppTab.allCases.map {
            ($0, NavigationPath())
        }
    )
    @State private var presentedSheet: ContentSheet?
    @State private var playerPresentation: PlayerPresentation?
    @State private var neteaseSharePresentation: NeteaseSharePresentation?
    @State private var nowPlayingSharePresentation: NeteaseSharePresentation?
    @State private var pendingMusicRoute: MusicRoute?
    @State private var isTabViewBottomAccessorySuppressed = false
    @State private var hasRestoredPlayback = false
    @State private var hasHandledHeartModeLaunch = false
    @State private var heartModeLaunchErrorMessage: String?
    @Namespace private var playerTransitionNamespace
    @Namespace private var musicNavigationNamespace

    private let playerTransitionID = "now-playing"

    init(initialTab: AppTab = .home) {
        _selectedTab = State(initialValue: initialTab)
        #if DEBUG && targetEnvironment(simulator)
        if MeloXDesignPreview.isEnabled,
           let pageName = ProcessInfo.processInfo.environment["MELOX_UI_PAGE"],
           let page = NowPlayingPage(rawValue: pageName) {
            _playerPresentation = State(initialValue: .nowPlaying(initialPage: page))
        }
        #endif
    }

    var body: some View {
        Group {
            if settings.hasCompletedOnboarding {
                mainExperience
            } else {
                OnboardingView()
            }
        }
    }

    private var mainExperience: some View {
        playerAwareTabView
            .environment(
                \.openMusicRoute,
                OpenMusicRouteAction(action: openMusicRoute)
            )
            .environment(
                \.openNeteaseShare,
                OpenNeteaseShareAction(action: openNeteaseShare)
            )
            .environment(
                \.setTabViewBottomAccessorySuppressed,
                SetTabViewBottomAccessorySuppressedAction {
                    isTabViewBottomAccessorySuppressed = $0
                }
            )
            .fullScreenCover(
                item: $playerPresentation,
                onDismiss: finishPendingSongNavigation
            ) { destination in
                switch destination {
                case .nowPlaying(let initialPage):
                    NowPlayingView(initialPage: initialPage)
                        .environment(
                            \.openMusicRoute,
                            OpenMusicRouteAction(action: openMusicRoute)
                        )
                        .environment(
                            \.openNeteaseShare,
                            OpenNeteaseShareAction { presentation in
                                presentNeteaseShare(
                                    presentation,
                                    fromNowPlaying: true
                                )
                            }
                        )
                        .sheet(item: $nowPlayingSharePresentation) {
                            presentation in
                            NeteaseShareSheet(presentation: presentation)
                        }
                        .presentationBackground(.clear)
                        .presentationContentInteraction(.resizes)
                        .navigationTransition(
                            .zoom(
                                sourceID: playerTransitionID,
                                in: playerTransitionNamespace
                            )
                        )
                }
            }
            .sheet(item: $neteaseSharePresentation) { presentation in
                NeteaseShareSheet(presentation: presentation)
            }
            .sheet(item: $presentedSheet) { destination in
                switch destination {
                case .settings:
                    NavigationStack {
                        SettingsView()
                            .musicDestinations(
                                in: musicNavigationNamespace
                            )
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)
                    .presentationCornerRadius(32)
                }
            }
            .task {
                await player.restore()
                guard !Task.isCancelled else { return }
                hasRestoredPlayback = true
            }
            .task(
                id: HeartModeLaunchReadiness(
                    hasRestoredPlayback: hasRestoredPlayback,
                    isLoggedIn: library.isLoggedIn,
                    canStartHeartMode: library.canStartHeartMode
                )
            ) {
                await startHeartModeOnLaunchIfNeeded()
            }
            .task(id: player.currentSong?.id) {
                await synchronizeLyrics()
            }
            .onChange(of: settings.lyricsSourcePreference) { _, _ in
                Task { await synchronizeLyrics() }
            }
            .task {
                await floatingLyrics.monitor()
            }
            .task(id: settings.cookie) {
                await library.refresh()
            }
            .background(alignment: .topLeading) {
                FloatingLyricsPictureInPictureSource(
                    controller: floatingLyrics
                )
                .frame(
                    width:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.width,
                    height:
                        FloatingLyricsPictureInPictureSource
                            .sourceSize.height
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: scenePhase) { _, phase in
                player.refreshLyricsNotification()
                guard phase == .active else { return }
                player.refreshLyricsLiveActivity()
            }
            .onChange(of: floatingLyrics.restorationRequestID) {
                guard floatingLyrics.restorationRequestID > 0,
                      player.currentSong != nil else {
                    floatingLyrics.completeRestoration(success: false)
                    return
                }

                presentPlayer(page: .lyrics)
                Task { @MainActor in
                    await Task.yield()
                    floatingLyrics.completeRestoration(success: true)
                }
            }
            .alert(
                "ui.error.playback.title",
                isPresented: Binding(
                    get: { player.playbackIssue != nil },
                    set: { isPresented in
                        if !isPresented {
                            player.dismissPlaybackIssue()
                        }
                    }
                )
            ) {
                if player.canPlayNext {
                    Button("ui.player.play_next") {
                        player.dismissPlaybackIssue()
                        Task { await player.next() }
                    }
                }
                Button("ui.common.ok", role: .cancel) {
                    player.dismissPlaybackIssue()
                }
            } message: {
                Text(player.playbackIssue?.message ?? L10n.string("ui.error.playback.current_unavailable"))
            }
            .alert(
                "ui.error.heart_mode_launch.title",
                isPresented: Binding(
                    get: { heartModeLaunchErrorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            heartModeLaunchErrorMessage = nil
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    heartModeLaunchErrorMessage = nil
                }
            } message: {
                Text(heartModeLaunchErrorMessage ?? L10n.string("ui.error.try_again_later"))
            }
            .alert(
                "ui.error.download.title",
                isPresented: Binding(
                    get: {
                        AppFeatureAvailability.downloads
                            && downloads.errorMessage != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            downloads.clearError()
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    downloads.clearError()
                }
            } message: {
                Text(downloads.errorMessage ?? L10n.string("ui.error.download.operation_failed"))
            }
            .alert(
                "ui.error.floating_lyrics.title",
                isPresented: Binding(
                    get: { floatingLyrics.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            floatingLyrics.dismissError()
                        }
                    }
                )
            ) {
                Button("ui.common.ok", role: .cancel) {
                    floatingLyrics.dismissError()
                }
            } message: {
                Text(
                    floatingLyrics.errorMessage
                        ?? L10n.string("ui.error.picture_in_picture.unavailable")
                )
            }
            .coordinateListenTogether()
            .recognizesClipboardLinksOnLaunch { song in
                openMusicRoute(.song(song))
            }
            .appLaunchExperience()
    }

    private func synchronizeLyrics() async {
        let song = player.currentSong
        let lyricSong = song?.isPodcastProgram == true ? nil : song
        await lyrics.load(for: lyricSong)
        guard !Task.isCancelled else { return }
        player.setNowPlayingLyrics(lyrics.lyrics, for: lyricSong?.id)
    }

    private func startHeartModeOnLaunchIfNeeded() async {
        guard !hasHandledHeartModeLaunch,
              hasRestoredPlayback else {
            return
        }
        guard settings.startsHeartModeOnLaunch else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.isLoggedIn else {
            hasHandledHeartModeLaunch = true
            return
        }
        guard library.canStartHeartMode,
              let playlistID = library.likedPlaylistID,
              let seedSongID = library.randomHeartModeSeedSongID() else {
            return
        }

        hasHandledHeartModeLaunch = true
        do {
            try await player.playHeartMode(
                playlistID: playlistID,
                seedSongID: seedSongID
            )
        } catch is CancellationError {
            return
        } catch {
            heartModeLaunchErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var playerAwareTabView: some View {
        if player.currentSong != nil {
            if #available(iOS 26.1, *) {
                tabs
                    .tabViewBottomAccessory(
                        isEnabled: !isTabViewBottomAccessorySuppressed
                    ) {
                        miniPlayer
                    }
            } else {
                tabs
                    .tabViewBottomAccessory {
                        if !isTabViewBottomAccessorySuppressed {
                            miniPlayer
                        }
                    }
            }
        } else {
            tabs
        }
    }

    @ViewBuilder
    private var miniPlayer: some View {
        if usesTabletNavigation {
            TabletMiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace,
                onExpand: presentPlayer
            )
        } else {
            MiniPlayerView(
                artworkTransitionID: playerTransitionID,
                artworkTransitionNamespace: playerTransitionNamespace
            ) {
                presentPlayer()
            }
        }
    }

    private var usesTabletNavigation: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
            && horizontalSizeClass == .regular
    }

    private var tabs: some View {
        let visibleTabs = usesTabletNavigation ? [.search] + AppTab.allCases.filter { $0 != .search } : AppTab.allCases
        return TabView(selection: $selectedTab) {
            ForEach(visibleTabs) { tab in
                Tab(value: tab, role: tab == .search ? .search : nil) {
                    tabNavigationStack(for: tab)
                } label: {
                    Label {
                        Text(tab.title)
                    } icon: {
                        tabBarIcon(for: tab)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(usesTabletNavigation ? .sidebar : .automatic)
        .tabViewSidebarBottomBar {
            SidebarAccountButton(accessibilityLabel: accountToolbarAccessibilityLabel) {
                presentedSheet = .settings
            } label: {
                HStack(spacing: 10) {
                    accountToolbarLabel
                        .frame(width: 38, height: 38)
                    Text(library.profile?.nickname ?? L10n.string("ui.account.login_settings"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background {
            TabBarTapObserver(visibleTabs: visibleTabs, selectedTab: selectedTab) { tab in
                guard #available(iOS 27.0, *), tab == .search else { return }
                searchFocusRequestToken += 1
            }
        }
        .tabBarMinimizeBehavior(usesTabletNavigation ? .never : .onScrollDown)
        .environment(\.musicUsesSidebar, usesTabletNavigation)
        .environment(\.musicNavigationNamespace, musicNavigationNamespace)
    }

    private func tabBarIcon(for tab: AppTab) -> Image {
        let name: String
        switch tab {
        case .home: name = "home.fill"
        case .library: name = "music.square.stack.fill"
        default: return Image(systemName: tab.systemImage)
        }
        if let bundle = Bundle(path: "/System/Library/CoreServices/CoreGlyphsPrivate.bundle"),
           let symbol = UIImage(named: name, in: bundle, with: nil) {
            return Image(uiImage: symbol.withRenderingMode(.alwaysTemplate))
        }
        return Image(systemName: tab.systemImage)
    }

    private func tabNavigationStack(for tab: AppTab) -> some View {
        NavigationStack(path: navigationPathBinding(for: tab)) {
            tabRoot(for: tab)
                .toolbarTitleDisplayMode(.inlineLarge)
                .modifier(TabRootNavigationBar())
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            presentedSheet = .settings
                        } label: {
                            accountToolbarLabel
                                .padding(2)
                                .glassEffect(.regular.interactive(), in: .circle)
                                .contentShape(.circle)
                        }
                        .offset(x: 2)
                        .accessibilityLabel(accountToolbarAccessibilityLabel)
                        .accessibilityIdentifier("navigation-account")
                        .tint(.primary)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
                .musicDestinations(in: musicNavigationNamespace)
        }
    }

    private func presentPlayer(page: NowPlayingPage? = nil) {
        if let page, settings.rememberNowPlayingPage {
            settings.rememberedNowPlayingPage = page.rawValue
        }
        playerPresentation = .nowPlaying(initialPage: page ?? initialNowPlayingPage)
    }

    @ViewBuilder
    private func tabRoot(for tab: AppTab) -> some View {
        switch tab {
        case .home:
            HomeRecommendedView()
                .navigationTitle(tab.title)
        case .podcasts:
            PodcastHomeView()
        case .explore:
            ExploreView()
        case .library:
            LibraryView()
        case .search:
            SearchView(focusRequestToken: searchFocusRequestToken)
        }
    }

    @ViewBuilder
    private var accountToolbarLabel: some View {
        if let profile = library.profile {
            AsyncImage(url: profile.artworkURL) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.fill")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 38, height: 38)
            .background(.quaternary, in: .circle)
            .clipShape(.circle)
        } else {
            Image(
                systemName: library.isLoggedIn
                    ? "person.crop.circle.fill"
                    : "person.crop.circle"
            )
            .resizable()
            .scaledToFit()
            .frame(width: 38, height: 38)
        }
    }

    private var accountToolbarAccessibilityLabel: String {
        if let profile = library.profile {
            return L10n.format("ui.account.settings_for_user", profile.nickname)
        }
        return library.isLoggedIn
            ? L10n.string("ui.account.settings")
            : L10n.string("ui.account.login_settings")
    }

    private func navigationPathBinding(
        for tab: AppTab
    ) -> Binding<NavigationPath> {
        Binding(
            get: {
                navigationPaths[tab] ?? NavigationPath()
            },
            set: {
                navigationPaths[tab] = $0
            }
        )
    }

    private var initialNowPlayingPage: NowPlayingPage {
        guard settings.rememberNowPlayingPage else { return .artwork }
        return NowPlayingPage(rawValue: settings.rememberedNowPlayingPage) ?? .artwork
    }

    private func openMusicRoute(_ route: MusicRoute) {
        guard playerPresentation == nil else {
            pendingMusicRoute = route
            playerPresentation = nil
            return
        }
        navigate(to: route)
    }

    private func openNeteaseShare(
        _ presentation: NeteaseSharePresentation
    ) {
        presentNeteaseShare(presentation, fromNowPlaying: false)
    }

    private func presentNeteaseShare(
        _ presentation: NeteaseSharePresentation,
        fromNowPlaying: Bool
    ) {
        Task { @MainActor in
            // Menu actions can fire before the system has completed
            // dismissing the menu. Present on the next settled UI turn.
            try? await Task.sleep(for: .milliseconds(140))
            if fromNowPlaying {
                nowPlayingSharePresentation = presentation
            } else {
                neteaseSharePresentation = presentation
            }
        }
    }

    private func finishPendingSongNavigation() {
        guard let route = pendingMusicRoute else { return }
        pendingMusicRoute = nil
        navigate(to: route)
    }

    private func navigate(to route: MusicRoute) {
        var path = navigationPaths[selectedTab] ?? NavigationPath()
        path.append(route)
        navigationPaths[selectedTab] = path
    }
}

extension View {
    @ViewBuilder
    func visibleDetailNavigationBar() -> some View {
        if #available(iOS 27, *) {
            toolbarMinimizationBehavior(.never, for: .navigationBar)
                .toolbarVisibility(.visible, for: .navigationBar)
        } else {
            toolbarVisibility(.visible, for: .navigationBar)
        }
    }
}

private struct TabRootNavigationBar: ViewModifier {
    @State private var atTop = true

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content
                .toolbarMinimizationBehavior(.onScrollDown, for: .navigationBar)
                .toolbarMinimizationRestoration(.atScrollEdge, for: .navigationBar)
        } else {
            content
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentOffset.y + $0.contentInsets.top <= 0.5
                } action: { _, value in
                    atTop = value
                }
                .toolbarVisibility(atTop ? .visible : .hidden, for: .navigationBar)
        }
    }
}
