import XCTest
@testable import ReaderCore

final class SandboxPathsTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReaderCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryRoot {
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    func testPrepareCreatesAllDirectories() throws {
        let paths = SandboxPaths(root: temporaryRoot)
        let created = try paths.prepare()

        XCTAssertEqual(created.count, 4)
        for url in created {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            XCTAssertTrue(exists, "目录未创建: \(url.lastPathComponent)")
            XCTAssertTrue(isDirectory.boolValue)
        }
    }

    func testPrepareIsIdempotent() throws {
        let paths = SandboxPaths(root: temporaryRoot)
        try paths.prepare()
        XCTAssertNoThrow(try paths.prepare())
    }

    func testDatabaseAndRootAreInsideRoot() {
        let paths = SandboxPaths(root: temporaryRoot)
        XCTAssertEqual(paths.database.deletingLastPathComponent().standardizedFileURL.path,
                       temporaryRoot.standardizedFileURL.path)
        XCTAssertEqual(paths.database.lastPathComponent, "library.db")
    }

    func testCoverFileUsesBookIDAndJPGExtension() {
        let paths = SandboxPaths(root: temporaryRoot)
        let url = paths.coverFile("ABC-123")
        XCTAssertEqual(url.lastPathComponent, "ABC-123.jpg")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Covers")
    }

    func testCacheDirectoryComposition() {
        let paths = SandboxPaths(root: temporaryRoot)
        let url = paths.cacheDirectory(bookID: "b1", chapterIndex: 42)
        XCTAssertEqual(url.lastPathComponent, "42")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "b1")
        XCTAssertEqual(url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent, "Cache")
    }

    func testBookDirectoryComposition() {
        let paths = SandboxPaths(root: temporaryRoot)
        let url = paths.bookDirectory("b9")
        XCTAssertEqual(url.lastPathComponent, "b9")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Books")
    }
}
