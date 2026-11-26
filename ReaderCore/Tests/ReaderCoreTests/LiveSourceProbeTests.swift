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
        for target in targets {
            guard case .legado(let source) = target else {
                XCTFail("\(target.name) 不是 legado 源"); continue
            }

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
}
