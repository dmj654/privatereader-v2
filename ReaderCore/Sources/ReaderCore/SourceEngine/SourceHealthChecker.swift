import Foundation

/// 一次「测一下」的结论。
public enum SourceHealthStatus: Equatable, Sendable {
    /// 搜索成功。`sampleCount` 是返回的书籍条数。
    case ok(milliseconds: Int, sampleCount: Int)
    case timeout
    case failed(String)
    /// 源自己不可用（关闭 / 没有搜索规则），不算失败。
    case skipped(String)

    public var isHealthy: Bool {
        if case .ok = self { return true }
        return false
    }

    /// 列表里显示的短标签。
    public var label: String {
        switch self {
        case .ok(let ms, let count): return "\(ms)ms · \(count) 条"
        case .timeout: return "超时"
        case .failed: return "失败"
        case .skipped(let reason): return reason
        }
    }
}

/// 书源体检：拿一个探针词搜一次，看这个源还能不能用。
///
/// 刻意不复用 `SourceClient` 的 20 秒请求超时——管理页要能一口气测几十个源，
/// 每个都等 20 秒就没法用了。这里用任务组赛跑，到点直接取消。
public struct SourceHealthChecker: Sendable {
    private let client: SourceClient
    private let venera: VeneraRuntime

    public init(client: SourceClient, venera: VeneraRuntime = VeneraRuntime()) {
        self.client = client
        self.venera = venera
    }

    public func check(_ source: LegadoSource,
                      keyword: String = "剑",
                      timeout: TimeInterval = 5) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }
        guard !source.searchUrl.isEmpty, !source.ruleSearch.bookList.isEmpty else {
            return .skipped("无搜索规则")
        }

        let started = Date()
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    return .success(try await client.search(source: source, key: keyword))
                } catch {
                    return .failure(error.localizedDescription)
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
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return .ok(milliseconds: ms, sampleCount: books.count)
        case .failure(let message):
            return .failed(message)
        case .timeout:
            return .timeout
        }
    }

    public func check(_ source: VeneraSource,
                      keyword: String = "海贼",
                      timeout: TimeInterval = 12) async -> SourceHealthStatus {
        guard source.enabled else { return .skipped("已关闭") }

        let started = Date()
        let race = await withTaskGroup(of: Race.self) { group in
            group.addTask {
                do {
                    return .success(try await venera.search(source: source,
                                                            keyword: keyword,
                                                            timeout: max(timeout, 30)))
                } catch {
                    return .failure((error as? LocalizedError)?.errorDescription
                                    ?? error.localizedDescription)
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
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return .ok(milliseconds: ms, sampleCount: books.count)
        case .failure(let message):
            return .failed(message)
        case .timeout:
            return .timeout
        }
    }

    private enum Race: Sendable {
        case success([OnlineBook])
        case failure(String)
        case timeout
    }
}
