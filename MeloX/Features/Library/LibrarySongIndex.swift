import Foundation

nonisolated enum LibrarySongSort: String, Equatable {
    case artist, added, name
}

nonisolated enum LibrarySongFilter: Equatable {
    case all, favorites, downloaded
}

nonisolated struct LibrarySongIndex {
    struct Section: Identifiable {
        let title: String
        var songs: [Song]
        var id: String { title }
    }

    struct Request: Equatable {
        let favorites: [Song]
        let favoriteDates: [Int: Date]
        let downloads: [DownloadedSong]
        let filter: LibrarySongFilter
        let sort: LibrarySongSort
        let query: String
        let locale: Locale

        init(
            favorites: [Song],
            favoriteDates: [Int: Date],
            downloads: [DownloadedSong],
            filter: LibrarySongFilter,
            sort: LibrarySongSort,
            query: String,
            locale: Locale,
            favoritesRevision: Int = 0
        ) {
            self.favorites = favorites
            self.favoriteDates = favoriteDates
            self.downloads = downloads
            self.filter = filter
            self.sort = sort
            self.query = query
            self.locale = locale
            self.favoritesRevision = favoritesRevision
            self.favoriteCount = favorites.count
            self.favoriteFirstID = favorites.first?.id
            self.favoriteLastID = favorites.last?.id
        }

        /// 收藏列表的 O(1) 指纹。
        ///
        /// `Song` 的 `Equatable` 是逐字段合成的（含 `artists`、`album` 里的字符串），
        /// 2592 首直接比较一次要几毫秒；而 SwiftUI 的 `body`、`.task(id:)`
        /// 每次求值都要比一次，滚动时累加起来就是整机掉帧。
        ///
        /// 现在只用「变更版本号 + 条数 + 首尾 id」这四项，全部在 `init` 里 O(1) 取出。
        /// 之前那版会在 `init` 里拼一个 12 个 id 的字符串，`body` 求值频率一高
        /// 就是纯浪费，这里也一并去掉。
        private let favoritesRevision: Int
        private let favoriteCount: Int
        private let favoriteFirstID: Int?
        private let favoriteLastID: Int?

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.filter == rhs.filter
                && lhs.sort == rhs.sort
                && lhs.query == rhs.query
                && lhs.locale.identifier == rhs.locale.identifier
                && lhs.downloads.count == rhs.downloads.count
                && lhs.favoriteDates.count == rhs.favoriteDates.count
                && lhs.favoriteCount == rhs.favoriteCount
                && lhs.favoriteFirstID == rhs.favoriteFirstID
                && lhs.favoriteLastID == rhs.favoriteLastID
                && lhs.favoritesRevision == rhs.favoritesRevision
        }
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
        seen.reserveCapacity(candidates.count)
        var entries = [(song: Song, letter: String, key: String, offset: Int)]()
        entries.reserveCapacity(candidates.count)
        for (offset, song) in candidates.enumerated() {
            if offset & 0xFF == 0 {
                try Task.checkCancellation()
            }
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
        index.sections.reserveCapacity(32)
        index.songs.reserveCapacity(entries.count)
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
        guard !trimmed.isEmpty else { return "" }
        // `applyingTransform(.toLatin)` 是 ICU 音译，中文歌名/歌手名每次都要走一遍，
        // 2592 首里同一歌手、同一专辑重复极多。缓存掉这部分能省下大半构建时间。
        return CollationKeyCache.shared.value(for: locale.identifier + "\u{1}" + trimmed) {
            let latin = trimmed.utf8.allSatisfy { $0 < 128 } ? trimmed
                : trimmed.applyingTransform(.toLatin, reverse: false) ?? trimmed
            return latin.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: locale).uppercased()
        }
    }
}

/// 音译排序键缓存。`build` 跑在 `@concurrent` 后台，用锁保护。
private nonisolated final class CollationKeyCache: @unchecked Sendable {
    nonisolated static let shared = CollationKeyCache()

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private let limit = 16_384

    func value(for key: String, build: () -> String) -> String {
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = build()

        lock.lock()
        if storage.count >= limit {
            storage.removeAll(keepingCapacity: true)
        }
        storage[key] = value
        lock.unlock()
        return value
    }
}
