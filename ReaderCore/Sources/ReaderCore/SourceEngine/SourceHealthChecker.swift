import Foundation

/// 一次「测一下」的结论。
public enum SourceHealthStatus: Equatable, Sendable {
    /// 只检查了搜索。`sampleCount` 是返回的书籍条数。
    case ok(milliseconds: Int, sampleCount: Int)
    /// 搜索、详情、目录都走通了。`chapterCount` 是目录里的章节数。
    case okDeep(milliseconds: Int, sampleCount: Int, chapterCount: Int)
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

    /// 列表里显示的短标签。
    public var label: String {
        switch self {
        case .ok(let ms, let count): return "\(ms)ms · \(count) 条"
        case .okDeep(let ms, let count, let chapters): return "\(ms)ms · \(count) 条 · \(chapters) 章"
        case .partial: return "部分可用"
        case .timeout: return "超时（可重试）"
        case .failed: return "失败"
        case .skipped(let reason): return reason
        }
    }
}

/// 书源体检：拿一个探针词搜一次，看这个源还能不能用。
///
/// 管理页要能一口气测几十个源，所以先做一轮快速探测；超时不是判死刑，
/// 会再用更长的超时重试一次。只有明确失败（4xx/5xx、解析错误、脚本报错）
/// 才算失效，可以删除。这样不会把「站点慢」误判成「源坏了」。
///
/// `deep: true` 会在搜索成功后继续打开第一条结果的详情、拉一次目录：
/// 搜索能通但详情/目录坏掉的源会得到 `.partial`，不会被当成“正常”。
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
                      deep: Bool = false) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }
        guard !source.searchUrl.isEmpty, !source.ruleSearch.bookList.isEmpty else {
            return .skipped("无搜索规则")
        }

        if deep {
            let first = await runDeepLegado(source,
                                            keyword: keyword,
                                            timeout: max(timeout, 20))
            if case .timeout = first, let retryTimeout {
                return await runDeepLegado(source,
                                           keyword: keyword,
                                           timeout: max(retryTimeout, 20))
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
                      deep: Bool = false) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }

        if deep {
            let first = await runDeepVenera(source,
                                            keyword: keyword,
                                            timeout: max(timeout, 20))
            if case .timeout = first, let retryTimeout {
                return await runDeepVenera(source,
                                           keyword: keyword,
                                           timeout: max(retryTimeout, 20))
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
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    return .success(try await client.search(source: source, key: keyword))
                } catch {
                    return Self.isTimeout(error) ? .timeout : .failure(Self.message(error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch race {
        case .success(let books):
            return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count)
        case .failure(let message):
            return .failed(message)
        case .timeout:
            return .timeout
        }
    }

    private func runVenera(_ source: VeneraSource,
                           keyword: String,
                           timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    // 这里必须和真实搜索用同一个超时，不能内层 30 秒、外层 12 秒互相打架。
                    return .success(try await venera.search(source: source,
                                                            keyword: keyword,
                                                            timeout: timeout))
                } catch {
                    return Self.isTimeout(error) ? .timeout : .failure(Self.message(error))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch race {
        case .success(let books):
            return .ok(milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                       sampleCount: books.count)
        case .failure(let message):
            return .failed(message)
        case .timeout:
            return .timeout
        }
    }

    // MARK: - 深度探测：搜索 + 详情 + 目录

    private func runDeepLegado(_ source: LegadoSource,
                               keyword: String,
                               timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        let race = await withTaskGroup(of: DeepRace.self) { group in
            group.addTask {
                do {
                    let books = try await client.search(source: source, key: keyword)

                    guard let first = books.first else {
                        return .status(.skipped("搜索 0 条，未验证详情"))
                    }

                    let info: OnlineBook
                    do {
                        info = try await client.bookInfo(source: source, book: first)
                    } catch {
                        return .status(.partial("搜索正常（\(books.count) 条），详情打不开：\(Self.message(error))"))
                    }

                    do {
                        let chapters = try await client.chapters(source: source, book: info)
                        guard !chapters.isEmpty else {
                            return .status(.partial("搜索和详情正常，目录为空"))
                        }
                        return .status(.okDeep(
                            milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                            sampleCount: books.count,
                            chapterCount: chapters.count
                        ))
                    } catch {
                        return .status(.partial("搜索正常（\(books.count) 条），目录打不开：\(Self.message(error))"))
                    }
                } catch {
                    return .status(Self.isTimeout(error) ? .timeout : .failed(Self.message(error)))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch race {
        case .status(let status): return status
        case .timeout: return .timeout
        }
    }

    private func runDeepVenera(_ source: VeneraSource,
                               keyword: String,
                               timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        let race = await withTaskGroup(of: DeepRace.self) { group in
            group.addTask {
                let books: [OnlineBook]
                do {
                    books = try await venera.search(source: source,
                                                    keyword: keyword,
                                                    timeout: timeout)
                } catch {
                    return .status(Self.isTimeout(error) ? .timeout : .failed(Self.message(error)))
                }

                guard let first = books.first else {
                    return .status(.skipped("搜索 0 条，未验证详情"))
                }

                do {
                    let detail = try await venera.detail(source: source,
                                                         comicId: first.bookUrl,
                                                         timeout: timeout,
                                                         forceRefresh: true)
                    guard !detail.chapters.isEmpty else {
                        return .status(.partial("详情能打开，但目录为空"))
                    }
                    return .status(.okDeep(
                        milliseconds: Int(Date().timeIntervalSince(started) * 1000),
                        sampleCount: books.count,
                        chapterCount: detail.chapters.count
                    ))
                } catch {
                    return .status(.partial("搜索正常（\(books.count) 条），详情打不开：\(Self.message(error))"))
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            group.cancelAll()
            return first
        }

        switch race {
        case .status(let status): return status
        case .timeout: return .timeout
        }
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

    private enum Race: Sendable {
        case success([OnlineBook])
        case failure(String)
        case timeout
    }

    private enum DeepRace: Sendable {
        case status(SourceHealthStatus)
        case timeout
    }
}
