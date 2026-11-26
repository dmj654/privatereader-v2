import XCTest
@testable import ReaderCore

final class StorageServiceTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var service: StorageService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        service = StorageService(paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: bytes).write(to: url)
    }

    func testBreakdownSumsFourDirectories() throws {
        try write(1000, to: paths.books.appendingPathComponent("a/book.txt"))
        try write(500, to: paths.cache.appendingPathComponent("b/0/body.txt"))
        try write(200, to: paths.covers.appendingPathComponent("c.jpg"))
        try write(300, to: paths.backups.appendingPathComponent("d.zip"))

        let breakdown = service.breakdown()

        XCTAssertEqual(breakdown.booksBytes, 1000)
        XCTAssertEqual(breakdown.cacheBytes, 500)
        XCTAssertEqual(breakdown.coversBytes, 200)
        XCTAssertEqual(breakdown.backupsBytes, 300)
        XCTAssertEqual(breakdown.totalBytes, 2000)
    }

    func testCacheByBookOnlyListsOnlineBooksWithCache() throws {
        let library = OnlineLibrary(paths: paths)
        try library.storeChapterText("正文", bookId: "remote-1", index: 0)
        try library.storeChapterText("正文", bookId: "remote-2", index: 0)

        let remote = Book(id: "remote-1", type: .novel, origin: .remote, title: "在线")
        let local = Book(id: "local-1", type: .novel, origin: .local, title: "本地")
        let empty = Book(id: "remote-3", type: .novel, origin: .remote, title: "没缓存")

        let list = service.cacheByBook([remote, local, empty])

        XCTAssertEqual(list.map(\.book.id), ["remote-1"])
        XCTAssertGreaterThan(list[0].usage.bytes, 0)
    }

    func testClearCacheKeepsBooksAndCovers() throws {
        try write(100, to: paths.books.appendingPathComponent("a/book.txt"))
        try write(200, to: paths.cache.appendingPathComponent("a/0/body.txt"))

        service.clearCache()

        XCTAssertEqual(service.breakdown().cacheBytes, 0)
        XCTAssertEqual(service.breakdown().booksBytes, 100)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.cache.path))
    }

    func testClearBackupsKeepsCache() throws {
        try write(300, to: paths.backups.appendingPathComponent("old.zip"))
        try write(200, to: paths.cache.appendingPathComponent("a/0/body.txt"))

        service.clearBackups()

        XCTAssertEqual(service.breakdown().backupsBytes, 0)
        XCTAssertEqual(service.breakdown().cacheBytes, 200)
    }

    func testTextFormattingIsHumanReadable() {
        XCTAssertFalse(StorageService.text(0).isEmpty)
        XCTAssertFalse(StorageService.text(1024 * 1024).isEmpty)
    }
}
