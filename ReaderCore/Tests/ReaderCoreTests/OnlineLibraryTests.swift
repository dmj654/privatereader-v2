import XCTest
@testable import ReaderCore

final class OnlineLibraryTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var library: OnlineLibrary!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OnlineLibraryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        library = OnlineLibrary(paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func manifest(bookId: String = "b1", count: Int = 3) -> OnlineManifest {
        OnlineManifest(
            bookId: bookId,
            sourceId: "s1",
            bookUrl: "https://example.com/book/1",
            title: "测试书",
            author: "作者",
            chapters: (0..<count).map { OnlineChapter(name: "第\($0 + 1)章", url: "https://example.com/c/\($0)") }
        )
    }

    func testManifestRoundTrip() throws {
        let saved = try library.save(manifest())
        XCTAssertEqual(saved, "Books/b1/online-manifest.json")

        let loaded = try library.loadManifest(bookId: "b1")
        XCTAssertEqual(loaded.title, "测试书")
        XCTAssertEqual(loaded.chapters.count, 3)
        XCTAssertEqual(loaded.chapters[1].name, "第2章")
    }

    func testLoadManifestFromBookFilePath() throws {
        let relative = try library.save(manifest())
        let book = Book(
            id: "b1", type: .novel, origin: .remote,
            title: "测试书", filePath: relative, chapterCount: 3
        )
        let loaded = try library.loadManifest(book: book)
        XCTAssertEqual(loaded.bookId, "b1")
    }

    func testChapterTextIsCachedAndReadable() throws {
        XCTAssertNil(library.chapterText(bookId: "b1", index: 0))
        XCTAssertFalse(library.hasChapter(bookId: "b1", index: 0))

        try library.storeChapterText("第一章正文", bookId: "b1", index: 0)

        XCTAssertEqual(library.chapterText(bookId: "b1", index: 0), "第一章正文")
        XCTAssertTrue(library.hasChapter(bookId: "b1", index: 0))
        XCTAssertEqual(library.cachedChapterIndices(bookId: "b1", chapterCount: 3), [0])
    }

    func testEmptyBodyIsTreatedAsMissing() throws {
        try library.storeChapterText("", bookId: "b1", index: 0)
        XCTAssertNil(library.chapterText(bookId: "b1", index: 0),
                     "空正文等于没缓存，否则界面会显示一整页空白")
    }

    func testCacheUsageCountsBytesAndChapters() throws {
        try library.storeChapterText(String(repeating: "字", count: 100), bookId: "b1", index: 0)
        try library.storeChapterText(String(repeating: "字", count: 50), bookId: "b1", index: 1)

        let usage = library.cacheSize(bookId: "b1")
        XCTAssertEqual(usage.chapterCount, 2)
        XCTAssertGreaterThan(usage.bytes, 0)
        XCTAssertEqual(library.cachedCount(bookId: "b1"), 2)
    }

    func testClearCacheRemovesBodiesButKeepsManifest() throws {
        try library.save(manifest())
        try library.storeChapterText("正文", bookId: "b1", index: 0)

        library.clearCache(bookId: "b1")

        XCTAssertNil(library.chapterText(bookId: "b1", index: 0))
        XCTAssertNoThrow(try library.loadManifest(bookId: "b1"))
    }

    func testRemoveDeletesManifestAndCache() throws {
        try library.save(manifest())
        try library.storeChapterText("正文", bookId: "b1", index: 0)

        library.remove(bookId: "b1")

        XCTAssertFalse(FileManager.default.fileExists(atPath: library.manifestURL(bookId: "b1").path))
        XCTAssertEqual(library.cacheSize(bookId: "b1").bytes, 0)
    }
}
