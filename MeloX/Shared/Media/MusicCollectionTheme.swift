import SwiftUI

extension ArtworkDetailPalette {
    var colorScheme: ColorScheme {
        prefersDarkAppearance ? .dark : .light
    }

    func collectionPalette(for scheme: ColorScheme) -> Self {
        let dark = scheme == .dark
        guard let sourceRGB else { return .fallback(prefersDarkAppearance: dark) }
        let background = dark
            ? sourceRGB * 0.29 + SIMD3(repeating: 0.035)
            : sourceRGB * 0.18 + SIMD3(repeating: 0.80)
        return Self(backgroundRGB: background, accentRGB: accentRGB,
                    prefersDarkAppearance: dark, sourceRGB: sourceRGB)
    }

    var backgroundColor: Color {
        Color(
            red: backgroundRGB.x,
            green: backgroundRGB.y,
            blue: backgroundRGB.z
        )
    }
}

func filterMusicCollectionTracks(_ tracks: [Song], query: String) -> [Song] {
    let keywords = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !keywords.isEmpty else { return tracks }
    return tracks.filter { song in
        song.name.localizedCaseInsensitiveContains(keywords)
            || song.artistText.localizedCaseInsensitiveContains(keywords)
            || (song.album?.name.localizedCaseInsensitiveContains(keywords) ?? false)
    }
}
