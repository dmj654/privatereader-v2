import XCTest
@testable import ReaderCore

/// 用真实 bqg9 搜索页做离线回归：页面是 GBK，表头 + 50 条数据行，
/// 列顺序与交付的书源规则一致。SwiftSoup / RuleRunner 必须能解析出书名。
final class NovelRuleFixtureTests: XCTestCase {

    private func html() throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "bqg9-search", withExtension: "html", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "bqg9-search", withExtension: "html")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBqg9SearchRulesParseRealFixture() throws {
        let html = try html()
        let rows = RuleRunner.elements("class.grid@tag.tr", html: html, baseUrl: "https://www.bqg9.xyz")
        print("[FIXTURE] rows=\(rows.count)")
        for index in 0..<min(3, rows.count) {
            print("[FIXTURE] row\(index) outer=\(rows[index].prefix(180))")
            print("[FIXTURE] row\(index) name=\(RuleRunner.string("tag.td.0@tag.a@text", html: rows[index], baseUrl: "https://www.bqg9.xyz"))")
        }
        XCTAssertEqual(rows.count, 51, "表头 + 50 条数据行")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@text", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "斗破苍穹")
        XCTAssertEqual(RuleRunner.string("tag.td.2@text", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "天蚕土豆")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@href", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "https://www.bqg9.xyz/0_844/")
    }
}
