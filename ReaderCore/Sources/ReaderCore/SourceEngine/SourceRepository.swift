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

    /// - Parameters:
    ///   - forceEnabled: nil 沿用源自己的开关；true/false 强制覆盖。
    ///   - category: 从哪个入口导入。漫画入口只收 `bookSourceType == 2`，
    ///     小说入口只收非漫画源；为 nil 时保持旧行为（不过滤）。
    @discardableResult
    public func importJSON(_ data: Data,
                           forceEnabled: Bool? = nil,
                           category: SourceImportCategory? = nil) throws -> SourceImportSummary {
        if Self.isVeneraIndex(data) {
            throw SourceImportError.veneraJavaScriptIndex
        }

        let parsed = try LegadoParser.parse(data: data)
        let matched = category.map { value in
            parsed.filter { value.matches($0.type) }
        } ?? parsed

        guard !matched.isEmpty else {
            throw SourceImportError.noMatchingSource(category ?? .novel)
        }

        let records = matched.map { source in
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
    public func importJSON(_ text: String, forceEnabled: Bool? = nil,
                           category: SourceImportCategory? = nil) throws -> SourceImportSummary {
        guard let data = text.data(using: .utf8) else { throw LegadoParserError.invalidJSON }
        return try importJSON(data, forceEnabled: forceEnabled, category: category)
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

/// 书源导入的两个入口。小说/漫画从入口到落库都严格分开。
public enum SourceImportCategory: String, Equatable, Sendable {
    case novel
    case comic

    public var title: String {
        self == .comic ? "漫画源" : "小说源"
    }

    /// 漫画：`bookSourceType == 2`；小说：其余类型（文本/音频/文件）。
    public func matches(_ type: Int) -> Bool {
        self == .comic ? type == 2 : type != 2
    }
}

public enum SourceImportError: LocalizedError, Equatable {
    /// 文件里没有一条属于当前入口的源。
    case noMatchingSource(SourceImportCategory)
    /// Venera 的 index.json 是 JavaScript 源清单，不是 legado 规则源。
    case veneraJavaScriptIndex

    public var errorDescription: String? {
        switch self {
        case .noMatchingSource(let category):
            if category == .comic {
                return "这份文件里没有漫画源。当前是「导入漫画源」，只接收 legado 的 bookSourceType = 2；小说源请到「小说源」入口导入。"
            }
            return "这份文件里没有小说源。当前是「导入小说源」，漫画源请到「漫画源」入口导入。"
        case .veneraJavaScriptIndex:
            return "这是 Venera 的 JavaScript 源索引（index.json），不是 legado 书源。PrivateReader 目前只支持 legado 规则的 JSON；Venera 源需要 JavaScript 运行时，不能直接导入。"
        }
    }
}

private extension SourceImportService {
    /// 只认结构特征，不靠域名或文件名：Venera 索引的每一项都有
    /// `fileName`（指向 .js）和 `key`，但没有 `bookSourceName`。
    static func isVeneraIndex(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return false
        }
        let items: [[String: Any]]
        if let array = root as? [[String: Any]] {
            items = array
        } else if let object = root as? [String: Any],
                  let array = object["sources"] as? [[String: Any]] {
            items = array
        } else {
            return false
        }
        guard !items.isEmpty else { return false }
        let looksLikeVenera = items.allSatisfy {
            ($0["fileName"] as? String)?.hasSuffix(".js") == true
                && $0["bookSourceName"] == nil
                && $0["bookSourceUrl"] == nil
        }
        return looksLikeVenera
    }
}
