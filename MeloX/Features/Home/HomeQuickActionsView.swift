import SwiftUI

enum HomeQuickAction: String, CaseIterable, Identifiable {
    case dailySongs
    case hotSongs
    case heartMode
    case privateRadar
    case privateRoaming
    case similarSongs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs")
        }
    }

    var systemImage: String {
        switch self {
        case .dailySongs:
            "calendar"
        case .hotSongs:
            "flame.fill"
        case .heartMode:
            "heart.fill"
        case .privateRadar:
            "dot.radiowaves.left.and.right"
        case .privateRoaming:
            "figure.walk.motion"
        case .similarSongs:
            "music.note.list"
        }
    }

    var eyebrow: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs.eyebrow")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs.eyebrow")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode.eyebrow")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar.eyebrow")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming.eyebrow")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs.eyebrow")
        }
    }

    var subtitle: String {
        switch self {
        case .dailySongs:
            L10n.string("ui.home.action.daily_songs.subtitle")
        case .hotSongs:
            L10n.string("ui.home.action.hot_songs.subtitle")
        case .heartMode:
            L10n.string("ui.home.action.heart_mode.subtitle")
        case .privateRadar:
            L10n.string("ui.home.action.private_radar.subtitle")
        case .privateRoaming:
            L10n.string("ui.home.action.private_roaming.subtitle")
        case .similarSongs:
            L10n.string("ui.home.action.similar_songs.subtitle")
        }
    }

    var colors: [Color] {
        switch self {
        case .dailySongs:
            [.indigo, .purple, .pink]
        case .hotSongs:
            [.orange, .red]
        case .heartMode:
            [.pink, .purple]
        case .privateRadar:
            [.indigo, .purple]
        case .privateRoaming:
            [.cyan, .blue]
        case .similarSongs:
            [.mint, .teal]
        }
    }
}

struct HomeQuickActionsView: View {
    @Environment(\.musicShelfLayout) private var layout
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerStore.self) private var player

    let dailySongs: [Song]
    let hotChart: Playlist?
    let radar: Playlist?

    let activeAction: HomeQuickAction?
    let perform: (HomeQuickAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("ui.home.section.quick_actions")
                .font(.title3.bold())
                .padding(.horizontal, layout.homeInset)
                .accessibilityAddTraits(.isHeader)
            cards
        }
    }

    private var cards: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(HomeQuickAction.allCases) { action in
                    Button {
                        perform(action)
                    } label: {
                        HomeEditorialCard(
                            action: action,
                            artworkURL: artworkURL(for: action),
                            detail: detail(for: action)
                        )
                        .overlay {
                            if activeAction == action {
                                ProgressView()
                                    .controlSize(.regular)
                                    .padding(14)
                                    .background(.regularMaterial)
                                    .clipShape(.circle)
                            }
                        }
                    }
                    .frame(width: min(layout.containerWidth * 0.615, 290))
                    .buttonStyle(.plain)
                    .disabled(activeAction != nil)
                    .accessibilityHint(accessibilityHint(for: action))
                    .accessibilityIdentifier("home-action-\(action.id)")
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, layout.homeInset, for: .scrollContent)
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.viewAligned)
    }

    private func artworkURL(for action: HomeQuickAction) -> URL? {
        switch action {
        case .dailySongs, .privateRoaming: nil
        case .hotSongs: hotChart?.artworkURL
        case .privateRadar: radar?.artworkURL
        case .heartMode: library.favoriteSongs.first?.album?.artworkURL
        case .similarSongs: player.currentSong?.album?.artworkURL
        }
    }

    private func detail(for action: HomeQuickAction) -> String {
        switch action {
        case .dailySongs:
            var seen = Set<String>()
            let artists = dailySongs.flatMap(\.artists).map(\.name)
                .filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(6)
            return artists.isEmpty ? action.subtitle : artists.formatted(.list(type: .and).locale(L10n.locale))
        case .privateRadar:
            return radar?.name ?? action.subtitle
        case .similarSongs:
            return player.currentSong?.name ?? action.subtitle
        default:
            return action.subtitle
        }
    }

    private func accessibilityHint(
        for action: HomeQuickAction
    ) -> String {
        switch action {
        case .dailySongs, .hotSongs, .privateRadar:
            L10n.format("ui.home.action.open_hint", action.title)
        case .heartMode, .privateRoaming, .similarSongs:
            L10n.format("ui.home.action.play_hint", action.title)
        }
    }
}
