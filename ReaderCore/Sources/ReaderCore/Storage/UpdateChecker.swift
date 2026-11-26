import Foundation

public struct BookUpdate: Equatable, Sendable {
    public let bookId: String
    public let title: String
    public let previousCount: Int
    public let newCount: Int
    public let error: String?

    public var added: Int { max(newCount - previousCount, 0) }
    public var hasUpdate: Bool { error == nil && added > 0 }

    public init(bookId: String,
                title: String,
                previousCount: Int,
                newCount: Int,
                error: String? = nil) {
        self.bookId = bookId
        self.title = title
        self.previousCount = previousCount
        self.newCount = newCount
        self.error = error
    }
}

/// 打开 App 时扫一遍书架里的在线书，看目录有没有变长。
///
/// 只拉目录（一页 HTML），不碰正文。几十本书并发 4 个，几秒能扫完；
/// 失败的书不弹错，只是这次不算更新——源站偶尔抽风不该打扰用户。
public struct UpdateChecker {
    private let online: OnlineReadingService
    private let books: BookRepository

    public init(online: OnlineReadingService, books: BookRepository) {
        self.online = online
        self.books = books
    }

    public func check(book: Book) async -> BookUpdate? {
        guard book.origin == .remote else { return nil }
        do {
            let added = try await online.refreshToc(for: book)
            let manifest = try online.manifest(for: book)
            let newCount = manifest.chapters.count
            if added > 0 {
                try books.updateChapterCount(
                    bookId: book.id,
                    chapterCount: newCount,
                    newChapterCount: book.newChapterCount + added
                )
            }
            return BookUpdate(
                bookId: book.id,
                title: book.title,
                previousCount: book.chapterCount,
                newCount: newCount
            )
        } catch {
            return BookUpdate(
                bookId: book.id,
                title: book.title,
                previousCount: book.chapterCount,
                newCount: book.chapterCount,
                error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
        }
    }

    /// - Parameter limit: 一次最多扫几本，避免书架有几百本时开机等太久。
    public func checkAll(limit: Int = 20, concurrency: Int = 4) async -> [BookUpdate] {
        guard let all = try? books.all() else { return [] }
        let targets = Array(all.filter { $0.origin == .remote && $0.sourceId != nil }.prefix(limit))
        guard !targets.isEmpty else { return [] }

        var results: [BookUpdate] = []
        var index = 0

        await withTaskGroup(of: BookUpdate?.self) { group in
            let width = max(1, min(concurrency, targets.count))
            while index < width {
                let book = targets[index]
                group.addTask { await check(book: book) }
                index += 1
            }
            while let result = await group.next() {
                if let result { results.append(result) }
                if index < targets.count {
                    let book = targets[index]
                    group.addTask { await check(book: book) }
                    index += 1
                }
            }
        }

        return results.filter(\.hasUpdate)
    }
}
