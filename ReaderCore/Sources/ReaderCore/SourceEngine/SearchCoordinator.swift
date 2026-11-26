import Foundation

/// 一个源的搜索结果。成功与失败都放在这里，方便界面逐个填充。
public struct SourceSearchResult: Sendable, Identifiable {
    public var id: String { source.id }
    public let source: LegadoSource
    public let books: [OnlineBook]
    public let errorText: String?
    public let elapsed: TimeInterval

    public var isSuccess: Bool { errorText == nil }

    public init(source: LegadoSource,
                books: [OnlineBook],
                errorText: String? = nil,
                elapsed: TimeInterval = 0) {
        self.source = source
        self.books = books
        self.errorText = errorText
        self.elapsed = elapsed
    }
}

/// 多源并发搜索：谁先回来谁先出，单源失败不影响其他源。
///
/// 用 `AsyncStream` 而不是 `async let` 数组，是因为搜索页要"逐组填充"——
/// 等全部源都回来再刷新，慢源会把整页拖住。
public actor SearchCoordinator {

    private let client: SourceClient
    private let perSourceTimeout: TimeInterval

    public init(client: SourceClient = SourceClient(), perSourceTimeout: TimeInterval = 15) {
        self.client = client
        self.perSourceTimeout = perSourceTimeout
    }

    /// - Parameter maxConcurrent: 同时打几个源。
    ///   两千多个源一次性全发出去，iOS 网络栈会大量返回“似乎已断开互联网”。
    public func search(sources: [LegadoSource],
                       key: String,
                       maxConcurrent: Int = 6) -> AsyncStream<SourceSearchResult> {
        let client = self.client
        let timeout = perSourceTimeout
        let enabled = sources.filter { $0.enabled && !$0.searchUrl.isEmpty }
        let width = max(1, min(maxConcurrent, enabled.count))

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceSearchResult.self) { group in
                    var iterator = enabled.makeIterator()

                    for _ in 0..<width {
                        guard let source = iterator.next() else { break }
                        group.addTask {
                            await Self.run(source: source, key: key,
                                           client: client, timeout: timeout)
                        }
                    }

                    while let result = await group.next() {
                        continuation.yield(result)
                        if let source = iterator.next() {
                            group.addTask {
                                await Self.run(source: source, key: key,
                                               client: client, timeout: timeout)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(source: LegadoSource,
                            key: String,
                            client: SourceClient,
                            timeout: TimeInterval) async -> SourceSearchResult {
        let started = Date()
        do {
            let books = try await withTimeout(seconds: timeout) {
                try await client.search(source: source, key: key)
            }
            return SourceSearchResult(
                source: source,
                books: books,
                elapsed: Date().timeIntervalSince(started)
            )
        } catch {
            return SourceSearchResult(
                source: source,
                books: [],
                errorText: (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription,
                elapsed: Date().timeIntervalSince(started)
            )
        }
    }
}

/// 给单个源套一层总超时。URLSession 的超时只管单次请求，
/// 一个源如果要连续请求多次（搜索 → 详情），总时长可能远超预期。
func withTimeout<T: Sendable>(seconds: TimeInterval,
                              operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw SourceError.cancelled
        }
        guard let result = try await group.next() else {
            throw SourceError.cancelled
        }
        group.cancelAll()
        return result
    }
}
