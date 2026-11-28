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

    func testExploreSectionsPreserveOrderAndMapToBooks() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            explore = [{
                title: "首页",
                type: "singlePageWithMultiPart",
                load: async () => ({
                    "推荐": [
                        { id: "r1", title: "推荐漫画", subTitle: "作者甲", cover: "https://example.com/r1.jpg", tags: ["热血"] }
                    ],
                    "热门": [
                        { id: "h1", title: "热门漫画", subTitle: "作者乙", cover: "", tags: [] },
                        { id: "h2", title: "热门第二本", subTitle: "作者丙", cover: "", tags: [] }
                    ]
                })
            }]
        }
        """
        let src = source(script)

        let pages = try await runtime.explorePages(source: src)
        XCTAssertEqual(pages.map(\.title), ["首页"])
        XCTAssertEqual(pages.first?.type, "singlePageWithMultiPart")

        let page = try XCTUnwrap(pages.first)
        let sections = try await runtime.explore(source: src, page: page)
        XCTAssertEqual(sections.map(\.title), ["推荐", "热门"], "栏目顺序必须和源返回的 JSON 一致")
        XCTAssertEqual(sections[0].books.first?.name, "推荐漫画")
        XCTAssertEqual(sections[0].books.first?.author, "作者甲")
        XCTAssertEqual(sections[0].books.first?.bookUrl, "r1")
        XCTAssertEqual(sections[1].books.count, 2)
    }

    func testChapterCommentsThroughJavaScriptCore() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            comic = {
                loadChapterComments: async (comicId, epId, page) => ({
                    comments: [{
                        userName: "读者甲",
                        avatar: "https://example.com/a.jpg",
                        content: "这话很好看 (" + comicId + ":" + epId + " 第" + page + "页)",
                        time: "2026-11-27",
                        replyCount: 3,
                        id: "c1"
                    }],
                    maxPage: 2
                })
            }
        }
        """
        let src = source(script)

        let result = try await runtime.chapterComments(
            source: src,
            comicId: "comic-1",
            epId: "ep-1",
            page: 1
        )
        XCTAssertEqual(result.maxPage, 2)
        XCTAssertEqual(result.comments.count, 1)
        XCTAssertEqual(result.comments[0].userName, "读者甲")
        XCTAssertEqual(result.comments[0].content, "这话很好看 (comic-1:ep-1 第1页)")
        XCTAssertEqual(result.comments[0].replyCount, 3)
    }

    func testConvertAndHtmlBridge() async throws {        let runtime = VeneraRuntime()
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

    /// 禁漫天堂这类源声明 idMatch 后，纯数字或 jm+数字会直接走详情，
    /// 不再被普通搜索吞掉；非编号关键词仍然走 search.load。
    func testSearchByIDUsesSourceIDMatch() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            idMatch = "^(\\\\d+|jm\\\\d+)$"
            search = {
                load: async (keyword, options, page) => ({
                    comics: [{
                        id: "normal",
                        title: keyword,
                        subTitle: "搜索作者",
                        cover: "",
                        description: "",
                        tags: []
                    }],
                    maxPage: 1
                })
            }
            comic = {
                loadInfo: async (id) => ({
                    title: "编号作品 " + id,
                    cover: "https://example.com/cover.jpg",
                    description: "编号简介",
                    tags: { "Author": ["作者甲"], "Tag": ["标签乙"] },
                    chapters: new Map([["e1", "第一话"], ["e2", "第二话"]])
                }),
                loadEp: async (comicId, epId) => ({ images: [] })
            }
        }
        """
        let src = source(script)

        let numeric = try await runtime.search(source: src, keyword: "12345")
        XCTAssertEqual(numeric.count, 1)
        XCTAssertEqual(numeric.first?.bookUrl, "12345")
        XCTAssertEqual(numeric.first?.name, "编号作品 12345")
        XCTAssertEqual(numeric.first?.author, "作者甲")
        XCTAssertEqual(numeric.first?.lastChapter, "ID 直达 · 共 2 话")

        // 大写前缀也要能用；JM 的 loadInfo 只认小写 jm。
        let prefixed = try await runtime.search(source: src, keyword: "JM987")
        XCTAssertEqual(prefixed.first?.bookUrl, "jm987")
        XCTAssertEqual(prefixed.first?.name, "编号作品 jm987")

        let normal = try await runtime.search(source: src, keyword: "斗破")
        XCTAssertEqual(normal.first?.bookUrl, "normal")
        XCTAssertEqual(normal.first?.name, "斗破")
    }

    /// 选中某个源后，编号无效/详情失败必须明确报错，不能悄悄退回关键词搜索。
    func testSearchByIDDoesNotSilentlyFallback() async throws {
        let runtime = VeneraRuntime()
        let script = """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            idMatch = "^(\\\\d+|jm\\\\d+)$"
            search = {
                load: async (keyword, options, page) => ({
                    comics: [{
                        id: "fallback",
                        title: keyword,
                        subTitle: "",
                        cover: "",
                        description: "",
                        tags: []
                    }],
                    maxPage: 1
                })
            }
            comic = {
                loadInfo: async (id) => { throw "详情接口失败"; },
                loadEp: async (comicId, epId) => ({ images: [] })
            }
        }
        """
        let src = source(script)

        do {
            _ = try await runtime.searchByID(source: src, keyword: "12345")
            XCTFail("编号详情失败时 searchByID 不应返回普通搜索结果")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("编号直达失败"),
                          "错误要说清是编号直达失败，实际：\(error.localizedDescription)")
        }

        // 普通全源搜索仍保留 1.9.3 的回退能力。
        let normal = try await runtime.search(source: src, keyword: "12345")
        XCTAssertEqual(normal.first?.bookUrl, "fallback")
    }

    func testVeneraIDMatchExtraction() {
        let script = """
        class Probe extends ComicSource {
            idMatch = "^(\\\\d+|jm\\\\d+)$"
        }
        """
        let src = source(script)
        XCTAssertEqual(VeneraIDMatch.pattern(from: src), #"^(\d+|jm\d+)$"#)
        XCTAssertEqual(VeneraIDMatch.id(from: "12345", source: src), "12345")
        XCTAssertEqual(VeneraIDMatch.id(from: "jm987", source: src), "jm987")
        XCTAssertNil(VeneraIDMatch.id(from: "斗破", source: src))

        // minify 后 idMatch 挤在分号/大括号后面，也要能读到。
        let minified = """
        class Probe extends ComicSource{name="P";idMatch="^(\\\\d+|jm\\\\d+)$";search={load:async()=>({comics:[],maxPage:1})}}
        """
        let minifiedSource = source(minified)
        XCTAssertEqual(VeneraIDMatch.pattern(from: minifiedSource), #"^(\d+|jm\d+)$"#)
        XCTAssertEqual(VeneraIDMatch.id(from: "456", source: minifiedSource), "456")
    }
}
