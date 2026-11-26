import XCTest
@testable import ReaderCore

final class ShelfFilterTests: XCTestCase {
    private func books() -> [Book] {
        [
            Book(id: "n1", type: .novel, origin: .local, title: "乙小说", addedAt: 100, lastReadAt: 300),
            Book(id: "n2", type: .novel, origin: .remote, title: "甲小说", addedAt: 300),
            Book(id: "c1", type: .comic, origin: .local, title: "漫画一", addedAt: 200, lastReadAt: 100),
            Book(id: "c2", type: .comic, origin: .remote, title: "漫画二",
                 groupId: BookGroup.builtinFinishedID, addedAt: 400)
        ]
    }

    func testFilterByType() {
        XCTAssertEqual(ShelfFilter.all.apply(to: books()).count, 4)
        XCTAssertEqual(ShelfFilter.novel.apply(to: books()).map(\.id), ["n1", "n2"])
        XCTAssertEqual(ShelfFilter.comic.apply(to: books()).map(\.id), ["c1", "c2"])
    }

    func testFilterByGroup() {
        let finished = ShelfFilter.group(BookGroup.builtinFinishedID).apply(to: books())
        XCTAssertEqual(finished.map(\.id), ["c2"])
    }

    func testSortByLastReadPutsUnreadLast() {
        let sorted = ShelfSort.lastRead.apply(to: books())
        XCTAssertEqual(sorted.map(\.id), ["n1", "c1", "c2", "n2"])
    }

    func testSortByAdded() {
        XCTAssertEqual(ShelfSort.added.apply(to: books()).map(\.id), ["c2", "n2", "c1", "n1"])
    }

    func testSortByTitleUsesLocalizedCompare() {
        // 中文排序依赖 ICU 与 locale，测试里改用确定性数据
        let list = [
            Book(id: "x", type: .novel, origin: .local, title: "Beta"),
            Book(id: "y", type: .novel, origin: .local, title: "Alpha"),
            Book(id: "z", type: .novel, origin: .local, title: "Gamma")
        ]
        XCTAssertEqual(ShelfSort.title.apply(to: list).map(\.id), ["y", "x", "z"])
    }
}

final class LibraryServiceTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var service: LibraryService!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Library-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try AppDatabase.inMemory()
        let paths = SandboxPaths(root: root)
        try paths.prepare()
        service = LibraryService(books: BookRepository(db: database.writer), paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        database = nil
        service = nil
    }

    func testSaveNovelCopiesFileAndCover() throws {
        let url = try ImportFixtures.makeEpub()
        let parsed = try EpubParser.parse(url: url)

        let book = try service.save(content: .novel(parsed), originalURL: url)

        XCTAssertEqual(book.type, .novel)
        XCTAssertEqual(book.title, "测试之书")
        XCTAssertEqual(book.chapterCount, 2)
        XCTAssertNotNil(book.coverPath)
        XCTAssertNotNil(book.filePath)

        let stored = try XCTUnwrap(try BookRepository(db: database.writer).fetch(id: book.id))
        XCTAssertEqual(stored.id, book.id)

        let coverURL = try XCTUnwrap(service.absoluteCoverURL(for: book))
        XCTAssertTrue(FileManager.default.fileExists(atPath: coverURL.path))

        let bookDir = root.appendingPathComponent("Books/\(book.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookDir.path))
    }

    func testSaveComicExtractsPages() throws {
        let url = try ImportFixtures.makeCbz()
        let parsed = try CbzParser.parse(url: url)

        let book = try service.save(content: .comic(parsed), originalURL: url)
        XCTAssertEqual(book.type, .comic)

        let pages = root.appendingPathComponent("Books/\(book.id)/pages")
        let files = try FileManager.default.contentsOfDirectory(atPath: pages.path).sorted()
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files.first, "0000.png")
    }

    func testDeleteKeepsFilesByDefault() throws {
        let url = try ImportFixtures.makeEpub()
        let book = try service.save(content: .novel(try EpubParser.parse(url: url)), originalURL: url)
        let bookDir = root.appendingPathComponent("Books/\(book.id)")

        try service.delete(book, removeFiles: false)

        XCTAssertNil(try BookRepository(db: database.writer).fetch(id: book.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bookDir.path), "默认应保留文件")
    }

    func testDeleteRemovesFilesWhenRequested() throws {
        let url = try ImportFixtures.makeEpub()
        let book = try service.save(content: .novel(try EpubParser.parse(url: url)), originalURL: url)
        let bookDir = root.appendingPathComponent("Books/\(book.id)")
        let coverURL = try XCTUnwrap(service.absoluteCoverURL(for: book))

        try service.delete(book, removeFiles: true)

        XCTAssertFalse(FileManager.default.fileExists(atPath: bookDir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: coverURL.path))
    }
}
