import XCTest
import CoreText
@testable import ReaderCore

final class PaginatorTests: XCTestCase {
    private func makeAttributed(_ text: String, fontSize: Double = 17.5) -> NSAttributedString {
        let style = ReaderStyle(fontSize: fontSize)
        let color = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        return NSAttributedString(string: text, attributes: style.attributes(color: color))
    }

    func testCoversWholeTextWithoutGaps() {
        let text = String(repeating: "这是一段用来测试分页的正文内容，需要足够长才能切出多页。\n", count: 60)
        let attributed = makeAttributed(text)
        let ranges = Paginator.pageRanges(attributedString: attributed, pageSize: CGSize(width: 320, height: 480))

        XCTAssertGreaterThan(ranges.count, 1)

        var expectedLocation = 0
        for range in ranges {
            XCTAssertEqual(range.location, expectedLocation, "页与页之间必须无缝")
            XCTAssertGreaterThan(range.length, 0, "不允许空页")
            expectedLocation += range.length
        }
        XCTAssertEqual(expectedLocation, attributed.length, "必须覆盖全文")
    }

    func testLargerFontProducesMorePages() {
        let text = String(repeating: "分页密度会随字号变化。\n", count: 40)
        let size = CGSize(width: 320, height: 480)

        let small = Paginator.pageCount(attributedString: makeAttributed(text, fontSize: 14), pageSize: size)
        let large = Paginator.pageCount(attributedString: makeAttributed(text, fontSize: 22), pageSize: size)

        XCTAssertGreaterThan(large, small)
    }

    func testEmptyInputReturnsNoPages() {
        let attributed = makeAttributed("")
        XCTAssertTrue(Paginator.pageRanges(attributedString: attributed, pageSize: CGSize(width: 320, height: 480)).isEmpty)
    }

    func testZeroSizeReturnsNoPages() {
        let attributed = makeAttributed("有内容")
        XCTAssertTrue(Paginator.pageRanges(attributedString: attributed, pageSize: .zero).isEmpty)
    }
}

final class ProgressMathTests: XCTestCase {
    func testPercentAcrossChapters() {
        XCTAssertEqual(ProgressMath.percent(chapterIndex: 0, chapterCount: 10, chapterProgress: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(ProgressMath.percent(chapterIndex: 5, chapterCount: 10, chapterProgress: 0.5), 0.55, accuracy: 0.0001)
        XCTAssertEqual(ProgressMath.percent(chapterIndex: 9, chapterCount: 10, chapterProgress: 1), 1, accuracy: 0.0001)
    }

    func testClampsOutOfRange() {
        XCTAssertEqual(ProgressMath.percent(chapterIndex: 20, chapterCount: 10, chapterProgress: 2), 1, accuracy: 0.0001)
        XCTAssertEqual(ProgressMath.percent(chapterIndex: -3, chapterCount: 10, chapterProgress: -1), 0, accuracy: 0.0001)
    }

    func testZeroChapterCountIsSafe() {
        XCTAssertEqual(ProgressMath.percent(chapterIndex: 3, chapterCount: 0, chapterProgress: 0.5), 0)
        XCTAssertEqual(ProgressMath.chapterIndex(fromPercent: 0.5, chapterCount: 0), 0)
    }

    func testChapterIndexFromPercent() {
        XCTAssertEqual(ProgressMath.chapterIndex(fromPercent: 0, chapterCount: 10), 0)
        XCTAssertEqual(ProgressMath.chapterIndex(fromPercent: 0.55, chapterCount: 10), 5)
        XCTAssertEqual(ProgressMath.chapterIndex(fromPercent: 1, chapterCount: 10), 9)
    }
}

final class ReaderStyleTests: XCTestCase {
    func testNormalizedBodyCollapsesBlankLinesWithoutPadding() {
        let raw = "第一段\n\n\n第二段\r\n  \n第三段"
        let normalized = ReaderStyle.normalizedBody(raw)
        let lines = normalized.components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        // 缩进由 paragraphStyle 负责，正文里不能再塞全角空格，否则缩进会变成四格
        XCTAssertEqual(lines[0], "第一段")
        XCTAssertEqual(lines[1], "第二段")
        XCTAssertFalse(normalized.contains("　　"))
    }

    func testIndentWidthFollowsFontSize() {
        XCTAssertEqual(ReaderStyle(fontSize: 20, indentFirstLine: true).indentWidth, 40, accuracy: 0.01)
        XCTAssertEqual(ReaderStyle(fontSize: 20, indentFirstLine: false).indentWidth, 0, accuracy: 0.01)
    }

    func testParagraphStyleReflectsIndentAndAlignment() throws {
        let indented = ReaderStyle(fontSize: 18, indentFirstLine: true, justified: true)
        let attributes = indented.attributes(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let paragraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(paragraph.firstLineHeadIndent, 36, accuracy: 0.5)
        XCTAssertEqual(paragraph.alignment, .justified)

        let plain = ReaderStyle(fontSize: 18, indentFirstLine: false)
        let plainAttributes = plain.attributes(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        let plainParagraph = try XCTUnwrap(plainAttributes[.paragraphStyle] as? NSParagraphStyle)
        XCTAssertEqual(plainParagraph.firstLineHeadIndent, 0, accuracy: 0.01)
    }

    func testLetterSpacingBecomesKern() throws {
        let spaced = ReaderStyle(letterSpacing: 1.2)
        let attributes = spaced.attributes(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(try XCTUnwrap(attributes[.kern] as? Double), 1.2, accuracy: 0.001)

        let normal = ReaderStyle(letterSpacing: 0)
        XCTAssertNil(normal.attributes(color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))[.kern])
    }

    /// 只验自己写的逻辑：候选名有没有声明、系统字体字号对不对。
    ///
    /// **不要**在 CI 里请求宋体 / 楷体：macOS 对未安装的字体会走按需下载，
    /// 无窗口进程会卡死在那一步（本项目 CI 卡 29 分钟就是这条测试导致的）。
    /// 字体是否真的存在是环境问题，只能在真机上确认。
    func testFontFamilyCandidatesAreDeclared() {
        XCTAssertTrue(ReaderFontFamily.system.candidates.isEmpty, "系统字体不需要候选名")
        XCTAssertFalse(ReaderFontFamily.songti.candidates.isEmpty)
        XCTAssertFalse(ReaderFontFamily.kaiti.candidates.isEmpty)
    }

    func testSystemFontKeepsRequestedSize() {
        let style = ReaderStyle(fontSize: 19, fontFamily: .system)
        XCTAssertEqual(CTFontGetSize(style.font()), 19, accuracy: 0.01)
    }

    func testEveryFamilyHasATitle() {
        for family in ReaderFontFamily.allCases {
            XCTAssertFalse(family.title.isEmpty)
        }
    }

    func testAttributesCarryFontAndColor() {
        let style = ReaderStyle(fontSize: 20)
        let color = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
        let attributes = style.attributes(color: color)

        guard let anyFont = attributes[.font] else {
            return XCTFail("缺少字体属性")
        }
        // CTFont 是 CoreFoundation 类型，as? 会被判为恒成立，这里直接强制转型
        let font = anyFont as! CTFont
        XCTAssertEqual(CTFontGetSize(font), 20, accuracy: 0.01)
        XCTAssertNotNil(attributes[.paragraphStyle])
    }
}

final class ChapterProviderTests: XCTestCase {
    private var root: URL!
    private var database: AppDatabase!
    private var library: LibraryService!
    private var provider: ChapterProvider!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = SandboxPaths(root: root)
        try paths.prepare()
        database = try AppDatabase.inMemory()
        library = LibraryService(books: BookRepository(db: database.writer), paths: paths)
        provider = ChapterProvider(paths: paths)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
        provider = nil
        library = nil
        database = nil
    }

    func testLoadsAndCachesChapters() throws {
        let url = try ImportFixtures.makeTxt(chapterCount: 5)
        let book = try library.save(content: .novel(try TxtParser.parse(url: url)), originalURL: url)

        XCTAssertNil(provider.cachedChapterCount(bookId: book.id))

        let chapters = try provider.chapters(for: book)
        XCTAssertEqual(chapters.count, 5)
        XCTAssertEqual(provider.cachedChapterCount(bookId: book.id), 5)

        let again = try provider.chapters(for: book)
        XCTAssertEqual(again.count, 5)
    }

    func testInvalidateDropsCache() throws {
        let url = try ImportFixtures.makeTxt(chapterCount: 3)
        let book = try library.save(content: .novel(try TxtParser.parse(url: url)), originalURL: url)
        _ = try provider.chapters(for: book)

        provider.invalidate(bookId: book.id)
        XCTAssertNil(provider.cachedChapterCount(bookId: book.id))
    }

    func testMissingFileThrows() throws {
        let book = Book(id: "ghost", type: .novel, origin: .local, title: "不存在", filePath: "Books/ghost/source.txt")
        XCTAssertThrowsError(try provider.chapters(for: book))
    }

    func testSavedBookFilePathPointsToRealFile() throws {
        let url = try ImportFixtures.makeTxt(chapterCount: 2)
        let book = try library.save(content: .novel(try TxtParser.parse(url: url)), originalURL: url)

        let filePath = try XCTUnwrap(book.filePath)
        let absolute = root.appendingPathComponent(filePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute.path),
                      "filePath 必须指向真实存在的文件，否则阅读器打不开")
    }
}
