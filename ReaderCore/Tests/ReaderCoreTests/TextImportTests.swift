import XCTest
@testable import ReaderCore

final class TextDecoderTests: XCTestCase {
    func testDecodesUTF8() throws {
        let text = "第一章 开始\n中文内容"
        let data = try XCTUnwrap(text.data(using: .utf8))
        let result = try XCTUnwrap(TextDecoder.decode(data))
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.encodingName, "UTF-8")
        XCTAssertFalse(result.isFallback)
    }

    func testFallsBackToGB18030() throws {
        let text = "第一章 开始\n这是一段中文。"
        let data = try XCTUnwrap(text.data(using: TextDecoder.gb18030))
        XCTAssertNil(String(data: data, encoding: .utf8), "GB18030 数据不应被误判为 UTF-8")

        let result = try XCTUnwrap(TextDecoder.decode(data))
        XCTAssertEqual(result.text, text)
        XCTAssertEqual(result.encodingName, "GB18030")
        XCTAssertTrue(result.isFallback)
    }

    func testStripsBOM() throws {
        let text = "\u{FEFF}第一章"
        let data = try XCTUnwrap(text.data(using: .utf8))
        let result = try XCTUnwrap(TextDecoder.decode(data))
        XCTAssertEqual(result.text, "第一章")
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(TextDecoder.decode(Data()))
    }
}

final class ChapterSplitterTests: XCTestCase {
    func testSplitsThreeChapters() {
        let text = """
        第一章 起
        内容一
        第二章 承
        内容二
        第三章 转
        内容三
        """
        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 3)
        XCTAssertEqual(chapters[0].title, "第一章 起")
        XCTAssertEqual(chapters[1].title, "第二章 承")
        XCTAssertEqual(chapters[0].body, "内容一")
        XCTAssertEqual(chapters[2].body, "内容三")
    }

    func testNoChapterMarkerFallsBackToSingle() {
        let text = "这是一段没有任何章节标记的文字。\n第二行。"
        let chapters = ChapterSplitter.split(text)
        XCTAssertEqual(chapters.count, 1)
        XCTAssertEqual(chapters[0].title, "正文")
    }

    func testHandlesChineseNumerals() {
        let text = "第一节 起\n一\n第二节 承\n二\n第三节 转\n三"
        XCTAssertEqual(ChapterSplitter.split(text).count, 3)
    }

    func testEmptyTextReturnsEmpty() {
        XCTAssertTrue(ChapterSplitter.split("   \n  ").isEmpty)
    }
}

final class TxtParserTests: XCTestCase {
    func testParsesThreeHundredChapters() throws {
        let url = try ImportFixtures.makeTxt(chapterCount: 300)
        let parsed = try TxtParser.parse(url: url)

        XCTAssertEqual(parsed.chapters.count, 300)
        XCTAssertEqual(parsed.chapters.first?.title, "第1章 标题1")
        XCTAssertEqual(parsed.chapters.last?.title, "第300章 标题300")
        XCTAssertEqual(parsed.title, "测试小说")
    }

    func testParsesGB18030File() throws {
        let url = try ImportFixtures.makeGB18030Txt()
        let parsed = try TxtParser.parse(url: url)
        XCTAssertEqual(parsed.chapters.count, 2)
        XCTAssertEqual(parsed.chapters[0].title, "第一章 开始")
        XCTAssertTrue(parsed.chapters[0].body.contains("中文"))
    }

    func testMissingFileThrows() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).txt")
        XCTAssertThrowsError(try TxtParser.parse(url: url))
    }
}

final class NaturalSortTests: XCTestCase {
    func testNumericOrdering() {
        let names = ["10.png", "2.png", "1.png"]
        XCTAssertEqual(NaturalSort.sorted(names), ["1.png", "2.png", "10.png"])
    }

    func testStableForEqualNames() {
        XCTAssertFalse(NaturalSort.isOrderedBefore("a.png", "a.png"))
        XCTAssertTrue(NaturalSort.isOrderedBefore("a1.png", "a2.png"))
    }
}
