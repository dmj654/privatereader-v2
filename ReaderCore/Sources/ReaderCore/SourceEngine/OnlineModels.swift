import Foundation

/// 从书源搜到 / 解析出的一本书。还没进书架，只是搜索结果。
public struct OnlineBook: Codable, Equatable, Identifiable, Sendable {
    public var sourceId: String
    public var name: String
    public var author: String
    public var coverUrl: String
    public var intro: String
    public var kind: String
    public var wordCount: String
    public var lastChapter: String
    public var bookUrl: String

    public var id: String { "\(sourceId)|\(bookUrl)|\(name)" }

    public init(sourceId: String,
                name: String,
                author: String = "",
                coverUrl: String = "",
                intro: String = "",
                kind: String = "",
                wordCount: String = "",
                lastChapter: String = "",
                bookUrl: String = "") {
        self.sourceId = sourceId
        self.name = name
        self.author = author
        self.coverUrl = coverUrl
        self.intro = intro
        self.kind = kind
        self.wordCount = wordCount
        self.lastChapter = lastChapter
        self.bookUrl = bookUrl
    }
}

/// 发现页的一个入口（周榜、分类、全部…）。
public struct ExploreCategory: Equatable, Identifiable, Sendable {
    public var name: String
    public var url: String

    public var id: String { "\(name)|\(url)" }

    public init(name: String, url: String) {
        self.name = name
        self.url = url
    }
}

/// 在线章节。和本地 `NovelChapter` 分开：这个只有名字和地址，正文要按需下载。
public struct OnlineChapter: Codable, Equatable, Identifiable, Sendable {
    public var name: String
    public var url: String
    public var updateTime: String

    public var id: String { url.isEmpty ? name : url }

    public init(name: String, url: String, updateTime: String = "") {
        self.name = name
        self.url = url
        self.updateTime = updateTime
    }
}

public enum SourceError: LocalizedError, Equatable {
    case invalidURL
    case http(Int)
    case emptyContent
    case emptyRule(String)
    case decodingFailed
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "书源地址无效"
        case .http(let code): return "站点返回 HTTP \(code)"
        case .emptyContent: return "这个页面没有取到内容"
        case .emptyRule(let name): return "书源的「\(name)」规则是空的"
        case .decodingFailed: return "网页编码无法识别"
        case .cancelled: return "已取消"
        }
    }
}
