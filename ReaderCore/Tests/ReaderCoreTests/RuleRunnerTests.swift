import XCTest
@testable import ReaderCore

final class RuleRunnerTests: XCTestCase {

    private let html = """
    <html><body>
      <div class="book-list">
        <div class="book-item">
          <h3><a href="/book/1">书名一</a></h3>
          <span class="author">作者甲</span>
          <img src="" data-src="/cover/1.jpg" />
        </div>
        <div class="book-item">
          <h3><a href="/book/2">书名二</a></h3>
          <span class="author">作者乙</span>
        </div>
      </div>
      <div id="content">正文<span>广告</span>内容</div>
      <a class="next" href="/next">下一页</a>
      <p class="intro">第一行<br/>第二行</p>
    </body></html>
    """

    // MARK: CSS

    func testSelectsTextFromNestedSelector() {
        XCTAssertEqual(RuleRunner.string("class.book-item@tag.h3@text", html: html), "书名一")
    }

    func testIndexPicksSecondItem() {
        XCTAssertEqual(RuleRunner.string("class.book-item.1@tag.h3@text", html: html), "书名二")
    }

    func testNegativeIndexPicksLast() {
        XCTAssertEqual(RuleRunner.string("class.book-item.-1@tag.h3@text", html: html), "书名二")
    }

    func testIdAndHtmlAttribute() {
        XCTAssertEqual(RuleRunner.string("id.content@text", html: html), "正文广告内容")
        let inner = RuleRunner.string("id.content@html", html: html)
        XCTAssertTrue(inner.contains("<span>广告</span>"), "html 属性要保留标签：\(inner)")
    }

    func testOwnTextExcludesChildren() {
        let text = RuleRunner.string("id.content@ownText", html: html)
        XCTAssertFalse(text.contains("广告"), "ownText 不包含子元素文字：\(text)")
    }

    func testRelativeHrefIsResolved() {
        XCTAssertEqual(
            RuleRunner.string("class.next@href", html: html, baseUrl: "https://example.com/list/1"),
            "https://example.com/next"
        )
    }

    func testLazyImageFallsBackToDataSrc() {
        XCTAssertEqual(
            RuleRunner.string("class.book-item@tag.img@src", html: html, baseUrl: "https://example.com"),
            "https://example.com/cover/1.jpg"
        )
    }

    func testMissingSelectorReturnsEmpty() {
        XCTAssertEqual(RuleRunner.string("class.not-there@text", html: html), "")
    }

    // MARK: 列表

    func testElementsReturnsAllMatches() {
        let items = RuleRunner.elements("class.book-item", html: html)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("书名一"))
        XCTAssertTrue(items[1].contains("书名二"))
    }

    func testElementsWithIndex() {
        let items = RuleRunner.elements("class.book-item.0", html: html)
        XCTAssertEqual(items.count, 1)
        XCTAssertTrue(items[0].contains("书名一"))
    }

    // MARK: 净化与串联

    func testPurifyRemovesMatchedText() {
        XCTAssertEqual(RuleRunner.string("id.content@text##广告##", html: html), "正文内容")
    }

    func testPurifyWithReplacement() {
        XCTAssertEqual(RuleRunner.string("id.content@text##广告##推广", html: html), "正文推广内容")
    }

    func testAndChainsPurifyAfterSelection() {
        XCTAssertEqual(RuleRunner.string("id.content@text&&##广告##", html: html), "正文内容")
    }

    func testDoublePipeFallsBack() {
        XCTAssertEqual(RuleRunner.string("class.missing@text||id.content@text", html: html), "正文广告内容")
    }

    func testEmptyRuleReturnsEmpty() {
        XCTAssertEqual(RuleRunner.string("", html: html), "")
    }

    // MARK: 模板

    func testVariableReplacement() {
        let url = RuleRunner.string("/search?q={{key}}&p={{page}}",
                                    html: "",
                                    variables: ["key": "斗破", "page": "2"])
        XCTAssertEqual(url, "/search?q=斗破&p=2")
    }

    func testUnresolvedVariableStaysLiteral() {
        XCTAssertEqual(RuleRunner.string("/s?q={{key}}", html: "", variables: [:]), "/s?q={{key}}")
    }

    // MARK: URL

    func testResolveAbsoluteURLUnchanged() {
        XCTAssertEqual(
            RuleRunner.resolveURL("https://a.com/x", baseUrl: "https://b.com"),
            "https://a.com/x"
        )
    }

    func testResolveEmptyURL() {
        XCTAssertEqual(RuleRunner.resolveURL("", baseUrl: "https://b.com"), "")
    }

    // MARK: JSONPath（基础）

    func testJSONPathString() {
        XCTAssertEqual(RuleRunner.string("$.name", html: "{\"name\":\"测试书\"}"), "测试书")
    }

    func testJSONPathNestedAndIndex() {
        let json = "{\"data\":{\"list\":[{\"title\":\"甲\"},{\"title\":\"乙\"}]}}"
        XCTAssertEqual(RuleRunner.string("$.data.list[1].title", html: json), "乙")
    }

    func testJSONPathWildcardElements() {
        let json = "{\"list\":[{\"name\":\"甲\"},{\"name\":\"乙\"}]}"
        let items = RuleRunner.elements("$.list[*]", html: json)
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].contains("甲"))
    }
}
