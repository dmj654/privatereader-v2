import Foundation

// MARK: - 索引

/// Venera 源索引里的一条。官方格式只要求 `url` 或 `filename` 二者之一，
/// 但社区仓库（含用户给的这个）普遍写成 `fileName`，所以两种都认。
public struct VeneraIndexEntry: Equatable, Sendable, Identifiable {
    public var name: String
    public var key: String
    public var version: String
    public var fileName: String?
    public var url: String?
    public var description: String?

    public var id: String { key }

    public init(name: String,
                key: String,
                version: String = "",
                fileName: String? = nil,
                url: String? = nil,
                description: String? = nil) {
        self.name = name
        self.key = key
        self.version = version
        self.fileName = fileName
        self.url = url
        self.description = description
    }

    /// 真正去下载脚本的地址。相对 fileName 以索引 URL 所在目录为基准。
    public func scriptURL(relativeTo indexURL: URL?) -> URL? {
        if let url, !url.isEmpty {
            if let absolute = URL(string: url), absolute.scheme != nil {
                return absolute
            }
            if let indexURL {
                return URL(string: url, relativeTo: indexURL.deletingLastPathComponent())
            }
        }
        guard let fileName, !fileName.isEmpty else { return nil }
        if let absolute = URL(string: fileName), absolute.scheme != nil {
            return absolute
        }
        let base = indexURL?.deletingLastPathComponent()
            ?? URL(string: "https://git.nyne.dev/nyne/venera-configs/raw/branch/main/")!
        return URL(string: fileName, relativeTo: base)
    }
}

public enum VeneraIndexParser {

    /// 只认结构，不认域名：有 `fileName`/`filename` 指向 `.js`，
    /// 且没有 legado 的 `bookSourceName` / `bookSourceUrl`。
    public static func isIndex(_ data: Data) -> Bool {
        guard let items = rawItems(data), !items.isEmpty else { return false }
        return items.allSatisfy { item in
            let file = (item["fileName"] as? String) ?? (item["filename"] as? String) ?? ""
            let url = (item["url"] as? String) ?? ""
            let looksLikeScript = file.lowercased().hasSuffix(".js")
                || url.lowercased().hasSuffix(".js")
            return looksLikeScript
                && item["bookSourceName"] == nil
                && item["bookSourceUrl"] == nil
        }
    }

    public static func parse(_ data: Data) throws -> [VeneraIndexEntry] {
        guard let items = rawItems(data), !items.isEmpty else {
            throw SourceImportError.veneraIndexInvalid
        }
        return items.compactMap { item in
            let file = (item["fileName"] as? String) ?? (item["filename"] as? String)
            let url = item["url"] as? String
            let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = (item["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let derivedKey = key.isEmpty
                ? ((file ?? url ?? "") as NSString).deletingPathExtension
                : key
            guard !derivedKey.isEmpty, !name.isEmpty else { return nil }
            return VeneraIndexEntry(
                name: name,
                key: derivedKey,
                version: (item["version"] as? String) ?? "",
                fileName: file,
                url: url,
                description: item["description"] as? String
            )
        }
    }

    private static func rawItems(_ data: Data) -> [[String: Any]]? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data = data.dropFirst(3) }
        guard let root = try? JSONSerialization.jsonObject(with: data,
                                                           options: [.fragmentsAllowed]) else {
            return nil
        }
        if let array = root as? [[String: Any]] { return array }
        if let object = root as? [String: Any],
           let array = object["sources"] as? [[String: Any]] {
            return array
        }
        return nil
    }
}

// MARK: - 可执行源

public struct VeneraSource: Equatable, Identifiable, Sendable {
    public var id: String
    public var key: String
    public var name: String
    public var version: String
    public var scriptURL: String
    public var js: String
    public var enabled: Bool

    public init(id: String,
                key: String,
                name: String,
                version: String = "",
                scriptURL: String = "",
                js: String,
                enabled: Bool = true) {
        self.id = id
        self.key = key
        self.name = name
        self.version = version
        self.scriptURL = scriptURL
        self.js = js
        self.enabled = enabled
    }

    public var isComic: Bool { true }

    /// 存进 `BookSource.rawJson` 的信封。JS 源码可能几十 KB，
    /// 但 SQLite 的 TEXT 足够，且这样备份/迁移不会丢脚本。
    public func envelopeJSON() -> String {
        let object: [String: Any] = [
            "engine": "venera",
            "key": key,
            "name": name,
            "version": version,
            "url": scriptURL,
            "js": js
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    public static func decode(_ record: BookSource) -> VeneraSource? {
        guard record.engine == "venera" else { return nil }
        guard let data = record.rawJson.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let js = object["js"] as? String, !js.isEmpty else { return nil }
        let key = (object["key"] as? String) ?? record.id.replacingOccurrences(of: "venera:", with: "")
        return VeneraSource(
            id: record.id,
            key: key,
            name: (object["name"] as? String) ?? record.name,
            version: (object["version"] as? String) ?? "",
            scriptURL: (object["url"] as? String) ?? "",
            js: js,
            enabled: record.enabled
        )
    }
}

/// 搜索/详情链路统一用这个，不再到处判断“是 legado 还是 Venera”。
public enum SearchTarget: Identifiable, Sendable, Equatable {
    case legado(LegadoSource)
    case venera(VeneraSource)

    public var id: String {
        switch self {
        case .legado(let source): return source.id
        case .venera(let source): return source.id
        }
    }

    public var name: String {
        switch self {
        case .legado(let source): return source.name
        case .venera(let source): return source.name
        }
    }

    public var isComic: Bool {
        switch self {
        case .legado(let source): return source.isComic
        case .venera: return true
        }
    }

    public var enabled: Bool {
        switch self {
        case .legado(let source): return source.enabled
        case .venera(let source): return source.enabled
        }
    }

    public var hasSearchEndpoint: Bool {
        switch self {
        case .legado(let source):
            return !source.searchUrl.isEmpty && !source.ruleSearch.bookList.isEmpty
        case .venera:
            return true
        }
    }

    public var legadoSource: LegadoSource? {
        if case .legado(let source) = self { return source }
        return nil
    }

    public var veneraSource: VeneraSource? {
        if case .venera(let source) = self { return source }
        return nil
    }
}

// MARK: - 详情

public struct VeneraDetail: Equatable, Sendable {
    public var comicId: String
    public var title: String
    public var author: String
    public var coverUrl: String
    public var intro: String
    public var kind: String
    public var chapters: [OnlineChapter]
    public var subId: String
    public var lastChapter: String

    public init(comicId: String,
                title: String,
                author: String = "",
                coverUrl: String = "",
                intro: String = "",
                kind: String = "",
                chapters: [OnlineChapter] = [],
                subId: String = "",
                lastChapter: String = "") {
        self.comicId = comicId
        self.title = title
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.chapters = chapters
        self.subId = subId
        self.lastChapter = lastChapter
    }
}
