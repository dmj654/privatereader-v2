import Foundation

public struct NovelChapter: Equatable, Sendable {
    public let title: String
    public let body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }
}

public struct ParsedNovel: Equatable, Sendable {
    public var title: String
    public var author: String?
    public var chapters: [NovelChapter]
    public var coverData: Data?

    public init(title: String, author: String? = nil, chapters: [NovelChapter], coverData: Data? = nil) {
        self.title = title
        self.author = author
        self.chapters = chapters
        self.coverData = coverData
    }
}

public struct ComicPage: Equatable, Sendable {
    public let entryName: String

    public init(entryName: String) {
        self.entryName = entryName
    }
}

public struct ParsedComic: Equatable, Sendable {
    public var title: String
    public var pages: [ComicPage]
    public var coverData: Data?

    public init(title: String, pages: [ComicPage], coverData: Data? = nil) {
        self.title = title
        self.pages = pages
        self.coverData = coverData
    }
}

public enum ImportedContent: Equatable, Sendable {
    case novel(ParsedNovel)
    case comic(ParsedComic)
}

public enum ImportError: Error, Equatable, LocalizedError {
    case unsupportedFormat(String)
    case unreadableFile(String)
    case emptyContent
    case malformedArchive(String)
    case missingMetadata

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let ext): return "不支持的格式：.\(ext)"
        case .unreadableFile(let name): return "文件无法读取：\(name)"
        case .emptyContent: return "内容为空"
        case .malformedArchive(let detail): return "压缩包结构异常：\(detail)"
        case .missingMetadata: return "缺少必要的元数据"
        }
    }
}
