import XCTest
import GRDB
@testable import ReaderCore

final class SourceRepositoryTests: XCTestCase {
    private var database: AppDatabase!

    override func setUpWithError() throws {
        database = try AppDatabase.inMemory()
    }

    override func tearDownWithError() throws {
        database = nil
    }

    private func json(count: Int, enabled: Bool = true) throws -> Data {
        let items: [[String: Any]] = (0..<count).map { index in
            [
                "bookSourceName": "源 \(index + 1)",
                "bookSourceUrl": "https://s\(index + 1).com",
                "bookSourceType": 0,
                "enabled": enabled,
                "searchUrl": "/s?q={{key}}",
                "ruleSearch": ["bookList": "class.item", "name": "tag.a@text"],
                "ruleToc": ["chapterList": "class.toc"],
                "ruleContent": ["content": "id.content"]
            ]
        }
        return try JSONSerialization.data(withJSONObject: items, options: [])
    }

    // MARK: 导入

    func testImportFiftySources() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)

        let summary = try service.importJSON(try json(count: 50))
        XCTAssertEqual(summary.added, 50)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(try repo.count(), 50)
    }

    func testImportTwiceUpdatesInsteadOfDuplicating() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)

        _ = try service.importJSON(try json(count: 3))
        let second = try service.importJSON(try json(count: 3))
        XCTAssertEqual(second.added, 0)
        XCTAssertEqual(second.updated, 3)
        XCTAssertEqual(try repo.count(), 3, "重复导入不能出现重复源")
    }

    func testForceDisabledImport() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 2), forceEnabled: false)

        let all = try repo.all()
        XCTAssertEqual(all.count, 2)
        XCTAssertTrue(all.allSatisfy { !$0.enabled })
        XCTAssertEqual(try repo.enabled().count, 0)
    }

    func testImportInvalidJSONThrows() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        XCTAssertThrowsError(try service.importJSON("不是 JSON"))
    }

    // MARK: 开关 / 删除 / 检测

    func testToggleEnabled() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 1))
        let id = try XCTUnwrap(try repo.all().first?.id)

        try repo.setEnabled(id: id, enabled: false)
        XCTAssertEqual(try repo.enabled().count, 0)

        try repo.setEnabled(id: id, enabled: true)
        XCTAssertEqual(try repo.enabled().count, 1)
    }

    func testDeleteOne() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 2))
        let id = try XCTUnwrap(try repo.all().first?.id)

        try repo.delete(id: id)
        XCTAssertEqual(try repo.count(), 1)
        XCTAssertNil(try repo.fetch(id: id))
    }

    func testMarkCheckedStoresResult() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 1))
        let id = try XCTUnwrap(try repo.all().first?.id)

        try repo.markChecked(id: id, at: 1234, result: "正常 · 0.8s")
        let record = try XCTUnwrap(try repo.fetch(id: id))
        XCTAssertEqual(record.lastCheckAt, 1234)
        XCTAssertEqual(record.lastCheckResult, "正常 · 0.8s")
    }

    // MARK: 还原成可执行源

    func testExecutableFromStoredRecord() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 1))

        let record = try XCTUnwrap(try repo.all().first)
        let source = try XCTUnwrap(service.executable(from: record))
        XCTAssertEqual(source.name, record.name)
        XCTAssertEqual(source.searchUrl, "/s?q={{key}}")
        XCTAssertEqual(source.ruleSearch.bookList, "class.item")
    }

    func testExecutableReflectsToggledState() throws {
        let repo = SourceRepository(db: database.writer)
        let service = SourceImportService(repo: repo)
        _ = try service.importJSON(try json(count: 1))
        let record = try XCTUnwrap(try repo.all().first)
        try repo.setEnabled(id: record.id, enabled: false)

        let refreshed = try XCTUnwrap(try repo.fetch(id: record.id))
        let source = try XCTUnwrap(service.executable(from: refreshed))
        XCTAssertFalse(source.enabled, "开关状态要以数据库为准")
    }

    func testInvalidSourcesOnlyIncludesFailedOrTimeout() throws {
        let repo = SourceRepository(db: database.writer)
        try repo.upsert(BookSource(id: "ok", name: "正常", rawJson: "{}"))
        try repo.upsert(BookSource(id: "bad", name: "失败", rawJson: "{}"))
        try repo.upsert(BookSource(id: "slow", name: "超时", rawJson: "{}"))
        try repo.upsert(BookSource(id: "new", name: "没测过", rawJson: "{}"))

        try repo.markChecked(id: "ok", at: 1, result: "ok 120ms 3")
        try repo.markChecked(id: "bad", at: 1, result: "failed: HTTP 404")
        try repo.markChecked(id: "slow", at: 1, result: "timeout")

        let invalid = try repo.invalidSources()

        XCTAssertEqual(Set(invalid.map(\.id)), ["bad", "slow"],
                       "正常与没测过的源不能被算成失效")
    }

    func testDeleteByIdsRemovesOnlyGivenSources() throws {
        let repo = SourceRepository(db: database.writer)
        try repo.upsert(BookSource(id: "a", name: "A", rawJson: "{}"))
        try repo.upsert(BookSource(id: "b", name: "B", rawJson: "{}"))
        try repo.upsert(BookSource(id: "c", name: "C", rawJson: "{}"))

        try repo.delete(ids: ["a", "c"])

        XCTAssertEqual(try repo.all().map(\.id), ["b"])
    }
}
