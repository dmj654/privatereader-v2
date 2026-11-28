import Foundation

/// 一次「测一下」的结论。
public enum SourceHealthStatus: Equatable, Sendable {
    /// 只检查了搜索。`sampleCount` 是返回的书籍条数。
    case ok(milliseconds: Int, sampleCount: Int)
    /// 搜索、详情、目录都走通了。`checkedSamples` 是真正抽查了几本书，
    /// `chapterCount` 是这几本样本的目录章节总数。
    case okDeep(milliseconds: Int, sampleCount: Int, checkedSamples: Int, chapterCount: Int)
    /// 搜索能通，但详情或目录打不开。它不算“明确失败”，不能因此删除源。
    case partial(String)
    /// 首轮和加长重试都没有在时限内返回。超时只代表“这次没测出来”，
    /// 不代表源已经失效，所以不能自动删除。
    case timeout
    case failed(String)
    /// 源自己不可用（关闭 / 没有搜索规则），不算失败。
    case skipped(String)

    public var isHealthy: Bool {
        switch self {
        case .ok, .okDeep: return true
        default: return false
        }
    }

    /// 明确失败：HTTP 4xx/5xx、解析错误、源脚本报错。
    /// 这种源删掉是安全的。
    public var isDefiniteFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 搜索能通，但详情或目录没走通。不能算“明确失败”，也不能算完全正常。
    public var isPartial: Bool {
        if case .partial = self { return true }
        return false
    }

    /// 这次没测出来，但源不一定是坏的。
    public var isTimeout: Bool {
        if case .timeout = self { return true }
        return false
    }

    /// 列表里显示的短标签。
    public var label: String {
        switch self {
        case .ok(let ms, let count):
            return "\(ms)ms · \(count) 条"
        case .okDeep(let ms, let count, let checked, let chapters):
            return "\(ms)ms · \(count) 条 · 抽查 \(checked) 本 · \(chapters) 章"
        case .partial:
            return "部分可用"
        case .timeout:
            return "超时（可重试）"
        case .failed:
            return "失败"
        case .skipped(let reason):
            return reason
        }
    }
}

/// 书源体检：拿一个探针词搜一次，看这个源还能不能用。
///
/// 管理页要能一口气测几十个源，所以先做一轮快速探测；超时不是判死刑，
/// 会再用更长的超时重试一次。只有明确失败（4xx/5xx、解析错误、脚本报错）
/// 才算失效，可以删除。这样不会把「站点慢」误判成「源坏了」。
///
/// `deep: true` 会在搜索成功后继续打开前几本书的详情、拉目录：
/// 搜索能通但详情/目录坏掉的源会得到 `.partial`，不会被当成“正常”。
/// 每个阶段单独计时，慢站不会因为「搜索 + 详情 + 目录」共享一个总预算
/// 被误判成超时。
public struct SourceHealthChecker: Sendable {
    private let client: SourceClient
    private let venera: VeneraRuntime

    public init(client: SourceClient, venera: VeneraRuntime = VeneraRuntime()) {
        self.client = client
        self.venera = venera
    }

    public func check(_ source: LegadoSource,
                      keyword: String = "剑",
                      timeout: TimeInterval = 5,
                      retryTimeout: TimeInterval? = nil,
                      deep: Bool = false,
                      deepSampleLimit: Int = 3) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }
        guard !source.searchUrl.isEmpty, !source.ruleSearch.bookList.isEmpty else {
            return .skipped("无搜索规则")
        }

        if deep {
            let first = await runDeepLegado(source,
                                            keyword: keyword,
                                            timeout: timeout,
                                            sampleLimit: deepSampleLimit)
            if case .timeout = first, let retryTimeout {
                return await runDeepLegado(source,
                                           keyword: keyword,
                                           timeout: max(retryTimeout, timeout),
                                           sampleLimit: deepSampleLimit)
            }
            return first
        }

        let started = Date()
        let first = await runLegado(source, keyword: keyword, timeout: timeout)
        if case .timeout = first, let retryTimeout {
            let second = await runLegado(source, keyword: keyword, timeout: retryTimeout)
            if case .ok(_, let count) = second {
                return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                           sampleCount: count)
            }
            return second
        }
        return first
    }

    public func check(_ source: VeneraSource,
                      keyword: String = "海贼",
                      timeout: TimeInterval = 12,
                      retryTimeout: TimeInterval? = nil,
                      deep: Bool = false,
                      deepSampleLimit: Int = 3) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }

        if deep {
            let first = await runDeepVenera(source,
                                            keyword: keyword,
                                            timeout: timeout,
                                            sampleLimit: deepSampleLimit)
            if case .timeout = first, let retryTimeout {
                return await runDeepVenera(source,
                                           keyword: keyword,
                                           timeout: max(retryTimeout, timeout),
                                           sampleLimit: deepSampleLimit)
            }
            return first
        }

        let started = Date()
        let first = await runVenera(source, keyword: keyword, timeout: timeout)
        if case .timeout = first, let retryTimeout {
            let second = await runVenera(source, keyword: keyword, timeout: retryTimeout)
            if case .ok(_, let count) = second {
                return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                           sampleCount: count)
            }
            return second
        }
        return first
    }

    // MARK: - 单轮探测：只搜

    private func runLegado(_ source: LegadoSource,
                           keyword: String,
                           timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        do {
            let books = try await withTimeout(seconds: timeout) {
                try await client.search(source: source, key: keyword)
            }
            return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count)
        } catch {
            return Self.isTimeout(error) ? .timeout : .failed(Self.message(error))
        }
    }

    private func runVenera(_ source: VeneraSource,
                           keyword: String,
                           timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        do {
            // 这里必须和真实搜索用同一个超时，不能内层 30 秒、外层 12 秒互相打架。
            let books = try await withTimeout(seconds: timeout) {
                try await venera.search(source: source, keyword: keyword, timeout: timeout)
            }
            return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count)
        } catch {
            return Self.isTimeout(error) ? .timeout : .failed(Self.message(error))
        }
    }

    // MARK: - 深度探测：搜索 + 详情 + 目录

    private func runDeepLegado(_ source: LegadoSource,
                               keyword: String,
                               timeout: TimeInterval,
                               sampleLimit: Int) async -> SourceHealthStatus {
        let started = Date()
        let stageTimeout = Self.stageTimeout(timeout)

        let books: [OnlineBook]
        do {
            books = try await withTimeout(seconds: stageTimeout) {
                try await client.search(source: source, key: keyword)
            }
        } catch {
            return Self.isTimeout(error) ? .timeout : .failed(Self.message(error))
        }

        guard !books.isEmpty else {
            return .skipped("搜索 0 条，未验证详情")
        }

        let sample = Array(books.prefix(max(1, sampleLimit)))
        var totalChapters = 0

        for (index, book) in sample.enumerated() {
            let info: OnlineBook
            do {
                info = try await withTimeout(seconds: stageTimeout) {
                    try await client.bookInfo(source: source, book: book)
                }
            } catch {
                return .partial("搜索正常（\(books.count) 条），第 \(index + 1) 条样本详情打不开：\(Self.message(error))")
            }

            let chapters: [OnlineChapter]
            do {
                chapters = try await withTimeout(seconds: stageTimeout) {
                    try await client.chapters(source: source, book: info)
                }
            } catch {
                return .partial("搜索正常（\(books.count) 条），第 \(index + 1) 条样本目录打不开：\(Self.message(error))")
            }
            guard !chapters.isEmpty else {
                return .partial("搜索正常（\(books.count) 条），第 \(index + 1) 条样本目录为空")
            }
            totalChapters += chapters.count
        }

        return .okDeep(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count,
                       checkedSamples: sample.count,
                       chapterCount: totalChapters)
    }

    private func runDeepVenera(_ source: VeneraSource,
                               keyword: String,
                               timeout: TimeInterval,
                               sampleLimit: Int) async -> SourceHealthStatus {
        let started = Date()
        let stageTimeout = Self.stageTimeout(timeout)

        let books: [OnlineBook]
        do {
            books = try await withTimeout(seconds: stageTimeout) {
                try await venera.search(source: source, keyword: keyword, timeout: stageTimeout)
            }
        } catch {
            return Self.isTimeout(error) ? .timeout : .failed(Self.message(error))
        }

        guard !books.isEmpty else {
            return .skipped("搜索 0 条，未验证详情")
        }

        let sample = Array(books.prefix(max(1, sampleLimit)))
        var totalChapters = 0

        for (index, book) in sample.enumerated() {
            do {
                let detail = try await withTimeout(seconds: stageTimeout) {
                    try await venera.detail(source: source,
                                            comicId: book.bookUrl,
                                            timeout: stageTimeout,
                                            forceRefresh: true)
                }
                guard !detail.chapters.isEmpty else {
                    return .partial("搜索正常（\(books.count) 条），第 \(index + 1) 条样本目录为空")
                }
                totalChapters += detail.chapters.count
            } catch {
                return .partial("搜索正常（\(books.count) 条），第 \(index + 1) 条样本详情打不开：\(Self.message(error))")
            }
        }

        return .okDeep(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count,
                       checkedSamples: sample.count,
                       chapterCount: totalChapters)
    }

    // MARK: - 辅助

    /// 深度模式的每个阶段至少给 10 秒；单源体检传进来的 5 秒只够一次搜索，
    /// 不该让详情和目录共用同一份预算。
    private static func stageTimeout(_ timeout: TimeInterval) -> TimeInterval {
        max(timeout, 10)
    }

    private static func message(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private static func isTimeout(_ error: Error) -> Bool {
        if let error = error as? URLError, error.code == .timedOut { return true }
        if let error = error as? SourceError, error == .cancelled { return true }
        let text = error.localizedDescription.lowercased()
        return text.contains("timed out")
            || text.contains("timeout")
            || text.contains("超时")
            || text.contains("已取消")
    }
}
