import XCTest
@testable import ReaderCore

/// 用真实 bqg9 搜索页做离线回归：页面是 GBK，表头 + 50 条数据行，
/// 列顺序与交付的书源规则一致。SwiftSoup / RuleRunner 必须能解析出书名。
final class NovelRuleFixtureTests: XCTestCase {

    private func html(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "\(name)-search", withExtension: "html", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "\(name)-search", withExtension: "html")
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testBqg9SearchRulesParseRealFixture() throws {
        let html = try html("bqg9")
        let rows = RuleRunner.elements("class.grid@tag.tr", html: html, baseUrl: "https://www.bqg9.xyz")
        print("[FIXTURE] rows=\(rows.count)")
        XCTAssertEqual(rows.count, 50, "表头 + 49 条数据行")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@text", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "斗破苍穹")
        XCTAssertEqual(RuleRunner.string("tag.td.2@text", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "天蚕土豆")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@href", html: rows[1], baseUrl: "https://www.bqg9.xyz"),
                       "https://www.bqg9.xyz/0_844/")
    }

    func test00ShugeSearchRulesParseRealFixture() throws {
        let html = try html("00shuge")
        let rows = RuleRunner.elements("class.grid@tag.tr", html: html, baseUrl: "https://www.00shuge.com")
        XCTAssertEqual(rows.count, 101, "表头 + 100 条数据行")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@text", html: rows[1], baseUrl: "https://www.00shuge.com"),
                       "斗破苍穹")
        XCTAssertEqual(RuleRunner.string("tag.td.2@text", html: rows[1], baseUrl: "https://www.00shuge.com"),
                       "天蚕土豆")
        XCTAssertEqual(RuleRunner.string("tag.td.0@tag.a@href", html: rows[1], baseUrl: "https://www.00shuge.com"),
                       "https://www.00shuge.com/3/3455/")
    }

    func testTianyuSearchRulesParseRealFixture() throws {
        let html = try html("tycqzw")
        let rows = RuleRunner.elements("class.grid@tag.tr", html: html, baseUrl: "http://www.tycqzw.info")
        XCTAssertEqual(rows.count, 101, "表头 + 100 条数据行")
        XCTAssertEqual(RuleRunner.string("class.even.0@tag.a.0@text", html: rows[1], baseUrl: "http://www.tycqzw.info"),
                       "斗破苍穹")
        XCTAssertEqual(RuleRunner.string("class.even.1@text", html: rows[1], baseUrl: "http://www.tycqzw.info"),
                       "天蚕土豆")
        XCTAssertEqual(RuleRunner.string("class.even.0@tag.a.0@href", html: rows[1], baseUrl: "http://www.tycqzw.info"),
                       "http://www.tycqzw.info/57_57672/")
    }
}
