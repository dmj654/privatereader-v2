import XCTest
@testable import ReaderCore

final class BackupServiceTests: XCTestCase {
    private var root: URL!
    private var paths: SandboxPaths!
    private var exporter: BackupExporter!
    private var importer: BackupImporter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = SandboxPaths(root: root)
        try paths.prepare()
        exporter = BackupExporter(paths: paths)
        importer = BackupImporter(paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func seedSandbox() throws {
        try write("DATABASE", to: paths.database)
        try write("WAL", to: URL(fileURLWithPath: paths.database.path + "-wal"))
        try write("COVER", to: paths.covers.appendingPathComponent("b1.jpg"))
        try write("BOOK", to: paths.books.appendingPathComponent("b1/source.txt"))
    }

    private func input(includeBooks: Bool = true) -> BackupInput {
        BackupInput(
            appVersion: "1.4.0",
            bookCount: 1,
            sources: ["{\"bookSourceName\":\"源A\",\"bookSourceUrl\":\"https://a.example\"}"],
            includeBooks: includeBooks
        )
    }

    func testExportProducesReadableManifest() throws {
        try seedSandbox()

        let url = try exporter.export(input())

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(url.pathExtension, "prbackup")

        let manifest = try importer.inspect(archiveURL: url)
        XCTAssertEqual(manifest.formatVersion, BackupManifest.currentFormat)
        XCTAssertEqual(manifest.appVersion, "1.4.0")
        XCTAssertEqual(manifest.bookCount, 1)
        XCTAssertEqual(manifest.sourceCount, 1)
        XCTAssertTrue(manifest.includesBooks)
        XCTAssertGreaterThan(manifest.databaseBytes, 0)
    }

    func testRestoreBringsBackDatabaseCoversAndBooks() throws {
        try seedSandbox()
        let url = try exporter.export(input())

        // 破坏现有数据
        try write("BROKEN", to: paths.database)
        try FileManager.default.removeItem(at: paths.covers.appendingPathComponent("b1.jpg"))
        try FileManager.default.removeItem(at: paths.books.appendingPathComponent("b1/source.txt"))

        let manifest = try importer.restore(archiveURL: url)
        XCTAssertEqual(manifest.bookCount, 1)

        XCTAssertEqual(try String(contentsOf: paths.database, encoding: .utf8), "DATABASE")
        XCTAssertEqual(try String(contentsOf: paths.covers.appendingPathComponent("b1.jpg"), encoding: .utf8), "COVER")
        XCTAssertEqual(try String(contentsOf: paths.books.appendingPathComponent("b1/source.txt"), encoding: .utf8), "BOOK")
    }

    func testExportWithoutBooksLeavesBookFilesOut() throws {
        try seedSandbox()
        let url = try exporter.export(input(includeBooks: false))

        try FileManager.default.removeItem(at: paths.books.appendingPathComponent("b1/source.txt"))
        try importer.restore(archiveURL: url)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: paths.books.appendingPathComponent("b1/source.txt").path
        ), "没勾选书文件时，恢复不应该凭空带回书")
        XCTAssertEqual(try String(contentsOf: paths.database, encoding: .utf8), "DATABASE")
    }

    func testNewerFormatIsRejectedWithoutTouchingData() throws {
        try seedSandbox()
        let url = try exporter.export(input(), formatVersion: 99)
        try write("CURRENT", to: paths.database)

        do {
            _ = try importer.restore(archiveURL: url)
            XCTFail("更高版本的备份应当被拒绝")
        } catch let error as BackupError {
            XCTAssertEqual(error, .unsupportedVersion(99))
        }

        XCTAssertEqual(try String(contentsOf: paths.database, encoding: .utf8), "CURRENT",
                       "拒绝恢复时不能动现有数据库")
    }

    func testExportFailsWhenDatabaseMissing() throws {
        XCTAssertThrowsError(try exporter.export(input())) { error in
            XCTAssertEqual(error as? BackupError, .missingDatabase)
        }
    }

    func testLatestBackupReturnsNewestFile() throws {
        try seedSandbox()
        let first = try exporter.export(input())
        Thread.sleep(forTimeInterval: 1.1)
        let second = try exporter.export(input())

        XCTAssertEqual(exporter.latestBackup()?.lastPathComponent, second.lastPathComponent,
                       "最新备份应当是后生成的那个")
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
    }
}
