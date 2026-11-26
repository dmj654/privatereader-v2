import XCTest
@testable import ReaderCore

// MARK: - Mock 网络

final class MockURLProtocol: URLProtocol {
    /// URL path -> (status, body, contentType)
    static var routes: [String: (Int, Data, String?)] = [:]
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        let path = request.url?.path ?? ""
        guard let route = Self.routes[path] else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("not found".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        var headers: [String: String] = [:]
        if let contentType = route.2 { headers["Content-Type"] = contentType }
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: route.0,
                                       httpVersion: nil,
                                       headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: route.1)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class SourceClientTests: XCTestCase {

    private func makeClient() -> SourceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return SourceClient(session: URLSession(configuration: config))
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.routes = [:]
        MockURLProtocol.lastRequest = nil
    }

    // MARK: 搜索

    func testSearchParsesBooksAndResolvesURLs() async throws {
        let html = """
        <html><body>
        <ul class="result">
          <li><h3><a href="/book/1">斗破苍穹</a></h3><span class="author">天蚕土豆</span></li>
          <li><h3><a href="/book/2">武动乾坤</a></h3><span class="author">天蚕土豆</span></li>
        </ul>
        </body></html>
        """
        MockURLProtocol.routes["/search"] = (200, Data(html.utf8), "text/html; charset=utf-8")

        let source = LegadoSource(
            id: "s1",
            name: "测试源",
            url: "https://example.com",
            searchUrl: "/search?q={{key}}",
            ruleSearch: SearchRule(
                bookList: "class.result@tag.li",
                name: "tag.h3@text",
                author: "class.author@text",
                bookUrl: "tag.a@href"
            )
        )

        let books = try await makeClient().search(source: source, key: "斗破")
        XCTAssertEqual(books.count, 2)
        XCTAssertEqual(books[0].name, "斗破苍穹")
        XCTAssertEqual(books[0].author, "天蚕土豆")
        XCTAssertEqual(books[0].bookUrl, "https://example.com/book/1")
        XCTAssertEqual(books[1].name, "武动乾坤")
        XCTAssertEqual(books[0].sourceId, "s1")
    }

    func testSearchEncodesKeyword() async throws {
        MockURLProtocol.routes["/search"] = (200, Data("<html></html>".utf8), "text/html")
        let source = LegadoSource(id: "s", name: "n", url: "https://example.com",
                                  searchUrl: "/search?q={{key}}",
                                  ruleSearch: SearchRule(bookList: "class.x", name: "tag.a@text"))
        _ = try? await makeClient().search(source: source, key: "斗破 苍穹")
        let query = MockURLProtocol.lastRequest?.url?.query ?? ""
        XCTAssertTrue(query.contains("%E6%96%97"), "中文关键词必须编码：\(query)")
    }

    func testSearchWithoutRuleThrows() async {
        let source = LegadoSource(id: "s", name: "n", url: "https://example.com")
        do {
            _ = try await makeClient().search(source: source, key: "x")
            XCTFail("空搜索规则应当抛错")
        } catch {
            XCTAssertEqual(error as? SourceError, .emptyRule("搜索"))
        }
    }

    // MARK: 目录

    func testChaptersFollowsTocRule() async throws {
        let detail = """
        <html><body><a class="toc" href="/toc">目录</a></body></html>
        """
        let toc = """
        <html><body><ul class="chapters">
          <li><a href="/c/1">第一章 开始</a></li>
          <li><a href="/c/2">第二章 继续</a></li>
        </ul></body></html>
        """
        MockURLProtocol.routes["/book/1"] = (200, Data(detail.utf8), "text/html; charset=utf-8")
        MockURLProtocol.routes["/toc"] = (200, Data(toc.utf8), "text/html; charset=utf-8")

        let source = LegadoSource(
            id: "s", name: "源", url: "https://example.com",
            ruleBookInfo: BookInfoRule(tocUrl: "class.toc@href"),
            ruleToc: TocRule(chapterList: "class.chapters@tag.li",
                             chapterName: "tag.a@text",
                             chapterUrl: "tag.a@href")
        )
        let book = OnlineBook(sourceId: "s", name: "书", bookUrl: "https://example.com/book/1")

        let chapters = try await makeClient().chapters(source: source, book: book)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0].name, "第一章 开始")
        XCTAssertEqual(chapters[0].url, "https://example.com/c/1")
    }

    // MARK: 正文

    func testContentConvertsHTMLToParagraphsAndPurifies() async throws {
        let html = """
        <html><body><div id="content">
          第一段<br/>第二行
          <p>第二段</p>
          <span>广告</span>
        </div></body></html>
        """
        MockURLProtocol.routes["/c/1"] = (200, Data(html.utf8), "text/html; charset=utf-8")

        let source = LegadoSource(
            id: "s", name: "源", url: "https://example.com",
            ruleContent: ContentRule(content: "id.content@html&&##广告##")
        )
        let chapter = OnlineChapter(name: "第一章", url: "https://example.com/c/1")

        let text = try await makeClient().content(source: source, chapter: chapter)
        XCTAssertTrue(text.contains("第一段"))
        XCTAssertTrue(text.contains("第二行"))
        XCTAssertTrue(text.contains("第二段"))
        XCTAssertFalse(text.contains("广告"), "净化规则要生效：\(text)")
        XCTAssertTrue(text.contains("\n"), "段落之间要保留换行：\(text)")
    }

    // MARK: 编码

    func testGBKPageIsDecoded() async throws {
        let html = "<html><head><meta charset=\"gbk\"></head><body><div id=\"c\">中文正文</div></body></html>"
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        ))
        let data = try XCTUnwrap(html.data(using: gbk))
        MockURLProtocol.routes["/c/1"] = (200, data, "text/html")

        let source = LegadoSource(id: "s", name: "源", url: "https://example.com",
                                  ruleContent: ContentRule(content: "id.c@text"))
        let chapter = OnlineChapter(name: "章", url: "https://example.com/c/1")

        let text = try await makeClient().content(source: source, chapter: chapter)
        XCTAssertEqual(text, "中文正文", "GBK 页面不能乱码")
    }

    // MARK: 错误

    func testHTTPErrorIsReported() async {
        let source = LegadoSource(id: "s", name: "源", url: "https://example.com",
                                  ruleContent: ContentRule(content: "id.c@text"))
        let chapter = OnlineChapter(name: "章", url: "https://example.com/missing")
        do {
            _ = try await makeClient().content(source: source, chapter: chapter)
            XCTFail("404 应当抛错")
        } catch {
            XCTAssertEqual(error as? SourceError, .http(404))
        }
    }

    func testEmptyContentThrows() async {
        MockURLProtocol.routes["/c/1"] = (200, Data("<html><body></body></html>".utf8), "text/html")
        let source = LegadoSource(id: "s", name: "源", url: "https://example.com",
                                  ruleContent: ContentRule(content: "id.none@text"))
        let chapter = OnlineChapter(name: "章", url: "https://example.com/c/1")
        do {
            _ = try await makeClient().content(source: source, chapter: chapter)
            XCTFail("没取到正文应当抛错")
        } catch {
            XCTAssertEqual(error as? SourceError, .emptyContent)
        }
    }

    // MARK: 纯文本

    func testPlainTextCollapsesBlankLines() {
        let html = "<p>一</p><br/><br/><br/><p>二</p>"
        let text = SourceClient.plainText(from: html)
        XCTAssertEqual(text, "一\n二")
    }

    func testHeaderParsing() {
        let headers = SourceClient.parseHeader("{\"Referer\":\"https://a.com\",\"X-Test\":\"1\"}")
        XCTAssertEqual(headers["Referer"], "https://a.com")
        XCTAssertEqual(SourceClient.parseHeader(nil).isEmpty, true)
        XCTAssertEqual(SourceClient.parseHeader("不是 JSON").isEmpty, true)
    }

    // MARK: 发现

    private func exploreSource() -> LegadoSource {
        LegadoSource(
            id: "s1",
            name: "发现源",
            url: "https://example.com",
            exploreUrl: "周榜::https://example.com/week?page={{page}}\n分类::/sort/1",
            ruleExplore: SearchRule(
                bookList: ".item",
                name: ".title@text",
                author: ".author@text",
                bookUrl: ".title@href"
            )
        )
    }

    func testCategoriesParseBothSeparators() {
        let categories = makeClient().categories(source: exploreSource())

        XCTAssertEqual(categories.map(\.name), ["周榜", "分类"])
        XCTAssertEqual(categories.count, 2)
        XCTAssertEqual(categories.first?.url, "https://example.com/week?page={{page}}")
        XCTAssertEqual(categories.last?.url, "/sort/1")
    }

    func testCategoriesEmptyWhenNoExploreUrl() {
        let source = LegadoSource(id: "s", name: "无发现", url: "https://example.com")
        XCTAssertTrue(makeClient().categories(source: source).isEmpty)
    }

    func testExploreParsesBookListAndReplacesPage() async throws {
        MockURLProtocol.routes = [
            "/week": (200, Data("""
            <div class="item"><a class="title" href="/b/1">书一</a><span class="author">作者一</span></div>
            <div class="item"><a class="title" href="/b/2">书二</a><span class="author">作者二</span></div>
            """.utf8), "text/html; charset=utf-8")
        ]
        defer { MockURLProtocol.routes = [:] }

        let books = try await makeClient().explore(
            source: exploreSource(),
            category: ExploreCategory(name: "周榜", url: "https://example.com/week?page={{page}}"),
            page: 2
        )

        XCTAssertEqual(books.map(\.name), ["书一", "书二"])
        XCTAssertEqual(books[0].bookUrl, "https://example.com/b/1")
        XCTAssertTrue(MockURLProtocol.lastRequest?.url?.query?.contains("page=2") == true,
                      "页码要替换进分类地址")
    }

    func testExploreWithoutRuleThrows() async {
        let source = LegadoSource(id: "s", name: "空", url: "https://example.com")
        do {
            _ = try await makeClient().explore(
                source: source,
                category: ExploreCategory(name: "全部", url: "https://example.com/all")
            )
            XCTFail("没有发现规则应当报错")
        } catch {
            // 预期
        }
    }

    // MARK: 漫画

    func testImageURLsFromHTML() {
        let html = """
        <div id="content">
          <img src="/img/1.jpg">
          <img src="" data-src="/img/2.jpg">
          <img data-original="https://cdn.example.com/3.jpg">
          <img src="data:image/gif;base64,xxx">
        </div>
        """

        let urls = SourceClient.imageURLs(in: html, base: "https://m.example.com/ch/1")

        XCTAssertEqual(urls, [
            "https://m.example.com/img/1.jpg",
            "https://m.example.com/img/2.jpg",
            "https://cdn.example.com/3.jpg"
        ])
    }

    func testImageURLsFromPlainList() {
        let raw = "https://a.example/1.jpg\n/img/2.jpg, /img/3.png"

        let urls = SourceClient.imageURLs(in: raw, base: "https://m.example.com")

        XCTAssertEqual(urls, [
            "https://a.example/1.jpg",
            "https://m.example.com/img/2.jpg",
            "https://m.example.com/img/3.png"
        ])
    }

    func testComicPagesParsesChapterHTML() async throws {
        MockURLProtocol.routes = [
            "/ch/1": (200, Data("""
            <div id="content"><img src="/p/1.jpg"><img data-src="/p/2.jpg"></div>
            """.utf8), "text/html; charset=utf-8")
        ]
        defer { MockURLProtocol.routes = [:] }

        let source = LegadoSource(
            id: "comic",
            name: "漫画源",
            url: "https://m.example.com",
            type: 2,
            ruleContent: ContentRule(content: "#content@html")
        )

        let urls = try await makeClient().comicPages(
            source: source,
            chapter: OnlineChapter(name: "第1话", url: "https://m.example.com/ch/1")
        )

        XCTAssertEqual(urls, [
            "https://m.example.com/p/1.jpg",
            "https://m.example.com/p/2.jpg"
        ])
    }

    func testImageHeadersIncludeRefererAndSourceHeader() {
        let source = LegadoSource(
            id: "comic",
            name: "漫画源",
            url: "https://m.example.com",
            header: "{\"X-Test\":\"1\"}"
        )

        let headers = makeClient().imageHeaders(source: source)

        XCTAssertEqual(headers["Referer"], "https://m.example.com")
        XCTAssertEqual(headers["X-Test"], "1")
        XCTAssertNotNil(headers["User-Agent"])
    }

    // MARK: 兼容性

    func testRequestSpecParsesLegadoPOSTSuffix() {
        let raw = "https://api.example/search,{\"method\":\"POST\",\"body\":\"q={{key}}\",\"headers\":{\"X-Token\":\"abc\"}}"

        let spec = SourceClient.requestSpec(raw)

        XCTAssertEqual(spec.url, "https://api.example/search")
        XCTAssertEqual(spec.method, "POST")
        XCTAssertEqual(spec.body, "q={{key}}")
        XCTAssertEqual(spec.headers["X-Token"], "abc")
    }

    func testPlainURLStaysGET() {
        let spec = SourceClient.requestSpec("https://api.example/list?page=2")
        XCTAssertEqual(spec.method, "GET")
        XCTAssertNil(spec.body)
    }

    func testSearchUsesPOSTWhenSpecified() async throws {
        MockURLProtocol.routes = [
            "/search": (200, Data("<div class=\"item\"><a class=\"name\" href=\"/b/1\">书</a></div>".utf8), "text/html")
        ]
        defer { MockURLProtocol.routes = [:] }

        let source = LegadoSource(
            id: "post",
            name: "POST 源",
            url: "https://api.example",
            searchUrl: "https://api.example/search,{\"method\":\"POST\",\"body\":\"q={{key}}\"}",
            ruleSearch: SearchRule(bookList: "class.item", name: "class.name@text", bookUrl: "class.name@href")
        )

        _ = try await makeClient().search(source: source, key: "剑来")

        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "POST")
    }

    func testChaptersFollowNextTocUrl() async throws {
        MockURLProtocol.routes = [
            "/toc1": (200, Data("""
            <div id="list"><dl><dd><a href="/c/1">第一章</a></dd></dl></div>
            <a class="next" href="/toc2">下一页</a>
            """.utf8), "text/html"),
            "/toc2": (200, Data("""
            <div id="list"><dl><dd><a href="/c/2">第二章</a></dd></dl></div>
            """.utf8), "text/html")
        ]
        defer { MockURLProtocol.routes = [:] }

        let source = LegadoSource(
            id: "toc",
            name: "目录分页",
            url: "https://a.example",
            ruleToc: TocRule(chapterList: "#list dd", chapterName: "a@text",
                             chapterUrl: "a@href", nextTocUrl: "a.next@href")
        )
        let book = OnlineBook(sourceId: "toc", name: "书", bookUrl: "https://a.example/toc1")

        let chapters = try await makeClient().chapters(source: source, book: book)

        XCTAssertEqual(chapters.map(\.name), ["第一章", "第二章"])
    }

    func testContentFollowNextContentUrl() async throws {
        MockURLProtocol.routes = [
            "/c/1": (200, Data("""
            <div id="content">第一页</div><a class="next" href="/c/2">下一页</a>
            """.utf8), "text/html"),
            "/c/2": (200, Data("<div id=\"content\">第二页</div>".utf8), "text/html")
        ]
        defer { MockURLProtocol.routes = [:] }

        let source = LegadoSource(
            id: "content",
            name: "正文分页",
            url: "https://a.example",
            ruleContent: ContentRule(content: "#content@text", nextContentUrl: "a.next@href")
        )
        let chapter = OnlineChapter(name: "第一章", url: "https://a.example/c/1")

        let text = try await makeClient().content(source: source, chapter: chapter)

        XCTAssertTrue(text.contains("第一页"))
        XCTAssertTrue(text.contains("第二页"))
    }
}
