import Foundation
import GRDB

/// 数据库入口：负责连接、迁移与建表。
/// 迁移只增不改，user_version 由 GRDB 自己维护。
public final class AppDatabase {
    public let writer: any DatabaseWriter

    public init(_ writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// 正式环境：WAL 模式的文件库。
    public static func open(at url: URL) throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let pool = try DatabasePool(path: url.path, configuration: configuration)
        return try AppDatabase(pool)
    }

    /// 测试环境：内存库。
    public static func inMemory() throws -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try DatabaseQueue(configuration: configuration)
        return try AppDatabase(queue)
    }

    /// 兜底：连文件库都打不开时用内存库，保证 App 仍可运行。
    public static func fallback() -> AppDatabase {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        let queue = try! DatabaseQueue(configuration: configuration)
        return try! AppDatabase(queue)
    }

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "source") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("type", .integer).notNull().defaults(to: 0)
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("rawJson", .text).notNull()
                t.column("lastCheckAt", .integer)
                t.column("lastCheckResult", .text)
            }

            try db.create(table: "bookGroup") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("builtin", .boolean).notNull().defaults(to: false)
                t.column("sort", .integer).notNull().defaults(to: 0)
            }

            try db.create(table: "book") { t in
                t.column("id", .text).primaryKey()
                t.column("type", .text).notNull()
                t.column("origin", .text).notNull()
                t.column("title", .text).notNull()
                t.column("author", .text)
                t.column("coverPath", .text)
                t.column("filePath", .text)
                t.column("sourceId", .text).references("source", onDelete: .setNull)
                t.column("sourceBookId", .text)
                t.column("sourceUrl", .text)
                t.column("groupId", .text).references("bookGroup", onDelete: .setNull)
                t.column("status", .text).notNull().defaults(to: BookStatus.reading.rawValue)
                t.column("chapterCount", .integer).notNull().defaults(to: 0)
                t.column("newChapterCount", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .integer).notNull()
                t.column("lastReadAt", .integer)
            }
            try db.create(index: "idxBookGroup", on: "book", columns: ["groupId"])
            try db.create(index: "idxBookLastRead", on: "book", columns: ["lastReadAt"])

            try db.create(table: "progress") { t in
                t.primaryKey("bookId", .text).references("book", onDelete: .cascade)
                t.column("chapterIndex", .integer).notNull()
                t.column("offset", .integer).notNull()
                t.column("percent", .double).notNull()
                t.column("updatedAt", .integer).notNull()
            }

            try db.create(table: "bookmark") { t in
                t.column("id", .text).primaryKey()
                t.column("bookId", .text).notNull().references("book", onDelete: .cascade)
                t.column("chapterIndex", .integer).notNull()
                t.column("offset", .integer).notNull()
                t.column("excerpt", .text)
                t.column("note", .text)
                t.column("createdAt", .integer).notNull()
            }
            try db.create(index: "idxBookmarkBook", on: "bookmark", columns: ["bookId", "chapterIndex"])

            try db.create(table: "readingSession") { t in
                t.column("id", .text).primaryKey()
                t.column("bookId", .text).notNull().references("book", onDelete: .cascade)
                t.column("startedAt", .integer).notNull()
                t.column("durationSec", .integer).notNull()
            }
            try db.create(index: "idxSessionTime", on: "readingSession", columns: ["startedAt"])

            try db.create(table: "chapterCache") { t in
                t.column("bookId", .text).notNull().references("book", onDelete: .cascade)
                t.column("chapterIndex", .integer).notNull()
                t.column("kind", .text).notNull()
                t.column("localPath", .text).notNull()
                t.column("sizeBytes", .integer).notNull()
                t.primaryKey(["bookId", "chapterIndex"])
            }

            try db.create(table: "searchHistory") { t in
                t.column("keyword", .text).primaryKey()
                t.column("createdAt", .integer).notNull()
            }

            let builtins: [(String, String, Int)] = [
                (BookGroup.builtinReadingID, "在追", 0),
                (BookGroup.builtinFinishedID, "看完", 1),
                (BookGroup.builtinDroppedID, "弃了", 2)
            ]
            for (id, name, sort) in builtins {
                try db.execute(
                    sql: "INSERT OR IGNORE INTO bookGroup (id, name, builtin, sort) VALUES (?, ?, 1, ?)",
                    arguments: [id, name, sort]
                )
            }
        }

        return migrator
    }
}
