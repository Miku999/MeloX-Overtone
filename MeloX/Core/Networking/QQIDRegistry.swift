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

    /// 脏标记与合并落盘状态，见 `markDirty`。
    private var songDirty = false
    private var entityDirty = false
    private var flushScheduled = false
    private static let flushQueue = DispatchQueue(
        label: "qq.melox.idregistry.flush",
        qos: .utility
    )

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
        let shouldSchedule = changed && !flushScheduled
        if changed { songDirty = true; flushScheduled = true }
        lock.unlock()
        if shouldSchedule { scheduleFlush() }
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
        let shouldSchedule = !flushScheduled
        entityDirty = true
        flushScheduled = true
        lock.unlock()
        if shouldSchedule { scheduleFlush() }
    }

    func mid(entity: String, numericID: Int) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return entityMid["\(entity):\(numericID)"]
    }

    // MARK: - 持久化

    /// 批量登记改为「脏标记 + 0.5 秒合并落盘」。
    ///
    /// 原实现每登记一条就 `defaults.set` 一次全量字典。一首歌要登记
    /// songid→songmid、media、album、singer 四条，2592 首的「我喜欢」
    /// 就是上万次全量序列化，主线程直接卡死几十秒；这也是音乐库
    /// 一直转圈读不出来的原因之一。合并之后一次歌单加载最多写 2 次盘，
    /// 内存里的映射仍然是即时的，播放/歌词反查不受影响。
    private func scheduleFlush() {
        Self.flushQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.flushIfNeeded()
        }
    }

    private func flushIfNeeded() {
        lock.lock()
        let needsSongs = songDirty
        let needsEntities = entityDirty
        let songSnapshot = idToMid
        let entitySnapshot = entityMid
        songDirty = false
        entityDirty = false
        flushScheduled = false
        lock.unlock()

        if needsSongs { persist(songSnapshot) }
        if needsEntities { defaults.set(entitySnapshot, forKey: entityStorageKey) }
    }

    /// 立即落盘：切后台或主动退出前调用，避免丢映射。
    func flushNow() {
        flushIfNeeded()
    }

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
