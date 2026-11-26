import Foundation

/// MeloX 全链路用 Int 作为 Song/Album/Artist/Playlist 的标识，而 QQ 音乐的播放、
/// 歌词 CGI 需要字符串 songmid。此注册表在 adapter 阶段登记 `songid -> songmid`，
/// 在播放/歌词阶段反查。持久化到 UserDefaults，避免 App 重启后丢失。
///
/// 若本地没有记录（例如从旧缓存恢复的歌曲），走 `fcg_play_single_song.fcg`
/// 按 songid 在线反查 mid，见 `QQMusicAPI.resolveSongMID`。
///
/// 可变状态全部由 `NSLock` 保护，所以用 `@unchecked Sendable`；
/// 类型本身 `nonisolated`，避免被默认 MainActor 隔离拖慢非主线程读取。
nonisolated final class QQIDRegistry: @unchecked Sendable {
    static let shared = QQIDRegistry()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "qq.melox.songid.mid.map.v1"
    private let entityStorageKey = "qq.melox.entity.mid.map.v1"

    private var idToMid: [Int: String]
    private var midToID: [String: Int]
    private var entityMid: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        var forward: [Int: String] = [:]
        var reverse: [String: Int] = [:]
        if let stored = defaults.dictionary(forKey: storageKey) as? [String: String] {
            for (key, value) in stored {
                guard let id = Int(key) else { continue }
                forward[id] = value
                reverse[value] = id
            }
        }
        self.idToMid = forward
        self.midToID = reverse
        self.entityMid = (defaults.dictionary(forKey: entityStorageKey) as? [String: String]) ?? [:]
    }

    // MARK: - 歌曲 id <-> songmid

    func register(songID: Int, songMID: String) {
        guard songID != 0, !songMID.isEmpty else { return }
        lock.lock()
        let changed = idToMid[songID] != songMID
        idToMid[songID] = songMID
        midToID[songMID] = songID
        let snapshot = idToMid
        lock.unlock()
        if changed {
            persist(snapshot)
        }
    }

    func mid(for songID: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return idToMid[songID]
    }

    func songID(for mid: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return midToID[mid]
    }

    // MARK: - 通用实体映射（album / singer / playlist）

    /// key 形如 "album:8220" / "singer:4558" / "playlist:9466535456"。
    func register(entity: String, numericID: Int, mid: String) {
        guard numericID != 0, !mid.isEmpty else { return }
        let key = "\(entity):\(numericID)"
        lock.lock()
        guard entityMid[key] != mid else {
            lock.unlock()
            return
        }
        entityMid[key] = mid
        let snapshot = entityMid
        lock.unlock()
        defaults.set(snapshot, forKey: entityStorageKey)
    }

    func mid(entity: String, numericID: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entityMid["\(entity):\(numericID)"]
    }

    // MARK: - 持久化

    private func persist(_ map: [Int: String]) {
        // 控制体积：只保留最近写入的 5000 条，足够覆盖任何实际资料库规模。
        let capped = map.suffix(5_000)
        var serialized: [String: String] = [:]
        serialized.reserveCapacity(capped.count)
        for (key, value) in capped {
            serialized[String(key)] = value
        }
        defaults.set(serialized, forKey: storageKey)
    }
}
