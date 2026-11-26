import Foundation

/// 把 legado JSON 拆包、转成数据库行、覆盖写入。
///
/// 仓储本身复用 `Data/Repositories.swift` 里的 `SourceRepository`（书源表读写）。
/// 这里只做"导入"这一件事：解析 → 转行 → upsert → 返回统计。
public struct SourceImportService {
    private let repo: SourceRepository

    public init(repo: SourceRepository) {
        self.repo = repo
    }

    /// - Parameter forceEnabled: nil 沿用源自己的开关；true/false 强制覆盖。
    @discardableResult
    public func importJSON(_ data: Data, forceEnabled: Bool? = nil) throws -> SourceImportSummary {
        let parsed = try LegadoParser.parse(data: data)
        let records = parsed.map { source in
            BookSource(
                id: source.id,
                name: source.name,
                type: source.type,
                enabled: forceEnabled ?? source.enabled,
                rawJson: source.rawJson
            )
        }
        let result = try repo.merge(records)
        return SourceImportSummary(added: result.added, updated: result.updated)
    }

    @discardableResult
    public func importJSON(_ text: String, forceEnabled: Bool? = nil) throws -> SourceImportSummary {
        guard let data = text.data(using: .utf8) else { throw LegadoParserError.invalidJSON }
        return try importJSON(data, forceEnabled: forceEnabled)
    }

    /// 从数据库里读一行，重新解析成可执行的源。
    public func executable(from record: BookSource) -> LegadoSource? {
        guard let data = record.rawJson.data(using: .utf8) else { return nil }
        guard let parsed = try? LegadoParser.parse(data: data).first else { return nil }
        var source = parsed
        source.enabled = record.enabled
        return source
    }

    /// 批量取出可执行的启用源：搜索时用这个。
    public func enabledSources() throws -> [LegadoSource] {
        try repo.enabled().compactMap { executable(from: $0) }
    }
}

public struct SourceImportSummary: Equatable, Sendable {
    public let added: Int
    public let updated: Int

    public var total: Int { added + updated }

    public init(added: Int, updated: Int) {
        self.added = added
        self.updated = updated
    }
}
