import Foundation
import GRDB

public enum BookType: String, Codable, CaseIterable, Sendable {
    case novel
    case comic
}

public enum BookOrigin: String, Codable, Sendable {
    case local
    case remote
}

public enum BookStatus: String, Codable, CaseIterable, Sendable {
    case reading
    case finished
    case dropped
}

public enum CacheKind: String, Codable, Sendable {
    case text
    case images
}

public struct Book: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var type: BookType
    public var origin: BookOrigin
    public var title: String
    public var author: String?
    public var coverPath: String?
    public var filePath: String?
    public var sourceId: String?
    public var sourceBookId: String?
    public var sourceUrl: String?
    public var groupId: String?
    public var status: BookStatus
    public var chapterCount: Int
    public var newChapterCount: Int
    public var addedAt: Int
    public var lastReadAt: Int?

    public init(
        id: String,
        type: BookType,
        origin: BookOrigin,
        title: String,
        author: String? = nil,
        coverPath: String? = nil,
        filePath: String? = nil,
        sourceId: String? = nil,
        sourceBookId: String? = nil,
        sourceUrl: String? = nil,
        groupId: String? = BookGroup.builtinReadingID,
        status: BookStatus = .reading,
        chapterCount: Int = 0,
        newChapterCount: Int = 0,
        addedAt: Int = Int(Date().timeIntervalSince1970),
        lastReadAt: Int? = nil
    ) {
        self.id = id
        self.type = type
        self.origin = origin
        self.title = title
        self.author = author
        self.coverPath = coverPath
        self.filePath = filePath
        self.sourceId = sourceId
        self.sourceBookId = sourceBookId
        self.sourceUrl = sourceUrl
        self.groupId = groupId
        self.status = status
        self.chapterCount = chapterCount
        self.newChapterCount = newChapterCount
        self.addedAt = addedAt
        self.lastReadAt = lastReadAt
    }
}

extension Book: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "book"
}

public struct ReadingProgress: Codable, Equatable, Sendable {
    public var bookId: String
    public var chapterIndex: Int
    public var offset: Int
    public var percent: Double
    public var updatedAt: Int

    public init(bookId: String, chapterIndex: Int, offset: Int, percent: Double, updatedAt: Int) {
        self.bookId = bookId
        self.chapterIndex = chapterIndex
        self.offset = offset
        self.percent = percent
        self.updatedAt = updatedAt
    }
}

extension ReadingProgress: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "progress"
}

public struct Bookmark: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var bookId: String
    public var chapterIndex: Int
    public var offset: Int
    public var excerpt: String?
    public var note: String?
    public var createdAt: Int

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        chapterIndex: Int,
        offset: Int,
        excerpt: String? = nil,
        note: String? = nil,
        createdAt: Int = Int(Date().timeIntervalSince1970)
    ) {
        self.id = id
        self.bookId = bookId
        self.chapterIndex = chapterIndex
        self.offset = offset
        self.excerpt = excerpt
        self.note = note
        self.createdAt = createdAt
    }
}

extension Bookmark: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookmark"
}

public struct BookGroup: Codable, Equatable, Identifiable, Sendable {
    public static let builtinReadingID = "builtin-reading"
    public static let builtinFinishedID = "builtin-finished"
    public static let builtinDroppedID = "builtin-dropped"

    public var id: String
    public var name: String
    public var builtin: Bool
    public var sort: Int

    public init(id: String = UUID().uuidString, name: String, builtin: Bool = false, sort: Int = 0) {
        self.id = id
        self.name = name
        self.builtin = builtin
        self.sort = sort
    }
}

extension BookGroup: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "bookGroup"
}

public struct BookSource: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var type: Int
    public var enabled: Bool
    public var rawJson: String
    /// `legado` / `venera`。Venera 的 rawJson 是一份带 JS 源码的信封，
    /// 不能交给 legado 解析器；两套引擎靠这个字段分流。
    public var engine: String
    public var lastCheckAt: Int?
    public var lastCheckResult: String?

    public init(
        id: String,
        name: String,
        type: Int = 0,
        enabled: Bool = true,
        rawJson: String,
        engine: String = "legado",
        lastCheckAt: Int? = nil,
        lastCheckResult: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.enabled = enabled
        self.rawJson = rawJson
        self.engine = engine
        self.lastCheckAt = lastCheckAt
        self.lastCheckResult = lastCheckResult
    }
}

extension BookSource: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "source"
}

public struct ReadingSession: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var bookId: String
    public var startedAt: Int
    public var durationSec: Int

    public init(
        id: String = UUID().uuidString,
        bookId: String,
        startedAt: Int,
        durationSec: Int
    ) {
        self.id = id
        self.bookId = bookId
        self.startedAt = startedAt
        self.durationSec = durationSec
    }
}

extension ReadingSession: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "readingSession"
}

public struct ChapterCache: Codable, Equatable, Sendable {
    public var bookId: String
    public var chapterIndex: Int
    public var kind: CacheKind
    public var localPath: String
    public var sizeBytes: Int

    public init(bookId: String, chapterIndex: Int, kind: CacheKind, localPath: String, sizeBytes: Int) {
        self.bookId = bookId
        self.chapterIndex = chapterIndex
        self.kind = kind
        self.localPath = localPath
        self.sizeBytes = sizeBytes
    }
}

extension ChapterCache: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chapterCache"
}

public struct SearchHistory: Codable, Equatable, Sendable {
    public var keyword: String
    public var createdAt: Int

    public init(keyword: String, createdAt: Int = Int(Date().timeIntervalSince1970)) {
        self.keyword = keyword
        self.createdAt = createdAt
    }
}

extension SearchHistory: FetchableRecord, PersistableRecord {
    public static let databaseTableName = "searchHistory"
}
