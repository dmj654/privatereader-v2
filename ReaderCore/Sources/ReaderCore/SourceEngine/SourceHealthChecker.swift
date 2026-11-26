import Foundation

/// 一次「测一下」的结论。
public enum SourceHealthStatus: Equatable, Sendable {
    /// 搜索成功。`sampleCount` 是返回的书籍条数。
    case ok(milliseconds: Int, sampleCount: Int)
    /// 首轮和加长重试都没有在时限内返回。超时只代表“这次没测出来”，
    /// 不代表源已经失效，所以不能自动删除。
    case timeout
    case failed(String)
    /// 源自己不可用（关闭 / 没有搜索规则），不算失败。
    case skipped(String)

    public var isHealthy: Bool {
        if case .ok = self { return true }
        return false
    }

    /// 明确失败：HTTP 4xx/5xx、解析错误、源脚本报错。
    /// 这种源删掉是安全的。
    public var isDefiniteFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    /// 列表里显示的短标签。
    public var label: String {
        switch self {
        case .ok(let ms, let count): return "\(ms)ms · \(count) 条"
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
                      retryTimeout: TimeInterval? = nil) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }
        guard !source.searchUrl.isEmpty, !source.ruleSearch.bookList.isEmpty else {
            return .skipped("无搜索规则")
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
                      retryTimeout: TimeInterval? = nil) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }

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

    // MARK: - 单轮探测

    private func runLegado(_ source: LegadoSource,
                           keyword: String,
                           timeout: TimeInterval) async -> SourceHealthStatus {
        let started = Date()
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    return .success(try await client.search(source: source, key: keyword))
                } catch {
                    return Self.isTimeout(error) ? .timeout : .failure(error.localizedDescription)
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
                    let message = (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription
                    return Self.isTimeout(error) ? .timeout : .failure(message)
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
}
