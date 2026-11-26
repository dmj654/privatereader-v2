import Foundation
import GRDB

public struct BookRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func insert(_ book: Book) throws {
        var book = book
        try db.write { try book.insert($0) }
    }

    public func upsert(_ book: Book) throws {
        try db.write { try book.save($0) }
    }

    public func fetch(id: String) throws -> Book? {
        try db.read { try Book.fetchOne($0, key: id) }
    }

    public func all() throws -> [Book] {
        try db.read {
            try Book.order(Column("lastReadAt").desc, Column("addedAt").desc).fetchAll($0)
        }
    }

    public func books(inGroup groupId: String) throws -> [Book] {
        try db.read {
            try Book.filter(Column("groupId") == groupId)
                .order(Column("lastReadAt").desc, Column("addedAt").desc)
                .fetchAll($0)
        }
    }

    public func books(ofType type: BookType) throws -> [Book] {
        try db.read {
            try Book.filter(Column("type") == type.rawValue).fetchAll($0)
        }
    }

    public func count() throws -> Int {
        try db.read { try Book.fetchCount($0) }
    }

    public func updateGroup(bookId: String, groupId: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE book SET groupId = ? WHERE id = ?",
                arguments: [groupId, bookId]
            )
        }
    }

    public func updateChapterCount(bookId: String, chapterCount: Int, newChapterCount: Int) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE book SET chapterCount = ?, newChapterCount = ? WHERE id = ?",
                arguments: [chapterCount, newChapterCount, bookId]
            )
        }
    }

    public func updateStatus(bookId: String, status: BookStatus) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE book SET status = ? WHERE id = ?",
                arguments: [status.rawValue, bookId]
            )
        }
    }

    public func clearNewChapterCount(bookId: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE book SET newChapterCount = 0 WHERE id = ?",
                arguments: [bookId]
            )
        }
    }

    public func touch(bookId: String, at timestamp: Int) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE book SET lastReadAt = ? WHERE id = ?",
                arguments: [timestamp, bookId]
            )
        }
    }

    public func delete(id: String) throws {
        _ = try db.write { db in
            try Book.deleteOne(db, key: id)
        }
    }
}

public struct ProgressRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func save(_ progress: ReadingProgress) throws {
        try db.write { try progress.save($0) }
    }

    public func fetch(bookId: String) throws -> ReadingProgress? {
        try db.read { try ReadingProgress.fetchOne($0, key: bookId) }
    }

    public func delete(bookId: String) throws {
        _ = try db.write { db in try ReadingProgress.deleteOne(db, key: bookId) }
    }
}

public struct BookmarkRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func add(_ bookmark: Bookmark) throws {
        try db.write { try bookmark.insert($0) }
    }

    public func list(bookId: String) throws -> [Bookmark] {
        try db.read {
            try Bookmark.filter(Column("bookId") == bookId)
                .order(Column("chapterIndex"), Column("offset"))
                .fetchAll($0)
        }
    }

    public func count(bookId: String) throws -> Int {
        try db.read {
            try Bookmark.filter(Column("bookId") == bookId).fetchCount($0)
        }
    }

    public func delete(id: String) throws {
        _ = try db.write { db in try Bookmark.deleteOne(db, key: id) }
    }
}

public struct GroupRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func all() throws -> [BookGroup] {
        try db.read { try BookGroup.order(Column("sort")).fetchAll($0) }
    }

    public func create(name: String) throws -> BookGroup {
        let sort = try db.read { try BookGroup.fetchCount($0) }
        let group = BookGroup(name: name, builtin: false, sort: sort)
        try db.write { try group.insert($0) }
        return group
    }

    public func rename(id: String, to name: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE bookGroup SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    public func delete(id: String) throws {
        try db.write { db in
            let builtin = try Bool.fetchOne(db, sql: "SELECT builtin FROM bookGroup WHERE id = ?", arguments: [id]) ?? false
            guard !builtin else { return }
            try db.execute(
                sql: "UPDATE book SET groupId = ? WHERE groupId = ?",
                arguments: [BookGroup.builtinReadingID, id]
            )
            _ = try BookGroup.deleteOne(db, key: id)
        }
    }
}

public struct SourceRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func upsertAll(_ sources: [BookSource]) throws {
        try db.write { db in
            for source in sources {
                try source.save(db)
            }
        }
    }

    /// 返回 true 表示新增，false 表示覆盖已有。
    @discardableResult
    public func upsert(_ source: BookSource) throws -> Bool {
        try db.write { db in
            let exists = try BookSource.fetchOne(db, key: source.id) != nil
            try source.save(db)
            return !exists
        }
    }

    public func fetch(id: String) throws -> BookSource? {
        try db.read { try BookSource.fetchOne($0, key: id) }
    }

    /// 一次事务写完。2500 条源逐条开事务在真机上要几十秒，
    /// 表现出来就是"点了导入没反应"。
    public func merge(_ sources: [BookSource]) throws -> (added: Int, updated: Int) {
        try db.write { db in
            var added = 0
            var updated = 0
            for source in sources {
                if try BookSource.fetchOne(db, key: source.id) == nil {
                    added += 1
                } else {
                    updated += 1
                }
                try source.save(db)
            }
            return (added, updated)
        }
    }

    public func all() throws -> [BookSource] {
        try db.read { try BookSource.order(Column("name")).fetchAll($0) }
    }

    public func enabled() throws -> [BookSource] {
        try db.read {
            try BookSource.filter(Column("enabled") == true).order(Column("name")).fetchAll($0)
        }
    }

    public func count() throws -> Int {
        try db.read { try BookSource.fetchCount($0) }
    }

    public func setEnabled(id: String, enabled: Bool) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE source SET enabled = ? WHERE id = ?", arguments: [enabled, id])
        }
    }

    public func delete(id: String) throws {
        _ = try db.write { db in try BookSource.deleteOne(db, key: id) }
    }

    public func deleteAll() throws {
        try db.write { _ = try BookSource.deleteAll($0) }
    }

    /// 上次体检明确失败或超时的源。没检测过的（lastCheckResult 为空）不算。
    public func invalidSources() throws -> [BookSource] {
        try db.read {
            try BookSource
                .filter(sql: "lastCheckResult LIKE 'failed%' OR lastCheckResult = 'timeout'")
                .order(Column("name"))
                .fetchAll($0)
        }
    }

    public func delete(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try db.write { db in
            for id in ids {
                _ = try BookSource.deleteOne(db, key: id)
            }
        }
    }

    public func markChecked(id: String, at timestamp: Int, result: String?) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE source SET lastCheckAt = ?, lastCheckResult = ? WHERE id = ?",
                arguments: [timestamp, result, id]
            )
        }
    }
}

public struct SessionRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func record(_ session: ReadingSession) throws {
        try db.write { try session.insert($0) }
    }

    public func totalDuration(from: Int, to: Int) throws -> Int {
        try db.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(durationSec), 0) FROM readingSession WHERE startedAt >= ? AND startedAt < ?",
                arguments: [from, to]
            ) ?? 0
        }
    }

    public func dailyDurations(from: Int, to: Int, calendar: Calendar = .current) throws -> [(day: Int, seconds: Int)] {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT startedAt, durationSec FROM readingSession WHERE startedAt >= ? AND startedAt < ?",
                arguments: [from, to]
            )
            var buckets: [Int: Int] = [:]
            for row in rows {
                let startedAt: Int = row["startedAt"]
                let duration: Int = row["durationSec"]
                let date = Date(timeIntervalSince1970: TimeInterval(startedAt))
                let startOfDay = Int(calendar.startOfDay(for: date).timeIntervalSince1970)
                buckets[startOfDay, default: 0] += duration
            }
            return buckets.map { (day: $0.key, seconds: $0.value) }.sorted { $0.day < $1.day }
        }
    }
}

public struct CacheRepository {
    private let db: any DatabaseWriter

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func upsert(_ entry: ChapterCache) throws {
        try db.write { try entry.save($0) }
    }

    public func list(bookId: String) throws -> [ChapterCache] {
        try db.read {
            try ChapterCache.filter(Column("bookId") == bookId)
                .order(Column("chapterIndex"))
                .fetchAll($0)
        }
    }

    public func totalBytes() throws -> Int {
        try db.read { db in
            try Int.fetchOne(db, sql: "SELECT COALESCE(SUM(sizeBytes), 0) FROM chapterCache") ?? 0
        }
    }

    public func delete(bookId: String) throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM chapterCache WHERE bookId = ?", arguments: [bookId])
        }
    }

    public func deleteAll() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM chapterCache")
        }
    }
}

public struct SearchHistoryRepository {
    private let db: any DatabaseWriter
    public static let limit = 20

    public init(db: any DatabaseWriter) {
        self.db = db
    }

    public func record(keyword: String) throws {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try db.write { db in
            try SearchHistory(keyword: trimmed).save(db)
            try db.execute(
                sql: "DELETE FROM searchHistory WHERE keyword NOT IN (SELECT keyword FROM searchHistory ORDER BY createdAt DESC LIMIT ?)",
                arguments: [Self.limit]
            )
        }
    }

    public func recent() throws -> [SearchHistory] {
        try db.read {
            try SearchHistory.order(Column("createdAt").desc).limit(Self.limit).fetchAll($0)
        }
    }

    public func clear() throws {
        try db.write { db in try db.execute(sql: "DELETE FROM searchHistory") }
    }
}
