import Observation

@MainActor
@Observable
final class LibraryIndexCache<Request: Equatable, Index> {
    private var browsing: (request: Request, index: Index)?
    private var filtered: (request: Request, index: Index)?

    func value(for request: Request) -> Index? {
        if let browsing, browsing.request == request { return browsing.index }
        if let filtered, filtered.request == request { return filtered.index }
        return nil
    }

    func load(_ request: Request, isBrowsing: Bool, build: () async throws -> Index) async {
        guard value(for: request) == nil,
              let index = try? await build(), !Task.isCancelled else { return }
        if isBrowsing {
            browsing = (request, index)
        } else {
            filtered = (request, index)
        }
    }
}
