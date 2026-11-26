import Foundation

/// 导入 Venera 的 index.json：先解析索引，再把每个条目指向的 `.js`
/// 下载下来，最后把「脚本 + 元信息」作为一条独立引擎的源写进库。
///
/// 这里刻意不依赖 App 的 UI：索引导入本身就是网络任务，放在后台跑。
public struct VeneraImportService: @unchecked Sendable {
    private let repo: SourceRepository
    private let session: URLSession
    private let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    public init(repo: SourceRepository, session: URLSession? = nil) {
        self.repo = repo
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 25
            config.timeoutIntervalForResource = 40
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            self.session = URLSession(configuration: config)
        }
    }

    @discardableResult
    public func importIndex(_ data: Data,
                            indexURL: URL?,
                            forceEnabled: Bool? = nil,
                            category: SourceImportCategory = .comic) async throws -> SourceImportSummary {
        guard category == .comic else {
            throw SourceImportError.noMatchingSource(category)
        }

        let entries = try VeneraIndexParser.parse(data)
        guard !entries.isEmpty else { throw SourceImportError.veneraIndexInvalid }

        var records: [BookSource] = []
        var failures: [String] = []

        // 31 个脚本，4 路并发。每个脚本只有几 KB，串行会让用户等太久。
        let width = min(4, entries.count)
        await withTaskGroup(of: (BookSource?, String?).self) { group in
            var iterator = entries.makeIterator()

            func addTask(_ entry: VeneraIndexEntry) {
                group.addTask {
                    do {
                        let script = try await self.fetchScript(entry, indexURL: indexURL)
                        guard Self.looksLikeComicSource(script) else {
                            return (nil, "\(entry.name)：脚本里找不到 extends ComicSource")
                        }
                        let source = VeneraSource(
                            id: "venera:\(entry.key)",
                            key: entry.key,
                            name: entry.name,
                            version: entry.version,
                            scriptURL: entry.scriptURL(relativeTo: indexURL)?.absoluteString ?? "",
                            js: script,
                            enabled: forceEnabled ?? true
                        )
                        let record = BookSource(
                            id: source.id,
                            name: source.name,
                            type: 2,
                            enabled: source.enabled,
                            rawJson: source.envelopeJSON(),
                            engine: "venera"
                        )
                        return (record, nil)
                    } catch {
                        return (nil, "\(entry.name)：\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                    }
                }
            }

            for _ in 0..<width {
                guard let entry = iterator.next() else { break }
                addTask(entry)
            }

            while let (record, failure) = await group.next() {
                if let record { records.append(record) }
                if let failure { failures.append(failure) }
                if let entry = iterator.next() { addTask(entry) }
            }
        }

        guard !records.isEmpty else {
            throw SourceImportError.veneraImportFailed(
                failures.first ?? "索引里的脚本全部下载失败"
            )
        }

        let result = try repo.merge(records)
        let note = failures.isEmpty
            ? nil
            : "另有 \(failures.count) 条脚本下载失败：\(failures.prefix(2).joined(separator: "；"))"
        return SourceImportSummary(
            added: result.added,
            updated: result.updated,
            failed: failures.count,
            note: note
        )
    }

    /// 只下载一个脚本，供「导入单个 .js / 源地址」的入口复用。
    public func fetchScript(_ entry: VeneraIndexEntry, indexURL: URL?) async throws -> String {
        guard let url = entry.scriptURL(relativeTo: indexURL) else {
            throw SourceImportError.veneraIndexInvalid
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 25
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SourceImportError.veneraImportFailed("\(entry.name) 返回 HTTP \(http.statusCode)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw SourceImportError.veneraImportFailed("\(entry.name) 的脚本不是 UTF-8 文本")
        }
        return text
    }

    static func looksLikeComicSource(_ script: String) -> Bool {
        script.range(of: #"class\s+[A-Za-z_$][A-Za-z0-9_$]*\s+extends\s+ComicSource"#,
                     options: .regularExpression) != nil
    }
}
