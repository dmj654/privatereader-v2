import XCTest
@testable import ReaderCore

final class SourceHealthCheckerTests: XCTestCase {

    // MARK: 桩

    private func makeClient(_ protocolClass: URLProtocol.Type) -> SourceClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        return SourceClient(session: URLSession(configuration: config))
    }

    private func makeSource(enabled: Bool = true, searchRule: String = ".book") -> LegadoSource {
        LegadoSource(
            id: "s1",
            name: "测试源",
            url: "https://example.com",
            enabled: enabled,
            searchUrl: "https://example.com/search?q={{key}}",
            ruleSearch: SearchRule(
                bookList: searchRule,
                name: ".name@text",
                author: ".author@text",
                bookUrl: ".name@href"
            )
        )
    }

    private static let searchHTML = """
    <html><body>
      <div class="book"><a class="name" href="/b/1">剑来</a><span class="author">烽火</span></div>
      <div class="book"><a class="name" href="/b/2">剑徒之路</a><span class="author">惰堕</span></div>
    </body></html>
    """

    private static let detailHTML = """
    <html><body>
      <div class="title">剑来</div>
      <div class="author">烽火</div>
      <div class="chapter"><a href="/c/1">第一章</a></div>
      <div class="chapter"><a href="/c/2">第二章</a></div>
    </body></html>
    """

    private func makeDeepSource() -> LegadoSource {
        LegadoSource(
            id: "deep",
            name: "深度测试源",
            url: "https://example.com",
            enabled: true,
            searchUrl: "https://example.com/search?q={{key}}",
            ruleSearch: SearchRule(
                bookList: ".book",
                name: ".name@text",
                author: ".author@text",
                bookUrl: ".name@href"
            ),
            ruleBookInfo: BookInfoRule(
                name: ".title@text",
                author: ".author@text"
            ),
            ruleToc: TocRule(
                chapterList: ".chapter",
                chapterName: "tag.a@text",
                chapterUrl: "tag.a@href"
            )
        )
    }

    override func tearDown() {
        StaticURLProtocol.routes = [:]
        super.tearDown()
    }

    // MARK: 测试

    func testHealthySourceReportsTimingAndCount() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8")
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeSource())

        guard case .ok(let ms, let count) = status else {
            return XCTFail("应当正常，实际 \(status)")
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertEqual(count, 2, "两条搜索结果都要数进来")
        XCTAssertTrue(status.isHealthy)
    }

    func testDeepCheckVerifiesDetailAndToc() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8"),
            "/b/1": (200, Data(Self.detailHTML.utf8), "text/html; charset=utf-8"),
            "/b/2": (200, Data(Self.detailHTML.utf8), "text/html; charset=utf-8")
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeDeepSource(), timeout: 2, deep: true)

        guard case .okDeep(let ms, let count, let checked, let chapters) = status else {
            return XCTFail("深度检测应当通过搜索、详情、目录，实际 \(status)")
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(checked, 2, "默认应抽查前三条搜索结果；这里只有两条")
        XCTAssertEqual(chapters, 4, "两本样本的目录章节数都要累计")
        XCTAssertTrue(status.isHealthy)
    }

    func testDeepCheckMarksDetailFailureAsPartial() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8")
            // /b/1 不配置 → 404
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeDeepSource(), timeout: 2, deep: true)

        guard case .partial(let message) = status else {
            return XCTFail("搜索成功但详情失败应当标为部分可用，实际 \(status)")
        }
        XCTAssertTrue(message.contains("详情"), "错误要指出是详情阶段：\(message)")
        XCTAssertFalse(status.isDefiniteFailure, "详情失败不能直接当成可删除的失效源")
    }

    func testDeepCheckMarksEmptyTocAsPartial() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8"),
            "/b/1": (200, Data("<html><body><div class=\"title\">剑来</div></body></html>".utf8),
                     "text/html; charset=utf-8")
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeDeepSource(), timeout: 2, deep: true)

        guard case .partial(let message) = status else {
            return XCTFail("目录为空应当标为部分可用，实际 \(status)")
        }
        XCTAssertTrue(message.contains("目录"), "错误要指出是目录阶段：\(message)")
    }

    func testDeepCheckFailsWhenASecondSampleIsBroken() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8"),
            "/b/1": (200, Data(Self.detailHTML.utf8), "text/html; charset=utf-8")
            // /b/2 不配置 → 404
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeDeepSource(), timeout: 2, deep: true)

        guard case .partial(let message) = status else {
            return XCTFail("第二本样本详情失败也应标为部分可用，实际 \(status)")
        }
        XCTAssertTrue(message.contains("第 2 条"), "错误要指出是哪一条样本：\(message)")
        XCTAssertFalse(status.isDefiniteFailure)
    }

    func testDeepCheckRespectsSampleLimit() async {
        StaticURLProtocol.routes = [
            "/search": (200, Data(Self.searchHTML.utf8), "text/html; charset=utf-8"),
            "/b/1": (200, Data(Self.detailHTML.utf8), "text/html; charset=utf-8")
            // /b/2 不配置，但只抽查第一本时不应被它拖成 partial
        ]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeDeepSource(), timeout: 2, deep: true, deepSampleLimit: 1)

        guard case .okDeep(let ms, let count, let checked, let chapters) = status else {
            return XCTFail("只抽查一本时应当正常，实际 \(status)")
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertEqual(count, 2)
        XCTAssertEqual(checked, 1)
        XCTAssertEqual(chapters, 2)
    }

    func testDeepVeneraCheckVerifiesDetailAndToc() async {
        let script = makeVeneraDeepScript(loadInfoThrows: false)
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))
        let source = VeneraSource(id: "v-deep", key: "v-deep", name: "Venera 深度源", js: script)

        let status = await checker.check(source, keyword: "斗破", timeout: 3, deep: true)

        guard case .okDeep(let ms, let count, let checked, let chapters) = status else {
            return XCTFail("Venera 深度检测应当通过，实际 \(status)")
        }
        XCTAssertGreaterThanOrEqual(ms, 0)
        XCTAssertEqual(count, 1)
        XCTAssertEqual(checked, 1)
        XCTAssertEqual(chapters, 2)
    }

    func testDeepVeneraDetailFailureIsPartial() async {
        let script = makeVeneraDeepScript(loadInfoThrows: true)
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))
        let source = VeneraSource(id: "v-bad", key: "v-bad", name: "Venera 坏详情", js: script)

        let status = await checker.check(source, keyword: "斗破", timeout: 3, deep: true)

        guard case .partial(let message) = status else {
            return XCTFail("Venera 详情失败应当标为部分可用，实际 \(status)")
        }
        XCTAssertTrue(message.contains("详情"))
        XCTAssertFalse(status.isDefiniteFailure)
    }

    private func makeVeneraDeepScript(loadInfoThrows: Bool) -> String {
        """
        class Probe extends ComicSource {
            name = "Probe"
            key = "probe"
            version = "1.0"
            search = {
                load: async () => ({
                    comics: [{
                        id: "c1",
                        title: "斗破苍穹",
                        subTitle: "作者",
                        cover: "",
                        description: "",
                        tags: []
                    }],
                    maxPage: 1
                })
            }
            comic = {
                loadInfo: async (id) => {
                    \(loadInfoThrows ? "throw '详情接口失败';" : "")
                    return {
                        title: "斗破苍穹",
                        cover: "",
                        description: "",
                        tags: {},
                        chapters: new Map([["e1", "第一话"], ["e2", "第二话"]])
                    };
                },
                loadEp: async (comicId, epId) => ({ images: [] })
            }
        }
        """
    }

    func testSlowSourceTimesOutInsteadOfWaitingRequestTimeout() async {        let checker = SourceHealthChecker(client: makeClient(SlowURLProtocol.self))
        let started = Date()

        let status = await checker.check(makeSource(), timeout: 0.2)

        XCTAssertEqual(status, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "体检必须按自己的超时返回，不能等 URLSession 的 20 秒")
    }

    func testTimeoutIsRetriedWithLongerBudget() async {
        let checker = SourceHealthChecker(client: makeClient(SlowURLProtocol.self))
        let started = Date()

        // 第一轮 0.2 秒必超时，站点 1 秒才返回；第二轮给 2 秒，应当判正常。
        let status = await checker.check(makeSource(), timeout: 0.2, retryTimeout: 2)

        guard case .ok = status else {
            return XCTFail("超时后加长重试应当通过，实际 \(status)")
        }
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.9,
                             "应当等完第二轮 1 秒的慢响应，而不是复用第一轮的超时结果")
        XCTAssertTrue(status.isHealthy)
    }

    func testTimeoutAfterRetryStaysTimeoutAndIsNotFailure() async {
        let checker = SourceHealthChecker(client: makeClient(SlowURLProtocol.self))

        let status = await checker.check(makeSource(), timeout: 0.2, retryTimeout: 0.2)

        XCTAssertEqual(status, .timeout)
        XCTAssertFalse(status.isDefiniteFailure, "两次都超时也只能算没测出来，不能算失效")
    }

    func testHTTPErrorIsReportedAsFailure() async {
        // 没有登记路由 → 桩返回 404
        StaticURLProtocol.routes = [:]
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeSource())

        guard case .failed(let message) = status else {
            return XCTFail("404 应当算失败，实际 \(status)")
        }
        XCTAssertTrue(message.contains("404"), "错误里要带状态码，实际：\(message)")
    }

    func testDisabledSourceIsSkippedNotFailed() async {
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))

        let status = await checker.check(makeSource(enabled: false))

        XCTAssertEqual(status, .skipped("已关闭"))
        XCTAssertFalse(status.isHealthy)
    }

    func testSourceWithoutSearchRuleIsSkipped() async {
        let checker = SourceHealthChecker(client: makeClient(StaticURLProtocol.self))
        let source = LegadoSource(
            id: "s2",
            name: "无搜索",
            url: "https://example.com",
            searchUrl: "",
            ruleSearch: SearchRule()
        )

        let status = await checker.check(source)

        XCTAssertEqual(status, .skipped("无搜索规则"))
    }

    func testLabelIsShortEnoughForList() {
        XCTAssertEqual(SourceHealthStatus.ok(milliseconds: 128, sampleCount: 3).label, "128ms · 3 条")
        XCTAssertEqual(SourceHealthStatus.okDeep(milliseconds: 128, sampleCount: 3,
                                                  checkedSamples: 2, chapterCount: 8).label,
                       "128ms · 3 条 · 抽查 2 本 · 8 章")
        XCTAssertEqual(SourceHealthStatus.partial("目录为空").label, "部分可用")
        XCTAssertEqual(SourceHealthStatus.timeout.label, "超时（可重试）")
        XCTAssertEqual(SourceHealthStatus.failed("x").label, "失败")
        XCTAssertEqual(SourceHealthStatus.skipped("已关闭").label, "已关闭")
    }
}

// MARK: - 桩

final class StaticURLProtocol: URLProtocol {
    static var routes: [String: (Int, Data, String?)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let route = Self.routes[path] ?? (404, Data("not found".utf8), "text/plain")
        var headers: [String: String] = [:]
        if let type = route.2 { headers["Content-Type"] = type }
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

final class SlowURLProtocol: URLProtocol {
    private let lock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 不阻塞 URLSession 的线程；1 秒后再回包，这样第一轮超时取消后，
        // 第二轮还能正常拿到响应，测试的是「重试」而不是线程被卡住。
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stopped = self.stopped
            self.lock.unlock()
            guard !stopped, let url = self.request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else {
                return
            }
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data("<html></html>".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}
