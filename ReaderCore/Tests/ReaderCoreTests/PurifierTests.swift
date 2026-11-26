import XCTest
@testable import ReaderCore

final class PurifierTests: XCTestCase {

    func testExtractsPurifySegmentsFromRule() {
        let rules = Purifier.extractRules(from: "id.content@html&&##广告##&&##最新网址##")
        XCTAssertEqual(rules, ["##广告##", "##最新网址##"])
    }

    func testExtractReturnsEmptyWhenNoPurifySegment() {
        XCTAssertTrue(Purifier.extractRules(from: "id.content@html").isEmpty)
        XCTAssertTrue(Purifier.extractRules(from: "").isEmpty)
    }

    func testRemovesMatchedTextAndCountsHits() {
        let purifier = Purifier(rules: ["##广告##"])
        let result = purifier.apply(to: "第一段广告第二段广告结尾")
        XCTAssertEqual(result.text, "第一段第二段结尾")
        XCTAssertEqual(result.hitCount, 2, "命中数要能对比开关前后")
    }

    func testReplacesWithTemplate() {
        let purifier = Purifier(rules: ["##(\\d+)岁##$1 岁##"])
        let result = purifier.apply(to: "他今年 18岁")
        XCTAssertEqual(result.text, "他今年 18 岁")
        XCTAssertEqual(result.hitCount, 1)
    }

    func testDisabledPurifierLeavesTextUntouched() {
        let purifier = Purifier(isEnabled: false, rules: ["##广告##"])
        let result = purifier.apply(to: "有广告")
        XCTAssertEqual(result.text, "有广告")
        XCTAssertEqual(result.hitCount, 0)
    }

    func testNoMatchCountsZero() {
        let result = Purifier(rules: ["##不存在的词##"]).apply(to: "干净正文")
        XCTAssertEqual(result.text, "干净正文")
        XCTAssertEqual(result.hitCount, 0)
    }

    func testInvalidRegexIsSkipped() {
        let result = Purifier(rules: ["##([##"]).apply(to: "正文")
        XCTAssertEqual(result.text, "正文")
        XCTAssertEqual(result.hitCount, 0)
    }

    func testMultipleRulesApplyInOrder() {
        let purifier = Purifier(rules: ["##广告##", "##水印##"])
        let result = purifier.apply(to: "广告正文水印")
        XCTAssertEqual(result.text, "正文")
        XCTAssertEqual(result.hitCount, 2)
    }

    func testEmptyTextIsSafe() {
        let result = Purifier(rules: ["##广告##"]).apply(to: "")
        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.hitCount, 0)
    }
}
