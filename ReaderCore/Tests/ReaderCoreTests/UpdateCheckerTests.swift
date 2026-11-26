import XCTest
import GRDB
@testable import ReaderCore

final class UpdateCheckerTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var library: OnlineLibrary!
    private var database: AppDatabase!
    private var sources: SourceRepository!
    private var books: BookRepository!
    private var online: OnlineReadingService!
    private var checker: UpdateChecker!

    private static let sourceJSON = """
    {
      "bookSourceName": "更新测试源",
      "bookSourceUrl": "https://example.com",
      "bookSourceType": 0,
      "searchUrl": "https://example.com/search?q={{key}}",
      "ruleSearch": {"bookList": ".book", "name": ".name@text", "bookUrl": ".name@href"},
      "ruleBookInfo": {"tocUrl": ".toc-link@href"},
      "ruleToc": {"chapterList": "#list dd", "chapterName": "a@text", "chapterUrl": "a@href"},
      "ruleContent": {"content": "#content@html"}
    }
    """

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateCheckerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        library = OnlineLibrary(paths: paths)
        database = try AppDatabase.inMemory()
        sources = SourceRepository(db: database.writer)
        books = BookRepository(db: database.writer)
        _ = try SourceImportService(repo: sources).importJSON(Self.sourceJSON)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StaticURLProtocol.self]
        let client = SourceClient(session: URLSession(configuration: config))
        online = OnlineReadingService(library: library, sources: sources, client: client)
        checker = UpdateChecker(online: online, books: books)

        StaticURLProtocol.routes = [
            "/book/1": (200, Data("<a class=\"toc-link\" href=\"/book/1/toc\">目录</a>".utf8), "text/html"),
            "/book/1/toc": (200, Data(tocHTML(count: 3).utf8), "text/html")
        ]
    }

    override func tearDownWithError() throws {
        StaticURLProtocol.routes = [:]
        if let root { try? FileManager.default.removeItem(at: root) }
        database = nil
    }

    private func tocHTML(count: Int) -> String {
        let items = (0..<count)
            .map { "<dd><a href=\"/c/\($0)\">第\($0 + 1)章</a></dd>" }
            .joined()
        return "<div id=\"list\"><dl>\(items)</dl></div>"
    }

    private func makeBook(id: String = "online-1", origin: BookOrigin = .remote, count: Int = 3) throws -> Book {
        let manifest = OnlineManifest(
            bookId: id,
            sourceId: "https://example.com",
            bookUrl: "https://example.com/book/1",
            title: "书\(id)",
            chapters: (0..<count).map {
                OnlineChapter(name: "第\($0 + 1)章", url: "https://example.com/c/\($0)")
            }
        )
        let relative = try library.save(manifest)
        let book = Book(
            id: id,
            type: .novel,
            origin: origin,
            title: "书\(id)",
            filePath: origin == .remote ? relative : nil,
            sourceId: origin == .remote ? "https://example.com" : nil,
            sourceUrl: origin == .remote ? "https://example.com/book/1" : nil,
            chapterCount: count
        )
        try books.insert(book)
        return book
    }

    func testCheckDetectsNewChaptersAndUpdatesDatabase() async throws {
        let book = try makeBook()
        StaticURLProtocol.routes["/book/1/toc"] = (200, Data(tocHTML(count: 5).utf8), "text/html")

        let update = await checker.check(book: book)

        XCTAssertEqual(update?.added, 2)
        XCTAssertEqual(update?.hasUpdate, true)

        let stored = try books.fetch(id: book.id)
        XCTAssertEqual(stored?.chapterCount, 5)
        XCTAssertEqual(stored?.newChapterCount, 2)
    }

    func testCheckWithoutChangeDoesNotTouchDatabase() async throws {
        let book = try makeBook()

        let update = await checker.check(book: book)

        XCTAssertEqual(update?.added, 0)
        XCTAssertEqual(update?.hasUpdate, false)
        XCTAssertEqual(try books.fetch(id: book.id)?.newChapterCount, 0)
    }

    func testCheckFailureReportsErrorAndKeepsCounts() async throws {
        let book = try makeBook()
        StaticURLProtocol.routes = [:]   // 全 404

        let update = await checker.check(book: book)

        XCTAssertNotNil(update?.error)
        XCTAssertEqual(update?.hasUpdate, false)
        XCTAssertEqual(try books.fetch(id: book.id)?.chapterCount, 3)
    }

    func testCheckSkipsLocalBooks() async throws {
        let local = try makeBook(id: "local-1", origin: .local)

        let update = await checker.check(book: local)

        XCTAssertNil(update, "本地书没有目录可刷新")
    }

    func testCheckAllReturnsOnlyUpdatedBooks() async throws {
        _ = try makeBook(id: "a", count: 3)
        _ = try makeBook(id: "b", count: 3)
        StaticURLProtocol.routes["/book/1/toc"] = (200, Data(tocHTML(count: 4).utf8), "text/html")

        let updates = await checker.checkAll()

        XCTAssertEqual(updates.count, 2, "两本在线书都会检出 1 章更新")
        XCTAssertTrue(updates.allSatisfy { $0.added == 1 })
    }

    func testCheckAllHonoursLimit() async throws {
        _ = try makeBook(id: "a")
        _ = try makeBook(id: "b")
        _ = try makeBook(id: "c")
        StaticURLProtocol.routes["/book/1/toc"] = (200, Data(tocHTML(count: 4).utf8), "text/html")

        let updates = await checker.checkAll(limit: 1)

        XCTAssertEqual(updates.count, 1)
    }
}
