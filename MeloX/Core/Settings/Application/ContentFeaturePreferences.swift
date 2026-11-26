import Foundation
import Observation

enum ContentFeature: String, CaseIterable, Identifiable {
    case podcasts
    case downloads
    case cloudMusic
    case listeningHistory

    var id: Self { self }

    var title: String {
        switch self {
        case .podcasts: L10n.string("ui.settings.content_feature.podcasts.title")
        case .downloads: L10n.string("ui.navigation.downloads")
        case .cloudMusic: L10n.string("ui.settings.content_feature.cloud.title")
        case .listeningHistory: L10n.string("ui.navigation.recently_played")
        }
    }

    var detail: String {
        switch self {
        case .podcasts: L10n.string("ui.settings.content_feature.podcasts.detail")
        case .downloads: L10n.string("ui.settings.content_feature.downloads.detail")
        case .cloudMusic: L10n.string("ui.settings.content_feature.cloud.detail")
        case .listeningHistory: L10n.string("ui.settings.content_feature.history.detail")
        }
    }

    var systemImage: String {
        switch self {
        case .podcasts: "dot.radiowaves.left.and.right"
        case .downloads: "arrow.down.circle"
        case .cloudMusic: "icloud"
        case .listeningHistory: "clock"
        }
    }

    static var availableCases: [ContentFeature] {
        allCases.filter {
            $0 != .downloads || AppFeatureAvailability.downloads
        }
    }
}
