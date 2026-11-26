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

    func testSlowSourceTimesOutInsteadOfWaitingRequestTimeout() async {
        let checker = SourceHealthChecker(client: makeClient(SlowURLProtocol.self))
        let started = Date()

        let status = await checker.check(makeSource(), timeout: 0.2)

        XCTAssertEqual(status, .timeout)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3,
                          "体检必须按自己的超时返回，不能等 URLSession 的 20 秒")
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
        XCTAssertEqual(SourceHealthStatus.timeout.label, "超时")
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
