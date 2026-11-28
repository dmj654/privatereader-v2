import Foundation

/// 一个源的搜索结果。成功与失败都放在这里，方便界面逐个填充。
public struct SourceSearchResult: Sendable, Identifiable {
    public var id: String { source.id }
    public let source: SearchTarget
    public let books: [OnlineBook]
    public let errorText: String?
    public let elapsed: TimeInterval

    public var isSuccess: Bool { errorText == nil }

    public init(source: SearchTarget,
                books: [OnlineBook],
                errorText: String? = nil,
                elapsed: TimeInterval = 0) {
        self.source = source
        self.books = books
        self.errorText = errorText
        self.elapsed = elapsed
    }

    /// 兼容旧测试/调用点：只传 legado 源。
    public init(source: LegadoSource,
                books: [OnlineBook],
                errorText: String? = nil,
                elapsed: TimeInterval = 0) {
        self.init(source: .legado(source), books: books, errorText: errorText, elapsed: elapsed)
    }
}

/// 多源并发搜索：谁先回来谁先出，单源失败不影响其他源。
///
/// 用 `AsyncStream` 而不是 `async let` 数组，是因为搜索页要"逐组填充"——
/// 等全部源都回来再刷新，慢源会把整页拖住。
public actor SearchCoordinator {

    private let client: SourceClient
    private let venera: VeneraRuntime
    private let perSourceTimeout: TimeInterval

    public init(client: SourceClient = SourceClient(),
                venera: VeneraRuntime = VeneraRuntime(),
                perSourceTimeout: TimeInterval = 15) {
        self.client = client
        self.venera = venera
        self.perSourceTimeout = perSourceTimeout
    }

    /// - Parameter maxConcurrent: 同时打几个源。
    ///   两千多个源一次性全发出去，iOS 网络栈会大量返回“似乎已断开互联网”。
    /// - Parameter directID: 所有源都只允许编号直达（用户只选了一个源时用）。
    /// - Parameter directIDSources: 只让这些源走编号直达，其余源照普通搜索。
    ///   “所有源都试一下”用它：声明了 idMatch 的源必须明确直达，不能偷偷回退。
    public func search(sources: [SearchTarget],
                       key: String,
                       maxConcurrent: Int = 6,
                       directID: Bool = false,
                       directIDSources: Set<String> = []) -> AsyncStream<SourceSearchResult> {
        let client = self.client
        let venera = self.venera
        let timeout = perSourceTimeout
        // 不再静默丢掉“配置不完整”的源；它会在结果里明确报错，方便用户看到。
        let enabled = sources.filter { $0.enabled }
        let width = max(1, min(maxConcurrent, enabled.count))

        return AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: SourceSearchResult.self) { group in
                    var iterator = enabled.makeIterator()

                    for _ in 0..<width {
                        guard let source = iterator.next() else { break }
                        group.addTask {
                            await Self.run(source: source, key: key,
                                           client: client, venera: venera,
                                           timeout: timeout, directID: directID,
                                           directIDSources: directIDSources)
                        }
                    }

                    while let result = await group.next() {
                        continuation.yield(result)
                        if let source = iterator.next() {
                            group.addTask {
                                await Self.run(source: source, key: key,
                                               client: client, venera: venera,
                                               timeout: timeout, directID: directID,
                                               directIDSources: directIDSources)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 兼容旧调用点。
    public func search(sources: [LegadoSource],
                       key: String,
                       maxConcurrent: Int = 6) -> AsyncStream<SourceSearchResult> {
        search(sources: sources.map { .legado($0) }, key: key, maxConcurrent: maxConcurrent)
    }

    private static func run(source: SearchTarget,
                            key: String,
                            client: SourceClient,
                            venera: VeneraRuntime,
                            timeout: TimeInterval,
                            directID: Bool = false,
                            directIDSources: Set<String> = []) async -> SourceSearchResult {
        let started = Date()
        guard source.hasSearchEndpoint else {
            return SourceSearchResult(
                source: source,
                books: [],
                errorText: "书源缺少搜索规则：搜索地址或书籍列表为空。请重新导入这个源，或在源管理里删掉后重新添加。",
                elapsed: 0
            )
        }
        let forceDirectID = directID || directIDSources.contains(source.id)
        if forceDirectID, source.veneraSource == nil {
            return SourceSearchResult(
                source: source,
                books: [],
                errorText: "这个源不支持编号直达，请重新选择一个漫画源。",
                elapsed: 0
            )
        }
        do {
            let books: [OnlineBook]
            switch source {
            case .legado(let legado):
                books = try await withTimeout(seconds: timeout) {
                    try await client.search(source: legado, key: key)
                }
            case .venera(let script):
                // Venera 源要下载脚本、建 JSContext、跑异步链，15 秒对慢站不够。
                books = try await withTimeout(seconds: max(timeout, 30)) {
                    if forceDirectID {
                        return try await venera.searchByID(source: script,
                                                           keyword: key,
                                                           timeout: max(timeout, 30))
                    }
                    return try await venera.search(source: script,
                                                   keyword: key,
                                                   timeout: max(timeout, 30))
                }
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
