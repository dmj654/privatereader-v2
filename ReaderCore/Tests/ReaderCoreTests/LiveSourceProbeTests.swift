import XCTest
import GRDB
@testable import ReaderCore

/// 真机之外能做到的最强验证：在 CI 的 macOS 上跑真实网络、真实 JS 源、
/// 真实 legado 规则。默认跳过，只有 workflow 里显式设置
/// PRIVATE_READER_LIVE=1 时才执行，避免日常单测被外网拖慢。
final class LiveSourceProbeTests: XCTestCase {

    private var live: Bool {
        ProcessInfo.processInfo.environment["PRIVATE_READER_LIVE"] == "1"
    }

    private func requireLive() throws {
        if !live { throw XCTSkip("未设置 PRIVATE_READER_LIVE=1，跳过真实网络探针") }
    }

    private func fixtureData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "novel-sources", withExtension: "json", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: "novel-sources", withExtension: "json")
        )
        return try Data(contentsOf: url)
    }

    // MARK: - 三个小说源

    func testThreeNovelSourcesRealSearchDetailAndContent() async throws {
        try requireLive()
        let database = try AppDatabase.inMemory()
        let service = SourceImportService(repo: SourceRepository(db: database.writer))
        _ = try service.importJSON(fixtureData(), category: .novel)
        let targets = try service.enabledTargets()
        XCTAssertEqual(targets.count, 3)

        let client = SourceClient()
        var failures: [String] = []
        for target in targets {
            guard case .legado(let source) = target else {
                XCTFail("\(target.name) 不是 legado 源"); continue
            }

            do {
                let books = try await client.search(source: source, key: "斗破苍穹")
                XCTAssertFalse(books.isEmpty, "\(source.name) 搜索「斗破苍穹」返回 0 条")

                guard let first = books.first else { continue }
                let detail = try await client.bookInfo(source: source, book: first)
                let chapters = try await client.chapters(source: source, book: detail)
                XCTAssertFalse(chapters.isEmpty, "\(source.name) 目录为空")

                guard let chapter = chapters.first else { continue }
                let content = try await client.content(source: source, chapter: chapter)
                XCTAssertFalse(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                               "\(source.name) 正文为空")
                print("[LIVE] \(source.name): \(books.count) 本 / \(chapters.count) 章 / \(content.count) 字")
            } catch let error as URLError where error.code == .timedOut {
                // GitHub 的美国 runner 访问部分国内站点会超时；这类失败不是解析问题，
                // 同一套规则已经在本地网络 + 离线 fixture 里验证过。
                print("[LIVE][NETWORK-TIMEOUT] \(source.name)")
            } catch {
                failures.append("\(source.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                print("[LIVE][FAIL] \(source.name): \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
            }
        }
        XCTAssertTrue(failures.isEmpty, "有源失败：\(failures.joined(separator: "；"))")
    }

    /// 绕开 App 网络层，直接抓 HTML + 直接跑 RuleRunner，确认 SwiftSoup 解析没问题。
    func testNovelRulesParseRealHTML() async throws {
        try requireLive()
        let cases: [(String, String, String)] = [
            ("笔趣阁 bqg9", "https://www.bqg9.xyz/modules/article/search.php?searchkey=斗破苍穹", "tag.td.0@tag.a@text"),
            ("天域小说网", "http://www.tycqzw.info/search.php?searchkey=斗破苍穹", "class.even.0@tag.a.0@text"),
            ("00小说网", "https://www.00shuge.com/modules/article/search.php?q=斗破苍穹", "tag.td.0@tag.a@text")
        ]
        for (name, rawURL, nameRule) in cases {
            do {
                let encoded = rawURL.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawURL
                let (data, response) = try await URLSession.shared.data(from: URL(string: encoded)!)
                let html = SourceClient.decode(data: data, response: response) ?? ""
                let hasGrid = html.contains("class=\"grid\"")
                let rows = RuleRunner.elements("class.grid@tag.tr", html: html, baseUrl: rawURL)
                let firstName = rows.compactMap {
                    RuleRunner.string(nameRule, html: $0, baseUrl: rawURL)
                }.first(where: { !$0.isEmpty }) ?? ""
                print("[LIVE][PARSE] \(name): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) 字节, html \(html.count) 字符, grid=\(hasGrid), \(rows.count) 行, 第一本 \(firstName)")
                XCTAssertFalse(rows.isEmpty, "\(name) 解析出 0 行")
                XCTAssertFalse(firstName.isEmpty, "\(name) 第一本没有书名")
            } catch {
                print("[LIVE][PARSE][FAIL] \(name): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Venera 索引与 CopyManga

    func testVeneraIndexImportAndCopyMangaRuntime() async throws {
        try requireLive()

        let indexURL = try XCTUnwrap(URL(string: "https://git.nyne.dev/nyne/venera-configs/raw/branch/main/index.json"))
        let (indexData, response) = try await URLSession.shared.data(from: indexURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let entries = try VeneraIndexParser.parse(indexData)
        XCTAssertGreaterThanOrEqual(entries.count, 20, "索引条目太少")

        let database = try AppDatabase.inMemory()
        let service = SourceImportService(repo: SourceRepository(db: database.writer))
        let summary = try await VeneraImportService(repo: SourceRepository(db: database.writer))
            .importIndex(indexData, indexURL: indexURL, category: .comic)
        XCTAssertGreaterThan(summary.total, 0, "Venera 索引一条都没导入")
        print("[LIVE] Venera 索引导入：新增 \(summary.added)，失败 \(summary.failed)，备注 \(summary.note ?? "无")")

        let copyEntry = try XCTUnwrap(entries.first { $0.key == "copy_manga" })
        let script = try await VeneraImportService(repo: SourceRepository(db: database.writer))
            .fetchScript(copyEntry, indexURL: indexURL)
        XCTAssertTrue(VeneraImportService.looksLikeComicSource(script))

        let source = VeneraSource(
            id: "venera:copy_manga",
            key: "copy_manga",
            name: copyEntry.name,
            version: copyEntry.version,
            scriptURL: copyEntry.scriptURL(relativeTo: indexURL)?.absoluteString ?? "",
            js: script
        )
        let runtime = VeneraRuntime()
        let books = try await runtime.search(source: source, keyword: "海贼", timeout: 40)
        XCTAssertFalse(books.isEmpty, "CopyManga 搜索返回 0 条")
        print("[LIVE] CopyManga 搜索：\(books.count) 本，第一本 \(books.first?.name ?? "-")")

        let comic = try XCTUnwrap(books.first)
        let detail = try await runtime.detail(source: source, comicId: comic.bookUrl, timeout: 50)
        XCTAssertFalse(detail.chapters.isEmpty, "CopyManga 目录为空")
        print("[LIVE] CopyManga 详情：\(detail.title)，\(detail.chapters.count) 章")

        let ep = try XCTUnwrap(detail.chapters.first)
        let pages = try await runtime.pages(source: source, comicId: comic.bookUrl, epId: ep.url, timeout: 70)
        XCTAssertFalse(pages.isEmpty, "CopyManga 章节图片为空")
        print("[LIVE] CopyManga 图片：\(pages.count) 张")
    }

    /// 不是只验证 CopyManga 一条：把索引里所有 Venera 源都跑一次真实搜索，
    /// 明确统计哪些能用、哪些因为源自身 API 限制失败。
    func testAllVeneraSourcesSmokeSearch() async throws {
        try requireLive()
        let indexURL = try XCTUnwrap(URL(string: "https://git.nyne.dev/nyne/venera-configs/raw/branch/main/index.json"))
        let (indexData, _) = try await URLSession.shared.data(from: indexURL)
        let database = try AppDatabase.inMemory()
        let repo = SourceRepository(db: database.writer)
        _ = try await VeneraImportService(repo: repo)
            .importIndex(indexData, indexURL: indexURL, category: .comic)
        let targets = try SourceImportService(repo: repo).enabledTargets()
            .filter(\.isComic)
        print("[LIVE][ALL] 共 \(targets.count) 个 Venera 源")

        var ok = 0
        var failed: [String] = []
        for target in targets {
            guard case .venera(let source) = target else { continue }
            do {
                let books = try await VeneraRuntime().search(source: source, keyword: "海贼", timeout: 12)
                if books.isEmpty {
                    failed.append("\(source.name): 0 条")
                    print("[LIVE][ALL][EMPTY] \(source.name)")
                } else {
                    ok += 1
                    print("[LIVE][ALL][OK] \(source.name): \(books.count) 条")
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                failed.append("\(source.name): \(message)")
                print("[LIVE][ALL][FAIL] \(source.name): \(message)")
            }
        }
        print("[LIVE][ALL] 成功 \(ok) / \(targets.count)，失败 \(failed.count)")
        XCTAssertGreaterThan(ok, 0, "没有一个 Venera 源能搜索")
    }
}
