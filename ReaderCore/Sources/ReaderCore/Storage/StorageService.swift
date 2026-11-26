import Foundation

public struct StorageBreakdown: Equatable, Sendable {
    public var booksBytes: Int64
    public var cacheBytes: Int64
    public var coversBytes: Int64
    public var backupsBytes: Int64

    public var totalBytes: Int64 { booksBytes + cacheBytes + coversBytes + backupsBytes }

    public init(booksBytes: Int64 = 0,
                cacheBytes: Int64 = 0,
                coversBytes: Int64 = 0,
                backupsBytes: Int64 = 0) {
        self.booksBytes = booksBytes
        self.cacheBytes = cacheBytes
        self.coversBytes = coversBytes
        self.backupsBytes = backupsBytes
    }
}

/// 存储管理页的数据来源。只统计这四类目录，别把数据库和日志算进来——
/// 那些用户删不掉，列出来只会让人困惑。
public struct StorageService {
    private let paths: SandboxPaths
    private let fileManager = FileManager.default

    public init(paths: SandboxPaths) {
        self.paths = paths
    }

    public func breakdown() -> StorageBreakdown {
        StorageBreakdown(
            booksBytes: bytes(in: paths.books),
            cacheBytes: bytes(in: paths.cache),
            coversBytes: bytes(in: paths.covers),
            backupsBytes: bytes(in: paths.backups)
        )
    }

    public struct BookCache: Equatable, Identifiable, Sendable {
        public let book: Book
        public let usage: OnlineLibrary.CacheUsage

        public var id: String { book.id }

        public init(book: Book, usage: OnlineLibrary.CacheUsage) {
            self.book = book
            self.usage = usage
        }
    }

    /// 每本在线书的缓存占用，按大小降序。
    public func cacheByBook(_ books: [Book]) -> [BookCache] {
        let library = OnlineLibrary(paths: paths)
        return books
            .filter { $0.origin == .remote }
            .map { BookCache(book: $0, usage: library.cacheSize(bookId: $0.id)) }
            .filter { $0.usage.bytes > 0 }
            .sorted { $0.usage.bytes > $1.usage.bytes }
    }

    public func clearCache() {
        try? fileManager.removeItem(at: paths.cache)
        try? fileManager.createDirectory(at: paths.cache, withIntermediateDirectories: true)
    }

    public func clearBackups() {
        try? fileManager.removeItem(at: paths.backups)
        try? fileManager.createDirectory(at: paths.backups, withIntermediateDirectories: true)
    }

    public static func text(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func bytes(in directory: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
