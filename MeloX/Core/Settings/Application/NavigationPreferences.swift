import Foundation

enum AppTab: String, CaseIterable, Identifiable {
    case home
    case explore
    case podcasts
    case library
    case search

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: L10n.string("ui.navigation.home")
        case .explore: L10n.string("ui.navigation.explore")
        case .podcasts: L10n.string("ui.navigation.podcasts")
        case .library: L10n.string("ui.navigation.library")
        case .search: L10n.string("ui.navigation.search")
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .explore: "square.grid.2x2.fill"
        case .podcasts: "dot.radiowaves.left.and.right"
        case .library: "music.note.list"
        case .search: "magnifyingglass"
        }
    }
}

enum LibraryPage: String, CaseIterable, Identifiable {
    case playlists
    case artists
    case albums
    case songs
    case downloads
    case podcasts
    case cloud

    var id: String { rawValue }

    static var availableCases: [LibraryPage] {
        allCases.filter {
            AppFeatureAvailability.downloads || $0 != .downloads
        }
    }

    var title: String {
        switch self {
        case .songs: L10n.string("ui.common.songs")
        case .playlists: L10n.string("ui.common.playlists")
        case .artists: L10n.string("ui.library.artists.title")
        case .albums: L10n.string("ui.common.albums")
        case .podcasts: L10n.string("ui.navigation.podcasts")
        case .downloads: L10n.string("ui.navigation.downloads")
        case .cloud: L10n.string("ui.navigation.cloud")
        }
    }

    var systemImage: String {
        switch self {
        case .songs: "music.note"
        case .playlists: "music.note.list"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .podcasts: "mic"
        case .downloads: "arrow.down.circle"
        case .cloud: "icloud"
        }
    }
}
