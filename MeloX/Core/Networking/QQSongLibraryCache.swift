import Foundation

/// 「我的歌单 / 我喜欢」一次拉回来的整份曲目缓存。
///
/// `GetPlaylistByUin` 与 `fcg_ucc_getcdinfo_byids_cp` 都能在**一次**响应里
/// 带回完整曲目对象（`songid` / `songmid` / `songname` / `albummid` /
/// `interval` / `singer`）。不缓存的话 `LibraryStore.refresh()` 紧接着会调
/// `songDetails(ids:)`，2592 首按 20 首一批要 130 次往返，界面在几十秒里
/// 都读不到收藏；缓存命中后整份收藏只需 1 次网络。
/// 主 actor 隔离：读写都发生在 `QQMusicAPI` / `LibraryStore` 的
/// 同一隔离域内，单线程访问无需加锁；跨账号切换时由 `LibraryStore` 清空。
@MainActor
final class QQSongLibraryCache {
    static let shared = QQSongLibraryCache()

    private var storage: [Int: Song] = [:]
    private var midStorage: [Int: String] = [:]
    /// 超过这个条数整份丢弃重来，避免长时间使用后无限增长。
    private let capacityLimit = 12_000

    func store(_ newSongs: [Song], mids newMIDs: [Int: String]) {
        guard !newSongs.isEmpty || !newMIDs.isEmpty else { return }
        if storage.count + newSongs.count > capacityLimit {
            storage.removeAll(keepingCapacity: true)
            midStorage.removeAll(keepingCapacity: true)
        }
        for song in newSongs where song.id != 0 {
            storage[song.id] = song
        }
        for (id, mid) in newMIDs where id != 0 && !mid.isEmpty {
            midStorage[id] = mid
        }
    }

    func song(for id: Int) -> Song? {
        storage[id]
    }

    func mid(for id: Int) -> String? {
        midStorage[id]
    }

    func clear() {
        storage.removeAll()
        midStorage.removeAll()
    }
}
