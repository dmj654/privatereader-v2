import XCTest
@testable import ReaderCore

final class LegadoParserTests: XCTestCase {

    // MARK: 样本

    /// 与真实 2500 源合集同构的一条。字段名照抄 legado 导出格式。
    private let realStyleSource: [String: Any] = [
        "bookSourceName": "示例书源",
        "bookSourceUrl": "https://example.com",
        "bookSourceType": 0,
        "enabled": true,
        "header": "{\"User-Agent\":\"Mozilla/5.0\"}",
        "searchUrl": "/search?q={{key}}",
        "exploreUrl": "",
        "ruleSearch": [
            "bookList": "class.book-item@tag.div",
            "name": "tag.h3@text",
            "author": "class.author@text",
            "bookUrl": "tag.a@href"
        ],
        "ruleBookInfo": [
            "name": "id.info@tag.h1@text",
            "intro": "id.intro@text",
            "tocUrl": "class.toc@href"
        ],
        "ruleToc": [
            "chapterList": "class.chapter-list@tag.li",
            "chapterName": "tag.a@text",
            "chapterUrl": "tag.a@href"
        ],
        "ruleContent": [
            "content": "id.content@html"
        ]
    ]

    private func makeSources(count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            [
                "bookSourceName": "源 \(index + 1)",
                "bookSourceUrl": "https://site\(index + 1).example.com",
                "bookSourceType": index % 2 == 0 ? 0 : 2,
                "enabled": index % 3 != 0,
                "searchUrl": "/s?q={{key}}",
                "ruleSearch": ["bookList": "class.item", "name": "tag.a@text"],
                "ruleBookInfo": [:],
                "ruleToc": ["chapterList": "class.toc"],
                "ruleContent": ["content": "id.content"]
            ] as [String: Any]
        }
    }

    private func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [])
    }

    // MARK: 拆包

    func testParsesFiftySourcesFromArray() throws {
        let json = try data(makeSources(count: 50))
        let sources = try LegadoParser.parse(data: json)
        XCTAssertEqual(sources.count, 50, "50 源的包必须展开成 50 条")
        XCTAssertEqual(sources.first?.name, "源 1")
        XCTAssertEqual(sources.last?.name, "源 50")
        XCTAssertEqual(Set(sources.map(\.id)).count, 50, "id 不能重复")
    }

    func testParsesSingleObject() throws {
        let json = try data(realStyleSource)
        let sources = try LegadoParser.parse(data: json)
        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "示例书源")
        XCTAssertEqual(sources[0].url, "https://example.com")
    }

    func testParsesNestedBookSourcesKey() throws {
        let json = try data(["bookSources": makeSources(count: 3)])
        let sources = try LegadoParser.parse(data: json)
        XCTAssertEqual(sources.count, 3)
    }

    func testParsesNestedDataKey() throws {
        let json = try data(["data": makeSources(count: 4)])
        XCTAssertEqual(try LegadoParser.parse(data: json).count, 4)
    }

    // MARK: 字段

    func testParsesRulesAndHeader() throws {
        let json = try data(realStyleSource)
        let source = try XCTUnwrap(try LegadoParser.parse(data: json).first)

        XCTAssertEqual(source.searchUrl, "/search?q={{key}}")
        XCTAssertEqual(source.header, "{\"User-Agent\":\"Mozilla/5.0\"}")
        XCTAssertEqual(source.ruleSearch.bookList, "class.book-item@tag.div")
        XCTAssertEqual(source.ruleSearch.bookUrl, "tag.a@href")
        XCTAssertEqual(source.ruleBookInfo.intro, "id.intro@text")
        XCTAssertEqual(source.ruleToc.chapterList, "class.chapter-list@tag.li")
        XCTAssertEqual(source.ruleContent.content, "id.content@html")
        XCTAssertEqual(source.type, 0)
        XCTAssertFalse(source.isComic)
    }

    func testComicTypeDetected() throws {
        var source = makeSources(count: 2)[1]
        source["bookSourceType"] = 2
        let parsed = try LegadoParser.parse(data: try data([source]))
        XCTAssertTrue(parsed[0].isComic)
    }

    func testMissingFieldsFallBack() throws {
        let json = try data([["bookSourceName": "只有名字"]])
        let source = try XCTUnwrap(try LegadoParser.parse(data: json).first)
        XCTAssertEqual(source.name, "只有名字")
        XCTAssertEqual(source.url, "")
        XCTAssertEqual(source.ruleSearch.bookList, "")
        XCTAssertEqual(source.ruleContent.content, "")
        XCTAssertTrue(source.enabled, "缺 enabled 时默认开启")
        XCTAssertFalse(source.rawJson.isEmpty, "原始 JSON 要留着，方便以后重新解析")
    }

    func testNumericAndStringFlagsAreTolerated() throws {
        let json = try data([
            ["bookSourceName": "数字开关", "bookSourceUrl": "https://a.com", "enabled": 0, "bookSourceType": "2"],
            ["bookSourceName": "字符串开关", "bookSourceUrl": "https://b.com", "enabled": "true"]
        ])
        let sources = try LegadoParser.parse(data: json)
        XCTAssertFalse(sources[0].enabled)
        XCTAssertEqual(sources[0].type, 2)
        XCTAssertTrue(sources[1].enabled)
    }

    func testDuplicateURLsAreCollapsed() throws {
        let json = try data([
            ["bookSourceName": "A", "bookSourceUrl": "https://same.com"],
            ["bookSourceName": "B", "bookSourceUrl": "https://same.com"]
        ])
        let sources = try LegadoParser.parse(data: json)
        XCTAssertEqual(sources.count, 1, "同一个 URL 的重复源只保留第一条")
        XCTAssertEqual(sources[0].name, "A")
    }

    func testEntriesWithoutNameAndURLAreSkipped() throws {
        let json = try data([
            ["bookSourceName": "", "bookSourceUrl": ""],
            ["bookSourceName": "有效", "bookSourceUrl": "https://ok.com"]
        ])
        XCTAssertEqual(try LegadoParser.parse(data: json).count, 1)
    }

    // MARK: 错误

    func testUTF8BOMIsTolerated() throws {
        let json = "[{\"bookSourceName\":\"带BOM\",\"bookSourceUrl\":\"https://bom.example\"}]"
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(json.utf8))

        let sources = try LegadoParser.parse(data: data)

        XCTAssertEqual(sources.count, 1)
        XCTAssertEqual(sources[0].name, "带BOM")
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try LegadoParser.parse(json: "这不是 JSON")) { error in
            XCTAssertEqual(error as? LegadoParserError, .invalidJSON)
        }
    }

    func testEmptyArrayThrows() {
        XCTAssertThrowsError(try LegadoParser.parse(json: "[]")) { error in
            XCTAssertEqual(error as? LegadoParserError, .empty)
        }
    }

    func testOnlyBlankEntriesThrows() {
        XCTAssertThrowsError(try LegadoParser.parse(json: "[{\"bookSourceName\":\"\",\"bookSourceUrl\":\"\"}]")) { error in
            XCTAssertEqual(error as? LegadoParserError, .empty)
        }
    }
}
