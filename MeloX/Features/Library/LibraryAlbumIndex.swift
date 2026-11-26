import Foundation

nonisolated enum LibraryAlbumSort: String {
    case name, added, artist, year
}

nonisolated struct LibraryAlbumIndex {
    struct Request: Equatable {
        let subscribed: [Album]
        let songs: [Song]
        let songDates: [Int: Date]
        let downloads: [DownloadedSong]
        let filter: LibrarySongFilter
        let sort: LibraryAlbumSort
        let query: String
        let locale: Locale
    }

    struct Entry: Identifiable {
        let album: Album
        var artists: [Artist]
        var releaseTime: Double?
        var added: Date?
        let sourceOrder: Int
        var id: Int { album.id }
        var artistText: String { L10n.joined(artists.map(\.name), separatorKey: "ui.common.artist_separator") }
    }

    struct Group: Identifiable {
        let title: String
        var entries: [Entry]
        var id: String { title }
    }

    var groups: [Group] = []

    @concurrent static func build(_ request: Request) async throws -> Self {
        var entries: [Int: Entry] = [:]

        func include(_ album: Album?, song: Song? = nil, added: Date?) {
            guard let album, album.id > 0 else { return }
            var entry = entries[album.id] ?? Entry(album: album, artists: album.artists,
                                                    releaseTime: album.publishTime, added: added, sourceOrder: entries.count)
            if entry.artists.isEmpty { entry.artists = song?.artists ?? album.artists }
            if entry.releaseTime == nil { entry.releaseTime = album.publishTime ?? song?.publishTime }
            if let added { entry.added = min(entry.added ?? added, added) }
            entries[album.id] = entry
        }

        if request.filter != .downloaded {
            for album in request.subscribed {
                try Task.checkCancellation()
                let date = album.subscriptionTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
                include(album, added: date)
            }
        }
        if request.filter == .all {
            for song in request.songs where !song.isPodcastProgram {
                try Task.checkCancellation()
                include(song.album, song: song, added: request.songDates[song.id])
            }
        }
        if request.filter != .favorites {
            for download in request.downloads where !download.song.isPodcastProgram {
                try Task.checkCancellation()
                include(download.song.album, song: download.song, added: download.downloadedAt)
            }
        }

        var rows: [(entry: Entry, section: String, key: String)] = []
        let calendar = Calendar(identifier: .gregorian)
        for entry in entries.values {
            try Task.checkCancellation()
            guard request.query.isEmpty || entry.album.name.localizedCaseInsensitiveContains(request.query)
                    || entry.artistText.localizedCaseInsensitiveContains(request.query) else { continue }
            let key: String
            let section: String
            switch request.sort {
            case .added:
                key = ""
                section = ""
            case .year:
                key = entry.album.name
                if let time = entry.releaseTime, time > 0 {
                    section = String(calendar.component(.year, from: Date(timeIntervalSince1970: time / 1000)))
                } else {
                    section = "#"
                }
            case .artist, .name:
                let text = request.sort == .artist ? entry.artists.first?.name ?? "" : entry.album.name
                key = LibrarySongIndex.collationKey(text, locale: request.locale)
                section = key.first.map { ("A"..."Z").contains($0) ? String($0) : "#" } ?? "#"
            }
            rows.append((entry, section, key))
        }
        rows.sort { a, b in
            if request.sort == .added {
                let left = a.entry.added ?? .distantPast
                let right = b.entry.added ?? .distantPast
                return left == right ? a.entry.sourceOrder < b.entry.sourceOrder : left > right
            }
            if a.section != b.section {
                if a.section == "#" { return false }
                if b.section == "#" { return true }
                return request.sort == .year ? a.section > b.section : a.section < b.section
            }
            let order = a.key.compare(b.key, options: .numeric, locale: request.locale)
            if order != .orderedSame { return order == .orderedAscending }
            let name = a.entry.album.name.localizedStandardCompare(b.entry.album.name)
            return name == .orderedSame ? a.entry.id < b.entry.id : name == .orderedAscending
        }
        var result = Self()
        for row in rows {
            if result.groups.last?.title != row.section {
                result.groups.append(Group(title: row.section, entries: []))
            }
            result.groups[result.groups.count - 1].entries.append(row.entry)
        }
        return result
    }
}
