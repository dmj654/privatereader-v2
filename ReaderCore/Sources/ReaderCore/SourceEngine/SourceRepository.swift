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
        if VeneraIndexParser.isIndex(data) {
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
    /// Venera 索引里下载失败的条目数；legado 导入恒为 0。
    public let failed: Int
    public let note: String?

    public var total: Int { added + updated }

    public init(added: Int, updated: Int, failed: Int = 0, note: String? = nil) {
        self.added = added
        self.updated = updated
        self.failed = failed
        self.note = note
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
    /// 旧同步接口遇到 Venera 索引时的提示；新 UI 会走异步导入。
    case veneraJavaScriptIndex
    case veneraIndexInvalid
    case veneraImportFailed(String)
    case veneraScriptInvalid(String)

    public var errorDescription: String? {
        switch self {
        case .noMatchingSource(let category):
            if category == .comic {
                return "这份文件里没有漫画源。当前是「导入漫画源」，只接收 legado 的 bookSourceType = 2，或 Venera 的 index.json；小说源请到「小说源」入口导入。"
            }
            return "这份文件里没有小说源。当前是「导入小说源」，漫画源请到「漫画源」入口导入。"
        case .veneraJavaScriptIndex:
            return "这是 Venera 的 JavaScript 源索引。请确认当前是「导入漫画源」入口，App 会下载索引里的 JS 源并运行。"
        case .veneraIndexInvalid:
            return "这不是有效的 Venera 源索引：每一项需要 name，以及指向 .js 的 fileName 或 url。"
        case .veneraImportFailed(let message):
            return "Venera 源导入失败：\(message)"
        case .veneraScriptInvalid(let name):
            return "「\(name)」不是有效的 Venera 漫画源：脚本里找不到 extends ComicSource 的类。"
        }
    }
}

public extension SourceImportService {
    /// 同时取出 legado 与 Venera 的可执行源。搜索页、换源页、体检都用它。
    func enabledTargets() throws -> [SearchTarget] {
        try repo.enabled().compactMap { record in
            if let venera = VeneraSource.decode(record) {
                return .venera(venera)
            }
            if let legado = executable(from: record) {
                return .legado(legado)
            }
            return nil
        }
    }

    func target(from record: BookSource) -> SearchTarget? {
        if let venera = VeneraSource.decode(record) {
            return .venera(venera)
        }
        if let legado = executable(from: record) {
            return .legado(legado)
        }
        return nil
    }
}
