import XCTest
import GRDB
@testable import ReaderCore

/// 用交付给用户的真实 3 条小说源 JSON 跑完整导入 + 取可执行源，
/// 防止「规则本身没问题，但导入/落库/启用/类型过滤把源吃掉了」。
final class SourceImportFixtureTests: XCTestCase {

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "novel-sources", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "novel-sources", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    func testThreeNovelSourcesSurviveImportAndAreEnabled() throws {
        let database = try AppDatabase.inMemory()
        let service = SourceImportService(repo: SourceRepository(db: database.writer))

        let summary = try service.importJSON(fixtureData(), category: .novel)

        XCTAssertEqual(summary.added, 3)
        XCTAssertEqual(summary.updated, 0)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(try SourceRepository(db: database.writer).count(), 3)

        let targets = try service.enabledTargets()
        XCTAssertEqual(targets.count, 3, "三条源导入后必须全部是「启用」的小说源")
        XCTAssertTrue(targets.allSatisfy { !$0.isComic })
        XCTAssertEqual(Set(targets.map(\.name)), ["00小说网", "天域小说网", "笔趣阁 bqg9"])

        for target in targets {
            guard case .legado(let source) = target else {
                return XCTFail("\(target.name) 不是 legado 源")
            }
            XCTAssertFalse(source.searchUrl.isEmpty, "\(source.name) 没有搜索地址")
            XCTAssertFalse(source.ruleSearch.bookList.isEmpty, "\(source.name) 没有搜索列表规则")
            XCTAssertFalse(source.ruleToc.chapterList.isEmpty, "\(source.name) 没有目录规则")
            XCTAssertFalse(source.ruleContent.content.isEmpty, "\(source.name) 没有正文规则")
        }
    }

    func testThreeNovelSourcesAreRejectedByComicEntry() throws {
        let database = try AppDatabase.inMemory()
        let service = SourceImportService(repo: SourceRepository(db: database.writer))

        XCTAssertThrowsError(try service.importJSON(fixtureData(), category: .comic)) { error in
            XCTAssertEqual(error as? SourceImportError, .noMatchingSource(.comic))
        }
        XCTAssertEqual(try SourceRepository(db: database.writer).count(), 0)
    }
}
