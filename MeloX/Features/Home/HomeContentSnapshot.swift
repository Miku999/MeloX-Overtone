import Foundation

struct HomeContentSnapshot: Codable {
    let payload: HomePagePayload
    let charts: [Playlist]
    let fallbacks: [HomeRecommendationSlot: HomeRecommendationFallback]

    var dailySongs: [Song]?
    var newAlbums: [Album]?

    static func cacheKey(musicArea: String) -> String {
        "home.v1.\(musicArea)"
    }
}
