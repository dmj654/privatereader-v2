import XCTest
@testable import ReaderCore

/// 这组测试不联网，只验证 JavaScriptCore 运行时本身：
/// async/await 能不能推进、Swift 桥返回的数组/字符串能不能被 JS 继续使用、
/// Venera 的 ComicSource 约定能不能被实例化。
final class VeneraRuntimeTests: XCTestCase {

    private func source(_ script: String, key: String = "probe") -> VeneraSource {
        VeneraSource(id: key, key: key, name: "Probe", js: script)
    }

    func testSearchDetailAndPagesThroughJavaScriptCore() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            search = {
                load: async (keyword, options, page) => ({
                    comics: [{
                        id: "c1",
                        title: keyword,
                        subTitle: "作者",
                        cover: "",
                        tags: ["测试"],
                        description: "简介"
                    }],
                    maxPage: 1
                })
            }
            comic = {
                loadInfo: async (id) => ({
                    title: "详情标题",
                    cover: "",
                    description: "详情简介",
                    tags: { "作者": ["作者"] },
                    chapters: new Map([["e1", "第一话"], ["e2", "第二话"]])
                }),
                loadEp: async (comicId, epId) => ({
                    images: ["https://example.com/1.jpg", "https://example.com/2.jpg"]
                })
            }
        }
        """
        let src = source(script)

        let books = try await runtime.search(source: src, keyword: "海贼")
        XCTAssertEqual(books.count, 1)
        XCTAssertEqual(books.first?.name, "海贼")
        XCTAssertEqual(books.first?.bookUrl, "c1")

        let detail = try await runtime.detail(source: src, comicId: "c1")
        XCTAssertEqual(detail.title, "详情标题")
        XCTAssertEqual(detail.chapters.map(\.name), ["第一话", "第二话"])
        XCTAssertEqual(detail.chapters.map(\.url), ["e1", "e2"])

        let pages = try await runtime.pages(source: src, comicId: "c1", epId: "e1")
        XCTAssertEqual(pages.count, 2)
    }

    func testConvertAndHtmlBridge() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            search = {
                load: async () => ({
                    comics: [{
                        id: Convert.hmacString(
                            Convert.decodeBase64("M2FmMDg1OTAzMTEwMzJlZmUwNjYwNTUwYTA1NjNhNTM="),
                            Convert.encodeUtf8("1700000000"),
                            "sha256"
                        ),
                        title: new HtmlDocument("<div class=\\"x\\">你好</div>")
                                    .querySelector("div.x").text,
                        tags: [],
                        description: ""
                    }],
                    maxPage: 1
                })
            }
        }
        """
        let books = try await runtime.search(source: source(script), keyword: "k")
        let item = try XCTUnwrap(books.first)
        XCTAssertEqual(item.name, "你好")
        // 同一套 Python 签名验证里用过的固定输入，结果应稳定。
        XCTAssertEqual(item.bookUrl.count, 64)
        XCTAssertTrue(item.bookUrl.allSatisfy { $0.isHexDigit })
    }
}
