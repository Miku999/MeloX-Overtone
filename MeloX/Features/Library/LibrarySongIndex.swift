import Foundation

nonisolated enum LibrarySongSort: String {
    case artist, added, name
}

nonisolated enum LibrarySongFilter {
    case all, favorites, downloaded
}

nonisolated struct LibrarySongIndex {
    struct Section: Identifiable {
        let title: String
        var songs: [Song]
        var id: String { title }
    }

    struct Request: Equatable {
        var favorites: [Song]
        let favoriteDates: [Int: Date]
        let downloads: [DownloadedSong]
        let filter: LibrarySongFilter
        let sort: LibrarySongSort
        let query: String
        let locale: Locale
    }

    var sections: [Section] = []
    var songs: [Song] = []

    @concurrent static func build(_ request: Request) async throws -> Self {
        let downloads = request.downloads
        let candidates: [Song]
        switch request.filter {
        case .all: candidates = request.favorites + downloads.map(\.song)
        case .favorites: candidates = request.favorites
        case .downloaded: candidates = downloads.map(\.song)
        }

        var dates = request.favoriteDates
        if request.sort == .added {
            for download in downloads {
                dates[download.id] = min(dates[download.id] ?? download.downloadedAt, download.downloadedAt)
            }
        }

        var seen = Set<Int>()
        var entries = [(song: Song, letter: String, key: String, offset: Int)]()
        for (offset, song) in candidates.enumerated() {
            try Task.checkCancellation()
            guard seen.insert(song.id).inserted else { continue }
            if !request.query.isEmpty,
               !song.name.localizedCaseInsensitiveContains(request.query),
               !song.artistText.localizedCaseInsensitiveContains(request.query),
               song.album?.name.localizedCaseInsensitiveContains(request.query) != true { continue }

            let text = request.sort == .artist ? song.artists.first?.name ?? "" : song.name
            let key = request.sort == .added ? "" : collationKey(text, locale: request.locale)
            let letter = key.first.map(String.init) ?? ""
            let isLetter = letter.count == 1 && ("A"..."Z").contains(letter)
            entries.append((song, request.sort == .added ? "" : (isLetter ? letter : "#"), key, offset))
        }
        entries.sort { left, right in
            if request.sort == .added {
                let a = dates[left.song.id] ?? .distantPast
                let b = dates[right.song.id] ?? .distantPast
                return a == b ? left.offset < right.offset : a > b
            }
            if left.letter != right.letter {
                if left.letter == "#" { return false }
                if right.letter == "#" { return true }
                return left.letter < right.letter
            }
            let order = left.key.compare(right.key, options: .numeric, locale: request.locale)
            if order != .orderedSame { return order == .orderedAscending }
            let byTitle = left.song.name.localizedStandardCompare(right.song.name)
            return byTitle == .orderedSame ? left.song.id < right.song.id : byTitle == .orderedAscending
        }

        var index = Self()
        for entry in entries {
            if index.sections.last?.title != entry.letter {
                index.sections.append(Section(title: entry.letter, songs: []))
            }
            index.sections[index.sections.count - 1].songs.append(entry.song)
            index.songs.append(entry.song)
        }
        return index
    }

    static func collationKey(_ text: String, locale: Locale) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let latin = trimmed.utf8.allSatisfy { $0 < 128 } ? trimmed
            : trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
        return latin.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale).uppercased()
    }
}
