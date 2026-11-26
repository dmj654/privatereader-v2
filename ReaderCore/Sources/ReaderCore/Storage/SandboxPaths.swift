import Foundation

/// 沙盒内所有固定路径的唯一来源。
/// 数据库里只存相对路径，取绝对路径一律走这里，避免路径散落各处。
public struct SandboxPaths {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// 真机 / 模拟器上的 Documents 目录。
    public static var live: SandboxPaths {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return SandboxPaths(root: documents)
    }

    public var database: URL { root.appendingPathComponent("library.db", isDirectory: false) }
    public var books: URL { root.appendingPathComponent("Books", isDirectory: true) }
    public var covers: URL { root.appendingPathComponent("Covers", isDirectory: true) }
    public var cache: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    public var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }

    public func bookDirectory(_ bookID: String) -> URL {
        books.appendingPathComponent(bookID, isDirectory: true)
    }

    public func coverFile(_ bookID: String) -> URL {
        covers.appendingPathComponent("\(bookID).jpg", isDirectory: false)
    }

    public func cacheDirectory(bookID: String, chapterIndex: Int) -> URL {
        cache
            .appendingPathComponent(bookID, isDirectory: true)
            .appendingPathComponent(String(chapterIndex), isDirectory: true)
    }

    /// 建齐四个目录，可重复调用。
    @discardableResult
    public func prepare() throws -> [URL] {
        let directories = [books, covers, cache, backups]
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directories
    }
}
