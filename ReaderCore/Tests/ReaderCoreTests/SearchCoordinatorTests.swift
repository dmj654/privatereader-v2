import XCTest
@testable import ReaderCore

final class SearchCoordinatorTests: XCTestCase {

    private func makeCoordinator() -> SearchCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return SearchCoordinator(client: SourceClient(session: URLSession(configuration: config)),
                                 perSourceTimeout: 5)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.routes = [:]
    }

    private func source(id: String, path: String, enabled: Bool = true) -> LegadoSource {
        LegadoSource(
            id: id,
            name: id,
            url: "https://example.com",
            enabled: enabled,
            searchUrl: path,
            ruleSearch: SearchRule(bookList: "class.item", name: "tag.a@text", bookUrl: "tag.a@href")
        )
    }

    func testEmitsOneResultPerSourceAndIsolatesFailures() async {
        let html = "<html><body><div class=\"item\"><a href=\"/b/1\">书</a></div></body></html>"
        MockURLProtocol.routes["/ok"] = (200, Data(html.utf8), "text/html; charset=utf-8")
        // /bad 不配置 → 404

        var results: [SourceSearchResult] = []
        let stream = await makeCoordinator().search(
            sources: [source(id: "ok", path: "/ok"), source(id: "bad", path: "/bad")],
            key: "关键词"
        )
        for await result in stream {
            results.append(result)
        }

        XCTAssertEqual(results.count, 2, "每个源都要有一条结果，成功的失败的都算")
        let ok = results.first { $0.source.id == "ok" }
        let bad = results.first { $0.source.id == "bad" }
        XCTAssertEqual(ok?.books.count, 1)
        XCTAssertNil(ok?.errorText)
        XCTAssertNotNil(bad?.errorText, "一个源失败不能影响另一个")
        XCTAssertEqual(bad?.books.count, 0)
    }

    func testDisabledSourcesAreSkipped() async {
        let html = "<html><body><div class=\"item\"><a href=\"/b/1\">书</a></div></body></html>"
        MockURLProtocol.routes["/a"] = (200, Data(html.utf8), "text/html; charset=utf-8")
        MockURLProtocol.routes["/b"] = (200, Data(html.utf8), "text/html; charset=utf-8")

        var results: [SourceSearchResult] = []
        let stream = await makeCoordinator().search(
            sources: [source(id: "a", path: "/a"),
                      source(id: "b", path: "/b", enabled: false)],
            key: "x"
        )
        for await result in stream { results.append(result) }

        XCTAssertEqual(results.map(\.source.id), ["a"])
    }

    func testEmptySourceListFinishesImmediately() async {
        var results: [SourceSearchResult] = []
        let stream = await makeCoordinator().search(sources: [] as [LegadoSource], key: "x")
        for await result in stream { results.append(result) }
        XCTAssertTrue(results.isEmpty)
    }

    func testTimeoutProducesFailureResult() async {
        // 用一个永不返回的路由模拟慢源
        MockURLProtocol.routes["/slow"] = (200, Data("<html></html>".utf8), "text/html")
        let coordinator = SearchCoordinator(
            client: SourceClient(session: {
                let config = URLSessionConfiguration.ephemeral
                config.protocolClasses = [DelayURLProtocol.self]
                return URLSession(configuration: config)
            }()),
            perSourceTimeout: 0.2
        )

        var results: [SourceSearchResult] = []
        let stream = await coordinator.search(sources: [source(id: "slow", path: "/slow")], key: "x")
        for await result in stream { results.append(result) }

        XCTAssertEqual(results.count, 1)
        XCTAssertNotNil(results[0].errorText, "超时要作为一种失败结果返回，不能把整页卡住")
    }

    func testDirectIDModeDoesNotFallbackToKeywordSearch() async {
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
        let target = SearchTarget.venera(VeneraSource(
            id: "v", key: "probe", name: "Venera 探针", js: script
        ))

        var results: [SourceSearchResult] = []
        let stream = await makeCoordinator().search(sources: [target], key: "12345", directID: true)
        for await result in stream { results.append(result) }

        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].books.isEmpty, "选中源编号失败时不能返回普通搜索结果")
        XCTAssertTrue(results[0].errorText?.contains("编号直达失败") == true,
                      "错误要说清是编号直达失败，实际：\(results[0].errorText ?? "nil")")
    }
}

/// 延迟返回的协议，用来验证总超时。
/// 用延迟而不是"永不返回"，是为了让取消后子任务能自然结束，测试不会挂住。
final class DelayURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Thread.sleep(forTimeInterval: 1.0)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
