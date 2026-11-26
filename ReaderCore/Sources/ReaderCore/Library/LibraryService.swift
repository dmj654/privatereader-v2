import Foundation
import GRDB

/// 把「解析结果」落成一本真实的书：写封面、拷文件、入库。
/// 删除同样走这里，保证文件与记录一起处理，不会只删一半。
public struct LibraryService {
    private let books: BookRepository
    private let paths: SandboxPaths
    private let fileManager: FileManager

    public init(books: BookRepository, paths: SandboxPaths, fileManager: FileManager = .default) {
        self.books = books
        self.paths = paths
        self.fileManager = fileManager
    }

    @discardableResult
    public func save(content: ImportedContent,
                     originalURL: URL) throws -> Book {
        let id = UUID().uuidString
        let bookDirectory = paths.bookDirectory(id)
        try fileManager.createDirectory(at: bookDirectory, withIntermediateDirectories: true)

        var coverPath: String?
        var storedFilePath: String?
        var chapterCount = 0
        var type: BookType
        var title: String
        var author: String?

        switch content {
        case .novel(let novel):
            type = .novel
            title = novel.title
            author = novel.author
            chapterCount = novel.chapters.count

            let destination = bookDirectory.appendingPathComponent("source.\(originalURL.pathExtension.lowercased())")
            if fileManager.fileExists(atPath: destination.path) == false {
                try? fileManager.copyItem(at: originalURL, to: destination)
            }
            storedFilePath = relativePath(of: destination)
            if let coverData = novel.coverData {
                let coverURL = paths.coverFile(id)
                if CoverStore.write(from: coverData, to: coverURL) {
                    coverPath = relativePath(of: coverURL)
                }
            }

        case .comic(let comic):
            type = .comic
            title = comic.title
            author = nil
            chapterCount = 1

            _ = try? CbzParser.extractPages(from: originalURL, to: bookDirectory.appendingPathComponent("pages", isDirectory: true))
            if let coverData = comic.coverData {
                let coverURL = paths.coverFile(id)
                if CoverStore.write(from: coverData, to: coverURL) {
                    coverPath = relativePath(of: coverURL)
                }
            }
        }

        let book = Book(
            id: id,
            type: type,
            origin: .local,
            title: title,
            author: author,
            coverPath: coverPath,
            filePath: storedFilePath,
            groupId: BookGroup.builtinReadingID,
            chapterCount: chapterCount
        )
        try books.insert(book)
        return book
    }

    /// 默认只删记录；removeFiles 为 true 时连书文件与封面一起删。
    public func delete(_ book: Book, removeFiles: Bool) throws {
        try books.delete(id: book.id)
        guard removeFiles else { return }

        let directory = paths.bookDirectory(book.id)
        try? fileManager.removeItem(at: directory)
        try? fileManager.removeItem(at: paths.coverFile(book.id))
        try? fileManager.removeItem(at: paths.cacheDirectory(bookID: book.id, chapterIndex: 0).deletingLastPathComponent())
    }

    public func absoluteCoverURL(for book: Book) -> URL? {
        guard let coverPath = book.coverPath else { return nil }
        return paths.root.appendingPathComponent(coverPath)
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = paths.root.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        guard fullPath.hasPrefix(rootPath) else { return fullPath }
        var relative = String(fullPath.dropFirst(rootPath.count))
        if relative.hasPrefix("/") { relative.removeFirst() }
        return relative
    }
}
