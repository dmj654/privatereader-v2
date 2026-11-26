import XCTest
@testable import ReaderCore

final class DirectoryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Scan-\(UUID().uuidString)", isDirectory: true)

        let fileManager = FileManager.default
        for directory in ["", "Import", "Import/Done", "Books/b1", "Covers", "Cache", "Backups"] {
            try fileManager.createDirectory(
                at: root.appendingPathComponent(directory, isDirectory: true),
                withIntermediateDirectories: true
            )
        }

        try Data("第一章\n正文\n第二章\n正文".utf8).write(to: root.appendingPathComponent("顶层.txt"))
        try Data("fake epub".utf8).write(to: root.appendingPathComponent("Import/嵌套.epub"))
        try Data("old".utf8).write(to: root.appendingPathComponent("Import/Done/已导入.txt"))
        try Data("copied".utf8).write(to: root.appendingPathComponent("Books/b1/source.txt"))
        try Data("img".utf8).write(to: root.appendingPathComponent("Covers/b1.jpg"))
        try Data("c".utf8).write(to: root.appendingPathComponent("Cache/a.cbz"))
        try Data("b".utf8).write(to: root.appendingPathComponent("Backups/bak.zip"))
        try Data("readme".utf8).write(to: root.appendingPathComponent("说明.md"))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testFindsTopLevelAndNestedBooks() {
        let found = DirectoryScanner.scan(root: root)
        XCTAssertEqual(Set(found.map(\.lastPathComponent)), ["顶层.txt", "嵌套.epub"])
    }

    func testSkipsAppOwnedDirectories() {
        let found = DirectoryScanner.scan(root: root)
        let paths = found.map { $0.standardizedFileURL.path }
        XCTAssertFalse(paths.contains { $0.contains("/Books/") }, "Books 目录不能被当成待导入的书")
        XCTAssertFalse(paths.contains { $0.contains("/Cache/") })
        XCTAssertFalse(paths.contains { $0.contains("/Backups/") })
        XCTAssertFalse(paths.contains { $0.contains("/Covers/") })
        XCTAssertFalse(paths.contains { $0.contains("Import/Done/") }, "已归档的文件不能被重复导入")
    }

    func testIgnoresUnsupportedExtension() {
        let found = DirectoryScanner.scan(root: root)
        XCTAssertFalse(found.contains { $0.pathExtension == "md" })
    }

    func testEmptyRootReturnsEmpty() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("Empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertTrue(DirectoryScanner.scan(root: empty).isEmpty)
    }

    func testCustomExtensions() {
        let found = DirectoryScanner.scan(root: root, extensions: ["md"])
        XCTAssertEqual(found.map(\.lastPathComponent), ["说明.md"])
    }
}

final class ImportLogTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Log-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testAppendThenRead() {
        let log = ImportLog(directory: directory)
        log.append("第一行")
        log.append("第二行")

        let text = log.read()
        XCTAssertTrue(text.contains("第一行"))
        XCTAssertTrue(text.contains("第二行"))
    }

    func testAppendIsCumulative() {
        let log = ImportLog(directory: directory)
        for index in 0..<10 {
            log.append("第 \(index) 行")
        }
        let lines = log.read().split(separator: "\n")
        XCTAssertEqual(lines.count, 10)
        XCTAssertTrue(lines.last?.contains("第 9 行") ?? false)
    }

    func testTrimsWhenExceedingLimit() {
        let log = ImportLog(directory: directory, maximumBytes: 300)
        for index in 0..<80 {
            log.append("填充内容填充内容 \(index)")
        }
        let text = log.read()
        XCTAssertLessThan(text.utf8.count, 700, "超限后应被裁剪，不能无限增长")
        XCTAssertTrue(text.contains("79"), "最近一条必须保留")
    }

    func testClearRemovesContent() {
        let log = ImportLog(directory: directory)
        log.append("x")
        log.clear()
        XCTAssertTrue(log.read().isEmpty)
    }

    func testReadOnMissingFileReturnsEmpty() {
        let log = ImportLog(directory: directory.appendingPathComponent("none", isDirectory: true))
        XCTAssertEqual(log.read(), "")
    }
}
